let source_root = if Sys.file_exists "db/migrations" then "." else "../.."
let counter = ref 0

let command program arguments =
  let argv = Array.of_list (program :: arguments) in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let pid = Unix.create_process program argv Unix.stdin dev_null dev_null in
  let _, status = Unix.waitpid [] pid in
  Unix.close dev_null;
  match status with Unix.WEXITED 0 -> () | _ -> Alcotest.fail (program ^ " failed")

let git repo arguments = command "git" ("-C" :: repo :: arguments)

let git_output repo arguments =
  let read_end, write_end = Unix.pipe () in
  let argv = Array.of_list ("git" :: "-C" :: repo :: arguments) in
  let pid = Unix.create_process "git" argv Unix.stdin write_end Unix.stderr in
  Unix.close write_end;
  let channel = Unix.in_channel_of_descr read_end in
  let output =
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        let buffer = Buffer.create 64 in
        (try while true do Buffer.add_channel buffer channel 1024 done
         with End_of_file -> ());
        Buffer.contents buffer)
  in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> String.trim output
  | _ -> Alcotest.fail "git output command failed"

let rec remove path =
  try
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR ->
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | _ -> Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let mkdir_p path =
  let rec create path =
    if path <> Filename.dirname path && not (Sys.file_exists path) then begin
      create (Filename.dirname path);
      Unix.mkdir path 0o700
    end
  in
  create path

let write path contents =
  mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents)

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let copy source destination = write destination (read source)

let fact ?(title = "Example") ?(body = "Body.") ?verified () =
  let verified = Option.value verified ~default:"" in
  Printf.sprintf
    "---\ntype: fact\ntitle: %s\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\n%sclamp: {asserted_by: human:owner}\n---\n%s\n"
    title verified body

let task state =
  Printf.sprintf
    "---\ntype: task\ntitle: Stable task\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\nclamp: {asserted_by: human:owner, task: {state: %s, priority: normal}}\n---\nTask body.\n"
    state

let commit_and_push author message =
  git author [ "add"; "-A" ];
  git author [ "commit"; "--quiet"; "-m"; message ];
  git author [ "push"; "--quiet"; "origin"; "main" ];
  git_output author [ "rev-parse"; "HEAD" ]

let quote_identifier value =
  "\"" ^ String.concat "\"\"" (String.split_on_char '\"' value) ^ "\""

let target = lazy (match Clamp.Database.discover_local_target () with
    | Ok target -> target
    | Error error -> Alcotest.fail error.message)

let user = (Unix.getpwuid (Unix.geteuid ())).pw_name

let connection database =
  let target = Lazy.force target in
  new Postgresql.connection ~host:target.socket_dir ~port:(string_of_int target.port)
    ~dbname:database ~user ()

let sql (connection : Postgresql.connection) statement =
  connection#exec ~expect:[ Postgresql.Command_ok ] statement |> ignore

let postgres database statement =
  let target = Lazy.force target in
  command "/usr/bin/sudo"
    [ "-u"; "postgres"; "/usr/bin/env"; "-i"; "HOME=/var/lib/postgresql";
      "USER=postgres"; "LOGNAME=postgres"; "PATH=/usr/bin:/bin";
      "PSQLRC=/dev/null"; "/usr/bin/psql"; "--no-psqlrc"; "--quiet";
      "--set=ON_ERROR_STOP=1"; "--host"; target.socket_dir; "--port";
      string_of_int target.port; "--username"; "postgres"; "--dbname"; database;
      "--command"; statement ]

type environment = {
  root : string;
  author : string;
  clone : string;
  database : string;
  connection : Postgresql.connection;
}

let with_environment label initial operation =
  incr counter;
  let root = Filename.temp_file "clamp phase5-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let bare = Filename.concat root "remote.git"
  and author = Filename.concat root "author"
  and clone = Filename.concat root "clone"
  and migration_root = Filename.concat root "migration-root" in
  command "git" [ "init"; "--quiet"; "--bare"; "--initial-branch=main"; bare ];
  command "git" [ "init"; "--quiet"; "--initial-branch=main"; author ];
  git author [ "config"; "user.name"; "Clamp Test" ];
  git author [ "config"; "user.email"; "clamp-test@local.invalid" ];
  git author [ "remote"; "add"; "origin"; bare ];
  let config =
    read (Filename.concat source_root "clamp.yaml")
    |> Str.global_replace (Str.regexp_string "github.com/gvrooyen/clamp")
         "local.test/clamp-fixture"
  in
  write (Filename.concat author "clamp.yaml") config;
  initial author;
  ignore (commit_and_push author "initial");
  command "git" [ "clone"; "--quiet"; "--depth"; "1"; "file://" ^ bare; clone ];
  let database = Printf.sprintf "clamp_p5_%s_%d_%d" label (Unix.getpid ()) !counter in
  let admin = connection "postgres" in
  sql admin ("CREATE DATABASE " ^ quote_identifier database);
  admin#finish;
  postgres database "CREATE EXTENSION vector WITH SCHEMA public";
  let db = ref None in
  Fun.protect
    ~finally:(fun () ->
      Option.iter (fun connection -> try connection#finish with _ -> ()) !db;
      postgres "postgres"
        ("DROP DATABASE IF EXISTS " ^ quote_identifier database ^ " WITH (FORCE)");
      remove root)
    (fun () ->
      List.iter
        (fun name ->
          copy (Filename.concat source_root (Filename.concat "db/migrations" name))
            (Filename.concat migration_root (Filename.concat "db/migrations" name)))
        [ "0001_enable_vector.sql"; "0002_application_schema.sql" ];
      (match Clamp.Database.migrate_local ~repo:migration_root ~database with
      | Error failure -> Alcotest.failf "migration: %s" failure.code
      | Ok _ -> ());
      let connection = connection database in
      db := Some connection;
      operation { root; author; clone; database; connection })

let vector () = Array.make Clamp.Openrouter.dimensions 0.

let run ?(reembed = false) ?(allow = false) ?commit env calls =
  Clamp.Sync.For_test.run_with_connection ~repo:env.clone ~connection:env.connection
    ~embed:(fun _ -> incr calls; Ok (vector ())) ~reembed
    ~allow_mass_deletion:allow ~target_commit:commit

let check_ok label = function
  | Ok value -> value
  | Error (failure : Clamp.Sync.error) ->
      Alcotest.failf "%s: %s (%s)" label failure.message failure.code

let check_error label code = function
  | Ok _ -> Alcotest.failf "%s: expected %s" label code
  | Error (failure : Clamp.Sync.error) ->
      Alcotest.(check string) label code failure.code

let tuple (connection : Postgresql.connection) query =
  connection#exec ~expect:[ Postgresql.Tuples_ok ] query

let scalar (connection : Postgresql.connection) query = (tuple connection query)#getvalue 0 0

let with_remote_login ?(configure_role = fun _ -> ()) env operation =
  let role = Printf.sprintf "clamp_p5_remote_%d_%d" (Unix.getpid ()) !counter in
  let password = "local-fixture-password" in
  let role_identifier = quote_identifier role in
  postgres "postgres"
    (Printf.sprintf "CREATE ROLE %s LOGIN PASSWORD '%s'" role_identifier password);
  Fun.protect
    ~finally:(fun () ->
      postgres env.database ("DROP OWNED BY " ^ role_identifier);
      postgres "postgres" ("DROP ROLE IF EXISTS " ^ role_identifier))
    (fun () ->
      configure_role role_identifier;
      postgres env.database
        (Printf.sprintf
           "GRANT CONNECT ON DATABASE %s TO %s; GRANT USAGE ON SCHEMA public TO %s; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO %s"
           (quote_identifier env.database) role_identifier role_identifier role_identifier);
      let target = Lazy.force target in
      let url =
        Printf.sprintf
          "postgresql://%s:%s@localhost:%d/%s?sslmode=require&channel_binding=require&connect_timeout=2"
          role password target.port env.database
      in
      operation url)

let capture_process ?(pooled = false) ~url arguments =
  let program =
    if Sys.file_exists "_build/default/bin/kb.exe" then "_build/default/bin/kb.exe"
    else "../../bin/kb.exe"
  in
  let stdout_read, stdout_write = Unix.pipe ~cloexec:true ()
  and stderr_read, stderr_write = Unix.pipe ~cloexec:true () in
  let environment =
    [| "PATH=/usr/bin:/bin"; "HOME=/nonexistent"; "LC_ALL=C"; "LANG=C";
       (if pooled then "KB_DATABASE_URL=" else "KB_DATABASE_DIRECT_URL=") ^ url |]
  in
  let argv = Array.of_list (program :: arguments) in
  let pid =
    Unix.create_process_env program argv environment Unix.stdin stdout_write stderr_write
  in
  Unix.close stdout_write; Unix.close stderr_write;
  Unix.set_nonblock stdout_read; Unix.set_nonblock stderr_read;
  let output = Buffer.create 4096 and errors = Buffer.create 4096 in
  let descriptors = ref [ (stdout_read, output); (stderr_read, errors) ] in
  let chunk = Bytes.create 8192 in
  let deadline = Unix.gettimeofday () +. 60. in
  while !descriptors <> [] do
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0. then begin
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (Unix.waitpid [] pid);
      List.iter (fun (descriptor, _) -> Unix.close descriptor) !descriptors;
      descriptors := [];
      Alcotest.fail "CLI output capture timed out"
    end;
    let readable, _, _ =
      Unix.select (List.map fst !descriptors) [] [] remaining
    in
    if readable = [] then begin
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (Unix.waitpid [] pid);
      List.iter (fun (descriptor, _) -> Unix.close descriptor) !descriptors;
      descriptors := [];
      Alcotest.fail "CLI output capture timed out"
    end;
    List.iter
      (fun descriptor ->
        let destination = List.assoc descriptor !descriptors in
        try
          let count = Unix.read descriptor chunk 0 (Bytes.length chunk) in
          if count = 0 then begin
            Unix.close descriptor;
            descriptors := List.remove_assoc descriptor !descriptors
          end else Buffer.add_subbytes destination chunk 0 count
        with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> ())
      readable
  done;
  let _, status = Unix.waitpid [] pid in
  (status, Buffer.contents output, Buffer.contents errors)

let core_convergence () =
  with_environment "core"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ~title:"Alpha" ());
      write (Filename.concat author "knowledge/facts/beta.md") (fact ~title:"Beta" ());
      write (Filename.concat author "knowledge/index.md")
        "# Reserved\n## Facts\n- [Alpha](facts/alpha.md)\n")
    (fun env ->
      Alcotest.(check string) "shallow" "true"
        (git_output env.clone [ "rev-parse"; "--is-shallow-repository" ]);
      let calls = ref 0 in
      let first = check_ok "initial" (run env calls) in
      Alcotest.(check int) "initial adds" 2 first.counts.added;
      Alcotest.(check int) "initial embeds" 2 !calls;
      Alcotest.(check string) "reserved excluded" "2"
        (scalar env.connection "SELECT count(*) FROM concepts");
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',7)";
      let repeated = check_ok "repeat" (run env calls) in
      Alcotest.(check int) "unchanged" 2 repeated.counts.unchanged;
      Alcotest.(check int) "no repeat embed" 2 !calls;
      Alcotest.(check string) "telemetry preserved" "7"
        (scalar env.connection "SELECT access_count FROM access_stats WHERE concept_path='facts/alpha'");
      with_remote_login env (fun url ->
          let status, output, errors =
            capture_process ~url [ "sync"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 0 -> () | _ ->
            Alcotest.failf "human sync summary failed: %s" errors);
          Alcotest.(check string) "exact human sync summary"
            (Printf.sprintf
               "Indexed origin/main at %s (added=0, metadata-updated=0, re-embedded=0, unchanged=2, deleted=0).\n"
               first.commit)
            output;
          Alcotest.(check string) "human sync stderr" "" errors;
          let status, output, errors =
            capture_process ~url [ "sync"; "--repo"; env.clone; "--json" ]
          in
          (match status with Unix.WEXITED 0 -> () | _ ->
            Alcotest.failf "JSON sync preservation failed: %s" errors);
          Alcotest.(check string) "exact JSON sync unchanged"
            (Printf.sprintf
               "{\"ok\":true,\"code\":\"sync_complete\",\"data\":{\"commit\":\"%s\",\"rebuilt\":false,\"diagnostics\":[],\"counts\":{\"added\":0,\"metadata_updated\":0,\"reembedded\":0,\"unchanged\":2,\"deleted\":0}}}\n"
               first.commit)
            output;
          Alcotest.(check string) "JSON sync stderr" "" errors);
      write (Filename.concat env.author "knowledge/facts/alpha.md")
        (fact ~title:"Alpha" ~verified:"verified: [{by: human:x, at: 2026-08-20T09:00:00Z}]\n" ());
      let metadata_commit = commit_and_push env.author "metadata" in
      let metadata = check_ok "metadata" (run ~commit:metadata_commit env calls) in
      Alcotest.(check int) "metadata update" 1 metadata.counts.metadata_updated;
      Alcotest.(check int) "metadata no embed" 2 !calls;
      write (Filename.concat env.author "knowledge/facts/beta.md")
        (fact ~title:"Beta" ~body:"Semantic change." ());
      ignore (commit_and_push env.author "semantic");
      let semantic = check_ok "semantic" (run env calls) in
      Alcotest.(check int) "semantic reembed" 1 semantic.counts.reembedded;
      Alcotest.(check int) "semantic call" 3 !calls;
      Alcotest.(check string) "semantic telemetry preserved" "7"
        (scalar env.connection "SELECT access_count FROM access_stats WHERE concept_path='facts/alpha'");
      Sys.rename (Filename.concat env.author "knowledge/facts/alpha.md")
        (Filename.concat env.author "knowledge/facts/gamma.md");
      ignore (commit_and_push env.author "rename");
      let renamed = check_ok "rename" (run env calls) in
      Alcotest.(check int) "rename add" 1 renamed.counts.added;
      Alcotest.(check int) "rename delete" 1 renamed.counts.deleted;
      Alcotest.(check string) "rename resets telemetry" "0"
        (scalar env.connection "SELECT count(*) FROM access_stats");
      let forced = check_ok "force" (run ~reembed:true env calls) in
      Alcotest.(check int) "forced all" 2 forced.counts.reembedded;
      sql env.connection "UPDATE index_state SET embedding_model='old-model'";
      let mismatch = check_ok "model mismatch" (run env calls) in
      Alcotest.(check int) "mismatch all" 2 mismatch.counts.reembedded;
      sql env.connection "UPDATE index_state SET embedding_dimensions=42";
      let dimensions = check_ok "dimension mismatch" (run env calls) in
      Alcotest.(check int) "dimension mismatch all" 2 dimensions.counts.reembedded;
      let transaction_checkpoint =
        scalar env.connection "SELECT last_indexed_commit FROM index_state"
      in
      let transaction_body =
        scalar env.connection "SELECT body FROM concepts WHERE path='facts/beta'"
      in
      write (Filename.concat env.author "knowledge/facts/beta.md")
        (fact ~title:"Beta" ~body:"Transactional failure." ());
      ignore (commit_and_push env.author "transaction failure");
      sql env.connection
        "CREATE FUNCTION phase5_reject_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture rejection'; END $$";
      sql env.connection
        "CREATE TRIGGER phase5_reject_update BEFORE UPDATE ON concepts FOR EACH ROW EXECUTE FUNCTION phase5_reject_update()";
      check_error "transaction failure" "database_sql_error" (run env calls);
      sql env.connection "DROP TRIGGER phase5_reject_update ON concepts";
      sql env.connection "DROP FUNCTION phase5_reject_update()";
      Alcotest.(check string) "transaction checkpoint rollback" transaction_checkpoint
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      Alcotest.(check string) "transaction row rollback" transaction_body
        (scalar env.connection "SELECT body FROM concepts WHERE path='facts/beta'");
      ignore (check_ok "transaction recovery" (run env calls));
      let checkpoint = scalar env.connection "SELECT last_indexed_commit FROM index_state" in
      write (Filename.concat env.author "knowledge/facts/beta.md")
        (fact ~title:"Beta" ~body:"Must roll back." ());
      ignore (commit_and_push env.author "embedding failure");
      let failed =
        Clamp.Sync.For_test.run_with_connection ~repo:env.clone
          ~connection:env.connection
          ~embed:(fun _ -> Error { Clamp.Sync.kind = Transient; code = "fixture_failed";
                                   message = "Fixture embedding failed.";
                                    diagnostics = [] })
          ~reembed:false ~allow_mass_deletion:false ~target_commit:None
      in
      check_error "embedding failure" "fixture_failed" failed;
      Alcotest.(check string) "checkpoint rollback" checkpoint
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      write (Filename.concat env.author "knowledge/facts/beta.md") "not frontmatter\n";
      ignore (commit_and_push env.author "parse failure");
      check_error "parse failure" "frontmatter_invalid" (run env calls);
      Alcotest.(check string) "parse checkpoint" checkpoint
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      check_error "exact SHA" "sync_target_mismatch"
        (run ~commit:(String.make 40 '0') env calls);
      write (Filename.concat env.author "knowledge/facts/beta.md")
        (fact ~title:"Beta" ~body:"Valid again." ());
      ignore (commit_and_push env.author "restore valid tree");
      sql env.connection "UPDATE index_state SET source_repository='local.test/wrong'";
      check_error "identity" "source_repository_mismatch" (run env calls))

let distinct_pushurl_does_not_affect_sync () =
  with_environment "distinct_pushurl"
    (fun author ->
      write (Filename.concat author "knowledge/facts/fetch-only.md")
        (fact ~title:"Fetch only" ()))
    (fun env ->
      let push_remote = Filename.concat env.root "unused-push.git" in
      command "git"
        [ "init"; "--quiet"; "--bare"; "--initial-branch=main"; push_remote ];
      git env.clone [ "remote"; "set-url"; "--push"; "origin"; push_remote ];
      let calls = ref 0 in
      let report = check_ok "fetch-only URL validation" (run env calls) in
      Alcotest.(check int) "fetched concept indexed" 1 report.counts.added;
      Alcotest.(check int) "fetch-only embedding" 1 !calls;
      Alcotest.(check string) "push URL remained unused" ""
        (git_output push_remote [ "for-each-ref"; "--format=%(refname)" ]))

let mass_deletion () =
  with_environment "mass"
    (fun author ->
      for index = 0 to 11 do
        write
          (Filename.concat author (Printf.sprintf "knowledge/facts/item-%02d.md" index))
          (fact ~title:(Printf.sprintf "Item %02d" index) ())
      done)
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "mass seed" (run env calls));
      for index = 2 to 11 do
        Sys.remove
          (Filename.concat env.author (Printf.sprintf "knowledge/facts/item-%02d.md" index))
      done;
      ignore (commit_and_push env.author "mass delete");
      check_error "majority guard" "mass_deletion_requires_approval" (run env calls);
      Alcotest.(check string) "majority rollback" "12"
        (scalar env.connection "SELECT count(*) FROM concepts");
      ignore (check_ok "majority approved" (run ~allow:true env calls));
      remove (Filename.concat env.author "knowledge");
      ignore (commit_and_push env.author "empty");
      check_error "empty guard" "mass_deletion_requires_approval" (run env calls);
      ignore (check_ok "empty approved" (run ~allow:true env calls));
      Alcotest.(check string) "empty converged" "0"
        (scalar env.connection "SELECT count(*) FROM concepts"))

let task_metadata_only () =
  let path =
    "knowledge/tasks/01ARZ3NDEKTSV4RRFFQ69G5FAV-stable-task.md"
  in
  with_environment "task"
    (fun author -> write (Filename.concat author path) (task "todo"))
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "task seed" (run env calls));
      write (Filename.concat env.author path) (task "doing");
      ignore (commit_and_push env.author "task state");
      let report = check_ok "task state" (run env calls) in
      Alcotest.(check int) "task metadata update" 1 report.counts.metadata_updated;
      Alcotest.(check int) "task state no embed" 1 !calls)

let advisory_lock () =
  with_environment "lock"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ()))
    (fun env ->
      sql env.connection
        "INSERT INTO concepts(path,blob_hash,embedding_input_hash,type,body,frontmatter,verified_tier,embedding_model,embedding) VALUES ('facts/unauthenticated','blob','input','fact','body','{}','unverified','model',array_fill(0::real,ARRAY[1536])::vector)";
      git env.clone [ "remote"; "set-url"; "origin"; "/local/remote/must-not-be-fetched" ];
      let missing_calls = ref 0 in
      check_error "missing checkpoint" "index_state_missing" (run env missing_calls);
      Alcotest.(check int) "missing checkpoint no embedding" 0 !missing_calls;
      git env.clone
        [ "remote"; "set-url"; "origin"; Filename.concat env.root "remote.git" ];
      sql env.connection "DELETE FROM concepts";
      let holder = connection env.database in
      ignore (holder#exec ~expect:[ Postgresql.Tuples_ok ]
                "SELECT pg_advisory_lock(hashtextextended('local.test/clamp-fixture',0))");
      let calls = ref 0 in
      check_error "concurrent lock" "sync_already_running" (run env calls);
      ignore (holder#exec ~expect:[ Postgresql.Tuples_ok ]
                "SELECT pg_advisory_unlock(hashtextextended('local.test/clamp-fixture',0))");
      holder#finish;
      let report = check_ok "after unlock" (run env calls) in
      Alcotest.(check int) "single write" 1 report.counts.added)

let source_preflight () =
  let root = Filename.temp_file "clamp-phase5-config-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
      write (Filename.concat root "clamp.yaml") "schema_version: 1\n";
      check_error "missing identity" "source_repository_missing"
        (Clamp.Sync.preflight_repository root);
      write (Filename.concat root "clamp.yaml")
        "schema_version: 1\nsource_repository: https://secret@example.test/repo.git\n";
      check_error "invalid identity" "source_repository_invalid"
        (Clamp.Sync.preflight_repository root))

let database_snapshot connection =
  String.concat "\n---\n"
    [ scalar connection
        "SELECT coalesce(string_agg(row_to_json(c)::text,E'\\n' ORDER BY path),'') FROM concepts c";
      scalar connection
        "SELECT coalesce(string_agg(row_to_json(a)::text,E'\\n' ORDER BY concept_path),'') FROM access_stats a";
      scalar connection
        "SELECT coalesce((SELECT row_to_json(i)::text FROM index_state i WHERE id=1),'absent')" ]

let integer_json_canonicalization () =
  let decimal = "-340282366920938463463374607431768211456" in
  with_environment "integer_json"
    (fun author ->
      write (Filename.concat author "knowledge/facts/integer.md")
        "---\ntype: fact\ntitle: Integer fixture\ncustom_integer: -0x1_00000000000000000000000000000000\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\nclamp: {asserted_by: human:owner}\n---\nInteger body.\n")
    (fun env ->
      let calls = ref 0 in
      let report = check_ok "integer sync" (run env calls) in
      Alcotest.(check int) "integer one embed" 1 !calls;
      Alcotest.(check int) "integer no warnings" 0
        (List.length report.diagnostics);
      Alcotest.(check string) "clean completion code" "sync_complete"
        (Clamp.Sync.completion_code report);
      Alcotest.(check string) "integer checkpoint" report.commit
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      Alcotest.(check string) "integer JSON number" "number"
        (scalar env.connection
           "SELECT jsonb_typeof(frontmatter->'custom_integer') FROM concepts WHERE path='facts/integer'");
      Alcotest.(check string) "integer exact decimal" decimal
        (scalar env.connection
           "SELECT frontmatter->>'custom_integer' FROM concepts WHERE path='facts/integer'"))

let numeric_contract () =
  let canonical kind lexeme expected =
    match Clamp.Exact_yaml.canonical_number kind lexeme with
    | Ok actual -> Alcotest.(check string) lexeme expected actual
    | Error _ -> Alcotest.failf "%s unexpectedly rejected" lexeme
  in
  canonical Clamp.Exact_yaml.Float "+001.2300e+2" "123";
  canonical Clamp.Exact_yaml.Float "-0.000e999999999999999999999" "0";
  canonical Clamp.Exact_yaml.Float "10e-16384"
    ("0." ^ String.make 16_382 '0' ^ "1");
  canonical Clamp.Exact_yaml.Integer "+0b1_010" "10";
  canonical Clamp.Exact_yaml.Integer "-0o1_777" "-1023";
  canonical Clamp.Exact_yaml.Integer "0xF_F" "255";
  let integer_boundary = String.make Clamp.Exact_yaml.max_numeric_integer_digits '9' in
  let fractional_boundary =
    "0." ^ String.make (Clamp.Exact_yaml.max_numeric_fractional_digits - 1) '0' ^ "1"
  in
  let document fields =
    "---\ntype: fact\ntitle: Numeric fixture\n" ^ fields
    ^ "generated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\n"
    ^ "clamp: {asserted_by: human:owner}\n---\nNumeric body.\n"
  in
  with_environment "numeric_contract"
    (fun author ->
      write (Filename.concat author "knowledge/facts/numeric.md")
        (document
           ("decimal: -000_001.2300\nnegative_zero: -0.000\n"
            ^ "based: 0xF_F\nunderflow: 1e-16383\ninteger_boundary: "
            ^ integer_boundary ^ "\nfractional_boundary: " ^ fractional_boundary ^ "\n")))
    (fun env ->
      let calls = ref 0 in
      let first = check_ok "numeric boundaries" (run env calls) in
      Alcotest.(check int) "numeric one embed" 1 !calls;
      Alcotest.(check string) "numeric checkpoint" first.commit
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      List.iter
        (fun (field, expected) ->
          Alcotest.(check string) (field ^ " JSON number") "number"
            (scalar env.connection
               (Printf.sprintf
                  "SELECT jsonb_typeof(frontmatter->'%s') FROM concepts WHERE path='facts/numeric'"
                  field));
          Alcotest.(check string) (field ^ " exact") expected
            (scalar env.connection
               (Printf.sprintf
                  "SELECT (frontmatter->>'%s')::numeric::text FROM concepts WHERE path='facts/numeric'"
                  field)))
        [ ("decimal", "-1.23"); ("negative_zero", "0"); ("based", "255");
          ("integer_boundary", integer_boundary) ];
      Alcotest.(check string) "fractional boundary exact" "t"
        (scalar env.connection
           (Printf.sprintf
              "SELECT (frontmatter->>'fractional_boundary')::numeric = ('1e-%d')::numeric FROM concepts WHERE path='facts/numeric'"
              Clamp.Exact_yaml.max_numeric_fractional_digits));
      Alcotest.(check string) "underflow exact" "t"
        (scalar env.connection
           "SELECT (frontmatter->>'underflow')::numeric = ('1e-16383')::numeric FROM concepts WHERE path='facts/numeric'");
      ignore (check_ok "numeric idempotent retry" (run env calls));
      Alcotest.(check int) "numeric retry no embed" 1 !calls;
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/numeric',23)";
      let before = database_snapshot env.connection and before_calls = !calls in
      let rejected =
        [ ("integer digits", "too_large: " ^ String.make 131_073 '9' ^ "\n",
           "numeric_out_of_range");
          ("fraction digits", "too_small: 0." ^ String.make 16_383 '0' ^ "1\n",
           "numeric_out_of_range");
          ("positive exponent", "too_large: 1e131072\n", "numeric_out_of_range");
          ("negative exponent", "too_small: 1e-16384\n", "numeric_out_of_range");
          ("positive infinity", "bad: .inf\n", "numeric_non_finite");
          ("negative infinity", "bad: -.inf\n", "numeric_non_finite");
          ("nan", "bad: .nan\n", "numeric_non_finite");
          ("long based", "bad: 0x" ^ String.make 500_000 'f' ^ "\n",
           "numeric_out_of_range");
          ("huge positive exponent", "bad: 1e" ^ String.make 100_000 '9' ^ "\n",
           "numeric_out_of_range");
          ("huge negative exponent", "bad: 1e-" ^ String.make 100_000 '9' ^ "\n",
           "numeric_out_of_range") ]
      in
      List.iter
        (fun (label, fields, code) ->
          write (Filename.concat env.author "knowledge/facts/numeric.md") (document fields);
          ignore (commit_and_push env.author label);
          check_error label code (run env calls);
          Alcotest.(check int) (label ^ " no embedding") before_calls !calls;
          Alcotest.(check string) (label ^ " exact DB") before
            (database_snapshot env.connection))
        rejected)

let diagnostic_overflow () =
  with_environment "diagnostic_overflow"
    (fun author ->
      write (Filename.concat author "knowledge/facts/seed.md") (fact ()))
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "diagnostic seed" (run env calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/seed',31)";
      let before = database_snapshot env.connection and before_calls = !calls in
      remove (Filename.concat env.author "knowledge/facts/seed.md");
      for index = 0 to Clamp.Limits.max_diagnostics do
        write
          (Filename.concat env.author
             (Printf.sprintf "knowledge/facts/warning-%04d.md" index))
          (Printf.sprintf
             "---\ntype: future-%04d\ntitle: Warning\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\nclamp: {asserted_by: human:owner}\n---\nWARNING-BODY-SECRET.\n"
             index)
      done;
      ignore (commit_and_push env.author "diagnostic overflow");
      match run env calls with
      | Ok _ -> Alcotest.fail "diagnostic overflow unexpectedly succeeded"
      | Error failure ->
          Alcotest.(check string) "diagnostic overflow code" "diagnostic_limit"
            failure.code;
          Alcotest.(check int) "diagnostics capped" Clamp.Limits.max_diagnostics
            (List.length failure.diagnostics);
          Alcotest.(check int) "one limit marker" 1
            (List.length
               (List.filter
                  (fun diagnostic -> diagnostic.Clamp.Diagnostic.code = "diagnostic_limit")
                  failure.diagnostics));
          Alcotest.(check bool) "diagnostics sorted" true
            (failure.diagnostics = List.sort Clamp.Diagnostic.compare failure.diagnostics);
          let json =
            `List (List.map Clamp.Diagnostic.json failure.diagnostics)
            |> Yojson.Safe.to_string
          and human =
            failure.diagnostics |> List.map Clamp.Diagnostic.human
            |> String.concat "\n"
          in
          List.iter
            (fun diagnostic ->
              Alcotest.(check bool) "human diagnostic code parity" true
                (try
                   ignore
                     (Str.search_forward
                        (Str.regexp_string ("[" ^ diagnostic.Clamp.Diagnostic.code ^ "]"))
                        human 0);
                   true
                 with Not_found -> false))
            failure.diagnostics;
          let contains_marker text =
            try
              ignore
                (Str.search_forward (Str.regexp_string "WARNING-BODY-SECRET") text 0);
              true
            with Not_found -> false
          in
          Alcotest.(check bool) "diagnostics body-free JSON" false
            (contains_marker json);
          Alcotest.(check bool) "diagnostics body-free human" false
            (contains_marker human);
          Alcotest.(check int) "overflow no embedding" before_calls !calls;
          Alcotest.(check string) "overflow exact DB" before
            (database_snapshot env.connection))

let production_adapter_diagnostics () =
  let warning_document type_name body =
    Printf.sprintf
      "---\ntype: %s\ntitle: Production adapter\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\nclamp: {asserted_by: human:owner}\n---\n%s\n"
      type_name body
  in
  with_environment "production_adapter"
    (fun author ->
      write (Filename.concat author "knowledge/facts/seed.md") (fact ()))
    (fun env ->
      let fixture_calls = ref 0 in
      ignore (check_ok "production adapter seed" (run env fixture_calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/seed',43)";
      remove (Filename.concat env.author "knowledge/facts/seed.md");
      for index = 0 to Clamp.Limits.max_diagnostics do
        write
          (Filename.concat env.author
             (Printf.sprintf "knowledge/facts/adapter-%04d.md" index))
          (warning_document (Printf.sprintf "future-%04d" index)
             "PRODUCTION-ADAPTER-BODY-SECRET")
      done;
      ignore (commit_and_push env.author "production adapter overflow");
      with_remote_login env (fun url ->
          let before = database_snapshot env.connection in
          let production () =
            Clamp.Sync.run ~repo:env.clone ~url ~reembed:false
              ~allow_mass_deletion:false ~target_commit:None
          in
          let failure =
            match production () with
            | Ok _ -> Alcotest.fail "production adapter overflow unexpectedly succeeded"
            | Error failure -> failure
          in
          Alcotest.(check string) "production adapter code" "diagnostic_limit"
            failure.code;
          Alcotest.(check int) "production adapter diagnostic count"
            Clamp.Limits.max_diagnostics (List.length failure.diagnostics);
          Alcotest.(check bool) "production adapter diagnostics sorted" true
            (failure.diagnostics = List.sort Clamp.Diagnostic.compare failure.diagnostics);
          Alcotest.(check int) "production adapter limit marker" 1
            (List.length
               (List.filter
                  (fun item -> item.Clamp.Diagnostic.code = "diagnostic_limit")
                  failure.diagnostics));
          let warning_paths =
            failure.diagnostics
            |> List.filter_map (fun item ->
                   if item.Clamp.Diagnostic.code = "unknown_type" then Some item.path
                   else None)
          in
          Alcotest.(check int) "production adapter retained warnings" 999
            (List.length warning_paths);
          Alcotest.(check string) "production adapter smallest first"
            "knowledge/facts/adapter-0000.md" (List.hd warning_paths);
          Alcotest.(check string) "production adapter smallest last"
            "knowledge/facts/adapter-0998.md" (List.hd (List.rev warning_paths));
          let expected_json =
            `List (List.map Clamp.Diagnostic.json failure.diagnostics)
            |> Yojson.Safe.to_string
          and expected_human =
            failure.diagnostics |> List.map Clamp.Diagnostic.human
            |> String.concat "\n"
          in
          let json_status, json_stdout, json_stderr =
            capture_process ~url [ "sync"; "--repo"; env.clone; "--json" ]
          in
          (match json_status with
          | Unix.WEXITED 2 -> ()
          | _ -> Alcotest.fail "production CLI JSON exit class changed");
          Alcotest.(check string) "production CLI JSON stderr" "" json_stderr;
          let json = Yojson.Safe.from_string json_stdout in
          let open Yojson.Safe.Util in
          Alcotest.(check string) "production CLI JSON code" "diagnostic_limit"
            (json |> member "code" |> to_string);
          Alcotest.(check string) "production CLI exact diagnostics" expected_json
            (json |> member "details" |> member "diagnostics" |> Yojson.Safe.to_string);
          let human_status, human_stdout, human_stderr =
            capture_process ~url [ "sync"; "--repo"; env.clone ]
          in
          (match human_status with
          | Unix.WEXITED 2 -> ()
          | _ -> Alcotest.fail "production CLI human exit class changed");
          Alcotest.(check string) "production CLI human stdout" "" human_stdout;
          Alcotest.(check string) "production CLI exact human diagnostics"
            ("kb: Git bundle exceeds the 1,000-diagnostic safety limit.\n"
             ^ expected_human ^ "\n")
            human_stderr;
          let contains_body text =
            try
              ignore
                (Str.search_forward
                   (Str.regexp_string "PRODUCTION-ADAPTER-BODY-SECRET") text 0);
              true
            with Not_found -> false
          in
          Alcotest.(check bool) "production JSON body-free" false
            (contains_body json_stdout);
          Alcotest.(check bool) "production human body-free" false
            (contains_body human_stderr);
          Alcotest.(check string) "production overflow exact DB" before
            (database_snapshot env.connection);

          remove (Filename.concat env.author "knowledge/facts");
          write (Filename.concat env.author "knowledge/facts/warning.md")
            (warning_document "future-kind" "[missing](absent.md)");
          ignore (commit_and_push env.author "production warning only");
          let expected_warning =
            check_ok "production warning fixture" (run env fixture_calls)
          in
          let actual_warning = check_ok "production warning adapter" (production ()) in
          Alcotest.(check string) "warning completion unchanged"
            "sync_complete_with_warnings" (Clamp.Sync.completion_code actual_warning);
          Alcotest.(check string) "warning diagnostics unchanged"
            (`List (List.map Clamp.Diagnostic.json expected_warning.diagnostics)
             |> Yojson.Safe.to_string)
            (`List (List.map Clamp.Diagnostic.json actual_warning.diagnostics)
             |> Yojson.Safe.to_string);

          write (Filename.concat env.author "knowledge/facts/warning.md")
            (warning_document "fact" "No warning.");
          ignore (commit_and_push env.author "production no warning");
          ignore (check_ok "production no-warning fixture" (run env fixture_calls));
          let no_warning = check_ok "production no-warning adapter" (production ()) in
          Alcotest.(check int) "no-warning diagnostics" 0
            (List.length no_warning.diagnostics);
          Alcotest.(check string) "no-warning completion unchanged" "sync_complete"
            (Clamp.Sync.completion_code no_warning)))

let non_markdown_paths () =
  with_environment "non_markdown_paths"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ()))
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "non-Markdown seed" (run env calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',19)";
      let before = database_snapshot env.connection and before_calls = !calls in
      write (Filename.concat env.author "knowledge/bad name/readme.txt") "fixture\n";
      ignore (commit_and_push env.author "nonportable non-Markdown path");
      check_error "nonportable non-Markdown" "path_component_invalid" (run env calls);
      Alcotest.(check int) "nonportable non-Markdown no embed" before_calls !calls;
      Alcotest.(check string) "nonportable non-Markdown exact DB" before
        (database_snapshot env.connection);
      remove (Filename.concat env.author "knowledge/bad name");
      write (Filename.concat env.author "knowledge/Foo/readme.txt") "upper\n";
      write (Filename.concat env.author "knowledge/foo/other.txt") "lower\n";
      ignore (commit_and_push env.author "case collision non-Markdown path");
      check_error "case collision non-Markdown" "path_duplicate" (run env calls);
      Alcotest.(check int) "case collision non-Markdown no embed" before_calls !calls;
      Alcotest.(check string) "case collision non-Markdown exact DB" before
        (database_snapshot env.connection))

let warning_policy () =
  let warning_codes = [ "unknown_type"; "link_invalid_uri"; "link_unresolved" ] in
  let warning_json diagnostics =
    diagnostics
    |> List.filter (fun diagnostic -> List.mem diagnostic.Clamp.Diagnostic.code warning_codes)
    |> List.map Clamp.Diagnostic.json |> fun values -> `List values
    |> Yojson.Safe.to_string
  in
  with_environment "warnings"
    (fun author ->
      write (Filename.concat author "knowledge/facts/warning.md")
        "---\ntype: future-kind\ntitle: Warning fixture\ngenerated: {by: amp/agent, at: 2026-08-20T08:00:00Z}\nclamp: {asserted_by: human:owner}\n---\nWARNING-BODY-SECRET [bad](bad%ZZ.md) [missing](missing.md)\n";
      write (Filename.concat author "knowledge/log.md")
        "# Log\n## 2026-08-20\n- [bad](bad%2Fname.md)\n- [missing](facts/absent.md)\n")
    (fun env ->
      let calls = ref 0 in
      let report = check_ok "warning sync" (run env calls) in
      Alcotest.(check int) "warning sync embeds" 1 !calls;
      Alcotest.(check string) "warning checkpoint" report.commit
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      let expected =
        (Clamp.Bundle.validate env.author).diagnostics |> warning_json
      in
      Alcotest.(check string) "warnings match validate exactly" expected
        (warning_json report.diagnostics);
      Alcotest.(check bool) "warnings are body-free" false
        (try
           ignore (Str.search_forward (Str.regexp_string "WARNING-BODY-SECRET")
                     (warning_json report.diagnostics) 0);
           true
         with Not_found -> false);
      Alcotest.(check (list string)) "stable warning order"
        [ "link_invalid_uri"; "link_unresolved"; "unknown_type";
          "link_invalid_uri"; "link_unresolved" ]
        (List.map (fun diagnostic -> diagnostic.Clamp.Diagnostic.code)
           report.diagnostics);
      Alcotest.(check bool) "warnings nonblocking" true
        (report.diagnostics <> []);
      Alcotest.(check string) "warning completion code"
        "sync_complete_with_warnings" (Clamp.Sync.completion_code report))

let object_format_and_root_parser () =
  let hash = String.make 40 'a' in
  let valid = "040000 tree " ^ hash ^ "\tknowledge\000" in
  let cases =
    [ ("absent", "", None);
      ("tree", valid, None);
      ("malformed", "BODY-MARKER", Some "git_tree_invalid");
      ("multiple", valid ^ valid, Some "git_tree_invalid");
      ("mode", "100600 blob " ^ hash ^ "\tknowledge\000",
       Some "git_tree_invalid");
      ("kind", "100644 blob " ^ hash ^ "\tknowledge\000",
       Some "knowledge_not_directory");
      ("commit kind", "160000 commit " ^ hash ^ "\tknowledge\000",
       Some "knowledge_not_directory");
      ("malformed kind", "100644 BLOB " ^ hash ^ "\tknowledge\000",
       Some "git_tree_invalid");
      ("hash", "040000 tree BODY-MARKER\tknowledge\000",
       Some "git_tree_invalid");
      ("path", "040000 tree " ^ hash ^ "\tBODY-MARKER\000",
       Some "git_tree_invalid");
      ("termination", "040000 tree " ^ hash ^ "\tknowledge",
       Some "git_tree_invalid") ]
  in
  List.iter
    (fun (label, input, expected) ->
      match Clamp.Sync.For_test.parse_knowledge_root input, expected with
      | Ok (), None -> ()
      | Error failure, Some code ->
          Alcotest.(check string) label code failure.code;
          Alcotest.(check bool) (label ^ " body-free") false
            (try
               ignore (Str.search_forward (Str.regexp_string "BODY-MARKER")
                         failure.message 0);
               true
             with Not_found -> false)
      | _ -> Alcotest.fail (label ^ " root parser mapping"))
    cases;
  List.iter
    (fun (lexeme, expected) ->
      Alcotest.(check (option string)) ("canonical integer " ^ lexeme)
        (Some expected) (Clamp.Exact_yaml.canonical_integer lexeme))
    [ ("+001_024", "1024"); ("-0", "0"); ("0b1_010", "10");
      ("+0o1_777", "1023"); ("-0xF_F", "-255") ];
  with_environment "object_format" (fun _ -> ()) (fun env ->
      let sha256 = Filename.concat env.root "sha256" in
      command "git" [ "init"; "--quiet"; "--object-format=sha256"; sha256 ];
      copy (Filename.concat env.clone "clamp.yaml")
        (Filename.concat sha256 "clamp.yaml");
      let calls = ref 0 and before = database_snapshot env.connection in
      let result =
        Clamp.Sync.For_test.run_with_connection ~repo:sha256
          ~connection:env.connection
          ~embed:(fun _ -> incr calls; Ok (vector ())) ~reembed:false
          ~allow_mass_deletion:false ~target_commit:None
      in
      check_error "SHA-256 repository" "git_object_format_unsupported" result;
      Alcotest.(check int) "SHA-256 no embedding" 0 !calls;
      Alcotest.(check string) "SHA-256 exact DB" before
        (database_snapshot env.connection))

let knowledge_root_validation () =
  with_environment "knowledge_root"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md")
        (fact ~title:"Alpha" ()))
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "knowledge root seed" (run env calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',17)";
      let before = database_snapshot env.connection and before_calls = !calls in
      remove (Filename.concat env.author "knowledge");
      write (Filename.concat env.author "knowledge") "not a bundle directory\n";
      ignore (commit_and_push env.author "knowledge root regular file");
      check_error "knowledge root regular file" "knowledge_not_directory"
        (run ~allow:true env calls);
      Alcotest.(check int) "regular root no embedding" before_calls !calls;
      Alcotest.(check string) "regular root exact database state" before
        (database_snapshot env.connection);
      Sys.remove (Filename.concat env.author "knowledge");
      let absent_commit = commit_and_push env.author "knowledge root absent" in
      let absent = check_ok "absent knowledge is empty" (run ~allow:true env calls) in
      Alcotest.(check string) "absent knowledge checkpoint" absent_commit absent.commit;
      Alcotest.(check int) "absent knowledge no embedding" before_calls !calls;
      Alcotest.(check string) "absent knowledge deletes derived rows" "0"
        (scalar env.connection "SELECT count(*) FROM concepts"))

let with_poisoned_git_environment root operation =
  let poison_config = Filename.concat root "poison.gitconfig" in
  write poison_config
    ("[remote \"origin\"]\n\turl = " ^ Filename.concat root "poison.git" ^ "\n");
  let values =
    [ ("GIT_DIR", Filename.concat root "other/.git");
      ("GIT_WORK_TREE", Filename.concat root "other");
      ("GIT_COMMON_DIR", Filename.concat root "other/.git");
      ("GIT_OBJECT_DIRECTORY", Filename.concat root "other/.git/objects");
      ("GIT_ALTERNATE_OBJECT_DIRECTORIES", Filename.concat root "other/.git/objects");
      ("GIT_INDEX_FILE", Filename.concat root "other/.git/index");
      ("GIT_SHALLOW_FILE", Filename.concat root "other/.git/shallow");
      ("GIT_NAMESPACE", "poison");
      ("GIT_REPLACE_REF_BASE", "refs/replace-poison/");
      ("GIT_GRAFT_FILE", Filename.concat root "poison.grafts");
      ("GIT_CEILING_DIRECTORIES", root);
      ("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1");
      ("GIT_CONFIG", poison_config);
      ("GIT_CONFIG_SYSTEM", poison_config);
      ("GIT_CONFIG_GLOBAL", poison_config);
      ("GIT_CONFIG_NOSYSTEM", "0");
      ("GIT_CONFIG_COUNT", "1");
      ("GIT_CONFIG_KEY_0", "remote.origin.url");
      ("GIT_CONFIG_VALUE_0", Filename.concat root "poison.git");
      ("GIT_CONFIG_PARAMETERS", "'remote.origin.url=poison'");
      ("GIT_EXEC_PATH", root);
      ("GIT_ATTR_NOSYSTEM", "0") ]
  in
  let previous = List.map (fun (name, _) -> (name, Sys.getenv_opt name)) values in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, value) ->
          match value with Some value -> Unix.putenv name value | None -> Unix.unsetenv name)
        previous)
    (fun () ->
      List.iter (fun (name, value) -> Unix.putenv name value) values;
      operation ())

let fetched_repository_identity () =
  with_environment "identity"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ()))
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "identity seed" (run env calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count,last_accessed_at) VALUES ('facts/alpha',9,pg_catalog.now())";
      let before_calls = !calls in
      let other_bare = Filename.concat env.root "other.git"
      and other = Filename.concat env.root "other" in
      command "git" [ "init"; "--quiet"; "--bare"; "--initial-branch=main"; other_bare ];
      command "git" [ "clone"; "--quiet"; Filename.concat env.root "remote.git"; other ];
      git other [ "config"; "user.name"; "Clamp Test" ];
      git other [ "config"; "user.email"; "clamp-test@local.invalid" ];
      let config = read (Filename.concat other "clamp.yaml") in
      write (Filename.concat other "clamp.yaml")
        (Str.global_replace (Str.regexp_string "local.test/clamp-fixture")
           "local.test/repointed-fixture" config);
      write (Filename.concat other "knowledge/facts/alpha.md")
        (fact ~body:"Repointed repository body." ());
      git other [ "remote"; "set-url"; "origin"; other_bare ];
      ignore (commit_and_push other "repointed identity");
      let legitimate_commit =
        scalar env.connection "SELECT last_indexed_commit FROM index_state"
      in
      with_poisoned_git_environment env.root (fun () ->
          let report = check_ok "poisoned environment remains bound" (run env calls) in
          Alcotest.(check string) "poisoned exact repository" legitimate_commit
            report.commit;
          Alcotest.(check int) "poisoned no embedding" before_calls !calls);
      git env.clone [ "remote"; "set-url"; "origin"; other_bare ];
      let before = database_snapshot env.connection and before_calls = !calls in
      with_poisoned_git_environment env.root (fun () ->
          check_error "fetched identity" "source_repository_mismatch" (run env calls));
      Alcotest.(check int) "identity no embedding" before_calls !calls;
      Alcotest.(check string) "identity zero database effects" before
        (database_snapshot env.connection))

let replacement_objects_disabled () =
  let path = "knowledge/facts/alpha.md" in
  let marker = "REPLACEMENT-OBJECT-B-MARKER" in
  with_environment "replacement"
    (fun author ->
      write (Filename.concat author path)
        (fact ~title:"Legitimate A" ~body:"Legitimate A body." ()))
    (fun env ->
      let commit_a = git_output env.author [ "rev-parse"; "HEAD" ] in
      let blob_a = git_output env.author [ "rev-parse"; commit_a ^ ":" ^ path ] in
      write (Filename.concat env.author path)
        (fact ~title:"Replacement B" ~body:marker ());
      git env.author [ "add"; "-A" ];
      git env.author [ "commit"; "--quiet"; "-m"; "replacement B" ];
      let commit_b = git_output env.author [ "rev-parse"; "HEAD" ] in
      let blob_b = git_output env.author [ "rev-parse"; commit_b ^ ":" ^ path ] in
      Alcotest.(check bool) "replacement blob differs" true (blob_a <> blob_b);
      git env.clone [ "fetch"; "--quiet"; env.author; commit_b ];
      git env.clone [ "replace"; commit_a; commit_b ];
      let uncontrolled_tree = git_output env.clone [ "ls-tree"; commit_a; "--"; path ] in
      Alcotest.(check bool) "fixture replacement is active" true
        (try ignore (Str.search_forward (Str.regexp_string blob_b) uncontrolled_tree 0); true
         with Not_found -> false);
      let inputs = ref [] in
      let sync () =
        Clamp.Sync.For_test.run_with_connection ~repo:env.clone
          ~connection:env.connection
          ~embed:(fun input -> inputs := input :: !inputs; Ok (vector ()))
          ~reembed:false ~allow_mass_deletion:false ~target_commit:None
      in
      let first = check_ok "replacement-safe sync" (sync ()) in
      Alcotest.(check string) "reported legitimate SHA" commit_a first.commit;
      Alcotest.(check string) "checkpoint legitimate SHA" commit_a
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      Alcotest.(check string) "stored legitimate blob" blob_a
        (scalar env.connection "SELECT blob_hash FROM concepts WHERE path='facts/alpha'");
      Alcotest.(check string) "stored legitimate body" "Legitimate A body.\n"
        (scalar env.connection "SELECT body FROM concepts WHERE path='facts/alpha'");
      Alcotest.(check string) "stored source identity" "local.test/clamp-fixture"
        (scalar env.connection "SELECT source_repository FROM index_state");
      Alcotest.(check int) "one legitimate embedding" 1 (List.length !inputs);
      let input = List.hd !inputs in
      Alcotest.(check bool) "embedding contains A" true
        (try ignore (Str.search_forward (Str.regexp_string "Legitimate A body.") input 0); true
         with Not_found -> false);
      Alcotest.(check bool) "embedding excludes B marker" false
        (try ignore (Str.search_forward (Str.regexp_string marker) input 0); true
         with Not_found -> false);
      Alcotest.(check string) "B marker absent from rows" "0"
        (scalar env.connection
           "SELECT count(*) FROM concepts WHERE body LIKE '%REPLACEMENT-OBJECT-B-MARKER%'");
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',13)";
      let repeated = check_ok "replacement-safe repeat" (sync ()) in
      Alcotest.(check string) "repeat reported legitimate SHA" commit_a repeated.commit;
      Alcotest.(check int) "repeat does not embed B" 1 (List.length !inputs);
      Alcotest.(check string) "repeat checkpoint A" commit_a
        (scalar env.connection "SELECT last_indexed_commit FROM index_state");
      Alcotest.(check string) "replacement preserves telemetry" "13"
        (scalar env.connection
           "SELECT access_count FROM access_stats WHERE concept_path='facts/alpha'");
      Alcotest.(check string) "repeat keeps A blob" blob_a
        (scalar env.connection "SELECT blob_hash FROM concepts WHERE path='facts/alpha'"))

let many_links count =
  let buffer = Buffer.create (count * 16) in
  Buffer.add_string buffer "# Index\n## Entries\n";
  for index = 1 to count do
    Printf.bprintf buffer "- [x%d](facts/alpha.md)\n" index
  done;
  Buffer.contents buffer

let reserved_validation () =
  with_environment "reserved"
    (fun author ->
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ());
      write (Filename.concat author "knowledge/index.md")
        "# Index\n## Entries\n- [Alpha](facts/alpha.md)\n";
      write (Filename.concat author "knowledge/log.md")
        "# Log\n## 2026-08-20\n- Added fixture.\n")
    (fun env ->
      let calls = ref 0 in
      ignore (check_ok "reserved seed" (run env calls));
      sql env.connection
        "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',11)";
      let before = database_snapshot env.connection and before_calls = !calls in
      let assert_rejected label code contents =
        write (Filename.concat env.author "knowledge/index.md") contents;
        ignore (commit_and_push env.author label);
        check_error label code (run env calls);
        Alcotest.(check int) (label ^ " no embedding") before_calls !calls;
        Alcotest.(check string) (label ^ " zero database effects") before
          (database_snapshot env.connection)
      in
      assert_rejected "invalid reserved" "reserved_index_sections" "# Index\n";
      assert_rejected "oversized reserved" "reserved_size_limit"
        (String.make (Clamp.Limits.max_file_bytes + 1) 'x');
      assert_rejected "reserved link overflow" "markdown_link_limit"
        (many_links (Clamp.Limits.max_markdown_links + 1));
      write (Filename.concat env.author "knowledge/index.md")
        "# Index\n## Entries\n- [Alpha](facts/alpha.md)\n";
      write (Filename.concat env.author "knowledge/bad name/index.md")
        "# Index\n## Entries\n";
      ignore (commit_and_push env.author "nonportable reserved ancestor");
      check_error "nonportable reserved ancestor" "path_component_invalid"
        (run env calls);
      Alcotest.(check int) "nonportable no embedding" before_calls !calls;
      Alcotest.(check string) "nonportable zero database effects" before
        (database_snapshot env.connection);
      remove (Filename.concat env.author "knowledge/bad name");
      write (Filename.concat env.author "knowledge/Index.md")
        "# Index\n## Entries\n";
      ignore (commit_and_push env.author "case-colliding reserved path");
      check_error "case-colliding reserved path" "path_duplicate" (run env calls);
      Alcotest.(check int) "case collision no embedding" before_calls !calls;
      Alcotest.(check string) "case collision zero database effects" before
        (database_snapshot env.connection))

let process_exists pid =
  try Unix.kill pid 0; true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false

let process_group_exists pid =
  try Unix.kill (-pid) 0; true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false

let await_process_exit pid =
  let rec loop remaining =
    if not (process_exists pid) then true
    else if remaining = 0 then false
    else (Unix.sleepf 0.02; loop (remaining - 1))
  in
  loop 100

let with_watchdog label operation =
  let child = Unix.fork () in
  if child = 0 then
    (try operation (); Unix._exit 0
     with failure ->
       prerr_endline (label ^ ": " ^ Printexc.to_string failure);
       Unix._exit 97)
  else
    let deadline = Unix.gettimeofday () +. 15. in
    let rec wait () =
      match Unix.waitpid [ Unix.WNOHANG ] child with
      | 0, _ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.02; wait ()
      | 0, _ ->
          Unix.kill child Sys.sigkill;
          ignore (Unix.waitpid [] child);
          Alcotest.fail (label ^ " watchdog expired")
      | _, Unix.WEXITED 0 -> ()
      | _, _ -> Alcotest.fail (label ^ " watchdog child failed")
    in
    wait ()

let with_variables variables operation =
  let previous =
    List.map (fun (name, _) -> (name, Sys.getenv_opt name)) variables
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, value) -> match value with
          | Some value -> Unix.putenv name value
          | None -> Unix.unsetenv name) previous)
    (fun () ->
      List.iter (fun (name, value) -> match value with
          | Some value -> Unix.putenv name value
          | None -> Unix.unsetenv name) variables;
      operation ())

let amp_authenticated_git () =
  with_watchdog "Amp authenticated Git" (fun () ->
    let root = Filename.temp_file "clamp-phase5-amp-auth-" "" in
    Sys.remove root; Unix.mkdir root 0o700;
    Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let home = Filename.concat root "home" in
      let runtime = Filename.concat home ".amp"
      and bin = Filename.concat home ".amp/bin"
      and source = Filename.concat root "source"
      and bare = Filename.concat root "remote.git"
      and clone = Filename.concat root "clone"
      and helper_marker = Filename.concat root "trusted-helper-ran"
      and hostile_marker = Filename.concat root "hostile-helper-ran"
      and port_file = Filename.concat root "port"
      and certificate = Filename.concat root "loopback.crt"
      and private_key = Filename.concat root "loopback.key"
      and server_script = Filename.concat root "git-http.py" in
      List.iter (fun path -> Unix.mkdir path 0o700) [ home; runtime; bin ];
      command "git" [ "init"; "--quiet"; "--initial-branch=main"; source ];
      git source [ "config"; "user.name"; "Clamp Test" ];
      git source [ "config"; "user.email"; "clamp-test@local.invalid" ];
      write (Filename.concat source "README") "authenticated fixture\n";
      git source [ "add"; "README" ];
      git source [ "commit"; "--quiet"; "-m"; "fixture" ];
      command "git" [ "clone"; "--quiet"; "--bare"; source; bare ];
      command "git" [ "clone"; "--quiet"; bare; clone ];
      let helper = Filename.concat bin "amp" in
      let write_helper mode =
        write helper
          ("#!/usr/bin/python3\nimport os,pathlib,sys,time\nxdg=os.environ.get('XDG_CONFIG_HOME')\nexpected=os.path.join(os.environ['HOME'],'.config')\nif xdg != expected: sys.exit(3)\nconfig=pathlib.Path(xdg); config.mkdir(parents=True,exist_ok=True)\nprobe=config/'.clamp-write-probe'; probe.write_text('ok'); probe.unlink()\nmarker=pathlib.Path('" ^
           helper_marker ^ "')\nmode='" ^ mode ^
           "'\nmarker.write_text(str(os.getpid()))\nif mode == 'hang': time.sleep(60)\nif mode == 'error': sys.exit(1)\nif mode == 'output': sys.stderr.write('x' * 1048576); sys.stderr.flush(); time.sleep(60)\nif os.environ.get('POISON_AUTH') is not None: sys.exit(2)\nif sys.argv[1:] == ['git-credential-helper','get']:\n sys.stdin.read(); print('username=amp'); print('password='+os.environ['AMP_API_KEY']); print()\n");
        Unix.chmod helper 0o755
      in
      write_helper "ok";
      write (Filename.concat home ".gitconfig")
        ("[credential]\n\thelper = !touch " ^ hostile_marker ^ "\n");
      let hostile_hook = Filename.concat clone ".git/hooks/post-fetch" in
      write hostile_hook ("#!/bin/sh\ntouch " ^ hostile_marker ^ "\n");
      Unix.chmod hostile_hook 0o755;
      command "openssl"
        [ "req"; "-x509"; "-newkey"; "rsa:2048"; "-nodes"; "-days"; "1";
          "-subj"; "/CN=127.0.0.1"; "-addext"; "subjectAltName=IP:127.0.0.1";
          "-keyout"; private_key; "-out"; certificate ];
      write server_script
        "import base64,http.server,os,pathlib,ssl,subprocess,sys,urllib.parse\nroot,portfile,secret,cert,key=sys.argv[1:6]\nexpected='Basic '+base64.b64encode(('amp:'+secret).encode()).decode()\nclass H(http.server.BaseHTTPRequestHandler):\n def log_message(self,*args): pass\n def handle_git(self):\n  if self.headers.get('Authorization') != expected:\n   self.send_response(401); self.send_header('WWW-Authenticate','Basic realm=fixture'); self.send_header('Content-Length','0'); self.end_headers(); return\n  parsed=urllib.parse.urlsplit(self.path); length=int(self.headers.get('Content-Length','0')); body=self.rfile.read(length)\n  env={'PATH':'/usr/bin:/bin','GIT_PROJECT_ROOT':root,'GIT_HTTP_EXPORT_ALL':'1','PATH_INFO':parsed.path,'QUERY_STRING':parsed.query,'REQUEST_METHOD':self.command,'CONTENT_TYPE':self.headers.get('Content-Type',''),'CONTENT_LENGTH':str(length),'REMOTE_USER':'amp'}\n  result=subprocess.run(['/usr/bin/git','http-backend'],input=body,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,check=True)\n  head,payload=result.stdout.split(b'\\r\\n\\r\\n',1); lines=head.decode().split('\\r\\n'); status=200\n  if lines and lines[0].startswith('Status:'): status=int(lines.pop(0).split()[1])\n  self.send_response(status)\n  for line in lines:\n   if line: self.send_header(*line.split(': ',1))\n  self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload)\n def do_GET(self): self.handle_git()\n def do_POST(self): self.handle_git()\nserver=http.server.HTTPServer(('127.0.0.1',0),H); context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key); server.socket=context.wrap_socket(server.socket,server_side=True); pathlib.Path(portfile).write_text(str(server.server_port)); server.serve_forever()\n";
      let secret = Printf.sprintf "fixture-%d-%d" (Unix.getpid ()) !counter in
      let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
      let server_arguments =
        [| "/usr/bin/python3"; server_script; root; port_file; secret;
           certificate; private_key |]
      in
      let server =
        Unix.create_process server_arguments.(0) server_arguments Unix.stdin
          dev_null dev_null
      in
      Unix.close dev_null;
      Fun.protect
        ~finally:(fun () ->
          (try Unix.kill server Sys.sigterm with Unix.Unix_error _ -> ());
          (try ignore (Unix.waitpid [] server) with Unix.Unix_error _ -> ()))
        (fun () ->
          let rec await_port attempts =
            if Sys.file_exists port_file then String.trim (read port_file)
            else if attempts = 0 then Alcotest.fail "Git HTTP fixture did not start"
            else (Unix.sleepf 0.01; await_port (attempts - 1))
          in
          let port = await_port 200 in
          let remote = "https://127.0.0.1:" ^ port ^ "/remote.git" in
          let tls_arguments arguments remote =
            [ "-c"; "http.sslCAInfo=" ^ certificate ] @ arguments remote
          in
          let variables ?(key = Some secret) () =
            [ ("AMP_BIN_DIR", Some bin); ("HOME", Some home);
              ("AMP_API_KEY", key); ("AMP_URL", Some ("https://127.0.0.1:" ^ port));
              ("POISON_AUTH", None) ]
          in
          Alcotest.(check bool) "exact Amp remote" true
            (Clamp.Sync.For_test.amp_remote "ampcode.com/@example/clamp"
               "https://ampcode.com/@example/clamp");
          Alcotest.(check bool) "Amp dot-git remote" true
            (Clamp.Sync.For_test.amp_remote "ampcode.com/@example/clamp"
               "https://ampcode.com/@example/clamp.git");
          Alcotest.(check bool) "Amp lookalike rejected" false
            (Clamp.Sync.For_test.amp_remote "ampcode.com/@example/clamp"
               "https://ampcode.com.example/@example/clamp");
          with_variables
            [ ("AMP_BIN_DIR", Some bin); ("HOME", Some home);
              ("AMP_API_KEY", Some secret);
              ("AMP_URL", Some "https://attacker.invalid") ]
            (fun () ->
              check_error "untrusted Amp URL" "git_auth_unavailable"
                (Clamp.Sync.For_test.trusted_amp_runtime ()));
          Unix.chmod helper 0o777;
          with_variables (variables ()) (fun () ->
            check_error "writable Amp helper" "git_auth_unavailable"
              (Clamp.Sync.For_test.trusted_amp_runtime ()));
          Unix.chmod helper 0o755;
          let saved_helper = helper ^ ".saved" in
          Unix.rename helper saved_helper;
          Unix.symlink saved_helper helper;
          with_variables (variables ()) (fun () ->
            check_error "symbolic Amp helper" "git_auth_unavailable"
              (Clamp.Sync.For_test.trusted_amp_runtime ()));
          Unix.unlink helper;
          Unix.rename saved_helper helper;
          with_variables (variables ()) (fun () ->
            let _, environment =
              check_ok "trusted Amp environment"
                (Clamp.Sync.For_test.trusted_amp_runtime ())
            in
            Alcotest.(check bool) "authenticated XDG is derived" true
              (Array.exists (( = ) ("XDG_CONFIG_HOME=" ^ Filename.concat home ".config"))
                 environment);
            let output = check_ok "authenticated sanitized Git"
                (Clamp.Sync.For_test.amp_git ~repo:clone ~remote
                   ~arguments:(tls_arguments (fun remote ->
                       [ "fetch"; "--quiet"; "--no-auto-maintenance"; remote;
                         "+refs/heads/main:refs/remotes/auth-fixture/main" ]))
                   ~maximum:4096 ~timeout:3.) in
            Alcotest.(check string) "authenticated fetch output" "" output;
            Alcotest.(check int) "authenticated ref fetched" 40
              (String.length
                 (git_output clone [ "rev-parse"; "refs/remotes/auth-fixture/main" ]));
            Alcotest.(check bool) "trusted helper ran" true
              (Sys.file_exists helper_marker);
            Alcotest.(check bool) "global hostile helper ignored" false
              (Sys.file_exists hostile_marker);
            Alcotest.(check bool) "secret absent from Git output" false
              (try ignore (Str.search_forward (Str.regexp_string secret) output 0); true
               with Not_found -> false));
          let ordinary_xdg =
            check_ok "ordinary sanitized XDG"
              (Clamp.Sync.For_test.run_process ~program:"/usr/bin/printenv"
                 ~arguments:[| "printenv"; "XDG_CONFIG_HOME" |]
                 ~maximum:128 ~timeout:1. ~after_spawn:(fun _ -> ()))
          in
          Alcotest.(check string) "ordinary XDG remains isolated"
            "/nonexistent\n" ordinary_xdg;
          let config_home = Filename.concat home ".config" in
          Unix.chmod config_home 0o777;
          with_variables (variables ()) (fun () ->
            check_error "unsafe-mode Amp config directory" "git_auth_unavailable"
              (Clamp.Sync.For_test.trusted_amp_runtime ()));
          Unix.chmod config_home 0o700;
          Sys.remove helper_marker;
          git clone [ "config"; "credential.helper";
                      "!touch " ^ hostile_marker ];
          with_variables (variables ()) (fun () ->
            check_error "repository hostile helper" "git_auth_config_unsafe"
              (Clamp.Sync.For_test.amp_git ~repo:clone ~remote
                 ~arguments:(tls_arguments (fun remote -> [ "ls-remote"; remote ]))
                 ~maximum:4096 ~timeout:1.));
          Alcotest.(check bool) "repository hostile helper did not execute" false
            (Sys.file_exists hostile_marker);
          git clone [ "config"; "--unset-all"; "credential.helper" ];
          with_variables (variables ~key:None ()) (fun () ->
            check_error "missing Amp auth" "git_auth_unavailable"
              (Clamp.Sync.For_test.amp_git ~repo:clone ~remote
                 ~arguments:(tls_arguments (fun remote -> [ "ls-remote"; remote ]))
                 ~maximum:4096 ~timeout:1.));
          with_variables (variables ~key:(Some (secret ^ "-invalid")) ()) (fun () ->
            match Clamp.Sync.For_test.amp_git ~repo:clone ~remote
                    ~arguments:(tls_arguments (fun remote -> [ "ls-remote"; remote ]))
                    ~maximum:4096 ~timeout:2. with
            | Error failure ->
                Alcotest.(check string) "invalid auth code" "git_auth_failed"
                  failure.code;
                Alcotest.(check bool) "invalid secret redacted" false
                  (try ignore (Str.search_forward (Str.regexp_string secret)
                                 failure.message 0); true with Not_found -> false)
            | Ok _ -> Alcotest.fail "invalid Amp auth succeeded");
          List.iter (fun (mode, code, maximum) ->
              Sys.remove helper_marker;
              write_helper mode;
              with_variables (variables ()) (fun () ->
                check_error ("helper " ^ mode) code
                  (Clamp.Sync.For_test.amp_git ~repo:clone ~remote
                     ~arguments:(tls_arguments (fun remote -> [ "ls-remote"; remote ]))
                     ~maximum ~timeout:0.2));
              let helper_pid = int_of_string (String.trim (read helper_marker)) in
              Alcotest.(check bool) (mode ^ " helper reaped") true
                (await_process_exit helper_pid))
            [ ("hang", "git_timeout", 4096);
              ("error", "git_auth_failed", 4096);
              ("output", "git_output_limit", 128) ])));
  with_environment "auth_missing_side_effects" (fun _ -> ()) (fun env ->
      let home = Filename.concat env.root "home" in
      let runtime = Filename.concat home ".amp"
      and bin = Filename.concat home ".amp/bin" in
      List.iter (fun path -> Unix.mkdir path 0o700) [ home; runtime; bin ];
      let helper = Filename.concat bin "amp" in
      write helper "#!/bin/sh\nexit 1\n"; Unix.chmod helper 0o755;
      write (Filename.concat env.clone "clamp.yaml")
        (Str.global_replace (Str.regexp_string "local.test/clamp-fixture")
           "ampcode.com/@example/clamp" (read (Filename.concat env.clone "clamp.yaml")));
      git env.clone [ "remote"; "set-url"; "origin";
                      "https://ampcode.com/@example/clamp" ];
      let before = database_snapshot env.connection and calls = ref 0 in
      with_variables
        [ ("AMP_BIN_DIR", Some bin); ("HOME", Some home); ("AMP_API_KEY", None);
          ("AMP_URL", Some "http://127.0.0.1:1") ]
        (fun () ->
          check_error "missing auth sync" "git_auth_unavailable" (run env calls));
      Alcotest.(check int) "missing auth zero embeddings" 0 !calls;
      Alcotest.(check string) "missing auth exact database" before
        (database_snapshot env.connection);
      Unix.chmod helper 0o777;
      with_variables
        [ ("AMP_BIN_DIR", Some bin); ("HOME", Some home);
          ("AMP_API_KEY", Some "synthetic-invalid-helper-key");
          ("AMP_URL", Some "https://ampcode.com") ]
        (fun () ->
          check_error "invalid helper sync" "git_auth_unavailable" (run env calls));
      Alcotest.(check int) "invalid helper zero embeddings" 0 !calls;
      Alcotest.(check string) "invalid helper exact database" before
        (database_snapshot env.connection))

let fetch_does_not_recurse_submodules () =
  with_environment "no_submodule_fetch"
    (fun author ->
      let root = Filename.dirname author in
      let sub_author = Filename.concat root "sub-author"
      and sub_remote = Filename.concat root "sub-remote.git" in
      command "git"
        [ "init"; "--quiet"; "--bare"; "--initial-branch=main"; sub_remote ];
      command "git"
        [ "init"; "--quiet"; "--initial-branch=main"; sub_author ];
      git sub_author [ "config"; "user.name"; "Clamp Test" ];
      git sub_author [ "config"; "user.email"; "clamp-test@local.invalid" ];
      git sub_author [ "remote"; "add"; "origin"; sub_remote ];
      write (Filename.concat sub_author "payload") "initial\n";
      git sub_author [ "add"; "payload" ];
      git sub_author [ "commit"; "--quiet"; "-m"; "initial" ];
      git sub_author [ "push"; "--quiet"; "origin"; "main" ];
      command "git"
        [ "-c"; "protocol.file.allow=always"; "-C"; author; "submodule";
          "add"; "--quiet"; "file://" ^ sub_remote; "vendor/dependency" ];
      write (Filename.concat author "knowledge/facts/alpha.md") (fact ()))
    (fun env ->
      let sub_author = Filename.concat env.root "sub-author"
      and control = Filename.concat env.root "control"
      and dependency = "vendor/dependency" in
      command "git" [ "clone"; "--quiet"; "file://" ^
                      Filename.concat env.root "remote.git"; control ];
      List.iter
        (fun repo ->
          command "git"
            [ "-c"; "protocol.file.allow=always"; "-C"; repo; "submodule";
              "update"; "--init"; "--quiet" ];
          git repo [ "config"; "fetch.recurseSubmodules"; "true" ];
          git repo
            [ "config"; "submodule." ^ dependency ^ ".fetchRecurseSubmodules";
              "true" ])
        [ env.clone; control ];
      let clone_submodule = Filename.concat env.clone dependency
      and control_submodule = Filename.concat control dependency in
      let initial_submodule =
        git_output clone_submodule [ "rev-parse"; "refs/remotes/origin/main" ]
      in
      let initial_gitlink =
        git_output env.author [ "rev-parse"; "HEAD:" ^ dependency ]
      in
      let seed_calls = ref 0 in
      ignore (check_ok "initial top-level sync" (run env seed_calls));
      Alcotest.(check int) "initial concept embedded" 1 !seed_calls;
      write (Filename.concat sub_author "payload") "updated\n";
      git sub_author [ "add"; "payload" ];
      git sub_author [ "commit"; "--quiet"; "-m"; "updated" ];
      git sub_author [ "push"; "--quiet"; "origin"; "main" ];
      let updated = git_output sub_author [ "rev-parse"; "HEAD" ] in
      write (Filename.concat env.author "knowledge/facts/alpha.md")
        (fact ~body:"Unrelated top-level semantic update." ());
      let target_commit = commit_and_push env.author "update top-level concept" in
      Alcotest.(check string) "top-level gitlink unchanged" initial_gitlink
        (git_output env.author [ "rev-parse"; "HEAD:" ^ dependency ]);
      git control [ "fetch"; "--quiet"; "origin" ];
      Alcotest.(check string) "control recursion fetched submodule" updated
        (git_output control_submodule [ "rev-parse"; "refs/remotes/origin/main" ]);
      Alcotest.(check bool) "fixture has a newer submodule commit" false
        (initial_submodule = updated);
      let calls = ref 0 in
      let report = check_ok "top-level-only production fetch" (run env calls) in
      Alcotest.(check string) "top-level checkpoint" target_commit report.commit;
      Alcotest.(check int) "top-level concept reembedded" 1 !calls;
      Alcotest.(check string) "database checkpoint" target_commit
        (scalar env.connection
           "SELECT last_indexed_commit FROM public.index_state WHERE id=1");
      Alcotest.(check string) "production fetch did not recurse" initial_submodule
        (git_output clone_submodule [ "rev-parse"; "refs/remotes/origin/main" ]))

let retrieval_vertical_slice () =
  with_environment "retrieval"
    (fun author ->
      List.iter
        (fun id ->
          write (Filename.concat author ("knowledge/facts/" ^ id ^ ".md"))
            (fact ~title:id ~body:("Indexed body for " ^ id ^ ".") ()))
        [ "stable"; "draft"; "deprecated"; "stale"; "closed" ])
    (fun env ->
      let sync_calls = ref 0 in
      let synced = check_ok "retrieval seed" (run env sync_calls) in
      Alcotest.(check int) "seed embeddings" 5 !sync_calls;
      let vector = Array.make Clamp.Openrouter.dimensions "0" in
      vector.(0) <- "1";
      let vector = "[" ^ String.concat "," (Array.to_list vector) ^ "]" in
      ignore
        (env.connection#exec ~expect:[ Postgresql.Command_ok ] ~params:[| vector |]
           "UPDATE public.concepts SET embedding=$1::public.vector,indexed_at=pg_catalog.now() - interval '30 days'");
      sql env.connection
        "UPDATE public.concepts SET status='draft',verified_tier='unverified',asserted_by='amp/agent',frontmatter=pg_catalog.jsonb_set(pg_catalog.jsonb_set(frontmatter,'{status}','\"draft\"'::jsonb),'{clamp,asserted_by}','\"amp/agent\"'::jsonb) WHERE path='facts/draft'";
      sql env.connection
        "UPDATE public.concepts SET status='deprecated',frontmatter=pg_catalog.jsonb_set(frontmatter,'{status}','\"deprecated\"'::jsonb) WHERE path='facts/deprecated'";
      sql env.connection
        "UPDATE public.concepts SET stale_after=(pg_catalog.now() AT TIME ZONE 'Africa/Johannesburg')::date,frontmatter=pg_catalog.jsonb_set(frontmatter,'{stale_after}',pg_catalog.to_jsonb(((pg_catalog.now() AT TIME ZONE 'Africa/Johannesburg')::date)::text)) WHERE path='facts/stale'";
      sql env.connection
        "UPDATE public.concepts SET type='task',task_state='done',task_priority='urgent',task_due_at='1969-12-31T23:59:59.9999994Z',task_completed_at='1970-01-01T02:00:00.9999995+02:00',frontmatter=pg_catalog.jsonb_set(pg_catalog.jsonb_set(frontmatter,'{type}','\"task\"'::jsonb),'{clamp,task}','{\"state\":\"done\",\"priority\":\"urgent\",\"due_at\":\"1969-12-31T23:59:59.9999994Z\",\"completed_at\":\"1970-01-01T02:00:00.9999995+02:00\"}'::jsonb) WHERE path='facts/closed'";
      let embed_calls = ref 0 in
      let embed _ = incr embed_calls; Ok (let result = Array.make Clamp.Openrouter.dimensions 0. in result.(0) <- 1.; result) in
      let search history =
        Clamp.Retrieval.For_test.search_with_connection ~connection:env.connection
          ~embed ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
          ~query:"fixture query" ~history
      in
      let retrieval_error label code = function
        | Ok _ -> Alcotest.failf "%s: expected %s" label code
        | Error (failure : Clamp.Retrieval.error) ->
            Alcotest.(check string) label code failure.code
      in
      let retrieval_ok label = function
        | Ok value -> value
        | Error (failure : Clamp.Retrieval.error) ->
            Alcotest.failf "%s: %s (%s)" label failure.message failure.code
      in
      let ids results =
        List.map (fun (item : Clamp.Retrieval.result) -> item.id) results
      in
      let normal = retrieval_ok "normal retrieval" (search Clamp.Retrieval.normal_history) in
      Alcotest.(check (list string)) "normal visibility"
        [ "facts/draft"; "facts/stable" ] (ids normal);
      let draft = List.find (fun (item : Clamp.Retrieval.result) -> item.id = "facts/draft") normal in
      Alcotest.(check string) "draft visible" "draft" draft.status;
      Alcotest.(check string) "draft trust visible" "unverified" draft.verified_tier;
      Alcotest.(check (option string)) "assertion origin visible" (Some "amp/agent")
        draft.asserted_by;
      Alcotest.(check string) "search records no access" "0"
        (scalar env.connection "SELECT count(*) FROM public.access_stats");
      let history = Clamp.Retrieval.normal_history in
      let deprecated = retrieval_ok "deprecated history"
          (search { history with include_deprecated = true })
      and stale = retrieval_ok "stale history"
          (search { history with include_stale = true })
      and closed = retrieval_ok "closed history"
          (search { history with include_closed_tasks = true }) in
      Alcotest.(check bool) "deprecated independently included" true
        (List.mem "facts/deprecated" (ids deprecated));
      Alcotest.(check bool) "deprecated flag excludes stale" false
        (List.mem "facts/stale" (ids deprecated));
      Alcotest.(check bool) "stale independently included" true
        (List.mem "facts/stale" (ids stale));
      Alcotest.(check bool) "closed independently included" true
        (List.mem "facts/closed" (ids closed));
      Alcotest.(check string) "all searches record no access" "0"
        (scalar env.connection "SELECT count(*) FROM public.access_stats");
      let readers = 6 in
      let ready_read, ready_write = Unix.pipe ~cloexec:true () in
      let children =
        List.init readers (fun _ ->
            match Unix.fork () with
            | 0 ->
                Unix.close ready_write;
                let byte = Bytes.create 1 in
                ignore (Unix.read ready_read byte 0 1);
                let child_connection = connection env.database in
                let result =
                  Clamp.Retrieval.For_test.get_with_connection
                    ~connection:child_connection ~source:"local.test/clamp-fixture"
                    ~local_commit:synced.commit ~id:"facts/stable"
                    ~history:Clamp.Retrieval.normal_history
                in
                child_connection#finish;
                Unix._exit (match result with Ok _ -> 0 | Error _ -> 1)
            | child -> child)
      in
      Unix.close ready_read;
      ignore (Unix.write ready_write (Bytes.make readers 'x') 0 readers);
      Unix.close ready_write;
      List.iter
        (fun child ->
          match snd (Unix.waitpid [] child) with
          | Unix.WEXITED 0 -> ()
          | _ -> Alcotest.fail "concurrent get failed")
        children;
      Alcotest.(check string) "atomic concurrent increments" (string_of_int readers)
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      let huge = "1" ^ String.make 1000 '0'
      and integer = "12345678901234567890123456789012345678901234567890"
      and precise = "0.123456789012345678901234567890123456789" in
      let numeric_frontmatter =
        Printf.sprintf
          "{\"type\":\"fact\",\"title\":\"stable\",\"generated\":{\"by\":\"amp/agent\",\"at\":\"2026-08-20T08:00:00Z\"},\"clamp\":{\"asserted_by\":\"human:owner\"},\"precise\":%s,\"huge\":1e1000,\"integer\":%s}"
          precise integer
      in
      ignore
        (env.connection#exec ~expect:[ Postgresql.Command_ok ]
           ~params:[| numeric_frontmatter |]
           "UPDATE public.concepts SET frontmatter=$1::jsonb WHERE path='facts/stable'");
      let settings =
        match Clamp.Config.retrieval (read (Filename.concat env.clone "clamp.yaml")) with
        | Ok settings -> settings
        | Error failure -> Alcotest.failf "fixture retrieval config: %s" failure
      in
      write (Filename.concat env.clone "clamp.yaml") "dirty worktree config\n";
      with_remote_login env (fun url ->
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/stable"; "--json"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 0 -> () | _ ->
            Alcotest.failf "get JSON failed: %s" errors);
          ignore (Yojson.Raw.from_string (String.trim output));
          List.iter
            (fun exact ->
              Alcotest.(check bool) ("exact JSON " ^ exact) true
                (try ignore (Str.search_forward (Str.regexp_string exact) output 0); true
                 with Not_found -> false))
            [ "\"code\":\"concept_retrieved\"";
              "\"precise\":" ^ precise; "\"integer\":" ^ integer;
              "\"huge\":" ^ huge;
              "\"body\":\"Indexed body for stable.\\n\"" ];
          let status, human, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/stable"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 0 -> () | _ ->
            Alcotest.failf "human get failed: %s" errors);
          let expected_human =
            Printf.sprintf
              "---\n\"type\": \"fact\"\n\"title\": \"stable\"\n\"generated\":\n  \"at\": \"2026-08-20T08:00:00Z\"\n  \"by\": \"amp/agent\"\n\"clamp\":\n  \"asserted_by\": \"human:owner\"\n\"huge\": !!int %s\n\"integer\": !!int %s\n\"precise\": !!float %s\n---\nIndexed body for stable.\n"
              huge integer precise
          in
          Alcotest.(check string) "complete exact human concept" expected_human human;
          let before_quiet =
            scalar env.connection
              "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'"
          in
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/stable"; "--quiet"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 2 -> () | _ ->
            Alcotest.failf "quiet get status: %s" errors);
          Alcotest.(check string) "quiet get emits no content" "" output;
          Alcotest.(check string) "quiet get records no access" before_quiet
            (scalar env.connection
               "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/stable"; "--json"; "--quiet";
                "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 0 -> () | _ ->
            Alcotest.failf "JSON quiet get failed: %s" errors);
          Alcotest.(check bool) "JSON quiet returns full content" true
            (try ignore (Str.search_forward (Str.regexp_string ("\"huge\":" ^ huge))
                           output 0); true with Not_found -> false));
      Alcotest.(check string) "three successful CLI gets record access"
        (string_of_int (readers + 3))
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      sql env.connection "DELETE FROM public.access_stats";
      let without_telemetry = retrieval_ok "lost telemetry search" (search history) in
      let stable = List.find (fun (item : Clamp.Retrieval.result) -> item.id = "facts/stable") without_telemetry in
      Alcotest.(check (float 1e-12)) "lost telemetry frequency" 0. stable.frequency;
      ignore (retrieval_ok "lost telemetry get recreation"
                (Clamp.Retrieval.For_test.get_with_connection
                   ~connection:env.connection ~source:"local.test/clamp-fixture"
                   ~local_commit:synced.commit ~id:"facts/stable" ~history));
      Alcotest.(check string) "telemetry recreated" "1"
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      sql env.connection
        "UPDATE public.concepts SET frontmatter='{}'::jsonb WHERE path='facts/stable'";
      let invalid_mapping_ref_checks = ref 0 in
      retrieval_error "invalid mapping get" "database_row_invalid"
        (Clamp.Retrieval.For_test.get_with_ref_check
           ~check_local_ref:(fun ~timeout:_ -> incr invalid_mapping_ref_checks; Ok ())
           ~connection:env.connection ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~id:"facts/stable" ~history);
      Alcotest.(check int) "invalid mapping fails before ref check" 0
        !invalid_mapping_ref_checks;
      Alcotest.(check string) "invalid mapping get records no access" "1"
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      let invalid_search_ref_checks = ref 0 in
      retrieval_error "invalid mapping search" "database_row_invalid"
        (Clamp.Retrieval.For_test.search_with_settings ~settings
           ~check_local_ref:(fun ~timeout:_ -> incr invalid_search_ref_checks; Ok ())
           ~connection:env.connection ~embed ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~query:"query" ~history);
      Alcotest.(check int) "invalid search fails before ref check" 0
        !invalid_search_ref_checks;
      Alcotest.(check string) "invalid mapping search records no access" "1"
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      ignore
        (env.connection#exec ~expect:[ Postgresql.Command_ok ]
           ~params:[| numeric_frontmatter |]
           "UPDATE public.concepts SET frontmatter=$1::jsonb WHERE path='facts/stable'");
      let projection_cases =
        [ ("type", "type='preference'", "type='fact'");
          ("title", "title='contradictory'", "title='stable'");
          ("description", "description='contradictory'", "description=NULL");
          ("tags", "tags=ARRAY['contradictory']::text[]", "tags='{}'::text[]");
          ("status", "status='draft'", "status='stable'");
          ("stale_after", "stale_after='2099-01-01'", "stale_after=NULL");
          ("generated_by", "generated_by='other'", "generated_by='amp/agent'");
          ("generated_at", "generated_at='1969-12-31T23:59:59.999999Z'",
           "generated_at='2026-08-20T08:00:00Z'");
          ("asserted_by", "asserted_by='other'", "asserted_by='human:owner'");
          ("verified_tier", "verified_tier='machine-confirmed'",
           "verified_tier='unverified'");
          ("task_state", "task_state='doing'", "task_state=NULL");
          ("task_priority", "task_priority='urgent'", "task_priority=NULL");
          ("task_due_on", "task_due_on='2099-01-01'", "task_due_on=NULL");
          ("task_due_at", "task_due_at='1970-01-01T02:00:00+02:00'",
           "task_due_at=NULL");
          ("task_completed_at",
           "task_completed_at='1970-01-01T02:00:00.9999995+02:00'",
           "task_completed_at=NULL") ]
      in
      List.iter
        (fun (label, mutation, restore) ->
          let before_path =
            scalar env.connection
              "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'"
          and before_total =
            scalar env.connection "SELECT COALESCE(sum(access_count),0)::text FROM public.access_stats"
          in
          sql env.connection
            ("UPDATE public.concepts SET " ^ mutation ^ " WHERE path='facts/stable'");
          let get_ref_checks = ref 0 in
          retrieval_error (label ^ " mismatch get") "database_row_invalid"
            (Clamp.Retrieval.For_test.get_with_ref_check
               ~check_local_ref:(fun ~timeout:_ -> incr get_ref_checks; Ok ())
               ~connection:env.connection ~source:"local.test/clamp-fixture"
               ~local_commit:synced.commit ~id:"facts/stable" ~history);
          Alcotest.(check int) (label ^ " get before ref check") 0 !get_ref_checks;
          Alcotest.(check string) (label ^ " get access unchanged") before_path
            (scalar env.connection
               "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
          let search_ref_checks = ref 0 in
          retrieval_error (label ^ " mismatch search") "database_row_invalid"
            (Clamp.Retrieval.For_test.search_with_settings ~settings
               ~check_local_ref:(fun ~timeout:_ -> incr search_ref_checks; Ok ())
               ~connection:env.connection ~embed ~source:"local.test/clamp-fixture"
               ~local_commit:synced.commit ~query:"query" ~history);
          Alcotest.(check int) (label ^ " search before ref check") 0
            !search_ref_checks;
          Alcotest.(check string) (label ^ " search access unchanged") before_total
            (scalar env.connection
               "SELECT COALESCE(sum(access_count),0)::text FROM public.access_stats");
          sql env.connection
            ("UPDATE public.concepts SET " ^ restore ^ " WHERE path='facts/stable'"))
        projection_cases;
      let clock = ref 0. in
      let now () = !clock in
      let search_timeout_cap = ref None in
      retrieval_error "search final-ref deadline" "retrieval_validation_timeout"
        (Clamp.Retrieval.For_test.search_with_clock ~now ~settings
           ~check_local_ref:(fun ~timeout ->
             search_timeout_cap := Some timeout;
             clock := 5.1;
             Error { Clamp.Retrieval.kind = Stale; code = "local_ref_missing";
                     message = "lower-level ref error" })
           ~connection:env.connection ~embed ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~query:"query" ~history);
      Alcotest.(check (option (float 1e-12))) "search Git timeout capped"
        (Some 5.) !search_timeout_cap;
      let before_deadline_get =
        scalar env.connection
          "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'"
      in
      clock := 0.;
      let get_timeout_cap = ref None in
      retrieval_error "get final-ref deadline" "retrieval_validation_timeout"
        (Clamp.Retrieval.For_test.get_with_clock ~now
           ~check_local_ref:(fun ~timeout ->
             get_timeout_cap := Some timeout;
             clock := 5.1;
             Ok ())
           ~connection:env.connection ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~id:"facts/stable" ~history);
      Alcotest.(check (option (float 1e-12))) "get Git timeout capped"
        (Some 5.) !get_timeout_cap;
      Alcotest.(check string) "deadline get records no access" before_deadline_get
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      clock := 0.;
      let within_cap = ref None in
      ignore
        (retrieval_ok "final ref just within deadline"
           (Clamp.Retrieval.For_test.search_with_clock ~now ~settings
              ~check_local_ref:(fun ~timeout ->
                within_cap := Some timeout;
                clock := 4.998;
                Ok ())
              ~connection:env.connection ~embed ~source:"local.test/clamp-fixture"
              ~local_commit:synced.commit ~query:"query" ~history));
      Alcotest.(check (option (float 1e-12))) "within-budget Git timeout capped"
        (Some 5.) !within_cap;
      clock := 4.9995;
      let submillisecond_cap = ref None in
      (match
         Clamp.Retrieval.For_test.check_final_ref ~now ~deadline:5.
           (fun ~timeout ->
             submillisecond_cap := Some timeout;
             clock := 4.9996;
             Ok ())
       with
      | Ok () -> ()
      | Error failure ->
          Alcotest.failf "sub-millisecond final ref: %s" failure.code);
      Alcotest.(check (option (float 1e-9))) "positive sub-millisecond Git cap"
        (Some 0.0005) !submillisecond_cap;
      clock := 0.;
      let lower_ref_error : Clamp.Retrieval.error =
        { kind = Stale; code = "synthetic_ref_error"; message = "synthetic" }
      in
      retrieval_error "in-budget ref error preserved" "synthetic_ref_error"
        (Clamp.Retrieval.For_test.search_with_clock ~now ~settings
           ~check_local_ref:(fun ~timeout:_ -> Error lower_ref_error)
           ~connection:env.connection ~embed ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~query:"query" ~history);
      sql env.connection
        "UPDATE public.index_state SET last_indexed_commit=repeat('a',40)";
      let before_stale = !embed_calls in
      let stale_accesses =
        scalar env.connection
          "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'"
      in
      retrieval_error "stale retrieval" "index_stale" (search history);
      Alcotest.(check int) "stale before embedding" before_stale !embed_calls;
      retrieval_error "stale get" "index_stale"
        (Clamp.Retrieval.For_test.get_with_connection ~connection:env.connection
           ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
           ~id:"facts/stable" ~history);
      Alcotest.(check string) "stale get records no access" stale_accesses
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      with_remote_login env (fun url ->
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/stable"; "--json"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 6 -> () | _ ->
            Alcotest.failf "stale get JSON failed: %s" errors);
          let json = Yojson.Safe.from_string (String.trim output) in
          Alcotest.(check string) "stale JSON code" "index_stale"
            Yojson.Safe.Util.(json |> member "code" |> to_string);
          Alcotest.(check string) "stale JSON fallback" "local_markdown_or_rg"
            Yojson.Safe.Util.(json |> member "details" |> member "fallback" |> to_string);
          Alcotest.(check bool) "fallback is not semantically equivalent" false
            Yojson.Safe.Util.(json |> member "details" |>
                              member "semantic_equivalent" |> to_bool));
      sql env.connection
        (Printf.sprintf "UPDATE public.index_state SET last_indexed_commit='%s',embedding_model='wrong'" synced.commit);
      retrieval_error "incompatible retrieval" "index_incompatible" (search history);
      sql env.connection
        (Printf.sprintf "UPDATE public.index_state SET embedding_model='%s'"
           Clamp.Openrouter.canonical_identity);
      let provider_error : Clamp.Retrieval.error =
        { kind = Transient; code = "openrouter_unavailable";
          message = "OpenRouter unavailable." }
      in
      retrieval_error "OpenRouter failure preserved" "openrouter_unavailable"
        (Clamp.Retrieval.For_test.search_with_connection ~connection:env.connection
           ~embed:(fun _ -> Error provider_error) ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~query:"query" ~history);
      write (Filename.concat env.author "knowledge/facts/stable.md")
        (fact ~title:"stable" ~body:"New remote content." ());
      let advanced_commit = commit_and_push env.author "advance retrieval race" in
      let advanced = ref false in
      let advance_ref ~timeout =
        if not !advanced then begin
          advanced := true;
          git env.clone [ "fetch"; "--quiet"; "origin" ]
        end;
        Clamp.Retrieval.For_test.check_local_commit ~timeout env.clone synced.commit
      in
      retrieval_error "search local-ref race" "local_ref_changed"
        (Clamp.Retrieval.For_test.search_with_settings ~settings
           ~check_local_ref:advance_ref ~connection:env.connection ~embed
           ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
           ~query:"query" ~history);
      git env.clone [ "update-ref"; "refs/remotes/origin/main"; synced.commit ];
      let race_accesses =
        scalar env.connection
          "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'"
      in
      retrieval_error "get local-ref race" "local_ref_changed"
        (Clamp.Retrieval.For_test.get_with_ref_check
           ~check_local_ref:(fun ~timeout ->
             git env.clone
               [ "update-ref"; "refs/remotes/origin/main"; advanced_commit ];
             Clamp.Retrieval.For_test.check_local_commit ~timeout env.clone synced.commit)
           ~connection:env.connection ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~id:"facts/stable" ~history);
      Alcotest.(check string) "ref-raced get records no access" race_accesses
        (scalar env.connection
           "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/stable'");
      git env.clone [ "update-ref"; "refs/remotes/origin/main"; synced.commit ];
      let status, output, _ =
        capture_process ~url:"unused" [ "search"; "query"; "--json";
                                        "--repo"; env.clone ]
      in
      (match status with Unix.WEXITED 2 -> () | _ -> Alcotest.fail "search JSON exit");
      let json = Yojson.Safe.from_string (String.trim output) in
      Alcotest.(check string) "search JSON missing URL"
        "database_url_missing" Yojson.Safe.Util.(json |> member "code" |> to_string);
      let status, help, _ = capture_process ~url:"unused" [ "search"; "--help" ] in
      (match status with Unix.WEXITED 0 -> () | _ -> Alcotest.fail "search help exit");
      List.iter
        (fun flag -> Alcotest.(check bool) (flag ^ " help") true
            (try ignore (Str.search_forward (Str.regexp_string flag) help 0); true
             with Not_found -> false))
        [ "--include-deprecated"; "--include-stale"; "--include-closed-tasks" ];
      sql env.connection "DROP TABLE public.index_state";
      let before_missing = !embed_calls in
      retrieval_error "missing index" "index_missing" (search history);
      Alcotest.(check int) "missing index before embedding" before_missing !embed_calls)

let retrieval_database_failure () =
  with_environment "retrieval_db_failure" (fun _ -> ()) (fun env ->
      let url =
        "postgresql://fixture:fixture@127.0.0.1:1/fixture?sslmode=require&channel_binding=require&connect_timeout=1"
      in
      match
        Clamp.Retrieval.search ~repo:env.clone ~url ~query:"query"
          ~history:Clamp.Retrieval.normal_history
      with
      | Ok _ -> Alcotest.fail "unavailable database search succeeded"
      | Error failure ->
          Alcotest.(check bool) "database failure is degraded transient" true
            (failure.Clamp.Retrieval.kind = Transient);
          Alcotest.(check bool) "stable database failure code" true
            (List.mem failure.code
               [ "database_unavailable"; "database_connection_timeout";
                 "database_connection_lost" ]))

let retrieval_utf8_client_encoding () =
  let non_ascii = "\194\128" in
  let body = "UTF-8 before " ^ non_ascii ^ " after.\n" in
  with_environment "retrieval_encoding"
    (fun author ->
      write (Filename.concat author "knowledge/facts/encoding.md")
        (fact ~title:"Encoding" ~body:(String.trim body) ()))
    (fun env ->
      let calls = ref 0 in
      let synced = check_ok "encoding seed" (run env calls) in
      Alcotest.(check int) "encoding seed embedding" 1 !calls;
      let database_identifier = quote_identifier env.database in
      Fun.protect
        ~finally:(fun () ->
          Unix.unsetenv "PGCLIENTENCODING";
          postgres "postgres"
            ("ALTER DATABASE " ^ database_identifier ^
             " RESET client_encoding"))
        (fun () ->
          postgres "postgres"
            ("ALTER DATABASE " ^ database_identifier ^
             " SET client_encoding TO 'GB18030'");
          with_remote_login env
            ~configure_role:(fun role ->
              postgres "postgres"
                ("ALTER ROLE " ^ role ^ " SET client_encoding TO 'GB18030'"))
            (fun url ->
              Unix.putenv "PGCLIENTENCODING" "GB18030";
              let measured =
                match
                  Clamp.Database.For_retrieval.with_remote ~url (fun connection ->
                    Result.bind
                      (Clamp.Database.For_retrieval.execute connection
                         ~expect:[ Postgresql.Tuples_ok ]
                         "SELECT pg_catalog.current_setting('client_encoding')")
                      (fun startup ->
                        Alcotest.(check string) "hostile startup encoding"
                          "GB18030" (startup#getvalue 0 0);
                        Result.bind
                          (Clamp.Database.For_retrieval.transaction connection
                             ~statement_timeout_ms:5000 (fun connection ->
                               Clamp.Database.For_retrieval.execute connection
                                 ~expect:[ Postgresql.Tuples_ok ]
                                 "SELECT pg_catalog.current_setting('client_encoding'),pg_catalog.octet_length(body)::text,body FROM public.concepts WHERE path='facts/encoding'"))
                          (fun utf8 ->
                            Result.bind
                              (Clamp.Database.For_retrieval.execute connection
                                 ~expect:[ Postgresql.Tuples_ok ]
                                 "SELECT pg_catalog.current_setting('client_encoding')")
                              (fun restored -> Ok (utf8, restored)))))
                with
                | Error failure ->
                    Alcotest.failf "encoding transaction: %s" failure.code
                | Ok value -> value
              in
              let utf8, restored = measured in
              Alcotest.(check string) "retrieval transaction pins UTF8" "UTF8"
                (utf8#getvalue 0 0);
              Alcotest.(check string) "UTF8 measured payload bytes"
                (string_of_int (String.length body)) (utf8#getvalue 0 1);
              Alcotest.(check string) "UTF8 fetched payload bytes" body
                (utf8#getvalue 0 2);
              Alcotest.(check string) "transaction-local encoding restored"
                "GB18030" (restored#getvalue 0 0);
              let concept =
                match
                  Clamp.Retrieval.get ~repo:env.clone ~url ~id:"facts/encoding"
                    ~history:Clamp.Retrieval.normal_history
                with
                | Ok concept -> concept
                | Error failure ->
                    Alcotest.failf "production UTF8 get: %s" failure.code
              in
              Alcotest.(check string) "production non-ASCII get" body concept.body;
              Alcotest.(check string) "successful encoding get telemetry" "1"
                (scalar env.connection
                   "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/encoding'");
              sql env.connection
                "UPDATE public.concepts SET body=pg_catalog.repeat(U&'\\0080',5000000) WHERE path='facts/encoding'";
              (match
                 Clamp.Retrieval.get ~repo:env.clone ~url ~id:"facts/encoding"
                   ~history:Clamp.Retrieval.normal_history
               with
              | Error failure ->
                  Alcotest.(check string) "expanded encoding row bounded"
                    "retrieval_validation_limit" failure.code
              | Ok _ -> Alcotest.fail "expanded encoding row unexpectedly succeeded");
              Alcotest.(check string) "bounded encoding failure no telemetry" "1"
                (scalar env.connection
                   "SELECT access_count::text FROM public.access_stats WHERE concept_path='facts/encoding'");
              Alcotest.(check string) "encoding checkpoint unchanged" synced.commit
                (scalar env.connection
                   "SELECT last_indexed_commit FROM public.index_state WHERE id=1"))))

let retrieval_commit_finalization () =
  with_environment "retrieval_commit"
    (fun author ->
      write (Filename.concat author "knowledge/facts/commit.md")
        (fact ~title:"Commit boundary" ()))
    (fun env ->
      let calls = ref 0 in
      let synced = check_ok "commit seed" (run env calls) in
      let access_count () =
        scalar env.connection
          "SELECT COALESCE((SELECT access_count FROM public.access_stats WHERE concept_path='facts/commit'),0)::text"
      in
      let get_connection operation =
        let remote = connection env.database in
        Fun.protect ~finally:(fun () -> try remote#finish with _ -> ())
          (fun () -> operation remote)
      in
      let get ~deadline_seconds ~check_local_ref =
        get_connection (fun connection ->
            Clamp.Retrieval.For_test.get_with_deadline ~deadline_seconds
              ~now:Unix.gettimeofday ~check_local_ref ~connection
              ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
              ~id:"facts/commit" ~history:Clamp.Retrieval.normal_history)
      in
      let check_error label expected = function
        | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
        | Error (failure : Clamp.Retrieval.error) ->
            Alcotest.(check string) label expected failure.code
      in
      let check_failure label expected_code expected_message = function
        | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
        | Error (failure : Clamp.Retrieval.error) ->
            Alcotest.(check string) (label ^ " code") expected_code failure.code;
            Alcotest.(check string) (label ^ " message") expected_message
              failure.message
      in
      let generic_connection_loss = "Database connection was lost."
      and get_commit_uncertain =
        "Database connection was lost after access telemetry commit was dispatched; access telemetry may or may not have committed. Do not retry blindly because access could be counted twice."
      and search_commit_uncertain =
        "Database connection was lost after the search transaction commit was dispatched; transaction acknowledgement is uncertain. Search did not update access telemetry."
      in
      let install_delay seconds =
        sql env.connection
          (Printf.sprintf
             "CREATE OR REPLACE FUNCTION public.retrieval_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.pg_sleep(%g); RETURN NEW; END $$"
             seconds);
        sql env.connection
          "DROP TRIGGER IF EXISTS retrieval_commit_delay ON public.access_stats";
        sql env.connection
          "CREATE CONSTRAINT TRIGGER retrieval_commit_delay AFTER INSERT OR UPDATE ON public.access_stats DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.retrieval_commit_delay()"
      in
      install_delay 0.1;
      let started = Unix.gettimeofday () in
      (match
         get ~deadline_seconds:1.
           ~check_local_ref:(fun ~timeout:_ -> Ok ())
       with
      | Ok _ -> ()
      | Error failure ->
          Alcotest.failf "delayed COMMIT success: %s" failure.code);
      Alcotest.(check bool) "COMMIT acknowledgement may consume budget" true
        (Unix.gettimeofday () -. started >= 0.08);
      Alcotest.(check string) "delayed successful COMMIT records telemetry" "1"
        (access_count ());
      sql env.connection "DELETE FROM public.access_stats";
      check_error "deadline expires before COMMIT dispatch"
        "retrieval_validation_timeout"
        (get ~deadline_seconds:0.05
           ~check_local_ref:(fun ~timeout:_ -> Unix.sleepf 0.06; Ok ()));
      Alcotest.(check string) "pre-dispatch expiry records no telemetry" "0"
        (access_count ());
      install_delay 0.2;
      let started = Unix.gettimeofday () in
      (match
         Clamp.Database.For_retrieval.transaction env.connection
           ~statement_timeout_ms:50 (fun connection ->
             Clamp.Database.For_retrieval.execute connection
               ~params:[| "facts/commit" |]
               "INSERT INTO public.access_stats(concept_path,last_accessed_at,access_count) VALUES ($1,pg_catalog.now(),1)")
       with
      | Ok _ -> ()
      | Error failure ->
          Alcotest.failf "deferred COMMIT statement-timeout probe: %s"
            failure.code);
      Alcotest.(check bool) "transaction-local timeout does not bound deferred COMMIT" true
        (Unix.gettimeofday () -. started >= 0.18);
      Alcotest.(check string) "deferred timeout probe committed" "1"
        (access_count ());
      sql env.connection "DELETE FROM public.access_stats";
      let started = Unix.gettimeofday () in
      (match
         get ~deadline_seconds:0.05
           ~check_local_ref:(fun ~timeout:_ -> Ok ())
       with
      | Ok _ -> ()
      | Error failure ->
          Alcotest.failf "dispatched delayed COMMIT: %s" failure.code);
      Alcotest.(check bool) "dispatched COMMIT may acknowledge after deadline" true
        (Unix.gettimeofday () -. started >= 0.18);
      Alcotest.(check string) "late successful COMMIT records telemetry" "1"
        (access_count ());
      sql env.connection "DELETE FROM public.access_stats";
      sql env.connection
        "CREATE OR REPLACE FUNCTION public.retrieval_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'administrator command'; END $$";
      get_connection (fun connection ->
          check_failure "deterministic deferred COMMIT error"
            "database_sql_error" "Database rejected the operation."
            (Clamp.Retrieval.For_test.get_with_deadline ~deadline_seconds:1.
               ~now:Unix.gettimeofday
               ~check_local_ref:(fun ~timeout:_ -> Ok ()) ~connection
               ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
               ~id:"facts/commit" ~history:Clamp.Retrieval.normal_history);
          (match
             Clamp.Database.For_retrieval.execute connection
               ~expect:[ Postgresql.Tuples_ok ] "SELECT 1"
           with
          | Ok rows ->
              Alcotest.(check string) "connection reusable after SQL error" "1"
                (rows#getvalue 0 0)
          | Error failure ->
              Alcotest.failf "connection not reusable: %s" failure.code));
      Alcotest.(check string) "deterministic COMMIT error records no telemetry" "0"
        (access_count ());
      sql env.connection
        "CREATE OR REPLACE FUNCTION public.retrieval_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_catalog.pg_terminate_backend(pg_catalog.pg_backend_pid()); RETURN NEW; END $$";
      check_failure "in-flight COMMIT connection loss" "database_connection_lost"
        get_commit_uncertain
        (get ~deadline_seconds:1.
           ~check_local_ref:(fun ~timeout:_ -> Ok ()));
      Alcotest.(check string) "self-terminated fixture did not commit telemetry" "0"
        (access_count ());
      with_remote_login env (fun url ->
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/commit"; "--json"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 5 -> () | _ ->
            Alcotest.failf "post-COMMIT get JSON status: %s" errors);
          Alcotest.(check string) "exact post-COMMIT get JSON"
            (Printf.sprintf
               "{\"ok\":false,\"code\":\"database_connection_lost\",\"message\":%s,\"details\":{\"fallback\":\"local_markdown_or_rg\",\"semantic_equivalent\":false}}\n"
               (Yojson.Safe.to_string (`String get_commit_uncertain)))
            output;
          Alcotest.(check string) "post-COMMIT get JSON stderr" "" errors;
          let status, output, errors =
            capture_process ~pooled:true ~url
              [ "get"; "facts/commit"; "--repo"; env.clone ]
          in
          (match status with Unix.WEXITED 5 -> () | _ ->
            Alcotest.failf "post-COMMIT get human status: %s" errors);
          Alcotest.(check string) "post-COMMIT get human stdout" "" output;
          Alcotest.(check string) "exact post-COMMIT get human"
            ("kb: " ^ get_commit_uncertain ^ "\n") errors);
      let after_dispatch : Clamp.Database.error =
        { kind = Transient; code = "database_connection_lost";
          message = generic_connection_loss;
          finalization = After_commit_dispatch }
      in
      let search_failure =
        Clamp.Retrieval.For_test.search_database_error after_dispatch
      in
      Alcotest.(check string) "post-COMMIT search message"
        search_commit_uncertain search_failure.message;
      Alcotest.(check string) "exact post-COMMIT search JSON contract"
        (Printf.sprintf
           "{\"ok\":false,\"code\":\"database_connection_lost\",\"message\":%s,\"details\":{\"fallback\":\"local_markdown_or_rg\",\"semantic_equivalent\":false}}"
           (Yojson.Safe.to_string (`String search_commit_uncertain)))
        (Clamp.Retrieval.cli_result search_failure
         |> Clamp.Cli_result.to_json_string);
      let before_dispatch =
        { after_dispatch with finalization = Before_commit_dispatch }
      in
      let ordinary = Clamp.Retrieval.For_test.get_database_error before_dispatch in
      Alcotest.(check string) "pre-COMMIT connection loss unchanged"
        generic_connection_loss ordinary.message;
      Alcotest.(check string) "exact pre-COMMIT connection loss JSON"
        "{\"ok\":false,\"code\":\"database_connection_lost\",\"message\":\"Database connection was lost.\",\"details\":{\"fallback\":\"local_markdown_or_rg\",\"semantic_equivalent\":false}}"
        (Clamp.Retrieval.cli_result ordinary |> Clamp.Cli_result.to_json_string);
      sql env.connection "DROP TRIGGER retrieval_commit_delay ON public.access_stats";
      get_connection (fun connection ->
          let result =
            Clamp.Database.For_retrieval.transaction_result connection
              ~statement_timeout_ms:1000
              ~commit_before_deadline:(fun () -> connection#finish; true)
              (fun connection ->
                Result.map
                  (fun _ -> Ok ())
                  (Clamp.Database.For_retrieval.execute connection
                     ~params:[| "facts/commit" |]
                     "INSERT INTO public.access_stats(concept_path,last_accessed_at,access_count) VALUES ($1,pg_catalog.now(),1)"))
          in
          match result with
          | Ok _ -> Alcotest.fail "closed pre-send connection unexpectedly committed"
          | Error failure ->
              Alcotest.(check string) "pre-send closed connection code"
                "database_connection_lost" failure.code;
              Alcotest.(check bool) "pre-send closed connection phase" true
                (failure.finalization = Clamp.Database.Before_commit_dispatch);
              let get_failure =
                Clamp.Retrieval.For_test.get_database_error failure
              and search_failure =
                Clamp.Retrieval.For_test.search_database_error failure
              in
              Alcotest.(check string) "pre-send get message remains generic"
                generic_connection_loss get_failure.message;
              Alcotest.(check string) "pre-send search message remains generic"
                generic_connection_loss search_failure.message;
              Alcotest.(check string) "exact pre-send get JSON"
                "{\"ok\":false,\"code\":\"database_connection_lost\",\"message\":\"Database connection was lost.\",\"details\":{\"fallback\":\"local_markdown_or_rg\",\"semantic_equivalent\":false}}"
                (Clamp.Retrieval.cli_result get_failure
                 |> Clamp.Cli_result.to_json_string);
              Alcotest.(check string) "exact pre-send search JSON"
                "{\"ok\":false,\"code\":\"database_connection_lost\",\"message\":\"Database connection was lost.\",\"details\":{\"fallback\":\"local_markdown_or_rg\",\"semantic_equivalent\":false}}"
                (Clamp.Retrieval.cli_result search_failure
                 |> Clamp.Cli_result.to_json_string));
      Alcotest.(check string) "pre-send close records no telemetry" "0"
        (access_count ());
      get_connection (fun connection ->
          let backend = scalar connection "SELECT pg_backend_pid()::text" in
          ignore
            (env.connection#exec ~expect:[ Postgresql.Tuples_ok ]
               ("SELECT pg_catalog.pg_terminate_backend(" ^ backend ^ ")"));
          check_failure "real pre-COMMIT connection loss"
            "database_connection_lost" generic_connection_loss
            (Clamp.Retrieval.For_test.get_with_deadline ~deadline_seconds:1.
               ~now:Unix.gettimeofday
               ~check_local_ref:(fun ~timeout:_ -> Ok ()) ~connection
               ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
               ~id:"facts/commit" ~history:Clamp.Retrieval.normal_history)))

let retrieval_hnsw_candidates () =
  with_environment "retrieval_hnsw"
    (fun author ->
      write (Filename.concat author "knowledge/facts/seed.md")
        (fact ~title:"Seed" ()))
    (fun env ->
      let calls = ref 0 in
      let synced = check_ok "ANN seed" (run env calls) in
      Alcotest.(check int) "seed embedding" 1 !calls;
      sql env.connection
        (Printf.sprintf
           "INSERT INTO public.concepts(path,blob_hash,embedding_input_hash,type,title,description,tags,body,frontmatter,status,generated_by,asserted_by,verified_tier,embedding_model,embedding) SELECT 'facts/ann-' || pg_catalog.lpad(g::text,4,'0'),'blob-' || g,'input-' || g,'fact','ANN ' || g,NULL,'{}'::text[],'ANN body.',pg_catalog.jsonb_build_object('type','fact','title','ANN ' || g,'clamp',pg_catalog.jsonb_build_object('asserted_by','human:fixture')) || CASE WHEN g <= 1800 THEN '{\"status\":\"deprecated\"}'::jsonb ELSE '{}'::jsonb END,CASE WHEN g <= 1800 THEN 'deprecated' ELSE 'stable' END,NULL,'human:fixture','unverified','%s',(ARRAY[1.0::real,(g::real / 2000.0::real)] || pg_catalog.array_fill(0.0::real,ARRAY[1534]))::public.vector FROM pg_catalog.generate_series(1,2000) AS series(g)"
           Clamp.Openrouter.canonical_identity);
      sql env.connection "ANALYZE public.concepts";
      let query = Array.make Clamp.Openrouter.dimensions 0. in
      query.(0) <- 1.;
      let vector =
        "[" ^
        (query |> Array.to_list |> List.map (Printf.sprintf "%.17g")
         |> String.concat ",") ^ "]"
      in
      let params =
        [| vector; "false"; "false"; "false";
           Clamp.Openrouter.canonical_identity; "100";
           string_of_int Clamp.Retrieval.For_test.validation_total_bytes |]
      in
      let plan =
        match
          Clamp.Database.For_retrieval.transaction env.connection
            ~statement_timeout_ms:5000 (fun connection ->
              Result.bind
                (Clamp.Retrieval.For_test.configure_ann connection)
                (fun _ ->
                  Clamp.Database.For_retrieval.execute connection
                    ~expect:[ Postgresql.Tuples_ok ] ~params
                    ("EXPLAIN (COSTS OFF) " ^
                     Clamp.Retrieval.For_test.candidate_sql)))
        with
        | Error failure -> Alcotest.failf "ANN explain: %s" failure.code
        | Ok rows ->
            List.init rows#ntuples (fun row -> rows#getvalue row 0)
            |> String.concat "\n"
      in
      (try
         ignore
           (Str.search_forward
              (Str.regexp_string "concepts_embedding_hnsw_idx") plan 0)
       with Not_found -> Alcotest.failf "actual HNSW index plan:\n%s" plan);
      let settings : Clamp.Config.retrieval =
        { candidate_limit = 100; result_limit = 100;
          semantic_weight = 0.70; recency_weight = 0.20;
          frequency_weight = 0.10; recency_half_life_days = 30;
          frequency_saturation_count = 100 }
      in
      let results =
        match
          Clamp.Retrieval.For_test.search_with_settings ~settings
            ~check_local_ref:(fun ~timeout:_ -> Ok ()) ~connection:env.connection
            ~embed:(fun _ -> Ok query) ~source:"local.test/clamp-fixture"
            ~local_commit:synced.commit ~query:"ANN"
            ~history:Clamp.Retrieval.normal_history
        with
        | Ok results -> results
        | Error failure -> Alcotest.failf "ANN retrieval: %s" failure.code
      in
      Alcotest.(check int) "selective ANN fills K" 100 (List.length results);
      Alcotest.(check bool) "all ANN candidates visible" true
        (List.for_all
           (fun (result : Clamp.Retrieval.result) -> result.status = "stable")
           results);
      let lightweight =
        match
          Clamp.Database.For_retrieval.transaction env.connection
            ~statement_timeout_ms:5000 (fun connection ->
              Result.bind
                (Clamp.Retrieval.For_test.configure_ann connection)
                (fun _ ->
                  Clamp.Database.For_retrieval.execute connection
                    ~expect:[ Postgresql.Tuples_ok ]
                    ~params:
                      [| vector; "true"; "false"; "false";
                         Clamp.Openrouter.canonical_identity; "1000";
                         string_of_int
                           Clamp.Retrieval.For_test.validation_total_bytes |]
                    Clamp.Retrieval.For_test.candidate_sql))
        with
        | Error failure -> Alcotest.failf "lightweight ANN query: %s" failure.code
        | Ok rows -> rows
      in
      Alcotest.(check int) "lightweight ANN fills K=1000" 1000 lightweight#ntuples;
      Alcotest.(check int) "lightweight ANN field count" 8 lightweight#nfields;
      let transferred = ref 0 in
      for row = 0 to lightweight#ntuples - 1 do
        for column = 0 to lightweight#nfields - 1 do
          if not (lightweight#getisnull row column) then
            transferred := !transferred + String.length (lightweight#getvalue row column)
        done
      done;
      Alcotest.(check bool) "lightweight ANN transfer is bounded" true
        (!transferred < 1024 * 1024);
      sql env.connection
        "UPDATE public.concepts SET frontmatter=pg_catalog.jsonb_set(frontmatter,'{padding}',pg_catalog.to_jsonb(pg_catalog.repeat('x',6*1024*1024))) WHERE path IN ('facts/ann-0001','facts/ann-0002','facts/ann-0003')";
      let bounded_settings : Clamp.Config.retrieval =
        { settings with candidate_limit = 1000 }
      in
      let ref_checks = ref 0 in
      (match
         Clamp.Retrieval.For_test.search_with_settings ~settings:bounded_settings
           ~check_local_ref:(fun ~timeout:_ -> incr ref_checks; Ok ())
           ~connection:env.connection ~embed:(fun _ -> Ok query)
           ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
           ~query:"ANN"
           ~history:{ Clamp.Retrieval.normal_history with include_deprecated = true }
       with
      | Error failure ->
          Alcotest.(check string) "candidate validation budget"
            "retrieval_validation_limit" failure.code
      | Ok _ -> Alcotest.fail "candidate validation budget unexpectedly succeeded");
      Alcotest.(check int) "resource limit before final ref check" 0 !ref_checks;
      Alcotest.(check string) "resource limit records no telemetry" "0"
        (scalar env.connection
           "SELECT COALESCE(pg_catalog.sum(access_count),0)::text FROM public.access_stats");
      sql env.connection
        "UPDATE public.concepts SET frontmatter=frontmatter-'padding' WHERE path IN ('facts/ann-0001','facts/ann-0002','facts/ann-0003')";
      sql env.connection
        "UPDATE public.concepts SET body=pg_catalog.repeat('oversized-body-marker-',524289) WHERE path='facts/ann-0001'";
      let oversized_get_ref_checks = ref 0 in
      (match
         Clamp.Retrieval.For_test.get_with_ref_check
           ~check_local_ref:(fun ~timeout:_ -> incr oversized_get_ref_checks; Ok ())
           ~connection:env.connection ~source:"local.test/clamp-fixture"
           ~local_commit:synced.commit ~id:"facts/ann-0001"
           ~history:{ Clamp.Retrieval.normal_history with include_deprecated = true }
       with
      | Error failure ->
          Alcotest.(check string) "oversized get classification"
            "retrieval_validation_limit" failure.code
      | Ok _ -> Alcotest.fail "oversized get unexpectedly succeeded");
      Alcotest.(check int) "oversized get before final ref check" 0
        !oversized_get_ref_checks;
      Alcotest.(check string) "oversized get records no telemetry" "0"
        (scalar env.connection
           "SELECT COALESCE(pg_catalog.sum(access_count),0)::text FROM public.access_stats");
      let oversized_ref_checks = ref 0 in
      (match
         Clamp.Retrieval.For_test.search_with_settings ~settings:bounded_settings
           ~check_local_ref:(fun ~timeout:_ -> incr oversized_ref_checks; Ok ())
           ~connection:env.connection ~embed:(fun _ -> Ok query)
           ~source:"local.test/clamp-fixture" ~local_commit:synced.commit
           ~query:"ANN"
           ~history:{ Clamp.Retrieval.normal_history with include_deprecated = true }
       with
      | Error failure ->
          Alcotest.(check string) "oversized malformed row classification"
            "retrieval_validation_limit" failure.code;
          Alcotest.(check string) "oversized malformed row is body-free"
            "The candidate set exceeds the fixed retrieval validation budget; use local Markdown or rg."
            failure.message
      | Ok _ -> Alcotest.fail "oversized malformed row unexpectedly succeeded");
      Alcotest.(check int) "oversized row before final ref check" 0
        !oversized_ref_checks;
      Alcotest.(check string) "oversized row records no telemetry" "0"
        (scalar env.connection
           "SELECT COALESCE(pg_catalog.sum(access_count),0)::text FROM public.access_stats"))

let concurrent_sync_acceptance () =
  with_watchdog "concurrent synchronization" (fun () ->
    with_environment "concurrent"
      (fun author ->
        write (Filename.concat author "knowledge/facts/alpha.md")
          (fact ~title:"Alpha" ()))
      (fun env ->
        let seed_calls = ref 0 in
        ignore (check_ok "concurrency seed" (run env seed_calls));
        Alcotest.(check int) "seed embedding" 1 !seed_calls;
        sql env.connection
          "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/alpha',13)";
        write (Filename.concat env.author "knowledge/facts/alpha.md")
          (fact ~title:"Alpha" ~body:"Concurrent semantic update." ());
        write (Filename.concat env.author "knowledge/facts/beta.md")
          (fact ~title:"Beta" ());
        let target_commit = commit_and_push env.author "concurrent target" in
        sql env.connection
          "CREATE TABLE sync_write_audit(path text NOT NULL, operation text NOT NULL)";
        sql env.connection
          "CREATE FUNCTION record_sync_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO sync_write_audit(path,operation) VALUES (COALESCE(NEW.path,OLD.path),TG_OP); RETURN NULL; END $$";
        sql env.connection
          "CREATE TRIGGER record_sync_write AFTER INSERT OR UPDATE OR DELETE ON concepts FOR EACH ROW EXECUTE FUNCTION record_sync_write()";
        let ready_read, ready_write = Unix.pipe ~cloexec:true ()
        and start_read, start_write = Unix.pipe ~cloexec:true ()
        and event_read, event_write = Unix.pipe ~cloexec:true ()
        and release_read, release_write = Unix.pipe ~cloexec:true ()
        and result_read, result_write = Unix.pipe ~cloexec:true () in
        let rec write_all descriptor text offset =
          if offset < String.length text then
            try
              let count =
                Unix.write_substring descriptor text offset
                  (String.length text - offset)
              in
              if count = 0 then raise End_of_file
              else write_all descriptor text (offset + count)
            with Unix.Unix_error (Unix.EINTR, _, _) ->
              write_all descriptor text offset
        in
        let read_exact descriptor count =
          let bytes = Bytes.create count in
          let rec read offset =
            if offset = count then Bytes.to_string bytes
            else
              try
                let amount = Unix.read descriptor bytes offset (count - offset) in
                if amount = 0 then raise End_of_file else read (offset + amount)
              with Unix.Unix_error (Unix.EINTR, _, _) -> read offset
          in
          read 0
        in
        let read_line descriptor =
          let buffer = Buffer.create 128 and byte = Bytes.create 1 in
          let rec read_byte () =
            try Unix.read descriptor byte 0 1
            with Unix.Unix_error (Unix.EINTR, _, _) -> read_byte ()
          in
          let rec read () =
            let count = read_byte () in
            if count = 0 then
              if Buffer.length buffer = 0 then raise End_of_file
              else Buffer.contents buffer
            else if Bytes.get byte 0 = '\n' then Buffer.contents buffer
            else (Buffer.add_char buffer (Bytes.get byte 0); read ())
          in
          read ()
        in
        let child identifier =
          Unix.close ready_read; Unix.close start_write; Unix.close event_read;
          Unix.close release_write; Unix.close result_read;
          let calls = ref 0 in
          let report text = write_all result_write (text ^ "\n") 0 in
          (try
             let child_connection = connection env.database in
             write_all ready_write "R" 0;
             ignore (read_exact start_read 1);
             let result =
               Clamp.Sync.For_test.run_with_connection ~repo:env.clone
                 ~connection:child_connection
                 ~embed:(fun _ ->
                   if !calls = 0 then begin
                     write_all event_write "W" 0;
                     ignore (read_exact release_read 1)
                   end;
                   incr calls;
                   Ok (vector ()))
                 ~reembed:false ~allow_mass_deletion:false ~target_commit:None
             in
             child_connection#finish;
             (match result with
             | Error failure ->
                 report
                   (Printf.sprintf "%d|error|%s|%d" identifier failure.code !calls)
             | Ok value ->
                 report
                   (Printf.sprintf "%d|ok|%s|%d|%d|%d|%d|%d|%d" identifier
                      value.commit value.counts.added value.counts.metadata_updated
                      value.counts.reembedded value.counts.unchanged
                      value.counts.deleted !calls));
             Unix._exit 0
           with _ ->
             (try report (Printf.sprintf "%d|exception|%d" identifier !calls)
              with _ -> ());
             Unix._exit 98)
        in
        let first = Unix.fork () in
        if first = 0 then child 1;
        let second = Unix.fork () in
        if second = 0 then child 2;
        Unix.close ready_write; Unix.close start_read; Unix.close event_write;
        Unix.close release_read; Unix.close result_write;
        ignore (read_exact ready_read 2);
        write_all start_write "SS" 0;
        Alcotest.(check string) "one lock winner reached embedding" "W"
          (read_exact event_read 1);
        let loser = read_line result_read in
        let loser_fields = String.split_on_char '|' loser in
        (match loser_fields with
        | [ _; "error"; "sync_already_running"; "0" ] -> ()
        | _ -> Alcotest.failf "unexpected concurrent loser: %s" loser);
        write_all release_write "G" 0;
        let winner = read_line result_read in
        let winner_fields = String.split_on_char '|' winner in
        (match winner_fields with
        | [ _; "ok"; commit; "1"; "0"; "1"; "0"; "0"; "2" ] ->
            Alcotest.(check string) "winner target checkpoint" target_commit commit
        | _ -> Alcotest.failf "unexpected concurrent winner: %s" winner);
        Unix.close ready_read; Unix.close start_write; Unix.close event_read;
        Unix.close release_write; Unix.close result_read;
        let wait child =
          match snd (Unix.waitpid [] child) with
          | Unix.WEXITED 0 -> ()
          | _ -> Alcotest.fail "concurrent sync child failed"
        in
        wait first; wait second;
        Alcotest.(check string) "final checkpoint" target_commit
          (scalar env.connection "SELECT last_indexed_commit FROM index_state");
        Alcotest.(check string) "final row count" "2"
          (scalar env.connection "SELECT count(*) FROM concepts");
        Alcotest.(check string) "exactly two concept writes" "2"
          (scalar env.connection "SELECT count(*) FROM sync_write_audit");
        Alcotest.(check string) "one alpha update" "1"
          (scalar env.connection
             "SELECT count(*) FROM sync_write_audit WHERE path='facts/alpha' AND operation='UPDATE'");
        Alcotest.(check string) "one beta insert" "1"
          (scalar env.connection
             "SELECT count(*) FROM sync_write_audit WHERE path='facts/beta' AND operation='INSERT'");
        Alcotest.(check string) "surviving telemetry preserved" "13"
          (scalar env.connection
             "SELECT access_count FROM access_stats WHERE concept_path='facts/alpha'");
        Alcotest.(check string) "new concept has no telemetry" "0"
          (scalar env.connection
             "SELECT count(*) FROM access_stats WHERE concept_path='facts/beta'")))

let process_group_cleanup () =
  with_watchdog "process-group cleanup" (fun () ->
    let root = Filename.temp_file "clamp-phase5-process-" "" in
    Sys.remove root; Unix.mkdir root 0o700;
    Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let helper = Filename.concat root "helper.py" in
      write helper
        "import os, pathlib, sys, time\npath=pathlib.Path(sys.argv[1]); mode=sys.argv[2]\nif mode == 'identity':\n print(f'{os.getpid()} {os.getpgrp()} {os.getsid(0)} {os.getppid()}'); sys.exit(0)\nchild=os.fork()\nif child == 0:\n if mode in ('eof','orphan'):\n  os.close(1); os.close(2)\n time.sleep(60)\nelse:\n path.write_text(f'{os.getpid()} {child}')\n if mode == 'orphan':\n  sys.exit(0)\n if mode == 'eof':\n  barrier=os.open(sys.argv[3],os.O_WRONLY); os.write(barrier,b'R'); os.close(barrier)\n  os.close(1); os.close(2)\n if mode == 'output':\n  sys.stdout.write('x' * 1048576); sys.stdout.flush()\n time.sleep(60)\n";
      let run mode maximum timeout after_spawn =
        let pids = Filename.concat root (mode ^ ".pids") in
        let result =
          Clamp.Sync.For_test.run_process ~program:"/usr/bin/python3"
            ~arguments:[| "/usr/bin/python3"; helper; pids; mode |]
            ~maximum ~timeout ~after_spawn
        in
        (pids, result)
      in
      let advanced ?(before_pipe = fun _ -> ()) ?(child_setup_delay = 0.)
          ?(after_fork = fun _ -> ())
          ?(after_readiness_selectable = fun () -> ())
          ?(before_ack_write = fun () -> ()) ?(before_ack_close = fun () -> ())
          ?(after_spawn = fun _ -> ()) ?(before_waitpid = fun () -> ())
          ~program ~arguments ~maximum ~timeout () =
        Clamp.Sync.For_test.run_process_with_hooks ~program ~arguments ~maximum
          ~timeout ~before_pipe ~child_setup_delay ~after_fork
          ~after_readiness_selectable ~before_ack_write ~before_ack_close
          ~after_spawn ~before_waitpid
      in
      let all_pids = ref [] in
      let record path =
        let values =
          read path |> String.trim |> String.split_on_char ' ' |> List.map int_of_string
        in
        all_pids := values @ !all_pids;
        values
      in
      let ack_descriptors = Array.length (Sys.readdir "/proc/self/fd") in
      let ack_acquisition =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:1.
          ~before_pipe:(fun number ->
            if number = 4 then
              raise (Unix.Unix_error (Unix.EMFILE, "ack-pipe", "fixture"))) ()
      in
      check_error "ACK acquisition" "git_unavailable" ack_acquisition;
      Alcotest.(check int) "ACK acquisition descriptors cleaned" ack_descriptors
        (Array.length (Sys.readdir "/proc/self/fd"));
      let start_helper = Filename.concat root "start-helper.py"
      and start_marker = Filename.concat root "helper-started" in
      write start_helper
        "import pathlib, sys\npathlib.Path(sys.argv[1]).write_text('started')\n";
      let handshake_pid = ref None and group_seen = ref false
      and acknowledged = ref false in
      let handshake_descriptors = Array.length (Sys.readdir "/proc/self/fd") in
      let handshake_timeout =
        advanced ~program:"/usr/bin/python3"
          ~arguments:[| "/usr/bin/python3"; start_helper; start_marker |]
          ~maximum:128 ~timeout:0.1
          ~after_fork:(fun pid -> handshake_pid := Some pid)
          ~after_readiness_selectable:(fun () ->
            group_seen := Option.exists process_group_exists !handshake_pid;
            Unix.sleepf 0.2)
          ~after_spawn:(fun _ -> acknowledged := true) ()
      in
      check_error "pre-ACK deadline" "git_timeout" handshake_timeout;
      Alcotest.(check bool) "confirmed process group observed" true !group_seen;
      Alcotest.(check bool) "ACK was not sent" false !acknowledged;
      Alcotest.(check bool) "helper execution impossible" false
        (Sys.file_exists start_marker);
      Alcotest.(check bool) "pre-ACK leader reaped" true
        (Option.exists await_process_exit !handshake_pid);
      Alcotest.(check bool) "pre-ACK group removed" false
        (Option.exists process_group_exists !handshake_pid);
      Alcotest.(check int) "pre-ACK descriptors cleaned" handshake_descriptors
        (Array.length (Sys.readdir "/proc/self/fd"));
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !handshake_pid;
      let ack_failures =
        ref [ Unix.EINTR; Unix.EAGAIN; Unix.EWOULDBLOCK ]
      and ack_attempts = ref 0 in
      let ack_retry =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:1.
          ~before_ack_write:(fun () ->
            incr ack_attempts;
            match !ack_failures with
            | [] -> ()
            | error :: rest ->
                ack_failures := rest;
                raise (Unix.Unix_error (error, "ack-write", "fixture"))) ()
      in
      (match ack_retry with
      | Ok (_, Unix.WEXITED 0) -> ()
      | _ -> Alcotest.fail "ACK transient write retry failed");
      Alcotest.(check int) "ACK write retried" 4 !ack_attempts;
      let ack_close_pid = ref None and ack_callback = ref false in
      let ack_close_descriptors = Array.length (Sys.readdir "/proc/self/fd") in
      let ack_close =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:1.
          ~after_fork:(fun pid -> ack_close_pid := Some pid)
          ~before_ack_close:(fun () ->
            raise (Unix.Unix_error (Unix.EIO, "ack-close", "fixture")))
          ~after_spawn:(fun _ -> ack_callback := true) ()
      in
      check_error "ACK close" "git_unavailable" ack_close;
      Alcotest.(check bool) "post-ACK callback blocked by close error" false !ack_callback;
      Alcotest.(check bool) "ACK close leader reaped" true
        (Option.exists await_process_exit !ack_close_pid);
      Alcotest.(check int) "ACK close descriptors cleaned" ack_close_descriptors
        (Array.length (Sys.readdir "/proc/self/fd"));
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !ack_close_pid;
      let eof_descriptors = Array.length (Sys.readdir "/proc/self/fd") in
      let barrier = Filename.concat root "eof-ready" in
      Unix.mkfifo barrier 0o600;
      let barrier_read =
        Unix.openfile barrier [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
      in
      let timeout_pids = Filename.concat root "eof.pids" in
      let timeout_result =
        Clamp.Sync.For_test.run_process ~program:"/usr/bin/python3"
          ~arguments:
            [| "/usr/bin/python3"; helper; timeout_pids; "eof";
               barrier |]
          ~maximum:1024 ~timeout:1. ~after_spawn:(fun _ -> ())
      in
      check_error "EOF-before-exit" "git_timeout" timeout_result;
      let marker = Bytes.create 1 in
      let rec read_barrier () =
        try Unix.read barrier_read marker 0 1
        with Unix.Unix_error (Unix.EINTR, _, _) -> read_barrier ()
      in
      Alcotest.(check int) "EOF helper readiness barrier" 1 (read_barrier ());
      Alcotest.(check char) "EOF helper readiness marker" 'R' (Bytes.get marker 0);
      Unix.close barrier_read;
      Alcotest.(check int) "EOF barrier descriptors cleaned" eof_descriptors
        (Array.length (Sys.readdir "/proc/self/fd"));
      record timeout_pids
      |> List.iter (fun pid ->
             Alcotest.(check bool) "EOF descendant reaped" true
               (await_process_exit pid));
      let hanging_pids, hanging_result =
        run "hang" 1024 0.3 (fun _ -> ())
      in
      check_error "hanging helper" "git_timeout" hanging_result;
      record hanging_pids |> List.iter
        (fun pid -> Alcotest.(check bool) "timeout descendant reaped" true
            (await_process_exit pid));
      let output_result =
        advanced ~program:"/usr/bin/python3"
          ~arguments:[| "/usr/bin/python3"; helper;
                        Filename.concat root "output.pids"; "output" |]
          ~maximum:128 ~timeout:0.2
          ~before_waitpid:(fun () -> Unix.sleepf 0.3) ()
      in
      check_error "output limit" "git_output_limit" output_result;
      record (Filename.concat root "output.pids")
      |> List.iter (fun pid ->
             Alcotest.(check bool) "output descendant reaped" true
               (await_process_exit pid));
      let delayed_callback = ref false in
      let delayed =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:0.05 ~child_setup_delay:0.2
          ~after_spawn:(fun _ -> delayed_callback := true) ()
      in
      check_error "delayed readiness" "git_timeout" delayed;
      Alcotest.(check bool) "callback not reached before readiness" false
        !delayed_callback;
      let local_ref_pid = ref None in
      let local_ref_timeout =
        Clamp.Sync.For_test.local_origin_main_with_hooks ~repo:(Sys.getcwd ())
          ~timeout:0.05 ~child_setup_delay:0.2
          ~after_fork:(fun pid -> local_ref_pid := Some pid)
      in
      check_error "bounded local-ref Git" "git_timeout" local_ref_timeout;
      Alcotest.(check bool) "bounded local-ref child reaped" true
        (Option.exists await_process_exit !local_ref_pid);
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !local_ref_pid;
      let exception_pid = ref None in
      let _, exception_result =
        run "exception" 1024 2. (fun pid ->
            exception_pid := Some pid; raise Exit)
      in
      check_error "exception cleanup" "git_unavailable" exception_result;
      Alcotest.(check bool) "exception process reaped" true
        (Option.exists await_process_exit !exception_pid);
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !exception_pid;
      let interrupted = ref true and wait_calls = ref 0 in
      let reaped = ref None in
      let eintr =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:1.
          ~after_spawn:(fun pid -> reaped := Some pid)
          ~before_waitpid:(fun () ->
            incr wait_calls;
            if !interrupted then begin
              interrupted := false;
              raise (Unix.Unix_error (Unix.EINTR, "waitpid", ""))
            end) ()
      in
      (match eintr with
      | Ok (_, Unix.WEXITED 0) -> ()
      | _ -> Alcotest.fail "waitpid EINTR retry failed");
      Alcotest.(check bool) "waitpid retried" true (!wait_calls >= 2);
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !reaped;
      let descriptors_before = Array.length (Sys.readdir "/proc/self/fd") in
      let pipe_failure =
        advanced ~program:"/bin/true" ~arguments:[| "/bin/true" |]
          ~maximum:128 ~timeout:1.
          ~before_pipe:(fun number ->
            if number = 2 then
              raise (Unix.Unix_error (Unix.EMFILE, "pipe", "fixture"))) ()
      in
      check_error "pipe acquisition" "git_unavailable" pipe_failure;
      Alcotest.(check int) "pipe descriptors cleaned" descriptors_before
        (Array.length (Sys.readdir "/proc/self/fd"));
      let identity_pid = ref None in
      let identity =
        advanced ~program:"/usr/bin/python3"
          ~arguments:[| "/usr/bin/python3"; helper;
                        Filename.concat root "identity.pids"; "identity" |]
          ~maximum:1024 ~timeout:1.
          ~after_spawn:(fun pid -> identity_pid := Some pid) ()
      in
      let identity_output =
        match identity with
        | Ok (output, Unix.WEXITED 0) -> output
        | _ -> Alcotest.fail "identity helper failed"
      in
      let fields =
        String.trim identity_output |> String.split_on_char ' ' |> List.map int_of_string
      in
      (match !identity_pid, fields with
      | Some expected, [ process; group; session; parent ] ->
          Alcotest.(check int) "reported child PID" expected process;
          Alcotest.(check int) "owned process group" expected group;
          Alcotest.(check int) "owned session" expected session;
          Alcotest.(check int) "direct parent" (Unix.getpid ()) parent;
          all_pids := expected :: !all_pids
      | _ -> Alcotest.fail "identity output invalid");
      let orphan_pids = Filename.concat root "orphan.pids" in
      let orphan =
        advanced ~program:"/usr/bin/python3"
          ~arguments:[| "/usr/bin/python3"; helper; orphan_pids; "orphan" |]
          ~maximum:1024 ~timeout:1. ()
      in
      (match orphan with
      | Ok (_, Unix.WEXITED 0) -> ()
      | _ -> Alcotest.fail "normal descendant cleanup failed");
      record orphan_pids
      |> List.iter (fun pid ->
             Alcotest.(check bool) "normal descendant residue" true
               (await_process_exit pid));
      let nonzero_pid = ref None in
      let nonzero =
        advanced ~program:"/bin/false" ~arguments:[| "/bin/false" |]
          ~maximum:128 ~timeout:1.
          ~after_spawn:(fun pid -> nonzero_pid := Some pid) ()
      in
      (match nonzero with
      | Ok (_, Unix.WEXITED 1) -> ()
      | _ -> Alcotest.fail "nonzero status was not retained");
      Option.iter (fun pid -> all_pids := pid :: !all_pids) !nonzero_pid;
      List.iter
        (fun pid ->
          Alcotest.(check bool) "final process residue" true (await_process_exit pid))
        !all_pids))

let () =
  Alcotest.run "Phase 5 Git synchronization"
    [ ("sync", [ Alcotest.test_case "shallow deterministic convergence" `Quick core_convergence;
                 Alcotest.test_case "distinct pushurl uses fetch URL" `Quick
                   distinct_pushurl_does_not_affect_sync;
                 Alcotest.test_case "mass deletion safeguards" `Quick mass_deletion;
                 Alcotest.test_case "task state metadata-only" `Quick task_metadata_only;
                 Alcotest.test_case "advisory lock" `Quick advisory_lock;
                 Alcotest.test_case "barrier-synchronized concurrent sync" `Quick
                   concurrent_sync_acceptance;
                 Alcotest.test_case "source identity preflight" `Quick source_preflight;
                 Alcotest.test_case "fetched source identity" `Quick fetched_repository_identity;
                 Alcotest.test_case "Amp authenticated sanitized fetch" `Quick
                   amp_authenticated_git;
                 Alcotest.test_case "fetch disables submodule recursion" `Quick
                   fetch_does_not_recurse_submodules;
                 Alcotest.test_case "retrieval vertical slice" `Quick
                   retrieval_vertical_slice;
                 Alcotest.test_case "retrieval database degradation" `Quick
                   retrieval_database_failure;
                 Alcotest.test_case "retrieval pins UTF8 client encoding" `Quick
                   retrieval_utf8_client_encoding;
                 Alcotest.test_case "retrieval COMMIT finalization boundary" `Quick
                   retrieval_commit_finalization;
                 Alcotest.test_case "replacement objects disabled" `Quick replacement_objects_disabled;
                 Alcotest.test_case "reserved Git documents" `Quick reserved_validation;
                 Alcotest.test_case "integer JSON canonicalization" `Quick
                   integer_json_canonicalization;
                 Alcotest.test_case "exact numeric contract" `Quick numeric_contract;
                 Alcotest.test_case "diagnostic overflow" `Quick diagnostic_overflow;
                 Alcotest.test_case "production adapter diagnostics" `Quick
                   production_adapter_diagnostics;
                 Alcotest.test_case "non-Markdown tree paths" `Quick non_markdown_paths;
                 Alcotest.test_case "successful warning policy" `Quick warning_policy;
                 Alcotest.test_case "object format and root parser" `Quick
                   object_format_and_root_parser;
                 Alcotest.test_case "knowledge root kind" `Quick knowledge_root_validation;
                 Alcotest.test_case "HNSW selective candidate fill" `Quick
                   retrieval_hnsw_candidates;
                 Alcotest.test_case "Git process-group cleanup" `Quick process_group_cleanup ]) ]
