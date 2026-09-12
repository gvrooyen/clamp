let parse_yaml input =
  match Clamp.Exact_yaml.parse input with
  | Ok value -> value
  | Error message -> Alcotest.fail message

let parse_frontmatter input =
  match Clamp.Frontmatter.parse input with
  | Ok value -> value
  | Error message -> Alcotest.fail message

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let project_root =
  Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:"../.."

let write path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
      output_string channel contents)

let rec remove path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
  | _ -> Unix.unlink path

let with_bundle callback =
  let root = Filename.temp_dir "clamp-phase1" "bundle" in
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let config =
        let channel = open_in_bin (Filename.concat project_root "clamp.yaml") in
        Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
            really_input_string channel (in_channel_length channel))
      in
      write (Filename.concat root "clamp.yaml") config;
      Unix.mkdir (Filename.concat root "knowledge") 0o700;
      write (Filename.concat root "TODO.md")
        (Clamp.Local.render_todo ~now:(Unix.gettimeofday ()) []);
      callback root)

let diagnostic_codes result =
  List.map (fun diagnostic -> diagnostic.Clamp.Diagnostic.code) result.Clamp.Bundle.diagnostics

let rec semantic_equal left right =
  match (left, right) with
  | Clamp.Exact_yaml.Scalar (Clamp.Exact_yaml.Null, _),
    Clamp.Exact_yaml.Scalar (Clamp.Exact_yaml.Null, _) -> true
  | Clamp.Exact_yaml.Scalar (Clamp.Exact_yaml.Bool, left),
    Clamp.Exact_yaml.Scalar (Clamp.Exact_yaml.Bool, right) ->
      let truth value =
        List.mem (String.lowercase_ascii value) [ "true"; "yes"; "y"; "on" ]
      in
      truth left = truth right
  | Clamp.Exact_yaml.Scalar (left_kind, left_value),
    Clamp.Exact_yaml.Scalar (right_kind, right_value) ->
      left_kind = right_kind && left_value = right_value
  | Clamp.Exact_yaml.Seq left, Clamp.Exact_yaml.Seq right ->
      List.length left = List.length right
      && List.for_all2 semantic_equal left right
  | Clamp.Exact_yaml.Map left, Clamp.Exact_yaml.Map right ->
      let sort = List.sort (fun (a, _) (b, _) -> String.compare a b) in
      let left = sort left and right = sort right in
      List.length left = List.length right
      && List.for_all2
           (fun (left_key, left_value) (right_key, right_value) ->
             left_key = right_key && semantic_equal left_value right_value)
           left right
  | _ -> false

let exact_yaml_roundtrip () =
  let source =
    "integer: 900719925474099312345\nnegative: -9007199254740993\nfloat: 1.25e3\nhex: 0xFFFFFFFFFFFFFFFF\nhuge_float: 1e99999\ninfinity: .inf\nboolean: true\nlegacy_boolean: yes\nnull_value: null\nempty_null:\nnested: [false, {value: text}]\nmultiline: |\n  first\n  second\n"
  in
  let parsed = parse_yaml source in
  let serialized = Clamp.Exact_yaml.to_string parsed in
  Alcotest.(check bool) "semantic value" true
    (semantic_equal parsed (parse_yaml serialized));
  Alcotest.(check bool) "large integer exact" true
    (contains serialized "900719925474099312345");
  Alcotest.(check string) "deterministic" serialized
    (Clamp.Exact_yaml.to_string parsed)

let empty_collection_roundtrip () =
  [ "{}\n"; "[]\n"; "empty_map: {}\nempty_sequence: []\nnested: [{}, []]\n";
    "clamp: {asserted_by: human:x, task: {state: todo, depends_on: []}}\ntype: task\n" ]
  |> List.iter (fun source ->
         let first = parse_yaml source |> Clamp.Exact_yaml.to_string in
         Alcotest.(check bool) "root LF" true
           (String.ends_with ~suffix:"\n" first);
         let second = parse_yaml first |> Clamp.Exact_yaml.to_string in
         Alcotest.(check string) source first second);
  [ "---\n{}\n---\nbody\n";
    "---\ntype: task\nclamp: {asserted_by: human:x, task: {state: todo, depends_on: []}}\nunknown: {}\n---\nbody\n" ]
  |> List.iter (fun source ->
         let first = parse_frontmatter source |> Clamp.Frontmatter.serialize in
         let second = parse_frontmatter first |> Clamp.Frontmatter.serialize in
         Alcotest.(check string) "frontmatter empty collection fixed point" first
           second)

let yaml_style_loss () =
  let parsed = parse_yaml "# comment\nsingle: 'value'\nliteral: |\n  first\n  second\n" in
  let output = Clamp.Exact_yaml.to_string parsed in
  Alcotest.(check bool) "comment removed" false (String.contains output '#');
  Alcotest.(check bool) "single quote removed" false (String.contains output '\'');
  Alcotest.(check bool) "values preserved" true
    (semantic_equal parsed (parse_yaml output))

let yaml_rejections () =
  [ "a: 1\na: 2\n"; "a: &anchor value\nb: *anchor\n";
    "&key anchored: value\n";
    "a: !custom value\n"; "unknown: !custom {x: y}\n";
    "[one, two]: value\n"; "1: value\n";
    "a: value\n---\nb: other\n"; "a: value\n---\nmalformed: [\n" ]
  |> List.iter (fun input ->
         Alcotest.(check bool) input true
           (Result.is_error (Clamp.Exact_yaml.parse input)))

let explicit_yaml_tags () =
  let source =
    "integer: !!int 1\nfloat: !!float 1\nboolean: !!bool true\nnull_value: !!null null\nsequence: !!seq [one]\nmapping: !!map {key: value}\n"
  in
  let first = parse_yaml source |> Clamp.Exact_yaml.to_string in
  let second = parse_yaml first |> Clamp.Exact_yaml.to_string in
  Alcotest.(check string) "serialization fixed point" first second;
  Alcotest.(check bool) "float remains tagged" true
    (contains first "!!float 1");
  [ "value: !!float 1example\n"; "value: !!int 0xZZ\n" ]
  |> List.iter (fun input ->
         Alcotest.(check bool) input true
           (Result.is_error (Clamp.Exact_yaml.parse input)));
  let plain = parse_yaml "word: 1example\ntimestamp: 2026-08-06T10:00:00.1Z\n" in
  Alcotest.(check bool) "digit-prefixed word remains string" true
    (Clamp.Exact_yaml.find "word" plain
    = Some (Clamp.Exact_yaml.Scalar (Clamp.Exact_yaml.String, "1example")));
  Alcotest.(check bool) "fractional RFC3339 remains string" true
    (Clamp.Exact_yaml.find "timestamp" plain
    = Some
        (Clamp.Exact_yaml.Scalar
           (Clamp.Exact_yaml.String, "2026-08-06T10:00:00.1Z")))

let yaml_limits () =
  let nested depth =
    String.make depth '[' ^ "value" ^ String.make depth ']' ^ "\n"
  in
  Alcotest.(check bool) "depth at ceiling" true
    (Result.is_ok (Clamp.Exact_yaml.parse (nested 63)));
  Alcotest.(check (result reject string)) "depth above ceiling"
    (Error "YAML depth limit exceeded")
    (Clamp.Exact_yaml.parse (nested 65));
  let nodes count =
    let buffer = Buffer.create (count * 2 + 3) in
    Buffer.add_char buffer '[';
    for index = 1 to count do
      if index > 1 then Buffer.add_char buffer ',';
      Buffer.add_char buffer '~'
    done;
    Buffer.add_string buffer "]\n";
    Buffer.contents buffer
  in
  Alcotest.(check bool) "node ceiling" true
    (Result.is_ok (Clamp.Exact_yaml.parse (nodes 99_999)));
  Alcotest.(check (result reject string)) "node above ceiling"
    (Error "YAML node limit exceeded")
    (Clamp.Exact_yaml.parse (nodes 100_000))

let frontmatter_contract () =
  let parsed =
    parse_frontmatter
      "---\r\ntype: fact\r\nclamp: {asserted_by: amp/agent}\r\n---\r\n\r\nBody\r\n\r\n"
  in
  let output = Clamp.Frontmatter.serialize parsed in
  Alcotest.(check bool) "LF only" false (String.contains output '\r');
  Alcotest.(check bool) "canonical separator" true
    (contains output "---\n\nBody\n");
  Alcotest.(check bool) "reparse" true
    (Result.is_ok (Clamp.Frontmatter.parse output));
  [ "body only"; "---\ntype: fact\n"; "---\n- item\n---\nbody";
    "---\na: 1\na: 2\n---\nbody";
    "---\ntype: fact\n---\n\255invalid" ]
  |> List.iter (fun input ->
         Alcotest.(check bool) input true
           (Result.is_error (Clamp.Frontmatter.parse input)));
  Alcotest.(check bool) "closing delimiter at EOF" true
    (Result.is_ok
       (Clamp.Frontmatter.parse
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---"))

let base_metadata extra =
  parse_yaml
    ("type: fact\nclamp: {asserted_by: human:owner}\n"
    ^ extra)

let fields_table () =
  let cases =
    [ ("title shape", "title: [bad]\n");
      ("tags shape", "tags: [valid, 3]\n");
      ("status enum", "status: old\n");
      ("date", "stale_after: 2025-02-29\n");
      ("generated timestamp", "generated: {by: amp/agent, at: 2026-08-06T25:00:00Z}\n");
      ("verification", "verified: [{by: human:x}]\n");
      ("source resource", "sources: [{title: missing}]\n");
      ("source count", "sources: [{resource: x, usage_count: -1}]\n");
      ("window order", "usage_window: {from: 2026-08-07, to: 2026-08-06}\n") ]
  in
  List.iter
    (fun (name, extra) ->
      Alcotest.(check bool) name true
        (Clamp.Concept.validate (base_metadata extra) <> []))
    cases;
  Alcotest.(check bool) "valid complete fields" true
    (Clamp.Concept.validate
       (base_metadata
          "tags: [one, two]\nstatus: stable\nstale_after: 2026-12-01\nverified: [{by: human:x, at: 2026-08-06T12:01:00+02:00}]\nsources: [{id: s, resource: https://example.test, usage_count: 9007199254740993, last_modified: 2026-08-01}]\nusage_window: {from: 2026-01-01, to: 2026-08-06}\n")
     = []);
  Alcotest.(check bool) "fractional generated timestamp" true
    (Clamp.Concept.validate
       (base_metadata
          "generated: {by: amp/agent, at: 2026-08-06T10:00:00.1Z}\n")
    = [])

let taxonomy () =
  let metadata = parse_yaml "type: custom\nclamp: {asserted_by: amp/agent}\n" in
  Alcotest.(check bool) "persisted unknown structurally valid" true
    (Clamp.Concept.validate metadata = [])

let task_table () =
  let task extra =
    parse_yaml
      ("type: task\nclamp:\n  asserted_by: human:owner\n  task:\n    state: todo\n"
      ^ extra)
  in
  Alcotest.(check bool) "valid task" true
    (Clamp.Concept.validate (task "    priority: urgent\n    due_on: 2026-08-10\n") = []);
  [ "    due_on: 2026-08-10\n    due_at: 2026-08-10T10:00:00Z\n";
    "    completed_at: 2026-08-10T10:00:00Z\n";
    "    depends_on: [../bad]\n" ]
  |> List.iter (fun extra ->
         Alcotest.(check bool) extra true
           (Clamp.Concept.validate (task extra) <> []));
  Alcotest.(check bool) "unknown task metadata is preserved" true
    (Clamp.Concept.validate (task "    unknown: value\n") = []);
  let done_task =
    parse_yaml
      "type: task\nclamp: {asserted_by: human:x, task: {state: done, completed_at: 2026-08-06T10:00:00Z}}\n"
  in
  Alcotest.(check bool) "done timestamp" true
    (Clamp.Concept.validate done_task = [])

let date_time_path_ulid () =
  [ ("2024-02-29", true); ("2023-02-29", false); ("2026-13-01", false) ]
  |> List.iter (fun (value, expected) ->
         Alcotest.(check bool) value expected (Clamp.Concept.date value));
  [ ("2026-08-06T23:59:59Z", true);
    ("2024-02-29T00:00:00.123456+02:30", true);
    ("2023-02-29T00:00:00Z", false);
    ("2026-08-06T24:00:00Z", false);
    ("2026-08-06T10:00:00+24:00", false);
    ("2026-08-06T10:00:00+02:60", false);
    ("2026-08-06T10:00:00.Z", false);
    ("2026-08-06T10:00:00.1Ztail", false);
    ("2026-08-06t23:59:60z", false) ]
  |> List.iter (fun (value, expected) ->
         Alcotest.(check bool) value expected (Clamp.Concept.rfc3339 value));
  [ ("facts/example", true); ("../example", false); ("facts/x.md", false);
    ("facts/bad?name", false); ("facts/caf\195\169", false);
    ("facts/name.", false);
    ("facts/CON", false); ("facts/lpt9.txt", false) ]
  |> List.iter (fun (value, expected) ->
         Alcotest.(check bool) value expected (Clamp.Concept.concept_id value));
  Alcotest.(check bool) "valid ULID" true
    (Clamp.Bundle.ulid "01ARZ3NDEKTSV4RRFFQ69G5FAV");
  Alcotest.(check bool) "forbidden ULID character" false
    (Clamp.Bundle.ulid "01ARZ3NDEKTSV4RRFFQ69G5FAI");
  Alcotest.(check bool) "timestamp overflow" false
    (Clamp.Bundle.ulid "81ARZ3NDEKTSV4RRFFQ69G5FAV")

let verification_classification () =
  let concept body extra =
    parse_frontmatter
      ("---\ntype: fact\ntitle: Example\nclamp: {asserted_by: human:x}\n" ^ extra
      ^ "---\n" ^ body ^ "\n")
  in
  let baseline = concept "Alpha [old label](old.md) omega." "" in
  let preserve =
    [ concept "  Alpha   [old label](new.md \"new title\") omega. " "status: draft\n";
      concept "Alpha [old label](old.md) omega." "verified: {by: human:x, at: 2026-08-06T10:00:00Z}\n";
      concept "Alpha [old label](old.md) omega." "stale_after: 2026-12-01\n" ]
  in
  List.iter
    (fun changed ->
      Alcotest.(check bool) "preserve" true
        (Clamp.Concept.classify_verification baseline changed
        = Clamp.Concept.Preserve_verification))
    preserve;
  let reordered_left =
    parse_frontmatter
      "---\ntype: fact\nunknown: {second: 2, first: {right: two, left: one}}\nclamp: {asserted_by: human:x}\n---\n**Alpha** and `code`.\n"
  and reordered_right =
    parse_frontmatter
      "---\nunknown: {first: {left: one, right: two}, second: 2}\nclamp: {asserted_by: human:x}\ntype: fact\n---\nAlpha and `code`.\n"
  in
  Alcotest.(check bool) "recursive metadata order and emphasis preserve" true
    (Clamp.Concept.classify_verification reordered_left reordered_right
    = Clamp.Concept.Preserve_verification);
  let html_old = concept "<div>\nold claim\n</div>" ""
  and html_new = concept "<div>\nnew claim\n</div>" "" in
  Alcotest.(check bool) "raw HTML semantic edit clears" true
    (Clamp.Concept.classify_verification html_old html_new
    = Clamp.Concept.Clear_verification);
  [ ("<div>Claim A</div>\n\nClaim B", "Claim B\n\n<div>Claim A</div>");
    ("A <span>first</span> B", "<span>first</span> A B");
    ("Inline `a  b` code.", "Inline `a b` code.");
    ("~~~\na  b\n~~~", "~~~\na b\n~~~") ]
  |> List.iter (fun (left, right) ->
         Alcotest.(check bool) "document order/code whitespace clears" true
           (Clamp.Concept.classify_verification (concept left "") (concept right "")
           = Clamp.Concept.Clear_verification));
  [ concept "Alpha changed omega." "";
    concept "Alpha [new label](old.md) omega." "";
    concept "Alpha [old label](old.md) omega. <div>new claim</div>" "";
    parse_frontmatter
      "---\ntype: fact\ntitle: Changed\nclamp: {asserted_by: human:x}\n---\nAlpha [old label](old.md) omega.\n";
    parse_frontmatter
      "---\ntype: fact\ntitle: Example\nclaim_scope: US\nclamp: {asserted_by: human:x}\n---\nAlpha [old label](old.md) omega.\n" ]
  |> List.iter (fun changed ->
         Alcotest.(check bool) "clear" true
           (Clamp.Concept.classify_verification baseline changed
           = Clamp.Concept.Clear_verification));

  let task task_fields =
    parse_frontmatter
      ("---\ntype: task\ntitle: Example task\nclamp:\n  asserted_by: human:x\n  task:\n"
      ^ task_fields ^ "---\nTask body.\n")
  in
  let task_baseline =
    task
      "    state: todo\n    priority: normal\n    due_on: 2026-08-10\n    depends_on: [facts/a]\n"
  in
  [ task
      "    state: todo\n    priority: normal\n    due_on: 2026-08-11\n    depends_on: [facts/a]\n";
    task
      "    state: todo\n    priority: normal\n    due_at: 2026-08-10T10:00:00Z\n    depends_on: [facts/a]\n";
    task
      "    state: todo\n    priority: normal\n    due_on: 2026-08-10\n    depends_on: [facts/b]\n";
    task
      "    state: todo\n    priority: normal\n    due_on: 2026-08-10\n    depends_on: [facts/a]\n    future_schedule_key: changed\n" ]
  |> List.iter (fun changed ->
         Alcotest.(check bool) "task semantic field clears" true
           (Clamp.Concept.classify_verification task_baseline changed
           = Clamp.Concept.Clear_verification));
  let due_at_baseline =
    task
      "    state: todo\n    priority: normal\n    due_at: 2026-08-10T10:00:00Z\n    depends_on: [facts/a]\n"
  and due_at_changed =
    task
      "    state: todo\n    priority: normal\n    due_at: 2026-08-10T11:00:00Z\n    depends_on: [facts/a]\n"
  in
  Alcotest.(check bool) "task due_at change clears" true
    (Clamp.Concept.classify_verification due_at_baseline due_at_changed
    = Clamp.Concept.Clear_verification);
  [ task
      "    state: doing\n    priority: normal\n    due_on: 2026-08-10\n    depends_on: [facts/a]\n";
    task
      "    state: todo\n    priority: urgent\n    due_on: 2026-08-10\n    depends_on: [facts/a]\n";
    task
      "    state: done\n    priority: urgent\n    completed_at: 2026-08-10T12:00:00Z\n    due_on: 2026-08-10\n    depends_on: [facts/a]\n" ]
  |> List.iter (fun changed ->
         Alcotest.(check bool) "task lifecycle field preserves" true
           (Clamp.Concept.classify_verification task_baseline changed
           = Clamp.Concept.Preserve_verification))

let commonmark_links () =
  let markdown =
    "[inline](facts/one.md) [full][target] [collapsed][] [shortcut]\n\n[target]: facts/two.md\n[collapsed]: facts/three.md\n[shortcut]: facts/four.md\n\n`[code](missing.md)`\n\n    [indented](missing.md)\n\n~~~\n[fenced](missing.md)\n~~~\n\n<!-- [comment](missing.md) -->\n\\[escaped](missing.md)\n"
  in
  Alcotest.(check (list string)) "only CommonMark links"
    [ "facts/one.md"; "facts/two.md"; "facts/three.md"; "facts/four.md" ]
    (Clamp.Markdown_links.extract markdown);
  let canonical =
    Clamp.Markdown_links.visible_text
      "The **approved** [policy](old.md \"title\") and `code`."
  in
  Alcotest.(check string) "destination/title ignored" canonical
    (Clamp.Markdown_links.visible_text
       "The approved [policy](new.md \"changed\") and `code`.");
  List.iter
    (fun label -> Alcotest.(check bool) label true (contains canonical label))
    [ "approved"; "policy"; "code" ];
  let links, truncated =
    Clamp.Markdown_links.extract_bounded ~limit:1
      "[one](one.md) [two](two.md)"
  in
  Alcotest.(check (list string)) "bounded extraction" [ "one.md" ] links;
  Alcotest.(check bool) "bounded extraction reports truncation" true truncated

let config_contract () =
  Alcotest.(check (result unit string)) "defaults" (Ok ())
    (Clamp.Config.load (Filename.concat project_root "clamp.yaml"));
  let source =
    let channel = open_in_bin (Filename.concat project_root "clamp.yaml") in
    Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
        really_input_string channel (in_channel_length channel))
  in
  Alcotest.(check (result string string)) "default human authority"
    (Ok "human:owner") (Clamp.Config.human_authority source);
  let configured_authority =
    Str.replace_first (Str.regexp_string "inferred_writes: confirm")
      "inferred_writes: confirm\nhuman_authority: human:test-owner" source
  in
  Alcotest.(check (result unit string)) "configured human authority accepted"
    (Ok ()) (Clamp.Config.validate configured_authority);
  Alcotest.(check (result string string)) "configured human authority"
    (Ok "human:test-owner")
    (Clamp.Config.human_authority configured_authority);
  List.iter
    (fun value ->
      let invalid =
        Str.replace_first (Str.regexp_string "inferred_writes: confirm")
          ("inferred_writes: confirm\nhuman_authority: " ^ value) source
      in
      Alcotest.(check bool) ("invalid human authority " ^ value) true
        (Result.is_error (Clamp.Config.validate invalid)))
    [ "human:"; "amp/agent"; "human:test owner"; "42" ];
  let cases =
    [ ("timezone", "Africa/Johannesburg", "UTC");
      ("schema type", "schema_version: 1", "schema_version: \"1\"");
      ("routing", "allow_fallbacks: false", "allow_fallbacks: true");
      ("integer", "candidate_limit: 100", "candidate_limit: 1.5");
      ("weights", "semantic_weight: 0.70", "semantic_weight: 0.71") ]
  in
  List.iter
    (fun (name, needle, replacement) ->
      let changed = Str.global_replace (Str.regexp_string needle) replacement source in
      let path = Filename.temp_file "clamp-config" ".yaml" in
      let channel = open_out_bin path in
      output_string channel changed;
      close_out channel;
      Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
          Alcotest.(check bool) name true (Result.is_error (Clamp.Config.load path))))
    cases;
  let directory = Filename.temp_dir "clamp-config-safe" "test" in
  Fun.protect
    ~finally:(fun () -> remove directory)
    (fun () ->
      let target = Filename.concat directory "target.yaml" in
      write target source;
      Unix.symlink "target.yaml" (Filename.concat directory "clamp.yaml");
      Alcotest.(check bool) "config symlink rejected" true
        (Result.is_error
           (Clamp.Config.load (Filename.concat directory "clamp.yaml"))))

let bundle_fixture () =
  let result =
    Clamp.Bundle.validate
      (Filename.concat project_root "test/fixtures/phase1-valid")
  in
  Alcotest.(check int) "concepts" 4 result.concepts;
  Alcotest.(check int) "reserved" 1 result.reserved;
  Alcotest.(check int) "diagnostics" 0 (List.length result.diagnostics)

let bundle_safety () =
  with_bundle
    (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let facts = Filename.concat knowledge "facts" in
      Unix.mkdir facts 0o700;
      write (Filename.concat facts "existing.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nExisting.\n";
      write (Filename.concat facts "bad.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n[missing](missing.md) [absolute existing](/facts/existing.md) [absolute missing](/facts/absent.md) [repository](../../README.md)\n";
      Unix.symlink "/tmp" (Filename.concat knowledge "escape");
      let tasks = Filename.concat knowledge "tasks" in
      Unix.mkdir tasks 0o700;
      write (Filename.concat tasks "bad-name.md")
        "---\ntype: task\nclamp: {asserted_by: human:x, task: {state: todo}}\n---\nTask.\n";
      let journal = Filename.concat knowledge "journal" in
      Unix.mkdir journal 0o700;
      let year = Filename.concat journal "2026" in
      Unix.mkdir year 0o700;
      write (Filename.concat year "2025-02-30.md")
        "---\ntype: journal\nclamp: {asserted_by: human:x}\n---\nJournal.\n";
      let result = Clamp.Bundle.validate root in
      let codes = diagnostic_codes result in
      List.iter
        (fun code ->
          Alcotest.(check bool) code true (List.mem code codes))
        [ "symlink_forbidden"; "task_path_invalid"; "journal_path_invalid";
          "link_unresolved" ];
      Alcotest.(check int) "only relative and bundle-absolute missing links warn" 2
        (List.length
           (List.filter
              (fun diagnostic ->
                diagnostic.Clamp.Diagnostic.code = "link_unresolved")
              result.diagnostics)));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let facts = Filename.concat knowledge "facts" in
      Unix.mkdir facts 0o700;
      write (Filename.concat facts "existing.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nExisting.\n";
      let source = Filename.concat knowledge "source.md" in
      let write_source destination =
        write source
          ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n[target]("
          ^ destination ^ ")\n")
      in
      let unresolved () =
        (Clamp.Bundle.validate root).diagnostics
        |> List.filter (fun diagnostic ->
               diagnostic.Clamp.Diagnostic.code = "link_unresolved")
        |> List.length
      in
      write_source "/facts/existing.md";
      Alcotest.(check int) "existing bundle-absolute link" 0 (unresolved ());
      write_source "/facts/missing.md";
      Alcotest.(check int) "missing bundle-absolute link" 1 (unresolved ());
      write_source "/../missing.md";
      Alcotest.(check int) "bundle-absolute traversal warns" 1 (unresolved ());
      List.iter
        (fun destination ->
          write_source destination;
          Alcotest.(check int) destination 1 (unresolved ()))
        [ "/../index.md"; "/../log.md"; "/../outside.txt" ];
      write_source "../README.md";
      Alcotest.(check int) "non-concept repository link" 0 (unresolved ()))

let safe_file_contract () =
  let directory = Filename.temp_dir "clamp-safe-file" "test" in
  Fun.protect
    ~finally:(fun () -> remove directory)
    (fun () ->
      let root_descriptor = Clamp.Secure_fs.open_directory directory in
      let read name =
        let _, expected = Clamp.Secure_fs.inspect root_descriptor name in
        Clamp.Secure_fs.open_file_at root_descriptor name
        |> Clamp.Safe_file.read_descriptor ~expected
      in
      let regular = Filename.concat directory "regular" in
      write regular "safe";
      Alcotest.(check bool) "regular" true
        (read "regular" = Ok "safe");
      let consumed = Clamp.Secure_fs.open_file_at root_descriptor "regular" in
      let _, consumed_expected = Clamp.Secure_fs.inspect root_descriptor "regular" in
      ignore (Clamp.Safe_file.read_descriptor ~expected:consumed_expected consumed);
      Alcotest.(check bool) "successful read consumes descriptor" true
        (try
           ignore (Unix.fstat consumed);
           false
         with Unix.Unix_error (Unix.EBADF, _, _) -> true);
      let exceptional = Clamp.Secure_fs.open_file_at root_descriptor "regular" in
      let original_exception_survives =
        try
          ignore
            (Clamp.Safe_file.For_test.read_descriptor_with_hook
               ~expected:consumed_expected
               ~after_open:(fun () ->
                 Unix.close exceptional;
                 raise Exit)
               exceptional);
          false
        with Exit -> true
      in
      Alcotest.(check bool) "cleanup preserves primary exception" true
        original_exception_survives;
      let rejects_nul operation =
        try
          operation ();
          false
        with Invalid_argument _ -> true
      in
      Alcotest.(check bool) "root path NUL rejected" true
        (rejects_nul (fun () ->
             ignore (Clamp.Secure_fs.open_directory (directory ^ "\000suffix"))));
      Alcotest.(check bool) "open_file_at NUL rejected" true
        (rejects_nul (fun () ->
             ignore (Clamp.Secure_fs.open_file_at root_descriptor "regular\000suffix")));
      Alcotest.(check bool) "inspect NUL rejected" true
        (rejects_nul (fun () ->
             ignore (Clamp.Secure_fs.inspect root_descriptor "regular\000suffix")));
      Alcotest.(check bool) "open_beneath NUL rejected" true
        (rejects_nul (fun () ->
             ignore (Clamp.Secure_fs.open_beneath root_descriptor "regular\000suffix")));
      let other = Filename.concat directory "other" in
      write other "other";
      let _, expected = Clamp.Secure_fs.inspect root_descriptor "regular" in
      Alcotest.(check bool) "substitution identity" true
        (Clamp.Secure_fs.open_file_at root_descriptor "other"
        |> Clamp.Safe_file.read_descriptor ~expected
        = Error Clamp.Safe_file.Changed_during_read);
      Alcotest.(check bool) "missing" true
        (try
           ignore (Clamp.Secure_fs.open_file_at root_descriptor "missing");
           false
         with Unix.Unix_error _ -> true);
      let fifo = Filename.concat directory "fifo" in
      Unix.mkfifo fifo 0o600;
      Alcotest.(check bool) "FIFO rejected without blocking" true
        (read "fifo" = Error Clamp.Safe_file.Not_regular);
      let oversized = Filename.concat directory "oversized" in
      let channel = open_out_bin oversized in
      seek_out channel Clamp.Limits.max_file_bytes;
      output_char channel 'x';
      close_out channel;
      Alcotest.(check bool) "8 MiB ceiling" true
        (read "oversized" = Error Clamp.Safe_file.Too_large);
      Unix.truncate oversized Clamp.Limits.max_file_bytes;
      Alcotest.(check int) "exactly 8 MiB accepted" Clamp.Limits.max_file_bytes
        (match read "oversized" with
        | Ok contents -> String.length contents
        | Error _ -> Alcotest.fail "exact file ceiling rejected");
      let before : Clamp.Secure_fs.identity =
        { device = 1L; inode = 2L; size = 10L;
          modified_seconds = 1L; modified_nanoseconds = 2;
          changed_seconds = 1L; changed_nanoseconds = 2 }
      and truncated : Clamp.Secure_fs.identity =
        { device = 1L; inode = 2L; size = 5L;
          modified_seconds = 2L; modified_nanoseconds = 3;
          changed_seconds = 2L; changed_nanoseconds = 3 }
      in
      Alcotest.(check bool) "truncation identity rejected" false
        (Clamp.Safe_file.unchanged before truncated);
      Fun.protect
        ~finally:(fun () -> Unix.close root_descriptor)
        (fun () ->
          write (Filename.concat directory "resized") "x";
          let _, resize_expected =
            Clamp.Secure_fs.inspect root_descriptor "resized"
          in
          write (Filename.concat directory "resized") "longer";
          Alcotest.(check bool) "inspect then resize" true
            (Clamp.Secure_fs.open_file_at root_descriptor "resized"
            |> Clamp.Safe_file.read_descriptor ~expected:resize_expected
            = Error Clamp.Safe_file.Changed_during_read);
          write (Filename.concat directory "rewritten") "old";
          write (Filename.concat directory "rewritten") "new";
          let _, rewritten =
            Clamp.Secure_fs.inspect root_descriptor "rewritten"
          in
          let ctime_only_expected =
            { rewritten with
              changed_nanoseconds = rewritten.changed_nanoseconds lxor 1 }
          in
          Alcotest.(check bool) "same-size ctime mismatch" true
            (Clamp.Secure_fs.open_file_at root_descriptor "rewritten"
            |> Clamp.Safe_file.read_descriptor ~expected:ctime_only_expected
            = Error Clamp.Safe_file.Changed_during_read);
          let growing = Filename.concat directory "growing" in
          let channel = open_out_bin growing in
          seek_out channel (Clamp.Limits.max_file_bytes - 1);
          output_char channel 'x';
          close_out channel;
          let _, growth_expected =
            Clamp.Secure_fs.inspect root_descriptor "growing"
          in
          let growth_descriptor =
            Clamp.Secure_fs.open_file_at root_descriptor "growing"
          in
          let append () =
            let channel =
              open_out_gen [ Open_wronly; Open_append; Open_binary ] 0 growing
            in
            output_string channel "too much";
            close_out channel
          in
          Alcotest.(check bool) "growth after open never exceeds buffer ceiling" true
            (Clamp.Safe_file.For_test.read_descriptor_with_hook
               ~expected:growth_expected ~after_open:append growth_descriptor
            = Error Clamp.Safe_file.Too_large);
          let nested = Filename.concat directory "nested" in
          Unix.mkdir nested 0o700;
          write (Filename.concat nested "file.md") "content";
          let nested_descriptor =
            Clamp.Secure_fs.open_directory_at root_descriptor "nested"
          in
          let _, expected =
            Clamp.Secure_fs.inspect nested_descriptor "file.md"
          in
          Unix.close nested_descriptor;
          Unix.rename nested (Filename.concat directory "moved");
          Unix.symlink "moved" nested;
          Alcotest.(check bool) "intermediate symlink substitution rejected" true
            (try
               let descriptor =
                 Clamp.Secure_fs.open_beneath root_descriptor "nested/file.md"
               in
               Unix.close descriptor;
               false
             with Unix.Unix_error _ -> true);
          let contents =
            Clamp.Secure_fs.open_beneath root_descriptor "moved/file.md"
            |> Clamp.Safe_file.read_descriptor ~expected
          in
          Alcotest.(check (result string reject)) "descriptor-relative read"
            (Ok "content") contents;
          [ ""; "."; ".."; "../outside"; "nested//file.md" ]
          |> List.iter (fun relative ->
                 Alcotest.(check bool) relative true
                   (try
                      let descriptor =
                        Clamp.Secure_fs.open_beneath root_descriptor relative
                      in
                      Unix.close descriptor;
                      false
                    with Invalid_argument _ -> true))))

let bundle_adversarial () =
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let invalid_name = "invalid-\255" in
      let invalid_path = Filename.concat knowledge invalid_name in
      let invalid_name_created =
        try Unix.mkdir invalid_path 0o700; true with
        | Unix.Unix_error (Unix.EUNKNOWNERR 92, _, _) ->
            (* APFS rejects non-UTF8 names at the syscall boundary (EILSEQ). *)
            Alcotest.(check bool) "filesystem rejected invalid name" false (Sys.file_exists invalid_path);
            false
      in
      let fifo = Filename.concat knowledge "pipe.md" in
      Unix.mkfifo fifo 0o600;
      write (Filename.concat knowledge "invalid-utf8.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n\255\n";
      let nested = Filename.concat knowledge "nested" in
      Unix.mkdir nested 0o700;
      write (Filename.concat nested "index.md")
        "---\ntype: fact\n---\n# Invalid nested index\n";
      write (Filename.concat nested "log.md")
        "---\ntype: fact\n---\n# Log\n\n## 2026-08-06\n* Entry\n";
      write (Filename.concat nested "ordinary.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n[query](../target.md?x=1#part) [root](/knowledge/target.md) [encoded](%2e%2e%2ftarget.md)\n";
      write (Filename.concat knowledge "target.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nTarget.\n";
      write (Filename.concat knowledge "name..md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nTrailing period.\n";
      write (Filename.concat knowledge "Case.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nUpper.\n";
      write (Filename.concat knowledge "case.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nLower.\n";
      let distinct_cases =
        (Unix.stat (Filename.concat knowledge "Case.md")).st_ino <>
        (Unix.stat (Filename.concat knowledge "case.md")).st_ino
      in
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      List.iter
        (fun code -> Alcotest.(check bool) code true (List.mem code codes))
        ([ "file_not_regular"; "invalid_utf8";
          "reserved_index_frontmatter"; "link_invalid_uri";
          "concept_id_invalid" ]
         @ (if invalid_name_created then ["path_component_invalid"] else [])
         @ (if distinct_cases then ["path_duplicate"] else []));
      Alcotest.(check bool) "query/fragment and root links resolve" false
        (List.mem "link_unresolved" codes))

let reserved_commonmark () =
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      write (Filename.concat knowledge "index.md")
        "~~~\n# Not a heading\n~~~\n";
      write (Filename.concat knowledge "log.md")
        "# Log\r\n\r\n## 2026-08-06 ##\r\n* Entry\r\n\r\n## 2026-08-05\r\n* Older\r\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "fenced heading ignored" true
        (List.mem "reserved_index_sections" codes);
      Alcotest.(check bool) "CRLF and closing marker accepted" false
        (List.mem "reserved_log_dates" codes || List.mem "reserved_log_order" codes));
  with_bundle (fun root ->
      write (Filename.concat root "knowledge/log.md")
        "# Log\n\n~~~\n## 2026-08-06\n~~~\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "fenced date ignored" true
        (List.mem "reserved_log_dates" codes));
  with_bundle (fun root ->
      let index = Filename.concat root "knowledge/index.md" in
      write index "---not frontmatter\n# Valid section\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "dash-prefixed Markdown is not frontmatter" false
        (List.mem "reserved_index_invalid" codes);
      write index "---\nokf_version: \"0.2\"\n---\n# Valid section\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "valid reserved frontmatter" false
        (List.mem "reserved_index_invalid" codes
        || List.mem "reserved_index_version" codes));
  with_bundle (fun root ->
      write (Filename.concat root "knowledge/log.md")
        "## 2026-08-06\n* Entry\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "log requires leading H1" true
        (List.mem "reserved_log_sections" codes));
  with_bundle (fun root ->
      let log = Filename.concat root "knowledge/log.md" in
      write log
        "---\ntype: Log\ntitle: Official-style log\n---\n# Bundle history\n\n## 2026-08-06\n* Entry\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "official log frontmatter accepted" false
        (List.mem "reserved_log_invalid" codes
        || List.mem "reserved_log_sections" codes);
      write log
        "---\ntype: [\n---\n# Bundle history\n\n## 2026-08-06\n* Entry\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "malformed log frontmatter rejected" true
        (List.mem "reserved_log_invalid" codes));
  [ "# Log\n\n## 2026-08-06\n\n# Second title\n";
    "# Log\n\n## 2026-08-06\n\n### Nested heading\n";
    "> # Log\n>\n> ## 2026-08-06\n>\n> - Entry\n";
    "Prose first.\n\n# Log\n\n## 2026-08-06\n\n- Entry\n" ]
  |> List.iter (fun contents ->
         with_bundle (fun root ->
             write (Filename.concat root "knowledge/log.md") contents;
             let codes = diagnostic_codes (Clamp.Bundle.validate root) in
             Alcotest.(check bool) "log heading structure is flat" true
               (List.mem "reserved_log_sections" codes)));
  [ "# Index only\n"; "# Index\n\nProse without entries.\n" ]
  |> List.iter (fun contents ->
         with_bundle (fun root ->
             write (Filename.concat root "knowledge/index.md") contents;
             let codes = diagnostic_codes (Clamp.Bundle.validate root) in
             Alcotest.(check bool) "index requires a linked entry" true
               (List.mem "reserved_index_sections" codes)));
  [ "> # Quoted\n>\n> - [Missing](missing.md)\n";
    "# Section\n\n1. Wrapper\n   - [Missing](missing.md)\n" ]
  |> List.iter (fun contents ->
         with_bundle (fun root ->
             write (Filename.concat root "knowledge/index.md") contents;
             let codes = diagnostic_codes (Clamp.Bundle.validate root) in
             Alcotest.(check bool) "nested index structure is not promoted" true
               (List.mem "reserved_index_sections" codes)));
  with_bundle (fun root ->
      write (Filename.concat root "knowledge/index.md")
        "# Section\n\n- [Missing][concept]\n\n[concept]: missing.md\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "top-level reference entry is structural" false
        (List.mem "reserved_index_sections" codes);
      Alcotest.(check bool) "top-level reference missing target warns" true
        (List.mem "link_unresolved" codes));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let facts = Filename.concat knowledge "facts" in
      Unix.mkdir facts 0o700;
      write (Filename.concat facts "existing.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nExisting.\n";
      let index = Filename.concat knowledge "index.md" in
      write index "# Facts\n\nSee [Missing](facts/missing.md).\n";
      let prose_result = Clamp.Bundle.validate root in
      Alcotest.(check bool) "prose link is not an index entry" true
        (List.mem "reserved_index_sections" (diagnostic_codes prose_result));
      Alcotest.(check bool) "prose broken link still warns" true
        (List.mem "link_unresolved" (diagnostic_codes prose_result));
      write index "# Documents\n\n- [This index](index.md)\n";
      Alcotest.(check bool) "self-index is not a concept entry" true
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write index "# Documents\n\n- [Missing log](log.md)\n";
      Alcotest.(check bool) "missing log is not a concept entry" true
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write (Filename.concat knowledge "log.md")
        "# Log\n\n## 2026-08-06\n\n- Created fixture.\n";
      write index "# Documents\n\n- [Existing log](log.md)\n";
      Alcotest.(check bool) "existing log is not a concept entry" true
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write index "# Resources\n\n- [Website](https://example.test)\n";
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "external-only index is invalid" true
        (List.mem "reserved_index_sections" codes);
      write index "# Facts\n\n- [Existing](/facts/existing.md)\n";
      let nested = Filename.concat knowledge "nested" in
      Unix.mkdir nested 0o700;
      write (Filename.concat nested "index.md")
        "# Nested facts\n\n- [Existing](../facts/existing.md)\n";
      let result = Clamp.Bundle.validate root in
      Alcotest.(check bool) "grouped linked index is valid" false
        (List.mem "reserved_index_sections" (diagnostic_codes result));
      Alcotest.(check int) "existing reserved link resolves" 0
        (List.length
           (List.filter
              (fun diagnostic ->
                diagnostic.Clamp.Diagnostic.code = "link_unresolved")
              result.diagnostics));
      write index
        "# Resources\n\n- [Website](https://example.test)\n- [Existing](/facts/existing.md)\n";
      Alcotest.(check bool) "mixed external/internal index is valid" false
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write index "# Directories\n\n- [Facts](facts/)\n";
      Alcotest.(check bool) "subdirectory index entry is valid" false
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write index "# Directories\n\n- [Facts](facts)\n";
      Alcotest.(check bool) "subdirectory requires trailing slash" true
        (List.mem "reserved_index_sections"
           (diagnostic_codes (Clamp.Bundle.validate root)));
      write index "# Facts\n\n- [Missing](/facts/missing.md)\n";
      let result = Clamp.Bundle.validate root in
      Alcotest.(check int) "missing reserved link warns" 1
        (List.length
           (List.filter
              (fun diagnostic ->
                diagnostic.Clamp.Diagnostic.code = "link_unresolved")
              result.diagnostics)))

let reserved_case_collisions () =
  List.iter
    (fun relative ->
      with_bundle (fun root ->
          let knowledge = Filename.concat root "knowledge" in
          let path = Filename.concat knowledge relative in
          let parent = Filename.dirname path in
          if parent <> knowledge then Unix.mkdir parent 0o700;
          write path
            "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nBody.\n";
          let result = Clamp.Bundle.validate root in
          Alcotest.(check bool) (relative ^ " rejected") true
            (List.exists
               (fun diagnostic ->
                 diagnostic.Clamp.Diagnostic.code = "reserved_case_invalid"
                 && diagnostic.path = "knowledge/" ^ relative)
               result.diagnostics);
          Alcotest.(check int) (relative ^ " is not a concept") 0 result.concepts))
    [ "INDEX.md"; "LOG.md"; "nested/INDEX.md"; "nested/LOG.md" ];
  let case_sensitive = with_bundle (fun root ->
      let upper = Filename.concat root "Case" in
      Unix.mkdir upper 0o700;
      let lower = Filename.concat root "case" in
      if Sys.file_exists lower then begin
        Alcotest.(check int) "APFS case aliases identify the same directory"
          (Unix.stat upper).st_ino (Unix.stat lower).st_ino;
        Alcotest.check_raises "case-colliding directory cannot be created"
          (Unix.Unix_error (Unix.EEXIST, "mkdir", lower))
          (fun () -> Unix.mkdir lower 0o700);
        false
      end else true) in
  if case_sensitive then begin
  let check reserved_name concept_name reserved_body expected_path =
    with_bundle (fun root ->
        let knowledge = Filename.concat root "knowledge" in
        write (Filename.concat knowledge reserved_name) reserved_body;
        write (Filename.concat knowledge concept_name)
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nBody.\n";
        let duplicates =
          (Clamp.Bundle.validate root).diagnostics
          |> List.filter_map (fun diagnostic ->
                 if diagnostic.Clamp.Diagnostic.code = "path_duplicate" then
                   Some diagnostic.path
                 else None)
        in
        Alcotest.(check (list string)) expected_path [ expected_path ] duplicates)
  in
  check "index.md" "INDEX.md" "# Index\n" "knowledge/index.md";
  check "log.md" "LOG.md" "# Log\n\n## 2026-08-06\n* Entry\n"
    "knowledge/log.md";
  let json diagnostics =
    `List (List.map Clamp.Diagnostic.json diagnostics) |> Yojson.Safe.to_string
  in
  let ancestor_case reverse =
    let result = ref None in
    with_bundle (fun root ->
        let knowledge = Filename.concat root "knowledge" in
        let names = if reverse then [ "facts"; "Facts" ] else [ "Facts"; "facts" ] in
        List.iter (fun name -> Unix.mkdir (Filename.concat knowledge name) 0o700) names;
        write (Filename.concat knowledge "Facts/a.md")
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nA.\n";
        write (Filename.concat knowledge "facts/b.md")
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nB.\n";
        result := Some (Clamp.Bundle.validate root));
    Option.get !result
  in
  let ancestor_forward = ancestor_case false
  and ancestor_reverse = ancestor_case true in
  Alcotest.(check int) "colliding ancestors exclude descendants" 0
    ancestor_forward.concepts;
  Alcotest.(check (list string)) "ancestor collision path"
    [ "knowledge/facts" ]
    (ancestor_forward.diagnostics
    |> List.filter_map (fun diagnostic ->
           if diagnostic.Clamp.Diagnostic.code = "path_duplicate" then
             Some diagnostic.path
           else None));
  Alcotest.(check string) "ancestor collision creation-order independent"
    (json ancestor_forward.diagnostics) (json ancestor_reverse.diagnostics);
  let mixed_case reverse =
    let result = ref None in
    with_bundle (fun root ->
        let knowledge = Filename.concat root "knowledge" in
        let make = function
          | "Data" ->
              let directory = Filename.concat knowledge "Data" in
              Unix.mkdir directory 0o700;
              write (Filename.concat directory "inside.md")
                "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nInside.\n"
          | "data" -> write (Filename.concat knowledge "data") "ordinary file\n"
          | _ -> assert false
        in
        (if reverse then [ "data"; "Data" ] else [ "Data"; "data" ])
        |> List.iter make;
        result := Some (Clamp.Bundle.validate root));
    Option.get !result
  in
  let mixed_forward = mixed_case false and mixed_reverse = mixed_case true in
  Alcotest.(check int) "file/directory collision excludes descendants" 0
    mixed_forward.concepts;
  Alcotest.(check (list string)) "file/directory collision path"
    [ "knowledge/data" ]
    (mixed_forward.diagnostics
    |> List.filter_map (fun diagnostic ->
           if diagnostic.Clamp.Diagnostic.code = "path_duplicate" then
             Some diagnostic.path
           else None));
  Alcotest.(check string) "file/directory creation-order independent"
    (json mixed_forward.diagnostics) (json mixed_reverse.diagnostics)
  end

let namespace_rules () =
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let tasks = Filename.concat knowledge "tasks" in
      Unix.mkdir tasks 0o700;
      write (Filename.concat tasks "fact.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nFact.\n";
      let journal = Filename.concat knowledge "journal" in
      Unix.mkdir journal 0o700;
      write (Filename.concat journal "fact.md")
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\nFact.\n";
      write (Filename.concat knowledge "misplaced-journal.md")
        "---\ntype: journal\nclamp: {asserted_by: human:x}\n---\nJournal.\n";
      write (Filename.concat knowledge "empty-type.md")
        "---\ntype: \"\"\nclamp: {asserted_by: human:x}\n---\nEmpty.\n";
      let result = Clamp.Bundle.validate root in
      let codes = diagnostic_codes result in
      Alcotest.(check bool) "task namespace" true
        (List.mem "task_path_invalid" codes);
      Alcotest.(check bool) "journal namespace" true
        (List.mem "journal_path_invalid" codes);
      Alcotest.(check bool) "empty type is not unknown warning" false
        (List.exists
           (fun diagnostic -> diagnostic.Clamp.Diagnostic.code = "unknown_type")
           result.diagnostics))

let diagnostic_limit () =
  let validate_symlinks count order =
    let result = ref None in
    with_bundle (fun root ->
        let knowledge = Filename.concat root "knowledge" in
        List.init count (fun index -> index + 1) |> order
        |> List.iter (fun index ->
               Unix.symlink "/tmp"
                 (Filename.concat knowledge (Printf.sprintf "bad-%04d" index)));
        result := Some (Clamp.Bundle.validate root).diagnostics);
    Option.get !result
  in
  [ 999; 1_000 ]
  |> List.iter (fun count ->
         let diagnostics = validate_symlinks count Fun.id in
         Alcotest.(check int) (string_of_int count) count
           (List.length diagnostics);
         Alcotest.(check bool) "no marker at or below ceiling" false
           (List.exists
              (fun diagnostic ->
                diagnostic.Clamp.Diagnostic.code = "diagnostic_limit")
              diagnostics));
  let ascending = validate_symlinks 1_001 Fun.id in
  let descending = validate_symlinks 1_001 List.rev in
  Alcotest.(check int) "diagnostics capped" Clamp.Limits.max_diagnostics
    (List.length ascending);
  Alcotest.(check int) "one limit diagnostic" 1
    (List.length
       (List.filter
          (fun diagnostic -> diagnostic.Clamp.Diagnostic.code = "diagnostic_limit")
          ascending));
  let json diagnostics =
    `List (List.map Clamp.Diagnostic.json diagnostics) |> Yojson.Safe.to_string
  in
  Alcotest.(check string) "creation order independent" (json ascending)
    (json descending);
  let symlink_paths =
    List.filter_map
      (fun diagnostic ->
        if diagnostic.Clamp.Diagnostic.code = "symlink_forbidden" then
          Some diagnostic.path
        else None)
      ascending
  in
  Alcotest.(check string) "smallest retained first" "knowledge/bad-0001"
    (List.hd symlink_paths);
  Alcotest.(check string) "smallest retained last" "knowledge/bad-0999"
    (List.hd (List.rev symlink_paths));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      for index = 1 to Clamp.Limits.max_diagnostics do
        write (Filename.concat knowledge (Printf.sprintf "warning-%04d.md" index))
          "---\ntype: future-type\nclamp: {asserted_by: human:x}\n---\nBody.\n"
      done;
      let diagnostics = (Clamp.Bundle.validate root).diagnostics in
      Alcotest.(check int) "exact warning ceiling retained"
        Clamp.Limits.max_diagnostics (List.length diagnostics);
      Alcotest.(check bool) "warning ceiling has no error" false
        (List.exists Clamp.Diagnostic.is_error diagnostics))

let descriptor_cleanup () =
  with_bundle (fun root ->
      let descriptor_count = Clamp.Secure_fs.descriptor_count in
      let before = descriptor_count () in
      let interrupted =
        try
          ignore
            (Clamp.Bundle.For_test.validate_with_open_hook root
               ~after_open:(fun () -> raise Exit));
          false
        with Exit -> true
      in
      let after = descriptor_count () in
      Alcotest.(check bool) "exception injected" true interrupted;
      Alcotest.(check int) "retained descriptors closed" before after)

let directory_membership_races () =
  let concept body =
    "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n" ^ body ^ "\n"
  in
  let validate_with_change root change =
    let changed = ref false in
    Clamp.Bundle.For_test.validate_with_entry_hooks root
      ~before_preflight_entry:(fun _ -> ()) ~after_preflight:(fun () -> ())
      ~before_validation_entry:(fun _ ->
        if not !changed then begin
          changed := true;
          change ();
          Unix.utimes (Filename.concat root "knowledge") 1.0 1.0
        end)
  in
  let assert_changed label result =
    let codes = diagnostic_codes result in
    Alcotest.(check bool) (label ^ " reports directory change") true
      (List.mem "directory_changed" codes || List.mem "path_duplicate" codes);
    Alcotest.(check bool) (label ^ " is not clean acceptance") true
      (List.exists Clamp.Diagnostic.is_error result.Clamp.Bundle.diagnostics);
    Alcotest.(check int) (label ^ " discards inconsistent concepts") 0
      result.concepts
  in
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let upper = Filename.concat knowledge "Facts" in
      Unix.mkdir upper 0o700;
      write (Filename.concat upper "a.md") (concept "A.");
      let result =
        validate_with_change root (fun () ->
            let lower = Filename.concat knowledge "facts" in
            let lower = if Sys.file_exists lower then Filename.concat knowledge "other" else lower in
            Unix.mkdir lower 0o700;
            write (Filename.concat lower "b.md") (concept "B."))
      in
      assert_changed "case-collision creation race" result);
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let victim = Filename.concat knowledge "delete.md" in
      write victim (concept "Delete me.");
      write (Filename.concat knowledge "keep.md") (concept "Keep me.");
      let result = validate_with_change root (fun () -> Sys.remove victim) in
      assert_changed "deletion race" result);
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let target = Filename.concat knowledge "replace.md" in
      let replacement = Filename.concat root "replacement.tmp" in
      write target (concept "Old.");
      write replacement (concept "New.");
      let result =
        validate_with_change root (fun () ->
            Sys.remove target;
            Unix.rename replacement target)
      in
      assert_changed "replacement race" result)

let bundle_resource_limits () =
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      for index = 1 to Clamp.Limits.max_markdown_files + 2 do
        write
          (Filename.concat knowledge (Printf.sprintf "concept-%05d.md" index))
          ""
      done;
      let deleted = ref false in
      let preflight_race =
        Clamp.Bundle.For_test.validate_with_entry_hooks root
          ~before_preflight_entry:(fun name ->
            if name = "concept-00001.md" && not !deleted then begin
              deleted := true;
              Sys.remove (Filename.concat knowledge name)
            end)
          ~after_preflight:(fun () -> ()) ~before_validation_entry:(fun _ -> ())
      in
      Alcotest.(check (list string)) "preflight entry race preserves overflow"
        [ "markdown_file_limit" ] (diagnostic_codes preflight_race);
      Sys.remove
        (Filename.concat knowledge
           (Printf.sprintf "concept-%05d.md" (Clamp.Limits.max_markdown_files + 2)));
      let deleted = ref false in
      let validation_race =
        Clamp.Bundle.For_test.validate_with_entry_hooks root
          ~before_preflight_entry:(fun _ -> ())
          ~after_preflight:(fun () ->
            write (Filename.concat knowledge "added-race-a.md") "";
            write (Filename.concat knowledge "added-race-b.md") "")
          ~before_validation_entry:(fun name ->
            if name = "concept-00002.md" && not !deleted then begin
              deleted := true;
              Sys.remove (Filename.concat knowledge name)
            end)
      in
      Alcotest.(check (list string)) "validation entry race preserves overflow"
        [ "markdown_file_limit" ] (diagnostic_codes validation_race);
      Sys.remove (Filename.concat knowledge "added-race-a.md");
      Sys.remove (Filename.concat knowledge "added-race-b.md");
      write (Filename.concat knowledge "concept-00001.md") "";
      write (Filename.concat knowledge "concept-00002.md") "";
      write (Filename.concat root "clamp.yaml") "malformed: [\n";
      let result = Clamp.Bundle.validate root in
      Alcotest.(check int) "overflow concepts not processed" 0 result.concepts;
      Alcotest.(check int) "only file limit diagnostic" 1
        (List.length result.diagnostics);
      Alcotest.(check (list string)) "Markdown file ceiling"
        [ "markdown_file_limit" ] (diagnostic_codes result);
      Sys.remove
        (Filename.concat knowledge
           (Printf.sprintf "concept-%05d.md" (Clamp.Limits.max_markdown_files + 1)));
      let exact = Clamp.Bundle.validate root in
      Alcotest.(check int) "exact Markdown file ceiling processed"
        Clamp.Limits.max_markdown_files exact.concepts;
      Alcotest.(check bool) "exact Markdown file ceiling accepted" false
        (List.mem "markdown_file_limit" (diagnostic_codes exact));
      let raced =
        Clamp.Bundle.For_test.validate_with_hook root ~after_preflight:(fun () ->
            write (Filename.concat knowledge "added-after-preflight.md") "")
      in
      Alcotest.(check int) "post-preflight overflow not processed" 0
        raced.concepts;
      Alcotest.(check (list string)) "post-preflight overflow"
        [ "markdown_file_limit" ] (diagnostic_codes raced));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let unreadable = Filename.concat knowledge "000-unreadable" in
      Unix.mkdir unreadable 0o000;
      for index = 1 to Clamp.Limits.max_markdown_files + 1 do
        write (Filename.concat knowledge (Printf.sprintf "%05d.md" index)) ""
      done;
      Fun.protect
        ~finally:(fun () -> Unix.chmod unreadable 0o700)
        (fun () ->
          let result = Clamp.Bundle.validate root in
          Alcotest.(check (list string)) "entry failure does not hide overflow"
            [ "markdown_file_limit" ] (diagnostic_codes result)));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let invalid index =
        Filename.concat knowledge (Printf.sprintf "bad#%05d.md" index)
      in
      for index = 1 to Clamp.Limits.max_markdown_files do
        write (invalid index) ""
      done;
      let exact_invalid = Clamp.Bundle.validate root in
      Alcotest.(check bool) "exact invalid-name file ceiling" false
        (List.mem "markdown_file_limit" (diagnostic_codes exact_invalid));
      let raced =
        Clamp.Bundle.For_test.validate_with_hook root ~after_preflight:(fun () ->
            write (invalid (Clamp.Limits.max_markdown_files + 1)) "")
      in
      Alcotest.(check (list string)) "invalid-name post-preflight overflow"
        [ "markdown_file_limit" ] (diagnostic_codes raced);
      Sys.remove (invalid (Clamp.Limits.max_markdown_files + 1));
      write (invalid (Clamp.Limits.max_markdown_files + 1)) "";
      let exceeded_invalid = Clamp.Bundle.validate root in
      Alcotest.(check (list string)) "invalid-name preflight overflow"
        [ "markdown_file_limit" ] (diagnostic_codes exceeded_invalid);
      Sys.remove (invalid (Clamp.Limits.max_markdown_files + 1));
      let half = Clamp.Limits.max_markdown_files / 2 in
      for index = 1 to half do
        Unix.rename (invalid index)
          (Filename.concat knowledge (Printf.sprintf "valid-%05d.md" index))
      done;
      let exact_mixed = Clamp.Bundle.validate root in
      Alcotest.(check bool) "exact mixed-name file ceiling" false
        (List.mem "markdown_file_limit" (diagnostic_codes exact_mixed));
      write (Filename.concat knowledge "valid-extra.md") "";
      let exceeded_mixed = Clamp.Bundle.validate root in
      Alcotest.(check (list string)) "mixed-name file overflow"
        [ "markdown_file_limit" ] (diagnostic_codes exceeded_mixed));
  with_bundle (fun root ->
      let knowledge = Filename.concat root "knowledge" in
      let invalid_parent = Filename.concat knowledge "bad#directory" in
      Unix.mkdir invalid_parent 0o700;
      for index = 1 to Clamp.Limits.max_markdown_files do
        write (Filename.concat invalid_parent (Printf.sprintf "%05d.md" index)) ""
      done;
      let exact = Clamp.Bundle.validate root in
      Alcotest.(check bool) "exact invalid-parent file ceiling" false
        (List.mem "markdown_file_limit" (diagnostic_codes exact));
      Alcotest.(check int) "invalid-parent files are not concepts" 0 exact.concepts;
      let raced =
        Clamp.Bundle.For_test.validate_with_hook root ~after_preflight:(fun () ->
            write (Filename.concat invalid_parent "10001.md") "")
      in
      Alcotest.(check (list string)) "invalid-parent post-preflight overflow"
        [ "markdown_file_limit" ] (diagnostic_codes raced);
      let exceeded = Clamp.Bundle.validate root in
      Alcotest.(check (list string)) "invalid-parent preflight overflow"
        [ "markdown_file_limit" ] (diagnostic_codes exceeded));
  with_bundle (fun root ->
      let link_body count =
        let body = Buffer.create (count * 20 + 64) in
        Buffer.add_string body
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n";
        for _ = 1 to count do
          Buffer.add_string body "[external](https://example.test) "
        done;
        Buffer.contents body
      in
      let half = Clamp.Limits.max_markdown_links / 2 in
      write (Filename.concat root "knowledge/links-a.md") (link_body half);
      write (Filename.concat root "knowledge/links-b.md") (link_body half);
      let exact_codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact Markdown link ceiling" false
        (List.mem "markdown_link_limit" exact_codes);
      write (Filename.concat root "knowledge/links-c.md") (link_body 1);
      let exceeded_codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "cumulative Markdown link ceiling" true
        (List.mem "markdown_link_limit" exceeded_codes));
  with_bundle (fun root ->
      let links count =
        let body = Buffer.create (count * 35 + 16) in
        for _ = 1 to count do
          Buffer.add_string body "[external](https://example.test) "
        done;
        Buffer.contents body
      in
      let index = Filename.concat root "knowledge/index.md" in
      write index ("# Index\n" ^ links Clamp.Limits.max_markdown_links);
      let exact_reserved = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact reserved link ceiling" false
        (List.mem "markdown_link_limit" exact_reserved);
      write index ("# Index\n" ^ links (Clamp.Limits.max_markdown_links + 1));
      let exceeded_reserved = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "reserved link ceiling exceeded" true
        (List.mem "markdown_link_limit" exceeded_reserved);
      Alcotest.(check bool) "overflow skips reserved structural extraction" false
        (List.mem "reserved_index_sections" exceeded_reserved);
      let half = Clamp.Limits.max_markdown_links / 2 in
      write index ("# Index\n" ^ links half);
      write (Filename.concat root "knowledge/mixed.md")
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n" ^ links half);
      let exact_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact mixed link ceiling" false
        (List.mem "markdown_link_limit" exact_mixed);
      write (Filename.concat root "knowledge/mixed.md")
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n"
        ^ links (half + 1));
      let exceeded_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "mixed link ceiling exceeded" true
        (List.mem "markdown_link_limit" exceeded_mixed));
  with_bundle (fun root ->
      let autolinks count =
        let body = Buffer.create (count * 15 + 64) in
        Buffer.add_string body
          "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n";
        for _ = 1 to count do
          Buffer.add_string body "<https://e.example> "
        done;
        Buffer.contents body
      in
      let path = Filename.concat root "knowledge/autolinks.md" in
      write path (autolinks Clamp.Limits.max_markdown_links);
      let exact = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact autolink ceiling" false
        (List.mem "markdown_link_limit" exact);
      write path (autolinks (Clamp.Limits.max_markdown_links + 1));
      let exceeded = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "autolink ceiling exceeded" true
        (List.mem "markdown_link_limit" exceeded));
  with_bundle (fun root ->
      let links count =
        let body = Buffer.create (count * 20 + 32) in
        for _ = 1 to count do Buffer.add_string body "[x](https://e.example) " done;
        Buffer.contents body
      in
      let index = Filename.concat root "knowledge/index.md" in
      let log = Filename.concat root "knowledge/log.md" in
      let invalid suffix body = body ^ suffix in
      write index (invalid "\255" ("# Index\n" ^ links Clamp.Limits.max_markdown_links));
      let exact_index = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact invalid-UTF8 index link ceiling" false
        (List.mem "markdown_link_limit" exact_index);
      write index
        (invalid "\255" ("# Index\n" ^ links (Clamp.Limits.max_markdown_links + 1)));
      let exceeded_index = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "invalid-UTF8 index link overflow" true
        (List.mem "markdown_link_limit" exceeded_index);
      Sys.remove index;
      write log
        (invalid "\255"
           ("# Log\n\n## 2026-08-06\n" ^ links Clamp.Limits.max_markdown_links));
      let exact_log = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact invalid-UTF8 log link ceiling" false
        (List.mem "markdown_link_limit" exact_log);
      write log
        (invalid "\255"
           ("# Log\n\n## 2026-08-06\n"
           ^ links (Clamp.Limits.max_markdown_links + 1)));
      let exceeded_log = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "invalid-UTF8 log link overflow" true
        (List.mem "markdown_link_limit" exceeded_log);
      Sys.remove log;
      let half = Clamp.Limits.max_markdown_links / 2 in
      write index (invalid "\255" ("# Index\n" ^ links half));
      write (Filename.concat root "knowledge/mixed-invalid-reserved.md")
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n" ^ links half);
      let exact_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact invalid-reserved/concept link ceiling" false
        (List.mem "markdown_link_limit" exact_mixed);
      write (Filename.concat root "knowledge/mixed-invalid-reserved.md")
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n"
        ^ links (half + 1));
      let exceeded_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "invalid-reserved/concept link overflow" true
        (List.mem "markdown_link_limit" exceeded_mixed));
  with_bundle (fun root ->
      let links count =
        let body = Buffer.create (count * 20 + 32) in
        for _ = 1 to count do
          Buffer.add_string body "[x](https://e.example) "
        done;
        Buffer.contents body
      in
      let malformed = Filename.concat root "knowledge/malformed.md" in
      let malformed_body count =
        "---\nmalformed: [\n---\n" ^ links count
      in
      write malformed (malformed_body Clamp.Limits.max_markdown_links);
      let exact = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact malformed-frontmatter link ceiling" false
        (List.mem "markdown_link_limit" exact);
      write malformed
        (malformed_body (Clamp.Limits.max_markdown_links + 1));
      let exceeded = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "malformed-frontmatter link ceiling exceeded" true
        (List.mem "markdown_link_limit" exceeded);
      let half = Clamp.Limits.max_markdown_links / 2 in
      write malformed (malformed_body half);
      let valid = Filename.concat root "knowledge/valid-links.md" in
      write valid
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n" ^ links half);
      let exact_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "exact invalid+valid mixed link ceiling" false
        (List.mem "markdown_link_limit" exact_mixed);
      write valid
        ("---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n"
        ^ links (half + 1));
      let exceeded_mixed = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "invalid+valid mixed link ceiling exceeded" true
        (List.mem "markdown_link_limit" exceeded_mixed));
  with_bundle (fun root ->
      let config = Filename.concat root "clamp.yaml" in
      let channel = open_out_bin config in
      seek_out channel Clamp.Limits.max_file_bytes;
      output_char channel 'x';
      close_out channel;
      let codes = diagnostic_codes (Clamp.Bundle.validate root) in
      Alcotest.(check bool) "config size diagnostic" true
        (List.mem "config_file_size_limit" codes))

let () =
  Alcotest.run "Phase 1 format"
    [ ( "YAML/frontmatter",
        [ Alcotest.test_case "exact roundtrip" `Quick exact_yaml_roundtrip;
          Alcotest.test_case "empty collection roundtrip" `Quick
            empty_collection_roundtrip;
          Alcotest.test_case "comment/style loss" `Quick yaml_style_loss;
          Alcotest.test_case "unsupported YAML" `Quick yaml_rejections;
          Alcotest.test_case "explicit standard tags" `Quick explicit_yaml_tags;
          Alcotest.test_case "depth and node limits" `Slow yaml_limits;
          Alcotest.test_case "frontmatter contract" `Quick frontmatter_contract ] );
      ( "metadata",
        [ Alcotest.test_case "standard and source fields" `Quick fields_table;
          Alcotest.test_case "explicit taxonomy" `Quick taxonomy;
          Alcotest.test_case "task fields" `Quick task_table;
          Alcotest.test_case "date/time/path/ULID" `Quick date_time_path_ulid;
          Alcotest.test_case "verification classification" `Quick
            verification_classification;
          Alcotest.test_case "CommonMark links" `Quick commonmark_links ] );
      ( "bundle",
        [ Alcotest.test_case "strict configuration" `Quick config_contract;
          Alcotest.test_case "fixture paths and links" `Quick bundle_fixture;
          Alcotest.test_case "path/link/symlink failures" `Quick bundle_safety;
          Alcotest.test_case "safe file reads" `Quick safe_file_contract;
          Alcotest.test_case "adversarial paths and reserved files" `Quick
            bundle_adversarial;
          Alcotest.test_case "reserved CommonMark" `Quick reserved_commonmark;
          Alcotest.test_case "reserved case collisions" `Quick
            reserved_case_collisions;
          Alcotest.test_case "namespace rules" `Quick namespace_rules;
          Alcotest.test_case "diagnostic limit" `Slow diagnostic_limit;
          Alcotest.test_case "exceptional descriptor cleanup" `Quick
            descriptor_cleanup;
          Alcotest.test_case "directory membership races" `Quick
            directory_membership_races;
          Alcotest.test_case "file and link limits" `Slow bundle_resource_limits
        ] ) ]
