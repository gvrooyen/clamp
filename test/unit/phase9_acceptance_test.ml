let source_root = if Sys.file_exists "PRD.md" then "." else "../.."

let path name = Filename.concat source_root name

let read file =
  let channel = open_in_bin file in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false

let check_contains label text fragment =
  Alcotest.(check bool) label true (contains text fragment)

let check_absent label text fragment =
  Alcotest.(check bool) label false (contains text fragment)

let section ~heading ~next_heading text =
  let first = Str.search_forward (Str.regexp_string heading) text 0 in
  let last =
    Str.search_forward (Str.regexp_string next_heading) text
      (first + String.length heading)
  in
  String.sub text first (last - first)

let valid_git_marker candidate =
  let git = Filename.concat candidate ".git" in
  try
    match (Unix.lstat git).st_kind with
    | Unix.S_DIR -> true
    | Unix.S_REG ->
        let marker = read git |> String.trim in
        let prefix = "gitdir: " in
        if not (String.starts_with ~prefix marker) then false
        else
          let target =
            String.sub marker (String.length prefix)
              (String.length marker - String.length prefix)
          in
          let target =
            if Filename.is_relative target then Filename.concat candidate target
            else target
          in
          Sys.file_exists target && Sys.is_directory target
    | _ -> false
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let rec find_repository_root candidate =
  if valid_git_marker candidate then candidate
  else
    let parent = Filename.dirname candidate in
    if parent = candidate then Alcotest.fail "repository root is unavailable"
    else find_repository_root parent

let repository_root () = find_repository_root (Sys.getcwd ())

let capture ?(environment = Unix.environment ()) program arguments =
  let stdout_path = Filename.temp_file "clamp-phase9" ".out"
  and stderr_path = Filename.temp_file "clamp-phase9" ".err" in
  let stdout =
    Unix.openfile stdout_path
      [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600
  and stderr =
    Unix.openfile stderr_path
      [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600
  in
  let argv = Array.of_list (program :: arguments) in
  let pid = Unix.create_process_env program argv environment Unix.stdin stdout stderr in
  Unix.close stdout;
  Unix.close stderr;
  let _, status = Unix.waitpid [] pid in
  let output = read stdout_path and errors = read stderr_path in
  Sys.remove stdout_path;
  Sys.remove stderr_path;
  status, output, errors

let clean_process_environment =
  [| "PATH=/usr/bin:/bin"; "HOME=/nonexistent"; "LC_ALL=C"; "LANG=C";
     "ALCOTEST_COLOR=never" |]

let matrix_rows plan =
  section ~heading:"## Acceptance-criteria traceability"
    ~next_heading:"## Cross-phase risk register" plan
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         if
           Str.string_match
             (Str.regexp
                "^| \\([0-9]+\\)\\. [^|]+ | \\([^|]+\\) | \\([^|]+\\) |$")
             line 0
         then
           Some
             ( int_of_string (Str.matched_group 1 line),
               Str.matched_group 2 line,
               Str.matched_group 3 line )
         else None)

let trim_terminal_period value =
  if String.ends_with ~suffix:"." value then
    String.sub value 0 (String.length value - 1)
  else value

let executable_location name =
  let unit =
    [ "contract_test"; "phase2_test"; "phase4_test"; "phase6_test";
      "phase8_skill_test"; "phase9_acceptance_test" ]
  in
  let directory = if List.mem name unit then "unit" else "integration" in
  if source_root = "." then
    Filename.concat "_build/default/test"
      (Filename.concat directory (name ^ ".exe"))
  else path (Filename.concat "test" (Filename.concat directory (name ^ ".exe")))

let registered_alcotest_cases name =
  let executable = executable_location name in
  let status, output, errors =
    capture ~environment:clean_process_environment executable
      [ "list"; "--color=never" ]
  in
  Alcotest.(check bool) (name ^ " lists registered cases") true
    (status = Unix.WEXITED 0);
  Alcotest.(check string) (name ^ " list stderr") "" errors;
  output |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         let regexp =
           Str.regexp
             "^\\(.+[^ ]\\)[ ]+\\([0-9]+\\)[ ][ ][ ]+\\(.+\\)$"
         in
         if Str.string_match regexp line 0 then
           Some
             ( Str.matched_group 1 line,
               Str.matched_group 3 line |> trim_terminal_period )
         else None)

let cram_headings file =
  let flush paragraph headings =
    match List.rev paragraph with
    | [] -> headings
    | lines -> String.concat " " lines :: headings
  in
  let rec collect paragraph headings = function
    | [] -> List.rev (flush paragraph headings)
    | line :: rest ->
        if line = "" then collect [] (flush paragraph headings) rest
        else if String.starts_with ~prefix:"  " line then
          collect [] (flush paragraph headings) rest
        else collect (line :: paragraph) headings rest
  in
  read file |> String.split_on_char '\n' |> collect [] []

let split_citations automated =
  automated |> String.split_on_char ';' |> List.map String.trim

let validate_citation registries citation =
  let alcotest =
    Str.regexp "^`\\([^`]+\\)` / `\\([^`]+\\)` / `\\([^`]+\\)`$"
  and cram = Str.regexp "^`\\([^`]+\\)` / `\\([^`]+\\)`$" in
  if Str.string_match alcotest citation 0 then (
    let executable = Str.matched_group 1 citation
    and group = Str.matched_group 2 citation
    and case = Str.matched_group 3 citation in
    let registered =
      match Hashtbl.find_opt registries executable with
      | Some value -> value
      | None ->
          let value = registered_alcotest_cases executable in
          Hashtbl.add registries executable value;
          value
    in
    Alcotest.(check bool) ("registered citation: " ^ citation) true
      (List.mem (group, case) registered))
  else if Str.string_match cram citation 0 then (
    let file = Str.matched_group 1 citation
    and heading = Str.matched_group 2 citation in
    Alcotest.(check string) "only the registered command cram is cited"
      "command_contract.t" file;
    check_contains "command cram has a Dune registration"
      (read (path "test/golden/dune")) "(cram";
    Alcotest.(check bool) ("registered cram heading: " ^ heading) true
      (List.mem heading (cram_headings (path ("test/golden/" ^ file)))))
  else Alcotest.failf "invalid acceptance citation syntax: %s" citation

let complete_criterion_matrix () =
  let plan = read (path "PLAN.md") in
  let rows = matrix_rows plan in
  Alcotest.(check (list int)) "matrix maps criteria 1-19 exactly once"
    (List.init 19 (fun index -> index + 1))
    (List.map (fun (number, _, _) -> number) rows);
  let registries = Hashtbl.create 16 in
  List.iter
    (fun (number, automated, manual) ->
      let citations = split_citations automated in
      Alcotest.(check bool)
        (Printf.sprintf "criterion %d has named automated evidence" number)
        true (citations <> []);
      List.iter (validate_citation registries) citations;
      Alcotest.(check bool)
        (Printf.sprintf "criterion %d states manual evidence disposition" number)
        true
        (String.starts_with ~prefix:"**Pending:**" manual
        || String.starts_with ~prefix:"**None:**" manual
        || String.starts_with ~prefix:"**Complete:**" manual
        || String.starts_with ~prefix:"**Operator gate:**" manual))
    rows;
  let pending =
    rows
    |> List.filter_map (fun (number, _, manual) ->
           if String.starts_with ~prefix:"**Pending:**" manual then Some number
           else None)
  in
  Alcotest.(check (list int)) "no manual/credentialed gate remains pending"
    [] pending

let run_capture arguments =
  let binary =
    if Sys.file_exists "_build/default/bin/kb.exe" then
      "_build/default/bin/kb.exe"
    else "../../bin/kb.exe"
  in
  let environment =
    [| "PATH=/usr/bin:/bin"; "HOME=/nonexistent"; "LC_ALL=C"; "LANG=C";
       "KB_DATABASE_URL=postgresql://phase9:runtime-secret@db.invalid/clamp";
       "KB_DATABASE_DIRECT_URL=postgresql://phase9:runtime-secret@db.invalid/clamp";
       "OPENROUTER_API_KEY=phase9-openrouter-secret";
       "AMP_API_KEY=phase9-amp-secret" |]
  in
  capture ~environment binary arguments

let successful_help arguments =
  let status, output, errors = run_capture arguments in
  Alcotest.(check bool) "help exits successfully" true
    (status = Unix.WEXITED 0);
  Alcotest.(check string) "help has no stderr" "" errors;
  output

let documentation_and_cli_contract_drift () =
  let readme = read (path "README.md")
  and plan = read (path "PLAN.md")
  and prd = read (path "PRD.md")
  and agents = read (path "AGENTS.md")
  and opam = read (path "clamp.opam")
  and locked_opam = read (path "clamp.opam.locked")
  and skill =
    read (path ".agents/skills/managing-clamp-knowledge/SKILL.md")
  in
  List.iter
    (fun (scope, command) ->
      check_contains ("README command " ^ command) readme command;
      if
        not
          (List.mem command
             [ "kb database migrate"; "kb init"; "kb upgrade" ])
      then
        check_contains ("skill command " ^ command) skill command;
      check_contains ("CLI help command " ^ command) scope
        (command |> String.split_on_char ' ' |> List.rev |> List.hd))
    [ (successful_help [ "--help=plain" ], "kb init");
      (successful_help [ "--help=plain" ], "kb search");
      (successful_help [ "--help=plain" ], "kb get");
      (successful_help [ "--help=plain" ], "kb add");
      (successful_help [ "--help=plain" ], "kb edit");
      (successful_help [ "--help=plain" ], "kb verify");
      (successful_help [ "--help=plain" ], "kb deprecate");
      (successful_help [ "task"; "--help=plain" ], "kb task add");
      (successful_help [ "task"; "--help=plain" ], "kb task list");
      (successful_help [ "task"; "--help=plain" ], "kb task start");
      (successful_help [ "task"; "--help=plain" ], "kb task block");
      (successful_help [ "task"; "--help=plain" ], "kb task done");
      (successful_help [ "task"; "--help=plain" ], "kb task cancel");
      (successful_help [ "--help=plain" ], "kb todo");
      (successful_help [ "--help=plain" ], "kb validate");
      (successful_help [ "database"; "--help=plain" ], "kb database migrate");
      (successful_help [ "--help=plain" ], "kb sync");
      (successful_help [ "--help=plain" ], "kb publish");
      (successful_help [ "--help=plain" ], "kb upgrade");
      ( successful_help [ "config"; "set"; "--help=plain" ],
        "kb config set inferred-writes" ) ];
  List.iter
    (fun fragment ->
      check_contains ("README contract " ^ fragment) readme fragment;
      check_contains ("skill contract " ^ fragment) skill fragment)
    [ "stable JSON"; "local_markdown_or_rg"; "semantic_equivalent";
      "performed-and-verified"; "publish_complete_index_stale";
      "publish_race_exhausted"; "publish_conflict_preserved" ];
  check_contains "README local acceptance command" readme
    ".agents/phase9-acceptance";
  check_contains "skill local acceptance boundary" skill
    ".agents/phase9-acceptance";
  check_contains "PLAN public status" plan
    "Repository-owned acceptance remains";
  List.iter
    (fun (label, contents) -> check_contains (label ^ " implemented status") contents
        "implemented")
    [ ("AGENTS", agents); ("PRD", prd); ("opam", opam);
      ("locked opam", locked_opam) ];
  List.iter
    (fun stale ->
      check_absent ("README removes stale compatibility status " ^ stale)
        readme stale;
      check_absent ("PLAN removes stale compatibility status " ^ stale) plan stale)
    [ "reviewed Phase 7 CLI compatibility check, final";
      "external compatibility, clean-room";
      "leaves it pending"; "external gates remain" ];
  check_contains "README records public implementation status" readme
    "Clamp v1 and Phases 0–9 are implemented";
  check_contains "README marks production operator-controlled" readme
    "no production authority";
  check_absent "PLAN has no pending matrix disposition" plan "**Pending:**"

let write_executable file body =
  let channel = open_out_bin file in
  output_string channel body;
  close_out channel;
  Unix.chmod file 0o755

let acceptance_entrypoint_contract () =
  let root = repository_root () in
  let script_path = Filename.concat root ".agents/phase9-acceptance" in
  let temporary = Filename.temp_file "clamp-phase9-hostile" "" in
  Sys.remove temporary;
  Unix.mkdir temporary 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("/bin/rm -rf -- " ^ Filename.quote temporary)))
    (fun () ->
      let hostile_home = Filename.concat temporary "home"
      and hostile_bin = Filename.concat temporary "bin"
      and wrapper_marker = Filename.concat temporary "path-wrapper-ran"
      and psqlrc_marker = Filename.concat temporary "psqlrc-ran"
      and shell_startup_marker = Filename.concat temporary "shell-startup-ran"
      and old_binary_marker = Filename.concat temporary "old-binary-ran" in
      Unix.mkdir hostile_home 0o700;
      Unix.mkdir hostile_bin 0o700;
      List.iter
        (fun name ->
          write_executable (Filename.concat hostile_bin name)
            ("#!/bin/sh\n/usr/bin/touch " ^ Filename.quote wrapper_marker
           ^ "\nexit 97\n"))
        [ "bash"; "dune"; "git"; "getent"; "id"; "opam"; "psql";
          "python3" ];
      let psqlrc = open_out_bin (Filename.concat hostile_home ".psqlrc") in
      output_string psqlrc
        ("\\! /usr/bin/touch " ^ Filename.quote psqlrc_marker ^ "\n");
      close_out psqlrc;
      let shell_startup = Filename.concat temporary "shell-startup" in
      let startup = open_out_bin shell_startup in
      output_string startup
        ("/usr/bin/touch " ^ Filename.quote shell_startup_marker ^ "\n");
      close_out startup;
      let old_binary = Filename.concat temporary "reviewed-kb" in
      write_executable old_binary
        ("#!/bin/sh\n/usr/bin/touch " ^ Filename.quote old_binary_marker
       ^ "\nexit 98\n");
      let environment =
        [| "PATH=" ^ hostile_bin; "HOME=" ^ hostile_home;
           "PHASE9_UNLISTED_SENTINEL=must-not-reach-child";
           "CLAMP_REVIEWED_PHASE7_KB=" ^ old_binary;
           "BASH_ENV=" ^ shell_startup; "ENV=" ^ shell_startup;
           "PSQLRC=" ^ Filename.concat hostile_home ".psqlrc";
           "PGPASSWORD=hostile-libpq-secret";
           "KB_DATABASE_URL="
           ^ ("postgresql://production-user:" ^ "secret@prod.example/clamp");
           "KB_DATABASE_DIRECT_URL="
           ^ ("postgresql://production-user:" ^ "secret@prod.example/clamp");
           "OPENROUTER_API_KEY=hostile-openrouter-secret";
           "AMP_API_KEY=hostile-amp-secret";
           "AMP_URL=https://attacker.invalid";
           "GIT_DIR=" ^ temporary; "GIT_CONFIG_GLOBAL=" ^ old_binary;
           "GIT_EXEC_PATH=" ^ hostile_bin; "AWS_ACCESS_KEY_ID=hostile-aws";
           "GOOGLE_APPLICATION_CREDENTIALS=" ^ old_binary;
           "AZURE_CLIENT_SECRET=hostile-azure" |]
      in
      let status, output, errors =
        capture ~environment script_path [ "--self-check" ]
      in
      Alcotest.(check bool) "self-check status" true (status = Unix.WEXITED 0);
      Alcotest.(check string) "self-check stderr" "" errors;
      List.iter
        (fun file -> Alcotest.(check bool) (file ^ " was not executed") false
            (Sys.file_exists file))
        [ wrapper_marker; psqlrc_marker; shell_startup_marker;
          old_binary_marker ];
      let json = Yojson.Safe.from_string output in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "self-check mode" "self-check"
        (json |> member "mode" |> to_string);
      Alcotest.(check string) "local psql probe" "ok"
        (json |> member "local_psql_probe" |> to_string);
      Alcotest.(check string) "cleanup path was exercised" "attempted"
        (json |> member "cleanup_database_probe" |> to_string);
      let sandbox = json |> member "sandbox" |> to_string in
      Alcotest.(check bool) "operation sandbox was cleaned" false
        (Sys.file_exists sandbox);
      let environment = json |> member "environment" |> to_assoc in
      let names = List.map fst environment |> List.sort String.compare in
      Alcotest.(check (list string)) "exact child environment names"
        [ "ALCOTEST_COLOR"; "CLAMP_PHASE9_HERMETIC";
          "CLAMP_PHASE9_SANDBOX"; "GIT_CONFIG_NOSYSTEM"; "HOME"; "LANG";
          "LC_ALL"; "LOGNAME"; "OPAMCOLOR"; "OPAMROOT"; "PATH"; "PSQLRC";
          "PWD"; "SHELL"; "SHLVL"; "USER"; "_" ]
        names;
      let env name = List.assoc name environment |> to_string in
      Alcotest.(check string) "fixed child PATH"
        (Filename.concat root "_opam/bin:/usr/bin:/bin") (env "PATH");
      Alcotest.(check string) "psql startup file disabled" "/dev/null"
        (env "PSQLRC");
      Alcotest.(check string) "system Git config disabled" "1"
        (env "GIT_CONFIG_NOSYSTEM");
      Alcotest.(check bool) "child HOME is isolated" true
        (String.starts_with ~prefix:"/tmp/clamp-phase9." (env "HOME"));
      let plan =
        json |> member "plan" |> to_list
        |> List.map (fun row -> row |> to_list |> List.map to_string)
      in
      let labels = List.map List.hd plan in
      Alcotest.(check (list string)) "shared execution-path step order"
        [ "candidate-unstaged"; "candidate-untracked"; "resume";
          "discover-port"; "discover-sockets"; "discover-data"; "build";
          "validate"; "create-database"; "bootstrap-pgvector";
          "migrate-local"; "extension-ledger-smoke"; "repository-tests";
          "package-lint"; "drop-database" ]
        labels;
      let step label =
        match
          List.find_opt
            (function name :: _ -> name = label | [] -> false)
            plan
        with
        | Some (_ :: command) when command <> [] -> command
        | _ -> Alcotest.failf "missing recorded command step %s" label
      in
      let real_home = (Unix.getpwuid (Unix.getuid ())).pw_dir in
      List.iter
        (fun (label, executable) ->
          Alcotest.(check string) (label ^ " fixed executable") executable
            (List.hd (step label)))
        [ ("candidate-unstaged", "/usr/bin/git");
          ("candidate-untracked", "/usr/bin/git");
          ("resume", "/bin/bash");
          ("discover-port", "/usr/bin/pg_conftool");
          ("discover-sockets", "/usr/bin/pg_conftool");
          ("discover-data", "/usr/bin/pg_conftool");
          ("build", Filename.concat root "_opam/bin/dune");
          ("validate", Filename.concat root "_build/default/bin/kb.exe");
          ("create-database", "/usr/bin/env");
          ("bootstrap-pgvector", "/usr/bin/sudo");
          ("migrate-local", Filename.concat root "_build/default/bin/kb.exe");
          ("extension-ledger-smoke", "/usr/bin/env");
          ("repository-tests", Filename.concat root "_opam/bin/dune");
          ("package-lint", Filename.concat real_home ".local/bin/opam");
          ("drop-database", "/usr/bin/env") ];
      let plan_tokens = List.concat plan in
      List.iter
        (fun forbidden ->
          Alcotest.(check bool) ("plan excludes " ^ forbidden) false
            (List.mem forbidden plan_tokens))
        [ "/usr/bin/curl"; "/usr/bin/wget"; "push"; "fetch"; "sync";
          "search"; "get" ];
      let rendered_plan = String.concat "\n" plan_tokens in
      List.iter
        (fun forbidden -> check_absent ("plan excludes " ^ forbidden)
            rendered_plan forbidden)
        [ "http://"; "https://"; "KB_DATABASE_URL";
          "KB_DATABASE_DIRECT_URL"; "OPENROUTER_API_KEY"; "AMP_API_KEY" ];
      let local = "/var/run/postgresql"
      and database = "<operation-database>" in
      List.iter
        (fun label ->
          let command = step label in
          Alcotest.(check bool) (label ^ " uses local socket") true
            (List.mem local command);
          Alcotest.(check bool) (label ^ " uses operation database") true
            (List.mem database command);
          Alcotest.(check bool) (label ^ " disables psql startup") true
            (List.mem "PSQLRC=/dev/null" command))
        [ "create-database"; "bootstrap-pgvector";
          "extension-ledger-smoke"; "drop-database" ];
      Alcotest.(check bool) "create command is exact local createdb" true
        (List.mem "/usr/bin/createdb" (step "create-database")
        && List.mem "--template=template0" (step "create-database"));
      Alcotest.(check bool) "drop command is idempotent local dropdb" true
        (List.mem "/usr/bin/dropdb" (step "drop-database")
        && List.mem "--if-exists" (step "drop-database")
        && List.mem "--force" (step "drop-database"));
      Alcotest.(check bool) "migration uses operation database" true
        (List.mem database (step "migrate-local"));
      let position label =
        let rec find index = function
          | [] -> Alcotest.failf "missing step position %s" label
          | (name :: _) :: _ when name = label -> index
          | _ :: rest -> find (index + 1) rest
        in
        find 0 plan
      in
      Alcotest.(check bool) "actual armed create path precedes cleanup" true
        (position "create-database" < position "drop-database");
      Alcotest.(check string) "cleanup armed before create invocation" "ok"
        (json |> member "create_database_armed_before_invocation" |> to_string);
      let script = read script_path
      and setup = read (Filename.concat root ".agents/setup")
      and resume = read (Filename.concat root ".agents/resume") in
      Alcotest.(check bool) "fixed startup-safe bootstrap interpreter" true
        (String.starts_with ~prefix:"#!/bin/sh\n" script);
      check_contains "bootstrap selects fixed Bash after sanitizing" script
        "/bin/bash \"$bootstrap_script_path\"";
      check_absent "old CLI path is never accepted" script
        "CLAMP_REVIEWED_PHASE7_KB";
      check_contains "runner labels historical case invocation-local" script
        "NOT INCLUDED in this invocation: reviewed Phase 7 CLI cross-version migration";
      check_contains "runner marks historical case unavailable" script
        "no old executable is accepted from the environment";
      check_contains "runner keeps production operator-controlled" script
        "production rollout remains operator-controlled";
      check_absent "runner no longer labels compatibility globally pending" script
        "PENDING external compatibility gate";
      check_contains "setup disables psql startup files" setup "--no-psqlrc";
      check_contains "resume disables psql startup files" resume "--no-psqlrc";
      List.iter
        (fun file ->
          let contents = read (Filename.concat root file) in
          check_contains (file ^ " clears PSQLRC") contents "PSQLRC=/dev/null";
          check_contains (file ^ " disables psql startup") contents
            "--no-psqlrc")
        [ "test/integration/phase3_database_test.ml";
          "test/integration/phase5_sync_test.ml";
          "test/integration/phase8_workflow_test.ml" ])

let git_environment =
  [| "PATH=/usr/bin:/bin"; "HOME=/nonexistent"; "LC_ALL=C"; "LANG=C" |]

let read_nul_records ~limit program arguments =
  let input, output = Unix.pipe ~cloexec:true () in
  let argv = Array.of_list (program :: arguments) in
  let pid =
    Unix.create_process_env program argv git_environment Unix.stdin output Unix.stderr
  in
  Unix.close output;
  let chunk = Bytes.create 4096 and current = Buffer.create 256 in
  let records = ref [] and count = ref 0 in
  let add_record () =
    incr count;
    if !count > limit then Alcotest.fail "candidate file-count limit exceeded";
    records := Buffer.contents current :: !records;
    Buffer.clear current
  in
  let rec consume offset length =
    if offset < length then (
      let character = Bytes.get chunk offset in
      if character = '\000' then add_record ()
      else (
        Buffer.add_char current character;
        if Buffer.length current > 8192 then
          Alcotest.fail "candidate index record exceeds 8 KiB");
      consume (offset + 1) length)
  in
  let rec pump () =
    match Unix.read input chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | length -> consume 0 length; pump ()
  in
  pump ();
  Unix.close input;
  let _, status = Unix.waitpid [] pid in
  Alcotest.(check bool) "candidate index enumeration status" true
    (status = Unix.WEXITED 0);
  Alcotest.(check int) "candidate enumeration ends on NUL" 0
    (Buffer.length current);
  List.rev !records

let parse_index_record record =
  let tab = String.index record '\t' in
  let header = String.sub record 0 tab |> String.split_on_char ' ' in
  let relative =
    String.sub record (tab + 1) (String.length record - tab - 1)
  in
  match header with
  | [ mode; object_id; "0" ] when mode = "100644" || mode = "100755" ->
      relative, object_id
  | [ _; _; stage ] when stage <> "0" ->
      Alcotest.failf "candidate index contains an unresolved stage for %s" relative
  | _ -> Alcotest.failf "candidate index contains a non-regular entry: %s" relative

let read_git_blob root object_id =
  let input, output = Unix.pipe ~cloexec:true () in
  let program = "/usr/bin/git" in
  let arguments = [ "-C"; root; "cat-file"; "blob"; object_id ] in
  let pid =
    Unix.create_process_env program (Array.of_list (program :: arguments))
      git_environment Unix.stdin output Unix.stderr
  in
  Unix.close output;
  let chunk = Bytes.create 65536 and contents = Buffer.create 4096 in
  let total = ref 0 in
  let rec pump () =
    match Unix.read input chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | length ->
        total := !total + length;
        if !total > 8 * 1024 * 1024 then
          Alcotest.fail "candidate blob exceeds 8 MiB";
        Buffer.add_subbytes contents chunk 0 length;
        pump ()
  in
  pump ();
  Unix.close input;
  let _, status = Unix.waitpid [] pid in
  Alcotest.(check bool) "candidate blob read status" true
    (status = Unix.WEXITED 0);
  Buffer.contents contents

let bounded_candidate_files () =
  let root = repository_root () in
  let entries =
    read_nul_records ~limit:10_000 "/usr/bin/git"
      [ "-C"; root; "ls-files"; "--cached"; "--stage"; "-z" ]
    |> List.map parse_index_record
  in
  let paths = List.map fst entries in
  Alcotest.(check (list string)) "candidate index order and uniqueness"
    (List.sort_uniq String.compare paths) paths;
  let total = ref 0 in
  let files =
    List.map
      (fun (relative, object_id) ->
        let contents = read_git_blob root object_id in
        total := !total + String.length contents;
        if !total > 64 * 1024 * 1024 then
          Alcotest.fail "candidate aggregate exceeds 64 MiB";
        relative, contents)
      entries
  in
  files

let regexp_present regexp text =
  try
    ignore (Str.search_forward regexp text 0);
    true
  with Not_found -> false

let trim = String.trim

let unsafe_secret_assignment line =
  let line = trim line in
  let names =
    [ "KB_DATABASE_URL"; "KB_DATABASE_DIRECT_URL"; "OPENROUTER_API_KEY";
      "AMP_API_KEY" ]
  in
  List.exists
    (fun name ->
      let prefixes = [ name ^ "="; "export " ^ name ^ "=" ] in
      List.exists
        (fun prefix ->
          if not (String.starts_with ~prefix line) then false
          else
            let value =
              String.sub line (String.length prefix)
                (String.length line - String.length prefix)
              |> trim
            in
            value <> "" && value <> "''" && value <> "\"\""
            && not (String.starts_with ~prefix:"$" value)
            && not (String.starts_with ~prefix:"\"$" value)
            && not (String.starts_with ~prefix:"'${" value))
        prefixes)
    names

let unsafe_recipient_assignment line =
  let line = trim line |> String.lowercase_ascii in
  String.contains line '@'
  && List.exists
       (fun prefix -> String.starts_with ~prefix line)
       [ "recipient="; "recipient:"; "recipient_email=";
         "recipient_email:" ]

let url_tokens text =
  let prefixes = [ "postgres://"; "postgresql://" ] in
  let delimiter = function
    | ' ' | '\t' | '\r' | '\n' | '"' | '\'' | '`' | '\\' -> true
    | _ -> false
  in
  let rec find prefix offset found =
    try
      let first = Str.search_forward (Str.regexp_string prefix) text offset in
      let rec finish index =
        if index >= String.length text || delimiter text.[index] then index
        else finish (index + 1)
      in
      let last = finish (first + String.length prefix) in
      let token = String.sub text first (last - first) in
      find prefix last (token :: found)
    with Not_found -> found
  in
  List.concat_map (fun prefix -> find prefix 0 []) prefixes

let credential_bearing_url token =
  match String.index_opt token '@' with
  | None -> false
  | Some at ->
      let scheme = String.index token '/' + 2 in
      let userinfo = String.sub token scheme (at - scheme) in
      String.contains userinfo ':'

let allowed_database_url_fixtures =
  [ ( "test/unit/phase9_acceptance_test.ml",
      "postgresql://phase9:" ^ "runtime-secret@db.invalid/clamp" );
    ( "test/unit/phase3_test.ml",
      "postgresql://user:"
      ^ "pass@db.example/clamp?sslmode=require&channel_binding=require" );
    ( "test/unit/phase3_test.ml",
      "postgresql://user:"
      ^ "secret@first.example:5432,second.example/db?sslmode=require&channel_binding=require" );
    ( "test/unit/phase3_test.ml",
      "postgresql://user:"
      ^ "secret@first.example:5432,first.example:5432,second.example/db?sslmode=require&channel_binding=require&hostaddr=192.0.2.2,192.0.2.1,2001%3Adb8%3A%3A1" );
    ( "test/unit/phase3_test.ml",
      "postgresql://user:"
      ^ "secret@resolver.example/db?sslmode=require&channel_binding=require" );
    ( "test/unit/contract_test.ml",
      "postgresql://alice:" ^ "hunter2@db.example/clamp" );
    ( "test/golden/command_contract.t",
      "postgresql://alice:" ^ "hunter2@db.example/clamp" );
    ( "test/golden/command_contract.t",
      "postgresql://alice:" ^ "hunter2@db.example/body" );
    ( "test/integration/phase5_sync_test.ml",
      "postgresql://%s:"
      ^ "%s@localhost:%d/%s?sslmode=require&channel_binding=require&connect_timeout=2" );
    ( "test/integration/phase5_sync_test.ml",
      "postgresql://fixture:"
      ^ "fixture@127.0.0.1:1/fixture?sslmode=require&channel_binding=require&connect_timeout=1" );
    ( "test/integration/phase3_database_test.ml",
      "postgresql://%s:"
      ^ "%s@does-not-exist.invalid:5432,127.0.0.1:5432/%s?sslmode=require&channel_binding=require" );
    ( "test/integration/phase3_database_test.ml",
      "postgresql://%s:"
      ^ "%s@[2001:db8::1]:5432,127.0.0.1:5432/%s?sslmode=require&channel_binding=require" ) ]

let allowed_test_database_url relative token =
  List.mem (relative, token) allowed_database_url_fixtures

let recursively_forbidden_keys json =
  let forbidden =
    [ "body"; "frontmatter"; "snippet"; "recipient"; "api_key";
      "database_url"; "database_direct_url" ]
  in
  let rec collect location = function
    | `Assoc fields ->
        List.concat_map
          (fun (name, value) ->
            let here = if location = "" then name else location ^ "." ^ name in
            (if List.mem name forbidden then [ here ] else []) @ collect here value)
          fields
    | `List values -> List.concat_map (collect location) values
    | _ -> []
  in
  collect "" json

let high_confidence_token prefixes text =
  let token_character = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  let rec has prefix offset =
    try
      let first = Str.search_forward (Str.regexp_string prefix) text offset in
      let token_start = first + String.length prefix in
      let rec finish index =
        if index < String.length text && token_character text.[index] then
          finish (index + 1)
        else index
      in
      let token_length = finish token_start - token_start in
      token_length >= 20 || has prefix (first + 1)
    with Not_found -> false
  in
  List.exists (fun prefix -> has prefix 0) prefixes

let bounded_repository_and_output_leakage_audit () =
  Alcotest.(check bool) "high-confidence API key detector" true
    (high_confidence_token [ "sk-or-v1-"; "sk-proj-" ]
       ("sk-or-v1-" ^ String.make 24 'a'));
  Alcotest.(check bool) "literal secret assignment detector" true
    (unsafe_secret_assignment
       ("OPENROUTER_API_KEY" ^ "=fixture-secret"));
  Alcotest.(check bool) "recipient assignment detector" true
    (unsafe_recipient_assignment
       ("recipient_email=" ^ "owner@example.invalid"));
  Alcotest.(check bool) "credential-bearing database URL detector" true
    (credential_bearing_url
       ("postgresql://fixture:" ^ "secret@db.invalid/clamp"));
  let production_looking =
    "postgresql://production-user:" ^ "secret@prod.example/clamp"
  in
  Alcotest.(check bool) "production-looking URL is rejected" false
    (allowed_test_database_url "test/unit/phase3_test.ml" production_looking);
  List.iter
    (fun (relative, token) ->
      Alcotest.(check bool) "exact fixture exception" true
        (allowed_test_database_url relative token);
      Alcotest.(check bool) "fixture exception is path-anchored" false
        (allowed_test_database_url (relative ^ ".other") token);
      Alcotest.(check bool) "fixture exception is token-anchored" false
        (allowed_test_database_url relative (token ^ "-changed")))
    allowed_database_url_fixtures;
  bounded_candidate_files ()
  |> List.iter (fun (relative, text) ->
         if
           regexp_present
             (Str.regexp_string ("-----BEGIN " ^ "PRIVATE KEY-----"))
             text
         then
           Alcotest.failf "static leakage audit found a private key in %s"
             relative;
         if high_confidence_token [ "sk-or-v1-"; "sk-proj-" ] text then
           Alcotest.failf
             "static leakage audit found a high-confidence OpenRouter/OpenAI token in %s"
             relative;
         if high_confidence_token [ "napi_" ] text then
           Alcotest.failf
             "static leakage audit found a high-confidence Neon account token in %s"
             relative;
         text |> String.split_on_char '\n'
         |> List.iter (fun line ->
                if unsafe_secret_assignment line then
                  Alcotest.failf
                    "static leakage audit found a literal secret assignment in %s"
                    relative;
                if unsafe_recipient_assignment line then
                  Alcotest.failf
                    "static leakage audit found a recipient address assignment in %s"
                    relative);
         url_tokens text
         |> List.iter (fun token ->
                if
                  credential_bearing_url token
                  && not (allowed_test_database_url relative token)
                then
                  Alcotest.failf
                    "static leakage audit found a credential-bearing database URL in %s"
                    relative));
  let body = "PHASE9_KNOWLEDGE_BODY_MUST_NOT_APPEAR" in
  let status, output, errors =
    run_capture
      [ "task"; "add"; "--input"; body; "--diagnostic"; "--json" ]
  in
  Alcotest.(check bool) "body-free invalid command status" true
    (status = Unix.WEXITED 2);
  let combined = output ^ errors in
  List.iter
    (fun secret -> check_absent ("runtime output excludes " ^ secret) combined secret)
    [ body; "runtime-secret"; "phase9-openrouter-secret";
      "phase9-amp-secret" ];
  let fixture =
    Yojson.Safe.from_file (path "test/fixtures/phase8/command-results.json")
  in
  let publication =
    Yojson.Safe.Util.(fixture |> member "publication_failure_contracts")
  in
  Alcotest.(check (list string))
    "publication conflict/recovery result fixture is body-free" []
    (recursively_forbidden_keys publication);
  let notification =
    Yojson.Safe.Util.(fixture |> member "notification_simulation")
  in
  Alcotest.(check (list string)) "notification fixture has only safe fields"
    [ "branch"; "commit"; "paths"; "sequence"; "subject"; "thread_url" ]
    (Yojson.Safe.Util.to_assoc notification |> List.map fst |> List.sort compare)

let () =
  Alcotest.run "Phase 9 local acceptance"
    [ ( "acceptance",
        [ Alcotest.test_case "complete criterion matrix" `Quick
            complete_criterion_matrix;
          Alcotest.test_case "documentation and CLI contract drift" `Quick
            documentation_and_cli_contract_drift;
          Alcotest.test_case "hermetic runner behavior and plan" `Quick
            acceptance_entrypoint_contract;
          Alcotest.test_case
            "bounded repository and output leakage audit" `Quick
            bounded_repository_and_output_leakage_audit ] ) ]
