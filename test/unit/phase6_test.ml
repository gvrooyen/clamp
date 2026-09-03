let epsilon = 1e-12

let float label expected actual =
  Alcotest.(check (float epsilon)) label expected actual

let scoring () =
  let module R = Clamp.Retrieval.For_test in
  float "semantic lower clamp" 0. (R.semantic (-2.));
  float "semantic lower boundary" 0. (R.semantic (-1.));
  float "semantic midpoint" 0.5 (R.semantic 0.);
  float "semantic upper boundary" 1. (R.semantic 1.);
  float "semantic upper clamp" 1. (R.semantic 2.);
  float "missing timestamp" 0. (R.recency ~now:1000. None);
  float "zero age" 1. (R.recency ~now:1000. (Some 1000.));
  float "future clamps to zero age" 1. (R.recency ~now:1000. (Some 2000.));
  float "thirty-day half life" 0.5
    (R.recency ~now:(30. *. 86400.) (Some 0.));
  float "frequency zero" 0. (R.frequency 0L);
  float "frequency logarithmic" (log 2. /. log 101.) (R.frequency 1L);
  float "frequency saturation" 1. (R.frequency 100L);
  float "frequency upper clamp" 1. (R.frequency 10000L);
  float "weighted score" 0.65
    (R.score ~semantic:0.5 ~recency:1. ~frequency:1.)

let timestamps_and_ties () =
  let module R = Clamp.Retrieval.For_test in
  float "access first" 3.
    (R.timestamp ~last_accessed:(Some 3.) ~generated:(Some 2.) ~indexed:1.);
  float "generated fallback" 2.
    (R.timestamp ~last_accessed:None ~generated:(Some 2.) ~indexed:1.);
  float "indexed fallback" 1.
    (R.timestamp ~last_accessed:None ~generated:None ~indexed:1.);
  let item id score : Clamp.Retrieval.result =
    { id; concept_type = "fact"; title = None; description = None;
      status = "stable"; verified_tier = "unverified"; asserted_by = None;
      task_state = None; semantic = 0.; recency = 0.; frequency = 0.;
      score; snippet = "" }
  in
  let sorted =
    List.sort R.compare_results [ item "facts/z" 0.5; item "facts/a" 0.5;
                                  item "facts/m" 0.7 ]
    |> List.map (fun (item : Clamp.Retrieval.result) -> item.id)
  in
  Alcotest.(check (list string)) "score then path tie" [ "facts/m"; "facts/a"; "facts/z" ] sorted

let visibility () =
  let module R = Clamp.Retrieval.For_test in
  let normal = Clamp.Retrieval.normal_history in
  let visible ?(history = normal) ?(status = "stable") ?stale_after ?task_state () =
    R.visible ~history ~today:"2026-08-24" ~status ~stale_after ~task_state
  in
  Alcotest.(check bool) "future stale date visible" true
    (visible ~stale_after:"2026-08-25" ());
  Alcotest.(check bool) "Johannesburg date boundary hidden" false
    (visible ~stale_after:"2026-08-24" ());
  Alcotest.(check bool) "deprecated hidden" false (visible ~status:"deprecated" ());
  Alcotest.(check bool) "done hidden" false (visible ~task_state:"done" ());
  Alcotest.(check bool) "cancelled hidden" false (visible ~task_state:"cancelled" ());
  Alcotest.(check bool) "draft visible" true (visible ~status:"draft" ());
  let stale = { normal with include_stale = true }
  and deprecated = { normal with include_deprecated = true }
  and closed = { normal with include_closed_tasks = true } in
  Alcotest.(check bool) "stale flag independent" true
    (visible ~history:stale ~stale_after:"2026-08-24" ());
  Alcotest.(check bool) "stale flag does not include deprecated" false
    (visible ~history:stale ~status:"deprecated" ());
  Alcotest.(check bool) "deprecated flag independent" true
    (visible ~history:deprecated ~status:"deprecated" ());
  Alcotest.(check bool) "closed flag independent" true
    (visible ~history:closed ~task_state:"done" ())

let snippets () =
  let module R = Clamp.Retrieval.For_test in
  Alcotest.(check string) "whitespace normalization" "one two three"
    (R.snippet " one\n\ttwo   three ");
  let value = R.snippet (String.make 300 'x') in
  Alcotest.(check int) "fixed byte length" 240 (String.length value);
  Alcotest.(check bool) "explicit marker" true (String.ends_with ~suffix:"…" value)

let human_results () =
  let item id title score semantic recency frequency : Clamp.Retrieval.result =
    { id; concept_type = "fact"; title; description = None; status = "stable";
      verified_tier = "unverified"; asserted_by = Some "human:test";
      task_state = None; semantic; recency; frequency; score;
      snippet = "The concise answer." }
  in
  let first = item "facts/first" (Some "First fact") 0.7974606 0.8609889
      0.9738422 0.
  and second = item "facts/second" None 0.730826 0.7657968 0.9738422 0. in
  Alcotest.(check string) "empty"
    "No indexed results." (Clamp.Retrieval.human_results ~verbose:false []);
  Alcotest.(check string) "concise top match"
    "The concise answer.\n\nSource: First fact (facts/first)\nStatus: stable · verification: unverified"
    (Clamp.Retrieval.human_results ~verbose:false [ first; second ]);
  Alcotest.(check string) "verbose ranked matches"
    "1. First fact\n   The concise answer.\n   Source: facts/first · fact\n   Status: stable · verification: unverified\n   Ranking score: 0.7975 (semantic 0.8610 · recency 0.9738 · frequency 0.0000)\n\n2. facts/second\n   The concise answer.\n   Source: facts/second · fact\n   Status: stable · verification: unverified\n   Ranking score: 0.7308 (semantic 0.7658 · recency 0.9738 · frequency 0.0000)"
    (Clamp.Retrieval.human_results ~verbose:true [ first; second ])

let config_document ~candidate ~result ~half_life ~saturation =
  Printf.sprintf
    "schema_version: 1\nsource_repository: github.com/gvrooyen/clamp\ntimezone: Africa/Johannesburg\ninferred_writes: confirm\nembedding:\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n  model: openai/text-embedding-3-small\n  dimensions: 1536\n  max_input_bytes: 8000\n  provider_order: [openai]\n  allow_fallbacks: false\n  data_collection: deny\nretrieval:\n  candidate_limit: %d\n  result_limit: %d\n  semantic_weight: 0.70\n  recency_weight: 0.20\n  frequency_weight: 0.10\n  recency_half_life_days: %d\n  frequency_saturation_count: %d\n"
    candidate result half_life saturation

let configured_defaults () =
  let document = config_document ~candidate:100 ~result:10 ~half_life:30
      ~saturation:100 in
  match Clamp.Config.retrieval document with
  | Error failure -> Alcotest.failf "retrieval config rejected: %s" failure
  | Ok config ->
      Alcotest.(check int) "candidate K" 100 config.candidate_limit;
      Alcotest.(check int) "result N" 10 config.result_limit;
      float "semantic weight" 0.70 config.semantic_weight;
      float "recency weight" 0.20 config.recency_weight;
      float "frequency weight" 0.10 config.frequency_weight;
      Alcotest.(check int) "half life" 30 config.recency_half_life_days;
      Alcotest.(check int) "frequency saturation" 100
        config.frequency_saturation_count

let configured_bounds () =
  let valid candidate result half_life saturation =
    Clamp.Config.validate
      (config_document ~candidate ~result ~half_life ~saturation)
    = Ok ()
  in
  Alcotest.(check bool) "lower bounds" true (valid 1 1 1 1);
  Alcotest.(check bool) "caps" true
    (valid Clamp.Config.maximum_candidate_limit
       Clamp.Config.maximum_result_limit
       Clamp.Config.maximum_recency_half_life_days
       Clamp.Config.maximum_frequency_saturation_count);
  Alcotest.(check bool) "candidate cap + 1" false
    (valid (Clamp.Config.maximum_candidate_limit + 1) 1 1 1);
  Alcotest.(check bool) "result cap + 1" false
    (valid Clamp.Config.maximum_candidate_limit
       (Clamp.Config.maximum_result_limit + 1) 1 1);
  Alcotest.(check bool) "half-life cap + 1" false
    (valid 1 1 (Clamp.Config.maximum_recency_half_life_days + 1) 1);
  Alcotest.(check bool) "saturation cap + 1" false
    (valid 1 1 1 (Clamp.Config.maximum_frequency_saturation_count + 1));
  Alcotest.(check bool) "result exceeds candidate" false (valid 9 10 30 100)

let () =
  Alcotest.run "Phase 6 retrieval scoring"
    [ ("scoring", [ Alcotest.test_case "normalization and curves" `Quick scoring;
                     Alcotest.test_case "fallbacks and deterministic ties" `Quick
                       timestamps_and_ties;
                     Alcotest.test_case "Johannesburg visibility" `Quick visibility;
                     Alcotest.test_case "fixed snippets" `Quick snippets;
                     Alcotest.test_case "human result rendering" `Quick human_results;
                     Alcotest.test_case "versioned defaults" `Quick
                       configured_defaults;
                     Alcotest.test_case "versioned bounds" `Quick
                       configured_bounds ]) ]
