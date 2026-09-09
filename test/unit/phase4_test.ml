let parse value =
  match Clamp.Frontmatter.parse value with
  | Ok concept -> concept
  | Error message -> Alcotest.fail message

let project_root =
  Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:"../.."

let fixture name =
  let path = Filename.concat project_root ("test/fixtures/phase4/" ^ name) in
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let input_fixture () =
  let concept =
    parse
      "---\ntype: fact\ntitle: \"Clamp\\r\\nidentity\"\ndescription: Stable semantic input\ntags: [beta, alpha, alpha]\ngenerated: {by: amp/agent, at: 2026-08-19T10:00:00Z}\nverified: [{by: human:x, at: 2026-08-19T10:01:00Z}]\nstatus: draft\nclamp: {asserted_by: human:x}\n---\nFirst line\r\nSecond line\r\n"
  in
  match Clamp.Embedding_input.make concept with
  | Error _ -> Alcotest.fail "fixture input rejected"
  | Ok result ->
      Alcotest.(check string) "exact input" (fixture "embedding_input.txt")
        result.text;
      Alcotest.(check string) "exact hash"
        (String.trim (fixture "embedding_input.sha256")) result.sha256

let canonical_concept ?(title = "") ?(description = "") ?(tags = []) body =
  let open Clamp.Exact_yaml in
  { Clamp.Frontmatter.metadata =
      Map
        [ ("type", Scalar (String, "fact"));
          ("title", Scalar (String, title));
          ("description", Scalar (String, description));
          ("tags", Seq (List.map (fun value -> Scalar (String, value)) tags)) ];
    body }

let canonical_text concept =
  match Clamp.Embedding_input.make concept with
  | Ok value -> value.text
  | Error _ -> Alcotest.fail "canonical fixture rejected"

let injective_fixtures () =
  let cases =
    [ ( "collision_multiline_a.txt",
        canonical_concept ~title:"alpha\r\ndescription:\r\nbeta" "" );
      ( "collision_multiline_b.txt",
        canonical_concept ~title:"alpha" ~description:"beta" "" );
      ("collision_tag_a.txt", canonical_concept ~tags:[ "a\r\n- b" ] "");
      ("collision_tag_b.txt", canonical_concept ~tags:[ "b"; "a" ] "");
      ("collision_tag_duplicate.txt", canonical_concept ~tags:[ "a"; "a" ] "");
      ("collision_tag_single.txt", canonical_concept ~tags:[ "a" ] "");
      ( "normalized_sorted_tags.txt",
        canonical_concept ~tags:[ "a\r\nz"; "a\nx" ] "" );
      ("empty_fields.txt", canonical_concept "");
      ("terminal_no_newline.txt", canonical_concept "x");
      ("terminal_newline.txt", canonical_concept "x\r\n") ]
  in
  List.iter
    (fun (name, concept) ->
      Alcotest.(check string) name (fixture name) (canonical_text concept))
    cases;
  let distinct left right name =
    Alcotest.(check bool) name true
      (canonical_text left <> canonical_text right)
  in
  distinct (List.assoc "collision_multiline_a.txt" cases)
    (List.assoc "collision_multiline_b.txt" cases)
    "multiline fields cannot collide";
  distinct (List.assoc "collision_tag_a.txt" cases)
    (List.assoc "collision_tag_b.txt" cases)
    "tag boundaries cannot collide";
  distinct (List.assoc "collision_tag_duplicate.txt" cases)
    (List.assoc "collision_tag_single.txt" cases)
    "duplicate tag boundaries cannot collide";
  distinct (List.assoc "terminal_no_newline.txt" cases)
    (List.assoc "terminal_newline.txt" cases)
    "terminal newline is semantic"

let predicates () =
  let concept extra body =
    parse
      ("---\ntype: task\ntitle: Link test\ndescription: Same\ntags: [one]\n"
      ^ extra
      ^ "clamp: {asserted_by: human:x, task: {state: todo, priority: normal}}\n---\n"
      ^ body ^ "\n")
  in
  let baseline = concept "" "Claim [label](old.md)." in
  let metadata =
    concept
      "verified: [{by: human:x, at: 2026-08-19T10:00:00Z}]\nstatus: draft\n"
      "Claim [label](old.md)."
  in
  let lifecycle =
    parse
      "---\ntype: task\ntitle: Link test\ndescription: Same\ntags: [one]\nclamp: {asserted_by: human:x, task: {state: doing, priority: urgent}}\n---\nClaim [label](old.md).\n"
  in
  let formatting = concept "" "  Claim   [label](old.md). " in
  let link = concept "" "Claim [label](new.md)." in
  let semantic = concept "" "Changed [label](old.md)." in
  let check name expected concept =
    match Clamp.Embedding_input.changed baseline concept with
    | Ok actual -> Alcotest.(check bool) name expected actual
    | Error _ -> Alcotest.fail (name ^ " rejected")
  in
  check "metadata only" false metadata;
  check "task lifecycle only" false lifecycle;
  check "formatting changes exact embedding input" true formatting;
  check "link destination changes exact embedding input" true link;
  check "semantic body" true semantic;
  Alcotest.(check bool) "formatting preserves verification" true
    (Clamp.Concept.classify_verification baseline formatting
    = Clamp.Concept.Preserve_verification);
  Alcotest.(check bool) "link preserves verification" true
    (Clamp.Concept.classify_verification baseline link
    = Clamp.Concept.Preserve_verification)

let boundaries () =
  let with_body bytes =
    let base =
      parse
        "---\ntype: fact\nclamp: {asserted_by: human:x}\n---\n"
    in
    let overhead =
      match Clamp.Embedding_input.make base with
      | Ok value -> String.length value.text
      | Error _ -> Alcotest.fail "overhead rejected"
    in
    { base with body = String.make (bytes - overhead) 'a' }
  in
  (match Clamp.Embedding_input.make (with_body 8000) with
  | Ok result -> Alcotest.(check int) "8,000 bytes" 8000 (String.length result.text)
  | Error _ -> Alcotest.fail "8,000 bytes rejected");
  (match Clamp.Embedding_input.make (with_body 8001) with
  | Error (Clamp.Embedding_input.Too_large { actual; maximum }) ->
      Alcotest.(check int) "actual" 8001 actual;
      Alcotest.(check int) "maximum" 8000 maximum
  | _ -> Alcotest.fail "8,001 bytes accepted");
  let base = with_body 7999 in
  let multibyte = { base with body = base.body ^ "\194\162" } in
  (match Clamp.Embedding_input.make multibyte with
  | Error (Clamp.Embedding_input.Too_large { actual; _ }) ->
      Alcotest.(check int) "multibyte counted as UTF-8 bytes" 8001 actual
  | _ -> Alcotest.fail "oversized multibyte input accepted");
  let invalid = { base with body = "\255" } in
  (match Clamp.Embedding_input.make invalid with
  | Error Clamp.Embedding_input.Invalid_utf8 -> ()
  | _ -> Alcotest.fail "invalid UTF-8 accepted")

let zeros ?(special = "0.0") () =
  List.init Clamp.Openrouter.dimensions (fun index ->
      if index = 0 then special else "0.0")
  |> String.concat ","

let shaped_response ?(top_object = "list") ?(item_object = "embedding")
    ?(index = 0) ?(model = "text-embedding-3-small")
    ?(usage = {|{"prompt_tokens":1,"total_tokens":1}|}) embedding =
  Printf.sprintf
    {|{"object":%S,"data":[{"object":%S,"index":%d,"embedding":[%s]}],"model":%S,"usage":%s}|}
    top_object item_object index embedding model usage

let response ?(model = "text-embedding-3-small") ?special () =
  shaped_response ~model (zeros ?special ())

let expect_error code = function
  | Error (error : Clamp.Openrouter.error) ->
      Alcotest.(check string) "error code" code error.code
  | Ok _ -> Alcotest.fail (code ^ " unexpectedly succeeded")

let test_error ?(ambiguous = false) kind code =
  Error
    { Clamp.Openrouter.kind;
      code;
      message = "safe test failure";
      paid_request_ambiguous = ambiguous }

let retry_policy () =
  let run request_kind failures =
    let clock = ref 0. and sleeps = ref [] and calls = ref 0
    and timeouts = ref [] in
    let queue = ref failures in
    let result =
      Clamp.Openrouter.For_test.run_retry ~request_kind ~total_timeout_ms:1000
        ~now:(fun () -> !clock)
        ~sleep:(fun delay -> sleeps := delay :: !sleeps; clock := !clock +. delay)
        ~jitter:(fun () -> 0.)
        ~operation:(fun ~timeout_ms ->
          incr calls;
          timeouts := timeout_ms :: !timeouts;
          match !queue with
          | [] -> Ok "done"
          | failure :: rest -> queue := rest; failure)
    in
    (result, !calls, List.rev !sleeps, List.rev !timeouts)
  in
  let transient = test_error Clamp.Openrouter.Transient "transient" in
  let ambiguous =
    test_error ~ambiguous:true Clamp.Openrouter.Transient "ambiguous"
  in
  let invalid = test_error Clamp.Openrouter.Invalid_response "invalid" in
  let result, calls, sleeps, timeouts =
    run Clamp.Openrouter.For_test.Non_paid_get [ transient; transient ]
  in
  Alcotest.(check (result string string)) "GET succeeds" (Ok "done")
    (Result.map_error (fun error -> error.Clamp.Openrouter.code) result);
  Alcotest.(check int) "GET capped attempts" 3 calls;
  Alcotest.(check (list (float 0.000001))) "backoff and jitter"
    [ 0.05; 0.1 ] sleeps;
  Alcotest.(check bool) "remaining timeout decreases" true
    (match timeouts with [ first; second; third ] -> first > second && second > third | _ -> false);
  let result, calls, _, _ =
    run Clamp.Openrouter.For_test.Non_paid_get
      [ transient; transient; transient; transient ]
  in
  expect_error "transient" result;
  Alcotest.(check int) "attempt cap" 3 calls;
  let rate_limited = test_error Clamp.Openrouter.Rate_limited "rate" in
  let _, calls, _, _ =
    run Clamp.Openrouter.For_test.Non_paid_get [ rate_limited ]
  in
  Alcotest.(check int) "GET retries rate limit" 2 calls;
  let _, calls, _, _ =
    run Clamp.Openrouter.For_test.Paid_post [ transient ]
  in
  Alcotest.(check int) "paid proven pre-send retries" 2 calls;
  let _, calls, sleeps, _ =
    run Clamp.Openrouter.For_test.Paid_post [ ambiguous ]
  in
  Alcotest.(check int) "paid ambiguous does not retry" 1 calls;
  Alcotest.(check int) "paid ambiguous has no backoff" 0 (List.length sleeps);
  let _, calls, _, _ =
    run Clamp.Openrouter.For_test.Paid_post [ invalid ]
  in
  Alcotest.(check int) "paid response failure does not retry" 1 calls;
  let _, calls, _, _ =
    run Clamp.Openrouter.For_test.Non_paid_get [ invalid ]
  in
  Alcotest.(check int) "GET deterministic failure does not retry" 1 calls;
  let clock = ref 0. and calls = ref 0 in
  let result =
    Clamp.Openrouter.For_test.run_retry
      ~request_kind:Clamp.Openrouter.For_test.Non_paid_get ~total_timeout_ms:1000
      ~now:(fun () -> !clock) ~sleep:(fun delay -> clock := !clock +. delay)
      ~jitter:(fun () -> 0.)
      ~operation:(fun ~timeout_ms:_ ->
        incr calls;
        clock := 0.98;
        transient)
  in
  expect_error "transient" result;
  Alcotest.(check int) "total deadline prevents backoff" 1 !calls

let curl_transport_context_matrix () =
  let former_allowlist =
    [ ("resolve proxy", Curl.CURLE_COULDNT_RESOLVE_PROXY);
      ("resolve host", Curl.CURLE_COULDNT_RESOLVE_HOST);
      ("connect", Curl.CURLE_COULDNT_CONNECT);
      ("SSL connect", Curl.CURLE_SSL_CONNECT_ERROR);
      ("SSL CA certificate", Curl.CURLE_SSL_CACERT);
      ("SSL peer certificate", Curl.CURLE_SSL_PEER_CERTIFICATE);
      ("SSL certificate problem", Curl.CURLE_SSL_CERTPROBLEM) ]
  in
  let check_safe name (error : Clamp.Openrouter.error) =
    List.iter
      (fun sentinel ->
        Alcotest.(check bool) (name ^ " redacted") false
          (let length = String.length sentinel in
           let rec contains offset =
             offset + length <= String.length error.message
             && (String.sub error.message offset length = sentinel
                || contains (offset + 1))
           in
           contains 0))
      [ "transport-key-sentinel"; "transport-input-sentinel";
        "transport-body-sentinel"; "transport-vector-sentinel" ]
  in
  List.iter
    (fun (name, code) ->
      let get_result, get_attempts =
        Clamp.Openrouter.For_test.with_curl_setup_exception code (fun () ->
            Clamp.Openrouter.For_test.authenticated_model_check_at
              ~timeout_ms:1000 ~url:"http://127.0.0.1:1/model"
              ~api_key:"transport-key-sentinel")
      in
      (match get_result with
      | Error error ->
          Alcotest.(check bool) (name ^ " GET transient") true
            (error.kind = Clamp.Openrouter.Transient);
          Alcotest.(check string) (name ^ " GET code")
            "openrouter_network_error" error.code;
          Alcotest.(check string) (name ^ " GET exact message")
            "OpenRouter could not be reached securely." error.message;
          Alcotest.(check bool) (name ^ " GET ambiguity") false
            error.paid_request_ambiguous;
          check_safe (name ^ " GET") error
      | Ok _ -> Alcotest.fail (name ^ " GET unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " GET bounded attempts") 3 get_attempts;
      let post_result, post_attempts =
        Clamp.Openrouter.For_test.with_curl_setup_exception code (fun () ->
            Clamp.Openrouter.For_test.embed_at ~timeout_ms:1000
              ~url:"http://127.0.0.1:1/embeddings"
              ~api_key:"transport-key-sentinel" "transport-input-sentinel")
      in
      (match post_result with
      | Error error ->
          Alcotest.(check bool) (name ^ " POST transient") true
            (error.kind = Clamp.Openrouter.Transient);
          Alcotest.(check string) (name ^ " POST code")
            "openrouter_network_error" error.code;
          Alcotest.(check string) (name ^ " POST exact message")
            "OpenRouter could not be reached securely." error.message;
          Alcotest.(check bool) (name ^ " POST ambiguity") true
            error.paid_request_ambiguous;
          check_safe (name ^ " POST") error
      | Ok _ -> Alcotest.fail (name ^ " POST unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " POST exactly one attempt") 1
        post_attempts)
    former_allowlist

let response_validation () =
  (match Clamp.Openrouter.parse_response ~status:200 ~body:(response ()) with
  | Ok value ->
      Alcotest.(check int) "dimensions" 1536 (Array.length value.values);
      Alcotest.(check string) "canonical identity"
        "openrouter:openai/text-embedding-3-small" value.identity
  | Error error -> Alcotest.fail error.code);
  (match
     Clamp.Openrouter.parse_response ~status:200
       ~body:(response ~model:"openai/text-embedding-3-small" ())
   with
  | Ok _ -> ()
  | Error error -> Alcotest.fail error.code);
  expect_error "openrouter_invalid_response"
    (Clamp.Openrouter.parse_response ~status:200 ~body:"not-json");
  expect_error "openrouter_invalid_embedding"
    (Clamp.Openrouter.parse_response ~status:200
       ~body:(response ~special:"1e999" ()));
  expect_error "openrouter_invalid_response"
    (Clamp.Openrouter.parse_response ~status:200
       ~body:
         {|{"data":[{"embedding":[0]}],"model":"text-embedding-3-small","usage":{"prompt_tokens":1,"total_tokens":1}}|});
  expect_error "openrouter_invalid_response"
    (Clamp.Openrouter.parse_response ~status:200
       ~body:
         (String.concat ""
            [ "{\"data\":[{\"embedding\":["; zeros ();
              "]}],\"model\":\"wrong/model\",\"usage\":{\"prompt_tokens\":1,\"total_tokens\":1}}" ]));
  expect_error "openrouter_invalid_response"
    (Clamp.Openrouter.parse_response ~status:200
       ~body:
         (String.concat ""
            [ "{\"data\":[{\"embedding\":["; zeros ();
              "]}],\"model\":\"text-embedding-3-small\",\"usage\":{\"prompt_tokens\":-1,\"total_tokens\":1}}" ]));
  expect_error "embedding_input_too_large"
    (Clamp.Openrouter.parse_response ~status:400
       ~body:{|{"error":{"message":"maximum context length exceeded"}}|});
  expect_error "openrouter_authentication_failed"
    (Clamp.Openrouter.parse_response ~status:401 ~body:"secret body");
  expect_error "openrouter_rate_limited"
    (Clamp.Openrouter.parse_response ~status:429 ~body:"{}")

let routing_payload () =
  Alcotest.(check string) "fixed payload"
    {|{"model":"openai/text-embedding-3-small","input":"hello","dimensions":1536,"provider":{"order":["openai"],"allow_fallbacks":false,"data_collection":"deny"}}|}
    (Clamp.Openrouter.request_body "hello")

let read_request descriptor =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec headers () =
    let count = Unix.read descriptor chunk 0 (Bytes.length chunk) in
    if count = 0 then Buffer.contents buffer
    else begin
      Buffer.add_subbytes buffer chunk 0 count;
      let value = Buffer.contents buffer in
      if String.contains value '\r' && String.split_on_char '\r' value |> List.length > 2
      then value
      else headers ()
    end
  in
  let initial = headers () in
  let marker = "\r\n\r\n" in
  let rec find index =
    if index + 4 > String.length initial then None
    else if String.sub initial index 4 = marker then Some index
    else find (index + 1)
  in
  match find 0 with
  | None -> initial
  | Some split ->
      let header = String.sub initial 0 split in
      let length =
        header |> String.split_on_char '\n'
        |> List.find_map (fun line ->
               let line = String.trim line in
               if String.starts_with ~prefix:"Content-Length:" line then
                 int_of_string_opt
                   (String.trim (String.sub line 15 (String.length line - 15)))
               else None)
        |> Option.value ~default:0
      in
      let have = String.length initial - split - 4 in
      while Buffer.length buffer < split + 4 + length do
        let count = Unix.read descriptor chunk 0 (Bytes.length chunk) in
        if count > 0 then Buffer.add_subbytes buffer chunk 0 count
      done;
      ignore have;
      Buffer.contents buffer

let with_server ?(delay = 0.) ?(status = 200) body action =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 1;
  let port =
    match Unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | _ -> assert false
  in
  let read_end, write_end = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close read_end;
      let client, _ = Unix.accept socket in
      let request = read_request client in
      ignore (Unix.write_substring write_end request 0 (String.length request));
      if delay > 0. then Unix.sleepf delay;
      let reply =
        Printf.sprintf
          "HTTP/1.1 %d Mock\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
          status (String.length body) body
      in
      (try ignore (Unix.write_substring client reply 0 (String.length reply)) with Unix.Unix_error _ -> ());
      Unix.close client;
      Unix.close write_end;
      Unix.close socket;
      exit 0
  | pid ->
      Unix.close write_end;
      let url = Printf.sprintf "http://127.0.0.1:%d/embeddings" port in
      let outcome = Fun.protect ~finally:(fun () -> Unix.close socket) (fun () -> action url) in
      let captured =
        let buffer = Buffer.create 1024 in
        let bytes = Bytes.create 4096 in
        let rec read () =
          match Unix.read read_end bytes 0 (Bytes.length bytes) with
          | 0 -> Buffer.contents buffer
          | count ->
              Buffer.add_subbytes buffer bytes 0 count;
              read ()
        in
        Fun.protect ~finally:(fun () -> Unix.close read_end) read
      in
      ignore (Unix.waitpid [] pid);
      (outcome, captured)

let with_sequence_server responses action =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 4;
  let port =
    match Unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | _ -> assert false
  in
  let read_end, write_end = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close read_end;
      let rec serve = function
        | [] -> ()
        | (status, body) :: rest ->
            let ready, _, _ = Unix.select [ socket ] [] [] 0.5 in
            if ready <> [] then begin
              let client, _ = Unix.accept socket in
              ignore (read_request client);
              ignore (Unix.write_substring write_end "x" 0 1);
              let reply =
                Printf.sprintf
                  "HTTP/1.1 %d Mock\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                  status (String.length body) body
              in
              (try
                 ignore (Unix.write_substring client reply 0 (String.length reply))
               with Unix.Unix_error _ -> ());
              Unix.close client;
              serve rest
            end
      in
      serve responses;
      Unix.close write_end;
      Unix.close socket;
      exit 0
  | pid ->
      Unix.close write_end;
      let url = Printf.sprintf "http://127.0.0.1:%d/model" port in
      let outcome = Fun.protect ~finally:(fun () -> Unix.close socket) (fun () -> action url) in
      let count =
        let bytes = Bytes.create 16 in
        let rec read total =
          match Unix.read read_end bytes 0 (Bytes.length bytes) with
          | 0 -> total
          | amount -> read (total + amount)
        in
        Fun.protect ~finally:(fun () -> Unix.close read_end) (fun () -> read 0)
      in
      ignore (Unix.waitpid [] pid);
      (outcome, count)

let http_408_policy () =
  let timeout_body = {|{"error":{"message":"secret-timeout-body"}}|} in
  let model_body =
    {|{"data":{"id":"openai/text-embedding-3-small"}}|}
  in
  let result, attempts =
    with_sequence_server [ (408, timeout_body); (200, model_body) ] (fun url ->
        Clamp.Openrouter.For_test.authenticated_model_check_at ~timeout_ms:1000
          ~url ~api_key:"test-get-key")
  in
  (match result with Ok () -> () | Error error -> Alcotest.fail error.code);
  Alcotest.(check int) "GET 408 then success attempts" 2 attempts;
  let result, attempts =
    with_sequence_server
      [ (408, timeout_body); (408, timeout_body); (408, timeout_body) ]
      (fun url ->
        Clamp.Openrouter.For_test.authenticated_model_check_at ~timeout_ms:1000
          ~url ~api_key:"test-get-key")
  in
  (match result with
  | Error error ->
      Alcotest.(check bool) "GET 408 transient" true
        (error.kind = Clamp.Openrouter.Transient);
      Alcotest.(check string) "GET 408 code" "openrouter_timeout" error.code;
      Alcotest.(check string) "GET 408 message" "OpenRouter request timed out."
        error.message;
      Alcotest.(check bool) "GET is not paid ambiguous" false
        error.paid_request_ambiguous
  | Ok () -> Alcotest.fail "repeated GET 408 succeeded");
  Alcotest.(check int) "GET repeated 408 bounded attempts" 3 attempts;
  let result, attempts =
    with_sequence_server [ (408, timeout_body); (200, response ()) ] (fun url ->
        Clamp.Openrouter.For_test.embed_at ~timeout_ms:1000 ~url
          ~api_key:"secret-post-key" "secret-post-input")
  in
  Alcotest.(check int) "paid POST sent exactly once" 1 attempts;
  (match result with
  | Error error ->
      Alcotest.(check bool) "paid 408 transient" true
        (error.kind = Clamp.Openrouter.Transient);
      Alcotest.(check string) "paid 408 code" "openrouter_timeout" error.code;
      Alcotest.(check string) "paid 408 stable message"
        "OpenRouter request timed out." error.message;
      Alcotest.(check bool) "paid 408 ambiguity" true
        error.paid_request_ambiguous;
      List.iter
        (fun secret ->
          Alcotest.(check bool) "paid 408 redacted" false
            (let length = String.length secret in
             let rec contains offset =
               offset + length <= String.length error.message
               && (String.sub error.message offset length = secret
                  || contains (offset + 1))
             in
             contains 0))
        [ "secret-timeout-body"; "secret-post-key"; "secret-post-input" ]
  | Ok _ -> Alcotest.fail "paid POST 408 succeeded")

let request_context_ambiguity_matrix () =
  let safe_body = {|{"error":{"message":"matrix-secret-body"}}|} in
  let cases =
    [ ( "402",
        402,
        safe_body,
        Clamp.Openrouter.Payment_required,
        "openrouter_payment_required",
        "OpenRouter credits are unavailable.",
        false );
      ( "408",
        408,
        safe_body,
        Clamp.Openrouter.Transient,
        "openrouter_timeout",
        "OpenRouter request timed out.",
        true );
      ( "429",
        429,
        safe_body,
        Clamp.Openrouter.Rate_limited,
        "openrouter_rate_limited",
        "OpenRouter rate limited the request.",
        true );
      ( "generic 4xx",
        418,
        safe_body,
        Clamp.Openrouter.Validation,
        "openrouter_request_rejected",
        "OpenRouter rejected the embedding request.",
        false );
      ( "5xx",
        503,
        safe_body,
        Clamp.Openrouter.Transient,
        "openrouter_unavailable",
        "OpenRouter returned a transient service failure.",
        true );
      ( "malformed 2xx",
        200,
        "{matrix-secret-body",
        Clamp.Openrouter.Invalid_response,
        "openrouter_invalid_model_response",
        "OpenRouter returned malformed model metadata.",
        false ) ]
  in
  let check_safe name (error : Clamp.Openrouter.error) =
    List.iter
      (fun secret ->
        Alcotest.(check bool) (name ^ " redacted") false
          (let length = String.length secret in
           let rec contains offset =
             offset + length <= String.length error.message
             && (String.sub error.message offset length = secret
                || contains (offset + 1))
           in
           contains 0))
      [ "matrix-secret-body"; "matrix-get-key"; "matrix-post-key";
        "matrix-post-input" ]
  in
  List.iter
    (fun (name, status, body, kind, code, message, get_retryable) ->
      let get_responses =
        if get_retryable then [ (status, body); (status, body); (status, body) ]
        else
          [ (status, body);
            (200, {|{"data":{"id":"openai/text-embedding-3-small"}}|}) ]
      in
      let get_result, get_attempts =
        with_sequence_server get_responses (fun url ->
            Clamp.Openrouter.For_test.authenticated_model_check_at
              ~timeout_ms:1000 ~url ~api_key:"matrix-get-key")
      in
      (match get_result with
      | Error error ->
          Alcotest.(check bool) (name ^ " GET kind") true (error.kind = kind);
          Alcotest.(check string) (name ^ " GET code") code error.code;
          Alcotest.(check string) (name ^ " GET message") message error.message;
          Alcotest.(check bool) (name ^ " GET ambiguity") false
            error.paid_request_ambiguous;
          check_safe (name ^ " GET") error
      | Ok () -> Alcotest.fail (name ^ " GET unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " GET attempts")
        (if get_retryable then 3 else 1)
        get_attempts;
      let post_result, post_attempts =
        with_sequence_server [ (status, body); (200, response ()) ] (fun url ->
            Clamp.Openrouter.For_test.embed_at ~timeout_ms:1000 ~url
              ~api_key:"matrix-post-key" "matrix-post-input")
      in
      (match post_result with
      | Error error ->
          let post_code, post_message =
            if status = 200 then
              ("openrouter_invalid_response", "OpenRouter returned malformed JSON.")
            else (code, message)
          in
          Alcotest.(check bool) (name ^ " POST kind") true (error.kind = kind);
          Alcotest.(check string) (name ^ " POST code") post_code error.code;
          Alcotest.(check string) (name ^ " POST message") post_message
            error.message;
          Alcotest.(check bool) (name ^ " POST ambiguity") true
            error.paid_request_ambiguous;
          check_safe (name ^ " POST") error
      | Ok _ -> Alcotest.fail (name ^ " POST unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " POST attempts") 1 post_attempts)
    cases

let invalid_2xx_context_matrix () =
  let oversized_sentinel = "matrix-oversized-body-sentinel" in
  let oversized =
    String.make Clamp.Openrouter.maximum_response_bytes 'x' ^ oversized_sentinel
  in
  let with_sentinel body sentinel =
    String.sub body 0 (String.length body - 1)
    ^ Printf.sprintf {|,"sentinel":%S}|} sentinel
  in
  let cases =
    [ ( "invalid shape",
        {|{"data":{"id":[]},"sentinel":"matrix-invalid-body-sentinel"}|},
        with_sentinel (shaped_response ~index:1 (zeros ()))
          "matrix-invalid-body-sentinel",
        Clamp.Openrouter.Invalid_response,
        "openrouter_invalid_model_response",
        "OpenRouter returned incompatible model metadata.",
        "openrouter_invalid_response",
        "OpenRouter returned invalid embedding or usage metadata.",
        "matrix-invalid-body-sentinel" );
      ( "nonfinite",
        {|{"data":{"id":1e999},"sentinel":"matrix-nonfinite-vector-sentinel"}|},
        with_sentinel (shaped_response (zeros ~special:"1e999" ()))
          "matrix-nonfinite-vector-sentinel",
        Clamp.Openrouter.Invalid_response,
        "openrouter_invalid_model_response",
        "OpenRouter returned incompatible model metadata.",
        "openrouter_invalid_embedding",
        "OpenRouter returned non-finite or non-numeric embedding values.",
        "matrix-nonfinite-vector-sentinel" );
      ( "oversized",
        oversized,
        oversized,
        Clamp.Openrouter.Response_too_large,
        "openrouter_response_too_large",
        "OpenRouter response exceeded the safe size limit.",
        "openrouter_response_too_large",
        "OpenRouter response exceeded the safe size limit.",
        oversized_sentinel ) ]
  in
  let check_safe name sentinel (error : Clamp.Openrouter.error) =
    List.iter
      (fun secret ->
        Alcotest.(check bool) (name ^ " redacted") false
          (let length = String.length secret in
           let rec contains offset =
             offset + length <= String.length error.message
             && (String.sub error.message offset length = secret
                || contains (offset + 1))
           in
           contains 0))
      [ "matrix-2xx-get-key"; "matrix-2xx-post-key";
        "matrix-2xx-post-input"; sentinel ]
  in
  List.iter
    (fun
      ( name,
        get_body,
        post_body,
        kind,
        get_code,
        get_message,
        post_code,
        post_message,
        sentinel ) ->
      let get_result, get_attempts =
        with_sequence_server [ (200, get_body) ] (fun url ->
            Clamp.Openrouter.For_test.authenticated_model_check_at
              ~timeout_ms:1000 ~url ~api_key:"matrix-2xx-get-key")
      in
      (match get_result with
      | Error error ->
          Alcotest.(check bool) (name ^ " GET kind") true (error.kind = kind);
          Alcotest.(check string) (name ^ " GET code") get_code error.code;
          Alcotest.(check string) (name ^ " GET exact message") get_message
            error.message;
          Alcotest.(check bool) (name ^ " GET ambiguity") false
            error.paid_request_ambiguous;
          check_safe (name ^ " GET") sentinel error
      | Ok () -> Alcotest.fail (name ^ " GET unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " GET attempts") 1 get_attempts;
      let post_result, post_attempts =
        with_sequence_server [ (200, post_body) ] (fun url ->
            Clamp.Openrouter.For_test.embed_at ~timeout_ms:1000 ~url
              ~api_key:"matrix-2xx-post-key" "matrix-2xx-post-input")
      in
      (match post_result with
      | Error error ->
          Alcotest.(check bool) (name ^ " POST kind") true (error.kind = kind);
          Alcotest.(check string) (name ^ " POST code") post_code error.code;
          Alcotest.(check string) (name ^ " POST exact message") post_message
            error.message;
          Alcotest.(check bool) (name ^ " POST ambiguity") true
            error.paid_request_ambiguous;
          check_safe (name ^ " POST") sentinel error
      | Ok _ -> Alcotest.fail (name ^ " POST unexpectedly succeeded"));
      Alcotest.(check int) (name ^ " POST attempts") 1 post_attempts)
    cases

let paid_boundary_failures () =
  let cases =
    [ ("malformed JSON", "{secret-response-body", "openrouter_invalid_response");
      ( "model",
        shaped_response ~model:"wrong/model" (zeros ()),
        "openrouter_invalid_response" );
      ( "object",
        shaped_response ~top_object:"wrong" (zeros ()),
        "openrouter_invalid_response" );
      ( "item object",
        shaped_response ~item_object:"wrong" (zeros ()),
        "openrouter_invalid_response" );
      ( "index",
        shaped_response ~index:1 (zeros ()),
        "openrouter_invalid_response" );
      ( "usage",
        shaped_response ~usage:"{}" (zeros ()),
        "openrouter_invalid_response" );
      ("dimension", shaped_response "0.0", "openrouter_invalid_response");
      ( "nonfinite",
        shaped_response (zeros ~special:"1e999" ()),
        "openrouter_invalid_embedding" ) ]
  in
  List.iter
    (fun (name, body, code) ->
      let result, request =
        with_server body (fun url ->
            Clamp.Openrouter.For_test.embed_at ~url
              ~api_key:"secret-api-key" "secret-input")
      in
      Alcotest.(check bool) (name ^ " request occurred") true (request <> "");
      match result with
      | Error error ->
          Alcotest.(check string) (name ^ " code") code error.code;
          Alcotest.(check bool) (name ^ " paid ambiguity") true
            error.paid_request_ambiguous;
          List.iter
            (fun secret ->
              Alcotest.(check bool) (name ^ " safe error") false
                (let length = String.length secret in
                 let rec contains offset =
                   offset + length <= String.length error.message
                   && (String.sub error.message offset length = secret
                      || contains (offset + 1))
                 in
                 contains 0))
            [ "secret-api-key"; "secret-input"; "secret-response-body" ]
      | Ok _ -> Alcotest.fail (name ^ " unexpectedly succeeded"))
    cases;
  let oversized = String.make (Clamp.Openrouter.maximum_response_bytes + 1) 'x' in
  let result, _ =
    with_server oversized (fun url ->
        Clamp.Openrouter.For_test.embed_at ~url ~api_key:"secret-api-key"
          "secret-input")
  in
  (match result with
  | Error error ->
      Alcotest.(check string) "oversize code" "openrouter_response_too_large"
        error.code;
      Alcotest.(check bool) "oversize paid ambiguity" true
        error.paid_request_ambiguous;
      Alcotest.(check string) "oversize safe message"
        "OpenRouter response exceeded the safe size limit." error.message
  | Ok _ -> Alcotest.fail "oversize unexpectedly succeeded")

let mock_http () =
  let result, request =
    with_server (response ()) (fun url ->
        Clamp.Openrouter.For_test.embed_at ~url ~api_key:"test-api-key" "hello")
  in
  (match result with Ok _ -> () | Error error -> Alcotest.fail error.code);
  Alcotest.(check bool) "authorization sent" true
    (let needle = "Authorization: Bearer test-api-key" in
     let rec loop index =
       index + String.length needle <= String.length request
       && (String.sub request index (String.length needle) = needle || loop (index + 1))
     in loop 0);
  Alcotest.(check bool) "routing payload sent" true
    (String.ends_with ~suffix:(Clamp.Openrouter.request_body "hello") request);
  let oversized = String.make (Clamp.Openrouter.maximum_response_bytes + 1) 'x' in
  let result, _ =
    with_server oversized (fun url ->
        Clamp.Openrouter.For_test.embed_at ~url ~api_key:"test-api-key" "hello")
  in
  expect_error "openrouter_response_too_large" result;
  let result, _ =
    with_server ~status:500 "{\"error\":{\"message\":\"hidden body\"}}"
      (fun url ->
        Clamp.Openrouter.For_test.embed_at ~url ~api_key:"test-api-key" "hello")
  in
  (match result with
  | Error error ->
      Alcotest.(check string) "5xx classification" "openrouter_unavailable"
        error.code;
      Alcotest.(check string) "5xx body redacted"
        "OpenRouter returned a transient service failure." error.message;
      Alcotest.(check bool) "5xx paid ambiguity" true
        error.paid_request_ambiguous
  | Ok _ -> Alcotest.fail "5xx succeeded");
  let result, _ =
    with_server ~status:404 "not JSON" (fun url ->
        Clamp.Openrouter.For_test.embed_at ~url ~api_key:"test-api-key" "hello")
  in
  expect_error "openrouter_request_rejected" result;
  let result, _ =
    with_server ~delay:0.2 (response ()) (fun url ->
        Clamp.Openrouter.For_test.embed_at ~timeout_ms:50 ~url
          ~api_key:"test-api-key" "hello")
  in
  (match result with
  | Error error ->
      Alcotest.(check string) "timeout" "openrouter_timeout" error.code;
      Alcotest.(check bool) "paid ambiguity surfaced" true
        error.paid_request_ambiguous
  | Ok _ -> Alcotest.fail "timeout succeeded")

let preflight () =
  expect_error "embedding_input_invalid_utf8"
    (Clamp.Openrouter.embed ~api_key:"unused" "\255");
  expect_error "embedding_input_too_large"
    (Clamp.Openrouter.embed ~api_key:"unused" (String.make 8001 'x'));
  expect_error "openrouter_api_key_missing"
    (Clamp.Openrouter.embed ~api_key:"" "hello")

let () =
  Alcotest.run "Phase 4 embedding and OpenRouter"
    [ ( "embedding input",
        [ Alcotest.test_case "exact fixture and hash" `Quick input_fixture;
          Alcotest.test_case "injective canonical fixtures" `Quick
            injective_fixtures;
          Alcotest.test_case "predicate cross-tests" `Quick predicates;
          Alcotest.test_case "byte and UTF-8 boundaries" `Quick boundaries ] );
      ( "OpenRouter",
        [ Alcotest.test_case "fixed routing payload" `Quick routing_payload;
          Alcotest.test_case "bounded retry policy" `Quick retry_policy;
          Alcotest.test_case "CURL transport context matrix" `Quick
            curl_transport_context_matrix;
          Alcotest.test_case "HTTP 408 retry and ambiguity" `Quick
            http_408_policy;
          Alcotest.test_case "request-context ambiguity matrix" `Quick
            request_context_ambiguity_matrix;
          Alcotest.test_case "invalid 2xx context matrix" `Quick
            invalid_2xx_context_matrix;
          Alcotest.test_case "strict response validation" `Quick response_validation;
          Alcotest.test_case "paid boundary ambiguity" `Quick
            paid_boundary_failures;
          Alcotest.test_case "preflight" `Quick preflight;
          Alcotest.test_case "bounded mock HTTP" `Quick mock_http ] ) ]
