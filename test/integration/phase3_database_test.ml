let source_root = if Sys.file_exists "db/migrations" then "." else "../.."

let check_ok name = function
  | Ok value -> value
  | Error (error : Clamp.Database.error) ->
      Alcotest.failf "%s: %s (%s)" name error.message error.code

let target = lazy (check_ok "local target" (Clamp.Database.discover_local_target ()))
let current_user = (Unix.getpwuid (Unix.geteuid ())).pw_name
let database_counter = ref 0

let fresh_database_name label =
  incr database_counter;
  let label = String.map (function 'a' .. 'z' as character -> character | _ -> '_') label in
  Printf.sprintf "clamp_p3_%s_%d_%d" label (Unix.getpid ()) !database_counter

let quote_identifier value =
  "\"" ^ String.concat "\"\"" (String.split_on_char '\"' value) ^ "\""

let connection database =
  let target = Lazy.force target in
  new Postgresql.connection ~host:target.socket_dir
    ~port:(string_of_int target.port) ~dbname:database ~user:current_user ()

let command (connection : Postgresql.connection) sql =
  ignore (connection#exec ~expect:[ Postgresql.Command_ok ] sql)

let postgres_psql database sql =
  let target = Lazy.force target in
  let arguments =
    [| "/usr/bin/sudo"; "-u"; "postgres"; "/usr/bin/env"; "-i";
       "HOME=/var/lib/postgresql"; "USER=postgres"; "LOGNAME=postgres";
       "PATH=/usr/bin:/bin"; "PSQLRC=/dev/null"; "/usr/bin/psql";
       "--no-psqlrc"; "--quiet";
       "--set=ON_ERROR_STOP=1"; "--host"; target.socket_dir; "--port";
       string_of_int target.port; "--username"; "postgres"; "--dbname";
       database; "--command"; sql |]
  in
  match Unix.create_process arguments.(0) arguments Unix.stdin Unix.stdout Unix.stderr
        |> Unix.waitpid [] |> snd with
  | Unix.WEXITED 0 -> ()
  | _ -> Alcotest.fail "local PostgreSQL administrator command failed"

let with_database label operation =
  let database = fresh_database_name label in
  let admin = connection "postgres" in
  command admin ("CREATE DATABASE " ^ quote_identifier database);
  admin#finish;
  postgres_psql database "CREATE EXTENSION vector";
  Fun.protect
    ~finally:(fun () ->
      let admin = connection "postgres" in
      (try command admin
             ("DROP DATABASE IF EXISTS " ^ quote_identifier database ^ " WITH (FORCE)")
       with _ -> ());
      admin#finish)
    (fun () -> operation database)

let with_tcp_database label operation =
  let database = fresh_database_name label in
  let role = database ^ "_role" in
  let password = "clamp-disposable-phase3-password" in
  postgres_psql "postgres"
    ("CREATE ROLE " ^ quote_identifier role ^ " LOGIN PASSWORD '" ^ password ^ "'");
  Fun.protect
    ~finally:(fun () ->
      postgres_psql "postgres"
        ("DROP DATABASE IF EXISTS " ^ quote_identifier database ^ " WITH (FORCE)");
      postgres_psql "postgres" ("DROP ROLE IF EXISTS " ^ quote_identifier role))
    (fun () ->
      postgres_psql "postgres"
        ("CREATE DATABASE " ^ quote_identifier database ^ " OWNER " ^ quote_identifier role);
      postgres_psql database "CREATE EXTENSION vector WITH SCHEMA public";
      operation database role password)

let rec write_all descriptor bytes offset length =
  if length > 0 then
    match Unix.write descriptor bytes offset length with
    | 0 -> raise End_of_file
    | written -> write_all descriptor bytes (offset + written) (length - written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        write_all descriptor bytes offset length

let relay left right =
  let buffer = Bytes.create 16384 in
  let rec loop () =
    let readable, _, _ = Unix.select [ left; right ] [] [] 5. in
    let forward source destination =
      match Unix.read source buffer 0 (Bytes.length buffer) with
      | 0 -> false
      | count -> write_all destination buffer 0 count; true
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> true
    in
    if readable = [] then loop ()
    else if List.for_all (fun source ->
        if source = left then forward left right else forward right left) readable
    then loop ()
  in
  loop ()

let with_delayed_tcp_proxy ~delay operation =
  let target = Lazy.force target in
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 16;
  let port = match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
      Unix.close ready_read;
      ignore (Unix.setsid ());
      Sys.set_signal Sys.sigchld Sys.Signal_ignore;
      ignore (Unix.write_substring ready_write "1" 0 1);
      Unix.close ready_write;
      let rec accept () =
        let client, _ = Unix.accept listener in
        (match Unix.fork () with
        | 0 ->
            Unix.close listener;
            (try
               Unix.sleepf delay;
               let upstream = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
               Fun.protect ~finally:(fun () -> Unix.close upstream) (fun () ->
                   Unix.connect upstream
                     (Unix.ADDR_INET (Unix.inet_addr_loopback, target.port));
                   relay client upstream)
             with _ -> ());
            Unix.close client;
            Unix._exit 0
        | _ -> Unix.close client);
        accept ()
      in
      (try accept () with _ -> ());
      Unix._exit 0
  | process ->
      Unix.close listener;
      Unix.close ready_write;
      let ready = Bytes.create 1 in
      ignore (Unix.read ready_read ready 0 1);
      Unix.close ready_read;
      Fun.protect
        ~finally:(fun () ->
          (try Unix.kill (-process) Sys.sigkill with _ -> ());
          try ignore (Unix.waitpid [] process) with _ -> ())
        (fun () -> operation port)

let copy source destination =
  let input = open_in_bin source and output = open_out_bin destination in
  Fun.protect ~finally:(fun () -> close_in_noerr input; close_out_noerr output)
    (fun () -> really_input_string input (in_channel_length input) |> output_string output)

let with_migration_copy operation =
  let root = Filename.temp_file "clamp-phase3-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let db = Filename.concat root "db" and migrations = Filename.concat root "db/migrations" in
  Unix.mkdir db 0o700;
  Unix.mkdir migrations 0o700;
  List.iter
    (fun name ->
      copy (Filename.concat source_root (Filename.concat "db/migrations" name))
        (Filename.concat migrations name))
    [ "0001_enable_vector.sql"; "0002_application_schema.sql" ];
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir migrations
      |> Array.iter (fun name ->
          let path = Filename.concat migrations name in
          if (Unix.lstat path).st_kind = Unix.S_DIR then Unix.rmdir path
          else Sys.remove path);
      Unix.rmdir migrations;
      Unix.rmdir db;
      Unix.rmdir root)
    (fun () -> operation root migrations)

let write path contents =
  let output = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents)

let add_suffix migrations =
  write (Filename.concat migrations "0003_test_suffix.sql")
    "CREATE TABLE public.phase3_suffix_marker (id pg_catalog.int4 PRIMARY KEY);\n"

let add_delayed_suffix migrations =
  write (Filename.concat migrations "0003_test_suffix.sql")
    "SELECT pg_catalog.pg_sleep(1);\nCREATE TABLE public.phase3_suffix_marker (id pg_catalog.int4 PRIMARY KEY);\n"

let checksum_0001 = "b669a28b01e6f0a7336b2df63b3b743596a01ecbd42df4e493590fef91549ced"
let checksum_0002 = "25995952d657af87b44ec9c8022a18c554e2b61669c681268b134c13325c807f"

let create_legacy_ledger connection rows =
  command connection
    "CREATE TABLE clamp_schema_migrations (version TEXT PRIMARY KEY, checksum CHAR(64) NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())";
  List.iteri (fun index (version, checksum) ->
      let sql = Printf.sprintf
          "INSERT INTO clamp_schema_migrations(version,checksum,applied_at) VALUES ('%s','%s',TIMESTAMPTZ '2026-01-01 00:00:00+00' + INTERVAL '%d second')"
          version checksum index in
      command connection sql) rows

let convert_current_to_legacy connection =
  command connection
    "DO $$ DECLARE item record; BEGIN FOR item IN SELECT conname FROM pg_constraint WHERE conrelid='clamp_schema_migrations'::regclass LOOP EXECUTE format('ALTER TABLE clamp_schema_migrations DROP CONSTRAINT %I', item.conname); END LOOP; END $$";
  command connection "ALTER TABLE clamp_schema_migrations DROP COLUMN position";
  command connection "ALTER TABLE clamp_schema_migrations ADD PRIMARY KEY(version)"

let check_report ?expected_already name expected_applied report =
  let (report : Clamp.Database.migration_report) = check_ok name report in
  Alcotest.(check (list string)) name expected_applied report.applied;
  Option.iter
    (fun expected ->
      Alcotest.(check (list string)) (name ^ " existing order") expected
        report.already_applied)
    expected_already

let check_error name expected = function
  | Ok _ -> Alcotest.failf "%s: expected %s" name expected
  | Error (error : Clamp.Database.error) ->
      Alcotest.(check string) name expected error.code

let table_exists (connection : Postgresql.connection) table =
  let result = connection#exec ~expect:[ Postgresql.Tuples_ok ]
      ~params:[| table |] "SELECT to_regclass($1) IS NOT NULL" in
  result#getvalue 0 0 = "t"

let ledger_rows (connection : Postgresql.connection) =
  let result = connection#exec ~expect:[ Postgresql.Tuples_ok ]
      "SELECT position, version, checksum FROM clamp_schema_migrations ORDER BY position" in
  List.init result#ntuples (fun row ->
      (int_of_string (result#getvalue row 0), result#getvalue row 1,
       result#getvalue row 2))

let expect_rejected (connection : Postgresql.connection) name sql =
  try
    ignore (connection#exec ~expect:[ Postgresql.Command_ok ] sql);
    Alcotest.failf "%s was accepted" name
  with Postgresql.Error (Postgresql.Unexpected_status _) -> ()

let vector = "array_fill(0::real, ARRAY[1536])::vector"

let concept_values ?(path = "facts/base") ?(status = "stable")
    ?(tier = "unverified") ?task_state ?task_priority ?due_on ?due_at () =
  let nullable = function None -> "NULL" | Some value -> "'" ^ value ^ "'" in
  Printf.sprintf
    "('%s','blob','input','fact','body','{}'::jsonb,'%s','%s',%s,%s,%s,%s,'model',%s)"
    path status tier (nullable task_state) (nullable task_priority)
    (nullable due_on) (nullable due_at) vector

let insert_sql values =
  "INSERT INTO concepts(path,blob_hash,embedding_input_hash,type,body,frontmatter,status,verified_tier,task_state,task_priority,task_due_on,task_due_at,embedding_model,embedding) VALUES "
  ^ values

let constraints (connection : Postgresql.connection) =
  command connection (insert_sql (concept_values ()));
  expect_rejected connection "concept primary key" (insert_sql (concept_values ()));
  expect_rejected connection "status check"
    (insert_sql (concept_values ~path:"facts/status" ~status:"invalid" ()));
  expect_rejected connection "verification tier check"
    (insert_sql (concept_values ~path:"facts/tier" ~tier:"invalid" ()));
  expect_rejected connection "task state check"
    (insert_sql (concept_values ~path:"tasks/state" ~task_state:"invalid" ()));
  expect_rejected connection "task priority check"
    (insert_sql (concept_values ~path:"tasks/priority" ~task_priority:"invalid" ()));
  expect_rejected connection "due date exclusivity"
    (insert_sql
       (concept_values ~path:"tasks/due" ~due_on:"2026-08-18"
          ~due_at:"2026-08-18T10:00:00Z" ()));
  expect_rejected connection "vector dimensions"
    "INSERT INTO concepts(path,blob_hash,embedding_input_hash,type,body,frontmatter,verified_tier,embedding_model,embedding) VALUES ('facts/vector','b','i','fact','body','{}','unverified','model','[0,0]'::vector)";
  expect_rejected connection "access foreign key"
    "INSERT INTO access_stats(concept_path) VALUES ('facts/missing')";
  expect_rejected connection "nonnegative access count"
    "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/base',-1)";
  command connection
    "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/base',2)";
  expect_rejected connection "access stats primary key"
    "INSERT INTO access_stats(concept_path,access_count) VALUES ('facts/base',3)";
  command connection "DELETE FROM concepts WHERE path='facts/base'";
  let count = connection#exec ~expect:[ Postgresql.Tuples_ok ]
      "SELECT count(*) FROM access_stats WHERE concept_path='facts/base'" in
  Alcotest.(check string) "access stats cascade" "0" (count#getvalue 0 0);
  command connection
    "INSERT INTO index_state(source_repository,embedding_model,embedding_dimensions) VALUES ('repo','model',1536)";
  expect_rejected connection "index state primary key"
    "INSERT INTO index_state(source_repository,embedding_model,embedding_dimensions) VALUES ('other','model',1536)";
  expect_rejected connection "singleton index state"
    "INSERT INTO index_state(id,source_repository,embedding_model,embedding_dimensions) VALUES (2,'repo','model',1536)";
  let index = connection#exec ~expect:[ Postgresql.Tuples_ok ]
      "SELECT indexdef FROM pg_indexes WHERE schemaname=current_schema() AND indexname='concepts_embedding_hnsw_idx'" in
  Alcotest.(check int) "HNSW index exists" 1 index#ntuples;
  Alcotest.(check bool) "HNSW cosine ops" true
    (String.starts_with
       ~prefix:"CREATE INDEX concepts_embedding_hnsw_idx ON public.concepts USING hnsw (embedding vector_cosine_ops)"
       (index#getvalue 0 0))

let migration_and_schema () =
  with_database "schema" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "fresh migration"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local_from ~migrations_dir:migrations ~database);
          check_report
            ~expected_already:[ "0001_enable_vector"; "0002_application_schema" ]
            "idempotent rerun" []
            (Clamp.Database.migrate_local_from ~migrations_dir:migrations ~database);
          let connection = connection database in
          constraints connection;
          Alcotest.(check int) "ledger rows" 2 (List.length (ledger_rows connection));
          connection#finish;
          let migration = Filename.concat migrations "0002_application_schema.sql" in
          let output = open_out_gen [ Open_append; Open_binary ] 0o600 migration in
          output_string output "\n-- checksum drift\n";
          close_out output;
          check_error "checksum rejection" "migration_checksum_mismatch"
            (Clamp.Database.migrate_local_from ~migrations_dir:migrations ~database)))

let trusted_0001_rejection () =
  with_database "untrusted" (fun database ->
      with_migration_copy (fun root migrations ->
          let migration = Filename.concat migrations "0001_enable_vector.sql" in
          let output = open_out_gen [ Open_append; Open_binary ] 0o600 migration in
          output_string output "\nCREATE TABLE privileged_side_effect(id integer);\n";
          close_out output;
          check_error "untrusted 0001" "migration_0001_untrusted"
            (Clamp.Database.migrate_local ~repo:root
               ~database:"clamp_p3_untrusted_database_must_not_connect");
          let db_connection = connection database in
          Alcotest.(check bool) "side effect absent" false
            (table_exists db_connection "privileged_side_effect");
          Alcotest.(check bool) "ledger absent" false
            (table_exists db_connection "clamp_schema_migrations");
          db_connection#finish))

let trusted_0001_input_failures () =
  let check_case label mutate =
    with_migration_copy (fun root migrations ->
        let path = Filename.concat migrations "0001_enable_vector.sql" in
        mutate path;
        check_error label "migration_0001_untrusted"
          (Clamp.Database.migrate_local ~repo:root
             ~database:"clamp_p3_trust_input_must_not_connect"))
  in
  check_case "missing trusted 0001" Sys.remove;
  check_case "directory trusted 0001" (fun path -> Sys.remove path; Unix.mkdir path 0o700);
  check_case "fifo trusted 0001" (fun path -> Sys.remove path; Unix.mkfifo path 0o600);
  check_case "symlink trusted 0001" (fun path ->
      let target = path ^ ".target" in
      Sys.rename path target;
      Unix.symlink target path);
  check_case "unreadable trusted 0001" (fun path -> Unix.chmod path 0o000);
  check_case "writable trusted 0001" (fun path -> Unix.chmod path 0o666);
  check_case "oversized trusted 0001" (fun path ->
      Unix.LargeFile.truncate path (Int64.of_int (8 * 1024 * 1024 + 1)))

let hostile_vector_extension () =
  with_database "vector_wrong_schema" (fun database ->
      postgres_psql database
        "DROP EXTENSION vector; CREATE SCHEMA evil; CREATE EXTENSION vector WITH SCHEMA evil";
      with_migration_copy (fun root _ ->
          check_error "wrong extension schema" "vector_extension_invalid"
            (Clamp.Database.migrate_local ~repo:root ~database);
          let database = connection database in
          Alcotest.(check bool) "application schema absent" false
            (table_exists database "concepts");
          Alcotest.(check bool) "ledger rollback" false
            (table_exists database "clamp_schema_migrations");
          database#finish));
  with_database "vector_detached" (fun database ->
      postgres_psql database
        "ALTER EXTENSION vector DROP TYPE public.vector";
      with_migration_copy (fun root _ ->
          check_error "detached vector type" "vector_extension_invalid"
            (Clamp.Database.migrate_local ~repo:root ~database);
          let database = connection database in
          Alcotest.(check bool) "detached application schema absent" false
            (table_exists database "concepts");
          Alcotest.(check bool) "detached ledger rollback" false
            (table_exists database "clamp_schema_migrations");
          database#finish))

let remote_dns_failover () =
  with_tcp_database "dns_failover" (fun database role password ->
      with_migration_copy (fun root _ ->
          let url = Printf.sprintf
              "postgresql://%s:%s@does-not-exist.invalid:5432,127.0.0.1:5432/%s?sslmode=require&channel_binding=require"
              role password database in
          check_report "DNS failure falls through to healthy host"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_remote ~repo:root ~url)))

let remote_network_route_failover () =
  with_tcp_database "route_failover" (fun database role password ->
      with_migration_copy (fun root _ ->
          let url = Printf.sprintf
              "postgresql://%s:%s@[2001:db8::1]:5432,127.0.0.1:5432/%s?sslmode=require&channel_binding=require"
              role password database in
          check_report "unreachable IPv6 falls through to healthy IPv4"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_remote ~repo:root ~url)))

let remote_staggered_connection_race () =
  with_tcp_database "connection_race" (fun database role password ->
      with_migration_copy (fun root _ ->
          with_delayed_tcp_proxy ~delay:0.9 (fun port ->
              let hosts =
                List.init 6 (fun _ -> Printf.sprintf "127.0.0.1:%d" port)
                |> String.concat "," in
              let authority = role ^ ":" ^ password ^ "@" ^ hosts in
              let url =
                "postgresql:" ^ "//" ^ authority ^ "/" ^ database
                ^ "?sslmode=require&channel_binding=require" in
              check_report "slow preferred connection wins staggered race"
                [ "0001_enable_vector"; "0002_application_schema" ]
                (Clamp.Database.migrate_remote ~repo:root ~url))))

let legacy_upgrade () =
  with_database "legacy_one" (fun database ->
      with_migration_copy (fun root migrations ->
          add_suffix migrations;
          let db_connection = connection database in
          create_legacy_ledger db_connection [ "0001_enable_vector", checksum_0001 ];
          db_connection#finish;
          check_report ~expected_already:[ "0001_enable_vector" ]
            "legacy 0001 suffix"
            [ "0002_application_schema"; "0003_test_suffix" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          check_report
            ~expected_already:[ "0001_enable_vector"; "0002_application_schema";
                                "0003_test_suffix" ]
            "legacy 0001 idempotent" []
            (Clamp.Database.migrate_local ~repo:root ~database)));
  with_database "legacy_full" (fun database ->
      with_migration_copy (fun root _ ->
          check_report "seed current" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          let db_connection = connection database in
          convert_current_to_legacy db_connection;
          db_connection#finish;
          check_report
            ~expected_already:[ "0001_enable_vector"; "0002_application_schema" ]
            "legacy full" [] (Clamp.Database.migrate_local ~repo:root ~database);
          let upgraded = connection database in
          Alcotest.(check int) "upgraded positions" 2
            (List.length (ledger_rows upgraded));
          upgraded#finish))

let invalid_legacy_ledgers () =
  let check_case label create expected =
    with_database label (fun database ->
        with_migration_copy (fun root migrations ->
            add_suffix migrations;
            let db_connection = connection database in
            create db_connection;
            db_connection#finish;
            check_error label expected
              (Clamp.Database.migrate_local ~repo:root ~database);
            let after = connection database in
            Alcotest.(check bool) (label ^ " no suffix") false
              (table_exists after "phase3_suffix_marker");
            Alcotest.(check bool) (label ^ " no position") false
              ((after#exec ~expect:[ Postgresql.Tuples_ok ]
                  "SELECT EXISTS (SELECT FROM pg_attribute WHERE attrelid='clamp_schema_migrations'::regclass AND attname='position' AND NOT attisdropped)")#getvalue 0 0 = "t");
            after#finish))
  in
  check_case "legacy malformed" (fun connection ->
      command connection
        "CREATE TABLE clamp_schema_migrations(version TEXT, checksum CHAR(64) NOT NULL, applied_at TIMESTAMPTZ NOT NULL)";
      command connection
        (Printf.sprintf "INSERT INTO clamp_schema_migrations VALUES ('0001_enable_vector','%s',now()),('0001_enable_vector','%s',now())" checksum_0001 checksum_0001))
    "migration_ledger_invalid";
  check_case "legacy missing column" (fun connection ->
      command connection
        "CREATE TABLE clamp_schema_migrations(version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL)")
    "migration_ledger_invalid";
  check_case "legacy rogue" (fun connection ->
      create_legacy_ledger connection [ "rogue", checksum_0001 ])
    "migration_history_mismatch";
  check_case "legacy reordered" (fun connection ->
      create_legacy_ledger connection
        [ "0002_application_schema", checksum_0002;
          "0001_enable_vector", checksum_0001 ])
    "migration_history_mismatch";
  check_case "legacy drift" (fun connection ->
      create_legacy_ledger connection
        [ "0001_enable_vector", String.make 64 '0' ])
    "migration_checksum_mismatch";
  check_case "legacy extra index" (fun connection ->
      create_legacy_ledger connection [ "0001_enable_vector", checksum_0001 ];
      command connection
        "CREATE INDEX clamp_schema_migrations_checksum_extra ON clamp_schema_migrations(checksum)")
    "migration_ledger_invalid";
  check_case "legacy trigger" (fun connection ->
      create_legacy_ledger connection [ "0001_enable_vector", checksum_0001 ];
      command connection
        "CREATE FUNCTION legacy_ledger_trigger() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$";
      command connection
        "CREATE TRIGGER legacy_ledger_extra BEFORE INSERT ON clamp_schema_migrations FOR EACH ROW EXECUTE FUNCTION legacy_ledger_trigger()")
    "migration_ledger_invalid";
  check_case "legacy default" (fun connection ->
      create_legacy_ledger connection [ "0001_enable_vector", checksum_0001 ];
      command connection
        "ALTER TABLE clamp_schema_migrations ALTER COLUMN applied_at SET DEFAULT clock_timestamp()")
    "migration_ledger_invalid"

let concurrent_legacy_upgrade () =
  with_database "legacy_concurrent" (fun database ->
      with_migration_copy (fun root _ ->
          check_report "seed" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          let db_connection = connection database in
          convert_current_to_legacy db_connection;
          db_connection#finish;
          let read_end, write_end = Unix.pipe () in
          let child () =
            Unix.close write_end;
            let byte = Bytes.create 1 in
            ignore (Unix.read read_end byte 0 1);
            exit (match Clamp.Database.migrate_local ~repo:root ~database with Ok _ -> 0 | Error _ -> 1)
          in
          let first = match Unix.fork () with 0 -> child () | pid -> pid in
          let second = match Unix.fork () with 0 -> child () | pid -> pid in
          Unix.close read_end;
          ignore (Unix.write_substring write_end "go" 0 2);
          Unix.close write_end;
          List.iter (fun pid -> match snd (Unix.waitpid [] pid) with
              | Unix.WEXITED 0 -> () | _ -> Alcotest.fail "concurrent legacy upgrade failed")
            [ first; second ];
          let upgraded = connection database in
          Alcotest.(check int) "concurrent exact ledger" 2
            (List.length (ledger_rows upgraded));
          upgraded#finish))

let noncooperating_relation_lock () =
  with_database "relation_lock" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "lock seed" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          add_delayed_suffix migrations;
          let child = match Unix.fork () with
            | 0 -> exit (match Clamp.Database.migrate_local ~repo:root ~database with
                | Ok _ -> 0 | Error _ -> 1)
            | pid -> pid
          in
          let observer = connection database in
          let rec await_lock attempts =
            if attempts = 0 then Alcotest.fail "migration never acquired ledger relation lock"
            else
              let result = observer#exec ~expect:[ Postgresql.Tuples_ok ]
                  "SELECT EXISTS (SELECT FROM pg_catalog.pg_locks WHERE relation='public.clamp_schema_migrations'::pg_catalog.regclass AND mode='AccessExclusiveLock' AND granted AND pid<>pg_catalog.pg_backend_pid())" in
              if result#getvalue 0 0 <> "t" then begin Unix.sleepf 0.02; await_lock (attempts - 1) end
          in
          await_lock 100;
          let attacker = connection database in
          command attacker "SET statement_timeout='100ms'";
          let blocked =
            try
              command attacker
                "UPDATE public.clamp_schema_migrations SET checksum=repeat('0',64) WHERE position=1";
              false
            with Postgresql.Error _ -> true
          in
          Alcotest.(check bool) "non-cooperating update blocked" true blocked;
          attacker#finish;
          observer#finish;
          (match snd (Unix.waitpid [] child) with
           | Unix.WEXITED 0 -> ()
           | _ -> Alcotest.fail "locked migration failed");
          let after = connection database in
          Alcotest.(check bool) "suffix committed with ledger lock" true
            (table_exists after "public.phase3_suffix_marker");
          Alcotest.(check (list string)) "ledger exact after blocked attacker"
            [ "0001_enable_vector"; "0002_application_schema"; "0003_test_suffix" ]
            (List.map (fun (_, version, _) -> version) (ledger_rows after));
          after#finish))

let await_expected_failure expected root database =
  match Unix.fork () with
  | 0 ->
      exit (match Clamp.Database.migrate_local ~repo:root ~database with
          | Error (error : Clamp.Database.error) when error.code = expected -> 0
          | Error (error : Clamp.Database.error) ->
              prerr_endline ("unexpected child error code: " ^ error.code); 1
          | Ok _ -> prerr_endline "unexpected child migration success"; 1)
  | pid ->
      Unix.sleepf 0.1;
      pid

let wait_expected_failure label pid =
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | _ -> Alcotest.fail (label ^ " did not return its stable expected error")

let noncooperating_prevalidation_races () =
  with_database "current_race" (fun database ->
      with_migration_copy (fun root _ ->
          check_report "current race seed"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          let attacker = connection database in
          command attacker "BEGIN";
          command attacker
            "LOCK TABLE public.clamp_schema_migrations IN ACCESS EXCLUSIVE MODE";
          command attacker
            "UPDATE public.clamp_schema_migrations SET checksum=repeat('0',64) WHERE position=1";
          let child = await_expected_failure "migration_checksum_mismatch" root database in
          command attacker "COMMIT";
          attacker#finish;
          wait_expected_failure "current row race" child));
  with_database "legacy_race" (fun database ->
      with_migration_copy (fun root _ ->
          let attacker = connection database in
          create_legacy_ledger attacker [ "0001_enable_vector", checksum_0001 ];
          command attacker "BEGIN";
          command attacker
            "LOCK TABLE public.clamp_schema_migrations IN ACCESS EXCLUSIVE MODE";
          command attacker
            "UPDATE public.clamp_schema_migrations SET checksum=repeat('0',64)";
          let child = await_expected_failure "migration_checksum_mismatch" root database in
          command attacker "COMMIT";
          attacker#finish;
          wait_expected_failure "legacy row race" child;
          let after = connection database in
          Alcotest.(check bool) "legacy suffix not applied" false
            (table_exists after "public.concepts");
          after#finish));
  with_database "replace_race" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "replace race seed"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          add_suffix migrations;
          let attacker = connection database in
          command attacker "BEGIN";
          command attacker
            "LOCK TABLE public.clamp_schema_migrations IN ACCESS EXCLUSIVE MODE";
          command attacker "DROP TABLE public.clamp_schema_migrations";
          command attacker
            "CREATE TABLE public.clamp_schema_migrations(rogue pg_catalog.text)";
          let child = await_expected_failure "migration_ledger_invalid" root database in
          command attacker "COMMIT";
          attacker#finish;
          wait_expected_failure "replacement race" child;
          let after = connection database in
          Alcotest.(check bool) "replacement suffix not applied" false
            (table_exists after "public.phase3_suffix_marker");
          after#finish));
  with_database "absent_race" (fun database ->
      with_migration_copy (fun root migrations ->
          add_suffix migrations;
          let attacker = connection database in
          command attacker "BEGIN";
          command attacker
            "CREATE TABLE public.clamp_schema_migrations(position pg_catalog.int4 PRIMARY KEY CHECK(position>0),version pg_catalog.text NOT NULL UNIQUE,checksum pg_catalog.bpchar(64) NOT NULL,applied_at pg_catalog.timestamptz NOT NULL DEFAULT pg_catalog.now())";
          command attacker
            "INSERT INTO public.clamp_schema_migrations VALUES (1,'rogue',repeat('0',64),pg_catalog.now())";
          let child = await_expected_failure "migration_history_mismatch" root database in
          command attacker "COMMIT";
          attacker#finish;
          wait_expected_failure "absent creation race" child;
          let after = connection database in
          Alcotest.(check bool) "fresh race migration not applied" false
            (table_exists after "public.concepts");
          Alcotest.(check bool) "fresh race suffix not applied" false
            (table_exists after "public.phase3_suffix_marker");
          after#finish))

let hostile_search_path () =
  with_database "search_path" (fun database ->
      with_migration_copy (fun root _ ->
          let db_connection = connection database in
          command db_connection "CREATE SCHEMA evil";
          command db_connection
            "CREATE TABLE evil.clamp_schema_migrations(marker pg_catalog.text)";
          command db_connection
            "INSERT INTO evil.clamp_schema_migrations VALUES ('untouched')";
          command db_connection
            "CREATE TABLE evil.concepts(marker pg_catalog.text)";
          command db_connection "INSERT INTO evil.concepts VALUES ('untouched')";
          command db_connection
            "CREATE FUNCTION evil.now() RETURNS pg_catalog.timestamptz LANGUAGE sql IMMUTABLE AS $$ SELECT '-infinity'::pg_catalog.timestamptz $$";
          command db_connection
            "CREATE FUNCTION evil.format_type(pg_catalog.oid,pg_catalog.int4) RETURNS pg_catalog.text LANGUAGE sql IMMUTABLE AS $$ SELECT 'evil'::pg_catalog.text $$";
          command db_connection
            ("ALTER DATABASE " ^ quote_identifier database
             ^ " SET search_path=evil,pg_catalog,public");
          db_connection#finish;
          check_report "hostile database search_path"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          let after = connection database in
          let evil = after#exec ~expect:[ Postgresql.Tuples_ok ]
              "SELECT marker FROM evil.clamp_schema_migrations" in
          Alcotest.(check string) "evil ledger untouched" "untouched"
            (evil#getvalue 0 0);
          let evil_concepts = after#exec ~expect:[ Postgresql.Tuples_ok ]
              "SELECT marker FROM evil.concepts" in
          Alcotest.(check string) "evil concepts untouched" "untouched"
            (evil_concepts#getvalue 0 0);
          Alcotest.(check bool) "public ledger created" true
            (table_exists after "public.clamp_schema_migrations");
          Alcotest.(check bool) "public schema created" true
            (table_exists after "public.concepts");
          after#finish))

let hostile_environment_is_ignored () =
  with_database "target" (fun database ->
      with_database "hostile" (fun hostile_database ->
          with_migration_copy (fun root _ ->
              let service_file = Filename.temp_file "clamp-hostile-" ".conf" in
              write service_file
                (Printf.sprintf "[hostile]\nhost=127.0.0.1\nport=%d\ndbname=%s\n"
                   (Lazy.force target).port hostile_database);
              let variables =
                [ ("PGHOST", "127.0.0.1");
                  ("PGHOSTADDR", "127.0.0.1");
                  ("PGPORT", string_of_int (Lazy.force target).port);
                  ("PGDATABASE", hostile_database); ("PGSERVICE", "hostile");
                  ("PGSERVICEFILE", service_file); ("PGUSER", current_user) ]
              in
              let saved = List.map (fun (name, _) -> (name, Sys.getenv_opt name)) variables in
              Fun.protect
                ~finally:(fun () ->
                  List.iter (fun (name, value) ->
                      match value with Some value -> Unix.putenv name value
                      | None -> Unix.unsetenv name) saved;
                  Sys.remove service_file)
                (fun () ->
                  List.iter (fun (name, value) -> Unix.putenv name value) variables;
                  check_report "reachable hostile environment ignored"
                    [ "0001_enable_vector"; "0002_application_schema" ]
                    (Clamp.Database.migrate_local ~repo:root ~database);
                  Unix.putenv "PGHOST" "203.0.113.1";
                  Unix.putenv "PGHOSTADDR" "203.0.113.1";
                  Unix.putenv "PGPORT" "1";
                  Unix.putenv "PGSERVICEFILE" "/nonexistent/hostile-service";
                  check_report "unreachable hostile environment ignored" []
                    (Clamp.Database.migrate_local ~repo:root ~database));
              let intended = connection database and hostile = connection hostile_database in
              let evidence = intended#exec ~expect:[ Postgresql.Tuples_ok ]
                  "SELECT inet_server_addr() IS NULL, current_setting('server_version_num')::int / 10000, current_setting('port')" in
              Alcotest.(check string) "Unix socket" "t" (evidence#getvalue 0 0);
              Alcotest.(check string) "PostgreSQL 15" "15" (evidence#getvalue 0 1);
              Alcotest.(check string) "configured port"
                (string_of_int (Lazy.force target).port) (evidence#getvalue 0 2);
              Alcotest.(check bool) "intended schema" true
                (table_exists intended "clamp_schema_migrations");
              Alcotest.(check bool) "hostile target untouched" false
                (table_exists hostile "clamp_schema_migrations");
              intended#finish;
              hostile#finish)))

let concurrent_first_migration () =
  with_database "concurrent" (fun database ->
      with_migration_copy (fun root _ ->
          let ready_read, ready_write = Unix.pipe () in
          let start_read, start_write = Unix.pipe () in
          let child () =
            Unix.close ready_read;
            Unix.close start_write;
            ignore (Unix.write_substring ready_write "r" 0 1);
            let byte = Bytes.create 1 in
            ignore (Unix.read start_read byte 0 1);
            let status =
              match Clamp.Database.migrate_local ~repo:root ~database with
              | Ok _ -> 0
              | Error _ -> 1
            in
            exit status
          in
          let first = match Unix.fork () with 0 -> child () | pid -> pid in
          let second = match Unix.fork () with 0 -> child () | pid -> pid in
          Unix.close ready_write;
          Unix.close start_read;
          let ready = Bytes.create 2 in
          let rec await offset =
            if offset < 2 then await (offset + Unix.read ready_read ready offset (2 - offset))
          in
          await 0;
          ignore (Unix.write_substring start_write "go" 0 2);
          Unix.close ready_read;
          Unix.close start_write;
          let wait pid =
            match snd (Unix.waitpid [] pid) with
            | Unix.WEXITED 0 -> ()
            | _ -> Alcotest.fail "concurrent migration process failed"
          in
          wait first;
          wait second;
          let connection = connection database in
          Alcotest.(check (list string)) "exact ledger"
            [ "0001_enable_vector"; "0002_application_schema" ]
            (List.map (fun (_, version, _) -> version) (ledger_rows connection));
          Alcotest.(check bool) "schema exists once" true
            (table_exists connection "concepts");
          connection#finish))

let deleted_and_renamed_history () =
  with_database "deleted" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "initial" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          Sys.remove (Filename.concat migrations "0002_application_schema.sql");
          check_error "deleted applied migration" "migration_history_mismatch"
            (Clamp.Database.migrate_local ~repo:root ~database)));
  with_database "renamed" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "initial" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          Sys.rename (Filename.concat migrations "0002_application_schema.sql")
            (Filename.concat migrations "0002_renamed.sql");
          check_error "renamed applied migration" "migration_history_mismatch"
            (Clamp.Database.migrate_local ~repo:root ~database)))

let invalid_repository_orders () =
  let check_case label mutate =
    with_database label (fun database ->
        with_migration_copy (fun root migrations ->
            mutate migrations;
            check_error label "migration_sequence_invalid"
              (Clamp.Database.migrate_local ~repo:root ~database);
            let connection = connection database in
            Alcotest.(check bool) (label ^ " no ledger") false
              (table_exists connection "clamp_schema_migrations");
            connection#finish))
  in
  check_case "gap" (fun migrations ->
      Sys.rename (Filename.concat migrations "0002_application_schema.sql")
        (Filename.concat migrations "0003_application_schema.sql"));
  check_case "inserted earlier" (fun migrations ->
      write (Filename.concat migrations "0000_inserted.sql") "SELECT 1;\n");
  check_case "duplicate position" (fun migrations ->
      write (Filename.concat migrations "0001_duplicate.sql") "SELECT 1;\n")

let rogue_reordered_and_suffix () =
  with_database "rogue" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "initial" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          add_suffix migrations;
          let db_connection = connection database in
          command db_connection
            "INSERT INTO clamp_schema_migrations(position,version,checksum) VALUES (3,'rogue','0000000000000000000000000000000000000000000000000000000000000000')";
          let before = ledger_rows db_connection in
          db_connection#finish;
          check_error "rogue ledger row" "migration_history_mismatch"
            (Clamp.Database.migrate_local ~repo:root ~database);
          let after = connection database in
          Alcotest.(check bool) "suffix not applied" false
            (table_exists after "phase3_suffix_marker");
          Alcotest.(check int) "rogue ledger preserved" (List.length before)
            (List.length (ledger_rows after));
          after#finish));
  with_database "reordered" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "initial" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          add_suffix migrations;
          let db_connection = connection database in
          command db_connection "UPDATE clamp_schema_migrations SET version='temporary' WHERE position=1";
          command db_connection "UPDATE clamp_schema_migrations SET version='0001_enable_vector' WHERE position=2";
          command db_connection "UPDATE clamp_schema_migrations SET version='0002_application_schema' WHERE position=1";
          let before = ledger_rows db_connection in
          db_connection#finish;
          check_error "reordered history" "migration_history_mismatch"
            (Clamp.Database.migrate_local ~repo:root ~database);
          let after = connection database in
          Alcotest.(check bool) "reordered suffix not applied" false
            (table_exists after "phase3_suffix_marker");
          Alcotest.(check int) "reordered ledger preserved" (List.length before)
            (List.length (ledger_rows after));
          after#finish))

let valid_suffix () =
  with_database "suffix" (fun database ->
      with_migration_copy (fun root migrations ->
          check_report "initial" [ "0001_enable_vector"; "0002_application_schema" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          add_suffix migrations;
          check_report
            ~expected_already:[ "0001_enable_vector"; "0002_application_schema" ]
            "valid suffix" [ "0003_test_suffix" ]
            (Clamp.Database.migrate_local ~repo:root ~database);
          check_report
            ~expected_already:[ "0001_enable_vector"; "0002_application_schema";
                                "0003_test_suffix" ]
            "suffix idempotent" []
            (Clamp.Database.migrate_local ~repo:root ~database)))

let ledger_constraint_catalog_forms () =
  let module Catalog = Clamp.Database.For_tests in
  let row ?key_dimensions ?key_length ?key_lower_bound ?public_namespace
      ?validated ?enforced ?period ?deferrable ?deferred ?local
      ?inherited_count ?no_inherit ?ancillary_canonical constraint_type name
      definition key =
    Catalog.ledger_constraint_row ~constraint_type ~name ~definition ~key
      ?key_dimensions ?key_length ?key_lower_bound ?public_namespace ?validated
      ?enforced ?period ?deferrable ?deferred ?local ?inherited_count
      ?no_inherit ?ancillary_canonical ()
  in
  let current =
    [ row "p" "clamp_schema_migrations_pkey"
        "PRIMARY KEY (\"position\")" "1";
      row "u" "clamp_schema_migrations_version_key"
        "UNIQUE (version)" "2";
      row "c" "clamp_schema_migrations_position_check"
        "CHECK ((\"position\" > 0))" "1" ]
  in
  let legacy =
    [ row "p" "clamp_schema_migrations_pkey" "PRIMARY KEY (version)" "1" ]
  in
  let not_null column key =
    let definition =
      if column = "position" then "NOT NULL \"position\""
      else "NOT NULL " ^ column
    in
    row "n" ("clamp_schema_migrations_" ^ column ^ "_not_null")
      definition key
  in
  let current_not_null =
    [ not_null "position" "1"; not_null "version" "2";
      not_null "checksum" "3"; not_null "applied_at" "4" ]
  and legacy_not_null =
    [ not_null "version" "1"; not_null "checksum" "2";
      not_null "applied_at" "3" ]
  in
  let check label expected server_version_num shape rows =
    Alcotest.(check bool) label expected
      (Catalog.valid_ledger_constraints ~server_version_num shape rows)
  in
  check "PG15 current" true 150_000 `Current current;
  check "PG18 current" true 180_000 `Current (current @ current_not_null);
  check "PG15 legacy" true 150_000 `Legacy legacy;
  check "PG18 legacy" true 180_000 `Legacy (legacy @ legacy_not_null);
  check "PG18 rejects empty NOT NULL catalog" false 180_000 `Current current;
  check "PG18 rejects empty legacy NOT NULL catalog" false 180_000 `Legacy
    legacy;
  check "PG15 rejects PG18 NOT NULL catalog" false 150_000 `Current
    (current @ current_not_null);
  check "PG15 rejects PG18 legacy NOT NULL catalog" false 150_000 `Legacy
    (legacy @ legacy_not_null);
  check "partial PG18 set" false 180_000 `Current
    (current @ List.tl current_not_null);
  check "duplicate PG18 row" false 180_000 `Current
    (current @ current_not_null @ [ not_null "version" "2" ]);
  check "unexpected PG18 column" false 180_000 `Current
    (current @ current_not_null @ [ not_null "hostile" "5" ]);
  check "multi-column PG18 key" false 180_000 `Current
    (current @ [ row ~key_length:2 "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2";
                 not_null "checksum" "3"; not_null "applied_at" "4" ]);
  check "malformed PG18 array lower bound" false 180_000 `Current
    (current @ [ row ~key_lower_bound:0 "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "renamed PG18 constraint" false 180_000 `Current
    (current @ [ row "n" "hostile" "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "noncanonical PG18 identifier deparse" false 180_000 `Current
    (current @ [ not_null "position" "1";
                 row "n" "clamp_schema_migrations_version_not_null"
                   "NOT NULL \"version\"" "2";
                 not_null "checksum" "3"; not_null "applied_at" "4" ]);
  check "wrong PG18 namespace" false 180_000 `Current
    (current @ [ row ~public_namespace:false "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "unvalidated PG18 constraint" false 180_000 `Current
    (current @ [ row ~validated:false "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "inherited PG18 constraint" false 180_000 `Current
    (current @ [ row ~inherited_count:1 "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "unenforced PG18 constraint" false 180_000 `Current
    (current @ [ row ~enforced:(Some false) "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "period PG18 constraint" false 180_000 `Current
    (current @ [ row ~period:(Some true) "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  check "hostile PG18 ancillary metadata" false 180_000 `Current
    (current @ [ row ~ancillary_canonical:false "n"
                   "clamp_schema_migrations_position_not_null"
                   "NOT NULL \"position\"" "1";
                 not_null "version" "2"; not_null "checksum" "3";
                 not_null "applied_at" "4" ]);
  let pg15_query = Catalog.ledger_constraint_query 150_000
  and pg18_query = Catalog.ledger_constraint_query 180_000 in
  Alcotest.(check bool) "PG15 projection avoids PG18 columns" false
    (Str.string_match (Str.regexp ".*conenforced.*") pg15_query 0);
  Alcotest.(check bool) "PG15 projection avoids period column" false
    (Str.string_match (Str.regexp ".*conperiod.*") pg15_query 0);
  Alcotest.(check bool) "PG18 projection includes enforcement" true
    (Str.string_match (Str.regexp ".*conenforced,conperiod.*") pg18_query 0)

let malformed_current_ledgers () =
  let check_case label mutate =
    with_database label (fun database ->
        with_migration_copy (fun root migrations ->
            check_report "seed trusted ledger"
              [ "0001_enable_vector"; "0002_application_schema" ]
              (Clamp.Database.migrate_local ~repo:root ~database);
            add_suffix migrations;
            let db_connection = connection database in
            let before = ledger_rows db_connection in
            mutate db_connection;
            db_connection#finish;
            check_error label "migration_ledger_invalid"
              (Clamp.Database.migrate_local ~repo:root ~database);
            let after = connection database in
            Alcotest.(check bool) (label ^ " suffix rolled back") false
              (table_exists after "phase3_suffix_marker");
            Alcotest.(check (list (triple int string string)))
              (label ^ " ledger unchanged") before (ledger_rows after);
            after#finish))
  in
  check_case "ledger suppressing trigger" (fun connection ->
      command connection
        "CREATE FUNCTION ledger_suppress() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$";
      command connection
        "CREATE TRIGGER ledger_suppress BEFORE INSERT ON clamp_schema_migrations FOR EACH ROW EXECUTE FUNCTION ledger_suppress()") ;
  check_case "ledger rewriting trigger" (fun connection ->
      command connection
        "CREATE FUNCTION ledger_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.checksum := repeat('f',64); RETURN NEW; END $$";
      command connection
        "CREATE TRIGGER ledger_rewrite BEFORE INSERT ON clamp_schema_migrations FOR EACH ROW EXECUTE FUNCTION ledger_rewrite()") ;
  check_case "ledger duplicating trigger" (fun connection ->
      command connection
        "CREATE FUNCTION ledger_duplicate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF pg_trigger_depth()=1 THEN INSERT INTO clamp_schema_migrations(position,version,checksum) VALUES (NEW.position+100,'duplicate_'||NEW.version,NEW.checksum); END IF; RETURN NEW; END $$";
      command connection
        "CREATE TRIGGER ledger_duplicate BEFORE INSERT ON clamp_schema_migrations FOR EACH ROW EXECUTE FUNCTION ledger_duplicate()") ;
  check_case "ledger extra rule" (fun connection ->
      command connection
        "CREATE RULE ledger_extra_rule AS ON INSERT TO clamp_schema_migrations DO ALSO NOTHING") ;
  check_case "ledger extra constraint" (fun connection ->
      command connection
        "ALTER TABLE clamp_schema_migrations ADD CHECK (length(version) > 0)") ;
  check_case "ledger extra index" (fun connection ->
      command connection
        "CREATE INDEX ledger_extra_index ON clamp_schema_migrations(checksum)") ;
  check_case "ledger changed default" (fun connection ->
      command connection
        "ALTER TABLE clamp_schema_migrations ALTER COLUMN checksum SET DEFAULT repeat('0',64)") ;
  check_case "ledger extra column" (fun connection ->
      command connection
        "ALTER TABLE clamp_schema_migrations ADD COLUMN unexpected text") ;
  check_case "ledger row security" (fun connection ->
      command connection "ALTER TABLE clamp_schema_migrations ENABLE ROW LEVEL SECURITY")

let () =
  Alcotest.run "Phase 3 local PostgreSQL"
    [ ("migrations and schema",
       [ Alcotest.test_case "fresh, repeat, drift, constraints" `Quick
           migration_and_schema;
         Alcotest.test_case "barrier synchronized first migration" `Quick
           concurrent_first_migration;
         Alcotest.test_case "trusted 0001 rejects before SQL" `Quick
           trusted_0001_rejection;
         Alcotest.test_case "trusted 0001 input failures" `Quick
           trusted_0001_input_failures;
         Alcotest.test_case "vector extension catalog identity" `Quick
           hostile_vector_extension;
         Alcotest.test_case "remote DNS failure failover" `Quick
           remote_dns_failover;
         Alcotest.test_case "remote network route failover" `Quick
           remote_network_route_failover;
         Alcotest.test_case "staggered connection race" `Quick
           remote_staggered_connection_race ]);
      ("local target",
       [ Alcotest.test_case "hostile libpq environment ignored" `Quick
           hostile_environment_is_ignored;
         Alcotest.test_case "hostile database search path ignored" `Quick
           hostile_search_path ]);
      ("non-cooperating sessions",
       [ Alcotest.test_case "relation lock blocks mutation" `Quick
           noncooperating_relation_lock;
         Alcotest.test_case "prevalidation serialization races" `Quick
           noncooperating_prevalidation_races ]);
      ("ordered prefix",
       [ Alcotest.test_case "deleted and renamed" `Quick
           deleted_and_renamed_history;
         Alcotest.test_case "gaps and ambiguous positions" `Quick
           invalid_repository_orders;
         Alcotest.test_case "rogue and reordered ledger" `Quick
           rogue_reordered_and_suffix;
         Alcotest.test_case "valid suffix" `Quick valid_suffix ]);
      ("ledger catalog",
       [ Alcotest.test_case "PG15 and PG18 constraint catalogs" `Quick
           ledger_constraint_catalog_forms;
         Alcotest.test_case "reject extras and hostile inserts" `Quick
           malformed_current_ledgers ]);
      ("legacy ledger",
       [ Alcotest.test_case "valid prefix upgrade" `Quick legacy_upgrade;
         Alcotest.test_case "invalid legacy rollback" `Quick invalid_legacy_ledgers;
         Alcotest.test_case "concurrent upgrade" `Quick concurrent_legacy_upgrade ]) ]
