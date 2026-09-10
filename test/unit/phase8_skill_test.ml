let source_root =
  Option.value (Sys.getenv_opt "DUNE_SOURCEROOT")
    ~default:(if Sys.file_exists ".agents/skills" then "." else "../..")

let skill_path =
  Filename.concat source_root
    ".agents/skills/managing-clamp-knowledge/SKILL.md"

let fixture_path =
  Filename.concat source_root "test/fixtures/phase8/command-results.json"

let prd_path = Filename.concat source_root "PRD.md"
let acceptance_path = Filename.concat source_root "ACCEPTANCE.md"

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false

let normalize_whitespace text =
  Str.global_replace (Str.regexp "[ \n\r\t]+") " " text

let check_contains label text fragment =
  Alcotest.(check bool) label true
    (contains (normalize_whitespace text) (normalize_whitespace fragment))

let check_absent label text fragment =
  Alcotest.(check bool) label false
    (contains (normalize_whitespace text) (normalize_whitespace fragment))

let field prefix lines =
  lines
  |> List.find_map (fun line ->
         if String.starts_with ~prefix line then
           Some
             (String.sub line (String.length prefix)
                (String.length line - String.length prefix))
         else None)

let unquote value =
  let length = String.length value in
  if length >= 2 && value.[0] = '"' && value.[length - 1] = '"' then
    String.sub value 1 (length - 2)
  else value

let skill_static_validation () =
  let text = read skill_path in
  Alcotest.(check bool) "LF-only skill" false (String.contains text '\r');
  Alcotest.(check bool) "frontmatter starts file" true
    (String.starts_with ~prefix:"---\n" text);
  let lines = String.split_on_char '\n' text in
  Alcotest.(check bool) "progressive disclosure threshold" true
    (List.length lines <= 500);
  let closing =
    let rec find index = function
      | [] -> Alcotest.fail "skill frontmatter is not closed"
      | "---" :: _ when index > 0 -> index
      | _ :: rest -> find (index + 1) rest
    in
    find 0 (List.tl lines)
  in
  let frontmatter = List.filteri (fun index _ -> index <= closing) lines in
  let name = Option.get (field "name: " frontmatter) in
  let description = Option.get (field "description: " frontmatter) |> unquote in
  let compatibility = Option.get (field "compatibility: " frontmatter) |> unquote in
  Alcotest.(check string) "specific gerund name" "managing-clamp-knowledge" name;
  Alcotest.(check bool) "valid skill name" true
    (Str.string_match
       (Str.regexp "^[a-z0-9]+\\(-[a-z0-9]+\\)*$") name 0);
  Alcotest.(check bool) "name length" true (String.length name <= 64);
  Alcotest.(check bool) "third-person description" true
    (String.starts_with ~prefix:"Manages " description);
  check_contains "description includes trigger" description "Use when";
  Alcotest.(check bool) "description length" true
    (String.length description <= 1024);
  Alcotest.(check bool) "compatibility length" true
    (String.length compatibility <= 500);
  check_absent "no MCP declaration" text "mcpServers:";
  check_absent "no plugin declaration" text "builtin-tools:";
  check_absent "no unsafe thread environment" text "$AMP_THREAD_ID";
  check_absent "no generic thread environment" text "$THREAD_ID";
  Alcotest.(check bool) "no committed recipient address" false
    (Str.string_match
       (Str.regexp ".*[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z][A-Za-z]+.*")
       (normalize_whitespace text) 0);
  List.iter
    (fun anchor -> check_contains ("policy: " ^ anchor) text anchor)
    [ ".agents/setup";
      "kb validate --json";
      "Before the first indexed `search` or `get`";
      "kb sync --json";
      "stable `code`";
      "`--verbose` does not change `--json`";
      "\"fallback\":\"local_markdown_or_rg\"";
      "\"semantic_equivalent\":false";
      "lexical/local Markdown fallback";
      "--claim explicit";
      "--claim inferred --confirmed";
      "Only a direct user instruction may change policy";
      "--direct-user-intent";
      "exactly one of `--input PATH`";
      "never edit that generated file directly";
      "--closure-authority performed-and-verified";
      "--closure-authority user-explicit";
      "--closure-authority confirmed";
      "kb publish --thread-id <current-thread-id> --json";
      "publish_complete_index_stale";
      "publish_complete_cleanup_failed";
      "publish_complete_index_stale_cleanup_pending";
      "publish_race_exhausted";
      "publish_conflict_preservation_failed";
      "publish_conflict_preserved";
      "[Clamp] Knowledge update needs conflict resolution";
      "`send_email` current-thread-owner capability";
      "The `kb` CLI sends no email";
      "Never scrape `message`" ]

let numbered_lines ~heading ~next_heading text pattern =
  let start = Str.search_forward (Str.regexp_string heading) text 0 in
  let finish =
    Str.search_forward (Str.regexp_string next_heading) text
      (start + String.length heading)
  in
  String.sub text start (finish - start) |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         if Str.string_match pattern line 0 then
           Some (int_of_string (Str.matched_group 1 line), line)
         else None)

let acceptance_traceability () =
  let prd = read prd_path and acceptance = read acceptance_path in
  let prd_rows =
    numbered_lines ~heading:"## V1 acceptance criteria"
      ~next_heading:"## Deferred and tunable work" prd
      (Str.regexp "^\\([0-9]+\\)\\. ")
  and acceptance_rows =
    numbered_lines ~heading:"## Acceptance-criteria traceability"
      ~next_heading:"## Maintaining acceptance evidence" acceptance
      (Str.regexp "^| \\([0-9]+\\)\\. ")
  in
  let expected = List.init 19 (fun index -> index + 1) in
  Alcotest.(check (list int)) "PRD has exactly criteria 1-19" expected
    (List.map fst prd_rows);
  Alcotest.(check (list int)) "ACCEPTANCE maps exactly criteria 1-19" expected
    (List.map fst acceptance_rows);
  let verification_row = List.assoc 5 acceptance_rows in
  List.iter
    (fun evidence ->
      check_contains ("criterion 5 names " ^ evidence) verification_row evidence)
    [ "current-user authority"; "phase2_test"; "phase8_workflow_test";
      "command_contract.t" ]

let json_equal label expected actual =
  Alcotest.(check bool) label true (Yojson.Safe.equal expected actual)

let expected_case_action id code =
  match id, code with
  | "fresh-sync", "sync_complete" -> "indexed_retrieval_ready"
  | "search", "search_complete" -> "inspect_ranked_candidates"
  | "get", "concept_retrieved" -> "report_full_content_access"
  | ("explicit-fact" | "inference-confirmed" | "journal"), "concept_added"
    -> "mutation_recorded"
  | "inference-blocked", "confirmation_required" ->
      "ask_for_confirmation_without_write"
  | "auto-draft-policy", "config_updated" ->
      "policy_updated_by_direct_user_intent"
  | "auto-draft-write", "concept_added" -> "unverified_draft_recorded"
  | ("verification-authority-required", "verification_authority_required")
  | ("verification-agent-rejected", "invalid_verification_authority") ->
      "do_not_record_human_verification"
  | "verify-user-explicit", "concept_verified" ->
      "human_verification_recorded"
  | "deprecate", "concept_deprecated" -> "mutation_recorded"
  | "task-add", "task_added" -> "retain_returned_task_id"
  | ("task-start", "task_started") | ("task-done", "task_done") ->
      "pass_returned_task_id_unchanged"
  | "degraded-search", "database_unavailable" -> "local_lexical_fallback"
  | "publish-success", "publish_complete" ->
      "report_durable_publication_and_index"
  | _ -> Alcotest.failf "fixture case %s has unsupported code %s" id code

let command_fixture_policy () =
  let text = read skill_path in
  let json = Yojson.Safe.from_file fixture_path in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "fixture schema" 2
    (json |> member "schema_version" |> to_int);
  Alcotest.(check string) "fixture skill" "managing-clamp-knowledge"
    (json |> member "skill" |> to_string);
  let seen = Hashtbl.create 32 in
  json |> member "cases" |> to_list
  |> List.iter (fun case ->
         let id = case |> member "id" |> to_string
         and command = case |> member "command" |> to_string
         and response = case |> member "response"
         and action = case |> member "expected_action" |> to_string in
         Alcotest.(check bool) (id ^ " unique") false (Hashtbl.mem seen id);
         Hashtbl.add seen id ();
         let ok = response |> member "ok" |> to_bool
         and code = response |> member "code" |> to_string in
         check_contains (id ^ " command documented") text command;
         Alcotest.(check string) (id ^ " executable policy action")
           (expected_case_action id code) action;
         Alcotest.(check bool) (id ^ " machine command") true
           (String.ends_with ~suffix:"--json" command);
         if ok then
           Alcotest.(check bool) (id ^ " success data") true
             (response |> member "data" <> `Null)
         else begin
           Alcotest.(check bool) (id ^ " failure message") true
             (response |> member "message" <> `Null);
           Alcotest.(check bool) (id ^ " failure details") true
             (response |> member "details" <> `Null)
         end);
  Alcotest.(check int) "complete command case count" 18 (Hashtbl.length seen);
  let case id =
    json |> member "cases" |> to_list
    |> List.find (fun value -> value |> member "id" |> to_string = id)
  in
  let task_id =
    case "task-add" |> member "response" |> member "data" |> member "id"
    |> to_string
  in
  Alcotest.(check bool) "returned task ID includes tasks namespace" true
    (String.starts_with ~prefix:"tasks/" task_id);
  List.iter
    (fun id ->
      let value = case id in
      let command = value |> member "command" |> to_string
      and returned =
        value |> member "response" |> member "data" |> member "id"
        |> to_string
      in
      Alcotest.(check string) (id ^ " returns same ID") task_id returned;
      check_contains (id ^ " passes placeholder unchanged") command
        "<returned-task-id>";
      check_absent (id ^ " does not duplicate namespace") command
        "tasks/<returned-task-id>")
    [ "task-start"; "task-done" ];
  let automatic = case "auto-draft-write" |> member "command" |> to_string in
  check_contains "auto_draft uses inferred authority" automatic "--claim inferred";
  check_absent "auto_draft remains unconfirmed" automatic "--confirmed";
  let verify = case "verify-user-explicit" |> member "command" |> to_string in
  check_contains "verification has direct user authority" verify
    "--verification-authority user-explicit";
  let agent_review =
    case "verification-agent-rejected" |> member "command" |> to_string
  in
  check_contains "agent review fixture is rejected" agent_review "agent-reviewed"

let sync_kind = function
  | "validation" -> Clamp.Sync.Validation
  | "authentication" -> Authentication
  | "transient" -> Transient
  | "internal" -> Internal
  | value -> Alcotest.failf "unknown sync fixture kind %s" value

let sync_kind_name = function
  | Clamp.Sync.Validation -> "validation"
  | Authentication -> "authentication"
  | Transient -> "transient"
  | Internal -> "internal"

let producer_sync_error code message =
  let database_kind =
    match code with
    | "database_authentication_failed" -> Some Clamp.Database.Authentication
    | "database_connection_timeout" | "database_query_timeout" ->
        Some Clamp.Database.Timeout
    | "database_connection_lost" | "database_unavailable" ->
        Some Clamp.Database.Transient
    | _ -> None
  in
  match database_kind with
  | Some database_kind ->
      Clamp.Sync.For_test.database_error
        { Clamp.Database.code; message; kind = database_kind;
          finalization = Clamp.Database.Before_commit_dispatch }
  | None ->
      let openrouter_status =
        match code with
        | "openrouter_authentication_failed" -> Some 401
        | "openrouter_payment_required" -> Some 402
        | "openrouter_timeout" -> Some 408
        | "openrouter_rate_limited" -> Some 429
        | "openrouter_unavailable" -> Some 503
        | _ -> None
      in
      (match openrouter_status with
      | Some status ->
          let upstream =
            match Clamp.Openrouter.parse_response ~status ~body:"{}" with
            | Error error -> error
            | Ok _ -> Alcotest.failf "OpenRouter status %d unexpectedly succeeded" status
          in
          Clamp.Sync.For_test.openrouter_error upstream
      | None when code = "openrouter_network_error" ->
          Clamp.Sync.For_test.openrouter_error
            { Clamp.Openrouter.kind = Transient; code; message;
              paid_request_ambiguous = true }
      | None -> Clamp.Sync.fallback_error ~code ~message)

let sync_failure_contracts () =
  let json = Yojson.Safe.from_file fixture_path in
  let open Yojson.Safe.Util in
  let contracts = json |> member "sync_failure_contracts" |> to_list in
  let fixture_producers =
    contracts
    |> List.map (fun contract ->
           ( contract |> member "code" |> to_string,
             contract |> member "kind" |> to_string ))
    |> List.sort compare
  and production_producers =
    Clamp.Sync.fallback_producers ()
    |> List.map (fun (code, kind) -> code, sync_kind_name kind)
    |> List.sort compare
  in
  Alcotest.(check int) "current authoritative producer count" 21
    (List.length production_producers);
  Alcotest.(check (list (pair string string)))
    "fixture exactly matches authoritative production producers"
    production_producers fixture_producers;
  contracts
  |> List.iter (fun contract ->
         let code = contract |> member "code" |> to_string
         and message = contract |> member "message" |> to_string
         and kind = contract |> member "kind" |> to_string |> sync_kind
         and expected = contract |> member "response"
         and expected_exit = contract |> member "expected_exit" |> to_int in
         let error = producer_sync_error code message in
         Alcotest.(check bool) (code ^ " adapter kind") true
           (error.kind = kind);
         Alcotest.(check string) (code ^ " adapter code") code error.code;
         let result = Clamp.Sync.cli_result error in
         json_equal (code ^ " exact production envelope") expected
           (Clamp.Cli_result.to_yojson result);
         Alcotest.(check int) (code ^ " exit class") expected_exit
           (Clamp.Cli_result.exit_code result);
         let details = expected |> member "details" in
         Alcotest.(check string) (code ^ " fallback")
           "local_markdown_or_rg" (details |> member "fallback" |> to_string);
         Alcotest.(check bool) (code ^ " non-equivalence") false
           (details |> member "semantic_equivalent" |> to_bool));
  List.iter
    (fun (code, kind) ->
      Alcotest.(check bool) (code ^ " fallback kind is eligible") true
        (kind = Clamp.Sync.Authentication || kind = Transient
         || (code = "database_direct_url_missing" && kind = Validation)))
    (Clamp.Sync.fallback_producers ())

let sync_diagnostics_preserved () =
  let diagnostic =
    Clamp.Diagnostic.make ~severity:Clamp.Diagnostic.Warning ~field:"type"
      "knowledge/facts/example.md"
      "unknown_type" "unknown non-empty OKF type"
  in
  let error : Clamp.Sync.error =
    { kind = Transient; code = "database_unavailable";
      message = "Database connection failed."; diagnostics = [ diagnostic ] }
  in
  let result = Clamp.Sync.cli_result error |> Clamp.Cli_result.to_yojson in
  let open Yojson.Safe.Util in
  let details = result |> member "details" in
  Alcotest.(check string) "diagnostic error fallback preserved"
    "local_markdown_or_rg" (details |> member "fallback" |> to_string);
  Alcotest.(check bool) "diagnostic error remains non-equivalent" false
    (details |> member "semantic_equivalent" |> to_bool);
  json_equal "diagnostics preserved unchanged"
    (`List [ Clamp.Diagnostic.json diagnostic ])
    (details |> member "diagnostics");
  List.iter
    (fun (label, error : string * Clamp.Sync.error) ->
      let details =
        Clamp.Sync.cli_result error |> Clamp.Cli_result.to_yojson
        |> member "details"
      in
      Alcotest.(check bool) (label ^ " has no fallback") true
        (details |> member "fallback" = `Null))
    [ ( "deterministic validation",
        { kind = Validation; code = "index_state_missing";
          message = "fixture"; diagnostics = [] } );
      ( "deterministic internal",
        { kind = Internal; code = "sync_plan_invalid";
          message = "fixture"; diagnostics = [] } );
      ( "publication-only remote verification",
        { kind = Transient; code = "git_remote_ref_unavailable";
          message = "fixture"; diagnostics = [] } ) ]

let publication_kind = function
  | "validation" -> Clamp.Publication.Validation
  | "conflict" -> Conflict
  | "authentication" -> Authentication
  | "transient" -> Transient
  | "stale" -> Stale
  | "internal" -> Internal
  | value -> Alcotest.failf "unknown publication fixture kind %s" value

let optional_string json name =
  match Yojson.Safe.Util.member name json with
  | `Null -> None
  | `String value -> Some value
  | _ -> Alcotest.failf "publication fixture %s is not a string option" name

let publication_action (error : Clamp.Publication.error) =
  match error.code with
  | "publish_complete_cleanup_failed" when error.published ->
      "retry_main_cleanup_without_email"
  | "publish_complete_index_stale" when error.published ->
      "report_published_and_resync_without_email"
  | "publish_complete_index_stale_cleanup_pending" when error.published ->
      "report_index_and_cleanup_obligations_without_email"
  | "publish_race_exhausted" when not error.published ->
      "report_recovery_branch_without_email"
  | "publish_conflict" when not error.preserved ->
      "attempt_semantic_resolution_without_email"
  | "publish_conflict_post_abort_preservation_required"
    when not error.preserved ->
      "retry_verified_post_abort_preservation_without_email"
  | "publish_conflict_post_abort_unverified" when not error.preserved ->
      "retain_owner_work_and_state_without_email"
  | "publish_conflict_preservation_allocation_failed"
    when not error.preserved ->
      "retry_branch_allocation_without_email"
  | "publish_conflict_preservation_failed"
    when error.preservation_pending && not error.preserved ->
      "retry_exact_pending_preservation_without_email"
  | "publish_conflict_preserved_cleanup_pending"
    when error.preserved && error.cleanup_pending ->
      "email_once_and_retry_cleanup_without_repush"
  | "publish_conflict_preserved"
    when error.preserved && not error.cleanup_pending ->
      "email_once_without_cleanup_obligation"
  | _ -> Alcotest.failf "unsupported publication policy case %s" error.code

let publication_failure_contracts () =
  let json = Yojson.Safe.from_file fixture_path in
  let open Yojson.Safe.Util in
  let seen = ref [] in
  json |> member "publication_failure_contracts" |> to_list
  |> List.iter (fun contract ->
         let code = contract |> member "code" |> to_string in
         let error : Clamp.Publication.error =
           { kind = contract |> member "kind" |> to_string |> publication_kind;
             code;
             message = contract |> member "message" |> to_string;
             published = contract |> member "published" |> to_bool;
             preserved = contract |> member "preserved" |> to_bool;
             preservation_pending =
               (match contract |> member "preservation_pending" with
               | `Null -> false
               | value -> to_bool value);
             cleanup_pending =
               contract |> member "cleanup_pending" |> to_bool;
             commit = optional_string contract "commit";
             branch = optional_string contract "branch";
             paths = contract |> member "paths" |> to_list |> List.map to_string;
             cause = optional_string contract "cause";
             cleanup_cause = optional_string contract "cleanup_cause";
             diagnostics = [] }
         in
         seen := code :: !seen;
         let result =
           Clamp.Cli_result.failure
             ~exit_class:(Clamp.Publication.exit_class error) ~code:error.code
             ~message:error.message
             ~details:(Clamp.Publication.error_details error)
         in
         json_equal (code ^ " exact production envelope")
           (contract |> member "response") (Clamp.Cli_result.to_yojson result);
         Alcotest.(check int) (code ^ " exit class")
           (contract |> member "expected_exit" |> to_int)
           (Clamp.Cli_result.exit_code result);
         Alcotest.(check string) (code ^ " executable policy")
           (contract |> member "expected_action" |> to_string)
           (publication_action error));
  Alcotest.(check int) "all publication policy variants executed" 11
    (List.length !seen)

let notification_simulation () =
  let json = Yojson.Safe.from_file fixture_path in
  let open Yojson.Safe.Util in
  let simulation = json |> member "notification_simulation" in
  Alcotest.(check string) "exact subject"
    "[Clamp] Knowledge update needs conflict resolution"
    (simulation |> member "subject" |> to_string);
  let thread_url = simulation |> member "thread_url" |> to_string
  and branch = simulation |> member "branch" |> to_string
  and commit = simulation |> member "commit" |> to_string
  and paths =
    simulation |> member "paths" |> to_list |> List.map to_string
  in
  Alcotest.(check bool) "direct Amp thread URL" true
    (String.starts_with ~prefix:"https://ampcode.com/threads/T-" thread_url);
  Alcotest.(check bool) "conflict branch" true
    (String.starts_with ~prefix:"conflicts/T-" branch);
  Alcotest.(check bool) "commit SHA" true
    (String.length commit = 40
     && String.for_all
          (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
          commit);
  Alcotest.(check (list string)) "body-free paths"
    [ "knowledge/facts/conflicted-concept.md" ] paths;
  let requested = Hashtbl.create 1 and total = ref 0 in
  simulation |> member "sequence" |> to_list
  |> List.iter (fun event ->
         let code = event |> member "code" |> to_string
         and preserved = event |> member "preserved" |> to_bool
         and expected = event |> member "email_requests" |> to_int in
         let key = branch ^ "\000" ^ commit in
         let actual =
           if List.mem code
                [ "publish_conflict_preserved";
                  "publish_conflict_preserved_cleanup_pending" ]
              && preserved
              && not (Hashtbl.mem requested key)
           then begin
             Hashtbl.add requested key ();
             incr total;
             1
           end
           else 0
         in
         Alcotest.(check int) (code ^ " email gating") expected actual);
  Alcotest.(check int) "exactly one owner email request" 1 !total;
  let body =
    String.concat "\n"
      ([ "Thread: " ^ thread_url; "Conflict ref: " ^ branch;
         "Preserved commit: " ^ commit; "Paths:" ]
       @ List.map (fun path -> "- " ^ path) paths)
  in
  List.iter
    (fun value -> check_contains ("email contains " ^ value) body value)
    (thread_url :: branch :: commit :: paths);
  List.iter
    (fun value -> check_absent ("email excludes " ^ value) body value)
    [ "KNOWLEDGE_BODY"; "OPENROUTER_API_KEY"; "KB_DATABASE_URL";
      "postgresql://" ]

let () =
  Alcotest.run "Phase 8 Clamp skill"
    [ ( "skill",
        [ Alcotest.test_case "static validation" `Quick
            skill_static_validation;
          Alcotest.test_case "acceptance traceability" `Quick
            acceptance_traceability;
          Alcotest.test_case "command fixture policy" `Quick
            command_fixture_policy;
          Alcotest.test_case "authoritative sync fallback producer envelopes" `Quick
            sync_failure_contracts;
          Alcotest.test_case "sync fallback preserves diagnostics" `Quick
            sync_diagnostics_preserved;
          Alcotest.test_case "publication production envelopes" `Quick
            publication_failure_contracts;
          Alcotest.test_case "preservation-gated notification simulation" `Quick
            notification_simulation ] ) ]
