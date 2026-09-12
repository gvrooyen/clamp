let check_ok name = function
  | Ok value -> value
  | Error (error : Clamp.Database.error) ->
      Alcotest.failf "%s: %s (%s)" name error.message error.code

let check_error_code expected = function
  | Ok _ -> Alcotest.failf "expected %s" expected
  | Error (error : Clamp.Database.error) -> Alcotest.(check string) "error code" expected error.code

let remote_url_validation () =
  [
    "postgresql://user:pass@db.example/clamp?sslmode=require&channel_binding=require";
    "postgres://db.example/clamp?channel_binding=require&sslmode=verify-full&connect_timeout=5";
    "postgresql://db.example:1/clamp?sslmode=require&channel_binding=require";
    "postgresql://[2001:db8::1]:65535/clamp?sslmode=require&channel_binding=require";
  ] |> List.iter (fun url -> ignore (check_ok "valid URL" (Clamp.Database.validate_remote_url url)));
  [
    "https://db.example/clamp?sslmode=require&channel_binding=require";
    "postgresql://db.example/clamp";
    "postgresql://db.example/clamp?sslmode=prefer&channel_binding=require";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=prefer";
    "postgresql://db.example/clamp?sslmode=require&sslmode=verify-full&channel_binding=require";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require&connect_timeout=30";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require&connect_timeout=2&connect_timeout=3";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require&options=-csearch_path%3Devil";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require&hostaddr=127.0.0.1";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require&port=5432";
    "postgresql://a,b,c,d,e,f,g,h,i/clamp?sslmode=require&channel_binding=require";
    "POSTGRESQL://db.example/clamp?sslmode=verify-ca&channel_binding=REQUIRE";
    "Postgres://db.example/clamp?sslmode=require&channel_binding=require";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require#fragment";
    "postgresql://db.example/clamp#ignored?sslmode=require&channel_binding=require";
  ] |> List.iter (fun url -> check_error_code "database_url_invalid" (Clamp.Database.validate_remote_url url));
  [ ""; "0"; "65536"; "-1"; "+1"; "1.0"; "%31"; " 1" ]
  |> List.iter (fun port ->
      let url = Printf.sprintf
          "postgresql://db.example:%s/clamp?sslmode=require&channel_binding=require" port in
      check_error_code "database_url_invalid" (Clamp.Database.validate_remote_url url);
      check_error_code "database_url_invalid"
        (Clamp.Database.migrate_remote ~repo:"/repository-must-not-be-read" ~url));
  [ "port="; "port=0"; "port=5432"; "port=65536"; "port=-1";
    "port=+1"; "port=1.0"; "port=%35%34%33%32";
    "p%6frt=5432"; "port=5432&port=5433" ]
  |> List.iter (fun parameter ->
      let url =
        "postgresql://db.example/clamp?sslmode=require&channel_binding=require&"
        ^ parameter in
      check_error_code "database_url_invalid" (Clamp.Database.validate_remote_url url);
      check_error_code "database_url_invalid"
        (Clamp.Database.migrate_remote ~repo:"/repository-must-not-be-read" ~url));
  [ "postgresql://[2001:db8::1]:/clamp?sslmode=require&channel_binding=require";
    "postgresql://[2001:db8::1]:0/clamp?sslmode=require&channel_binding=require";
    "postgresql://[2001:db8::1]:65536/clamp?sslmode=require&channel_binding=require" ]
  |> List.iter (fun url ->
      check_error_code "database_url_invalid" (Clamp.Database.validate_remote_url url));
  let resolver_calls = ref 0 in
  let effects : Clamp.Database.retry_effects =
    { now = (fun () -> 0.); sleep = (fun _ -> ()); jitter = (fun () -> 0.) } in
  check_error_code "database_url_invalid"
    (Clamp.Database.prepare_remote_url ~effects ~deadline:1.
       ~resolver:(fun ~deadline:_ _ -> incr resolver_calls; Ok [ "127.0.0.1" ])
       "postgresql://db.example:+5432/clamp?sslmode=require&channel_binding=require");
  Alcotest.(check int) "invalid port rejected before DNS" 0 !resolver_calls;
  [ "db%2eexample"; "%64b.example"; "db example"; "db..example";
    "-db.example"; "db-.example"; "db\\example";
    "[not-an-ipv6-address]"; "[2001:db8::1%25eth0]" ]
  |> List.iter (fun host ->
      let url = Printf.sprintf
          "postgresql://%s/clamp?sslmode=require&channel_binding=require" host in
      check_error_code "database_url_invalid" (Clamp.Database.validate_remote_url url);
      check_error_code "database_url_invalid"
        (Clamp.Database.prepare_remote_url ~effects ~deadline:1.
           ~resolver:(fun ~deadline:_ _ -> incr resolver_calls; Ok [ "127.0.0.1" ]) url));
  Alcotest.(check int) "malformed hosts rejected before DNS" 0 !resolver_calls;
  [ "POSTGRESQL://db.example/clamp?sslmode=require&channel_binding=require";
    "postgresql://db.example/clamp?sslmode=require&channel_binding=require#fragment" ]
  |> List.iter (fun url ->
      check_error_code "database_url_invalid"
        (Clamp.Database.migrate_remote ~repo:"/repository-must-not-be-read" ~url))

let classification () =
  let open Clamp.Database in
  Alcotest.(check bool) "auth" true
    (classify_connection_message "password authentication failed" = Authentication);
  Alcotest.(check bool) "transient" true
    (classify_connection_message "connection refused" = Transient);
  Alcotest.(check bool) "network unreachable is transient" true
    (classify_connection_message "connect to server failed: Network is unreachable" = Transient);
  Alcotest.(check bool) "no route is transient" true
    (classify_connection_message "connect failed: No route to host" = Transient);
  [ "Cannot assign requested address"; "EADDRNOTAVAIL";
    "Network is down"; "ENETDOWN"; "Host is down"; "EHOSTDOWN";
    "Address family not supported by protocol"; "EAFNOSUPPORT";
    "could not create socket: ai_family not supported";
    "SSL SYSCALL error: EOF detected";
    "Network dropped connection on reset"; "ENETRESET";
    "Software caused connection abort"; "ECONNABORTED" ]
  |> List.iter (fun message ->
      Alcotest.(check bool) ("failover classification: " ^ message) true
        (classify_connection_message message = Transient));
  Alcotest.(check bool) "TLS validation" true
    (classify_connection_message "certificate verify failed" = Validation);
  Alcotest.(check bool) "unknown is not retried" true
    (classify_connection_message "unknown libpq failure" = Internal);
  Alcotest.(check bool) "SQL body is not connection liveness" true
    (classify_connection_message "administrator command: terminating connection"
     = Internal);
  Alcotest.(check bool) "timeout" true
    (classify_query_message "canceling statement due to statement timeout" = Timeout);
  Alcotest.(check bool) "deterministic SQL" true
    (classify_query_message "duplicate key value" = Sql)

let retry_without_sleeping () =
  let attempts = ref 0 and sleeps = ref [] and now = ref 0. in
  let effects : Clamp.Database.retry_effects =
    { now = (fun () -> !now);
      sleep = (fun delay -> sleeps := delay :: !sleeps; now := !now +. delay);
      jitter = (fun () -> 0.) }
  in
  let transient : Clamp.Database.error =
    { kind = Transient; code = "temporary"; message = "temporary";
      finalization = Before_commit_dispatch }
  in
  let result = Clamp.Database.retry ~effects (fun () ->
      incr attempts; if !attempts < 3 then Error transient else Ok "connected") in
  Alcotest.(check string) "result" "connected" (check_ok "retry" result);
  Alcotest.(check int) "attempts" 3 !attempts;
  Alcotest.(check (list (float 0.0001))) "backoff" [ 0.5; 1. ] (List.rev !sleeps);
  attempts := 0; sleeps := [];
  let authentication = { transient with kind = Authentication } in
  ignore (Clamp.Database.retry ~effects (fun () -> incr attempts; Error authentication));
  Alcotest.(check int) "auth is not retried" 1 !attempts;
  Alcotest.(check int) "auth does not sleep" 0 (List.length !sleeps);
  attempts := 0; sleeps := []; now := 0.;
  let jittered_effects = { effects with jitter = (fun () -> 1.) } in
  Alcotest.(check (float 0.0001)) "outer retry delay includes jitter" 0.625
    (Clamp.Database.retry_delay jittered_effects 1);
  ignore (Clamp.Database.retry ~effects:jittered_effects ~max_attempts:2
            (fun () -> incr attempts; Error transient));
  Alcotest.(check (list (float 0.0001))) "effective jitter" [ 0.625 ]
    (List.rev !sleeps)

let absolute_connection_deadline () =
  let now = ref 9. and sleeps = ref [] in
  let effects : Clamp.Database.retry_effects =
    { now = (fun () -> !now);
      sleep = (fun delay -> sleeps := delay :: !sleeps; now := 11.);
      jitter = (fun () -> 0.) } in
  Alcotest.(check (option (float 0.0001))) "child capped by parent" (Some 10.)
    (Clamp.Database.child_deadline ~effects ~parent:10. ~cap:5.);
  Alcotest.(check (option (float 0.0001))) "local child cap" (Some 9.25)
    (Clamp.Database.child_deadline ~effects ~parent:10. ~cap:0.25);
  Alcotest.(check bool) "descheduled sleep cannot continue work" false
    (Clamp.Database.sleep_before_deadline ~effects ~deadline:10. 0.5);
  Alcotest.(check (list (float 0.0001))) "sleep uses live remaining budget" [ 0.5 ] !sleeps;
  now := 9.;
  let configured = ref false in
  Alcotest.(check bool) "Polling_ok after configuration expiry is rejected" false
    (Clamp.Database.polling_ok_before_deadline ~effects ~deadline:10. (fun () ->
         configured := true; now := 10.));
  Alcotest.(check bool) "Polling_ok configuration was exercised" true !configured;
  Alcotest.(check (option (float 0.0001))) "expired parent has no child" None
    (Clamp.Database.child_deadline ~effects ~parent:10. ~cap:1.);
  now := 9.;
  check_error_code "database_connection_timeout"
    (Clamp.Database.prepare_remote_url ~effects ~deadline:10.
       ~resolver:(fun ~deadline host ->
         Alcotest.(check string) "deadline resolver host" "db.example" host;
         Alcotest.(check bool) "child never exceeds parent" true (deadline <= 10.);
         now := 10.;
         Ok [ "127.0.0.1" ])
       "postgresql://db.example/clamp?sslmode=require&channel_binding=require")

let resolution_deadline_without_sleeping () =
  let now = ref 10. and resolved = ref [] in
  let effects : Clamp.Database.retry_effects =
    { now = (fun () -> !now); sleep = (fun delay -> now := !now +. delay);
      jitter = (fun () -> 0.) }
  in
  let resolver ~deadline host =
    Alcotest.(check bool) "deadline stays in shared budget" true
      (deadline > !now && deadline <= 15.);
    resolved := host :: !resolved;
    Ok (if host = "first.example" then [ "192.0.2.2"; "192.0.2.1"; "192.0.2.2" ]
        else [ "2001:db8::1" ])
  in
  let prepared =
    Clamp.Database.prepare_remote_url ~effects ~deadline:15. ~resolver
      "postgresql://user:secret@first.example:5432,second.example/db?sslmode=require&channel_binding=require"
    |> check_ok "prepared URL"
  in
  Alcotest.(check (list string)) "all hosts resolved"
    [ "first.example"; "second.example" ] (List.rev !resolved);
  Alcotest.(check bool) "host/address alignment" true
    (String.starts_with
       ~prefix:"postgresql://user:secret@first.example:5432,first.example:5432,second.example/db?sslmode=require&channel_binding=require&hostaddr=192.0.2.2,192.0.2.1,2001%3Adb8%3A%3A1"
       prepared);
  let resolver ~deadline:_ _ = Ok [ "2001:db8::2"; "192.0.2.22" ] in
  let preferred =
    Clamp.Database.prepare_remote_url ~effects ~deadline:15. ~resolver
      "postgresql://preferred.example/db?sslmode=require&channel_binding=require"
    |> check_ok "preferred address order" in
  Alcotest.(check bool) "IPv6 to IPv4 resolver preference is preserved" true
    (String.starts_with
       ~prefix:"postgresql://preferred.example,preferred.example/db?sslmode=require&channel_binding=require&hostaddr=2001%3Adb8%3A%3A2,192.0.2.22"
       preferred);
  resolved := [];
  let resolver ~deadline:_ host =
    resolved := host :: !resolved;
    if host = "first.example" then Error `Resolve else Ok [ "192.0.2.9" ]
  in
  let failover = Clamp.Database.prepare_remote_url ~effects ~deadline:15. ~resolver
      "postgresql://first.example,second.example/db?sslmode=require&channel_binding=require"
      |> check_ok "DNS failure failover" in
  Alcotest.(check (list string)) "DNS failure continues to healthy host"
    [ "first.example"; "second.example" ] (List.rev !resolved);
  Alcotest.(check bool) "only healthy host retained" true
    (String.starts_with ~prefix:"postgresql://second.example/db?" failover);
  now := 10.; resolved := [];
  let resolver ~deadline host =
    resolved := host :: !resolved;
    if host = "first.example" then (now := deadline; Error `Timeout)
    else Ok [ "192.0.2.10" ]
  in
  ignore (check_ok "DNS timeout failover"
    (Clamp.Database.prepare_remote_url ~effects ~deadline:15. ~resolver
       "postgresql://first.example,second.example/db?sslmode=require&channel_binding=require"));
  Alcotest.(check (list string)) "DNS timeout leaves budget for healthy host"
    [ "first.example"; "second.example" ] (List.rev !resolved);
  now := 10.;
  let resolver ~deadline:_ _ = Ok (List.init 9 (fun index -> "192.0.2." ^ string_of_int (index + 1))) in
  check_error_code "database_url_invalid"
    (Clamp.Database.prepare_remote_url ~effects ~deadline:15. ~resolver
       "postgresql://many.example/db?sslmode=require&channel_binding=require")

let process_jitter_reseeds () =
  let pid = ref 10 and initializations = ref 0 in
  let jitter = Clamp.Database.make_process_jitter
      ~pid:(fun () -> !pid)
      ~initialize:(fun () ->
        incr initializations;
        Random.State.make [| !initializations |]) () in
  let first = jitter () in
  ignore (jitter ());
  Alcotest.(check int) "one seed in one process" 1 !initializations;
  pid := 11;
  let second_process = jitter () in
  Alcotest.(check int) "fresh process reseeds" 2 !initializations;
  Alcotest.(check bool) "fresh process does not share sequence" true
    (first <> second_process);
  let fresh_sequence () =
    let input, output = Unix.pipe ~cloexec:true () in
    match Unix.fork () with
    | 0 ->
        Unix.close input;
        let channel = Unix.out_channel_of_descr output in
        Marshal.to_channel channel
          (List.init 3 (fun _ -> Clamp.Database.production_jitter ())) [];
        close_out channel;
        Unix._exit 0
    | child ->
        Unix.close output;
        let channel = Unix.in_channel_of_descr input in
        let sequence : float list = Marshal.from_channel channel in
        close_in channel;
        (match snd (Unix.waitpid [] child) with
        | Unix.WEXITED 0 -> sequence
        | _ -> Alcotest.fail "fresh jitter child failed")
  in
  let first_process = fresh_sequence () and second_process = fresh_sequence () in
  Alcotest.(check bool) "fresh OS processes have independent sequences" true
    (first_process <> second_process)

let waitpid_bounded_poll () =
  let calls = ref 0 and now = ref 0. in
  let effects : Clamp.Database.retry_effects =
    { now = (fun () -> !now);
      sleep = (fun delay -> now := !now +. delay);
      jitter = (fun () -> 0.) } in
  Alcotest.(check bool) "eventually collected" true
    (Clamp.Database.poll_waitpid ~effects ~deadline:1. (fun () ->
         incr calls;
         if !calls <= 2 then raise (Unix.Unix_error (Unix.EINTR, "waitpid", ""))
         else if !calls <= 4 then `Running else `Collected));
  Alcotest.(check int) "EINTR and running retry" 5 !calls;
  Alcotest.(check (float 0.0001)) "bounded polling time" 0.02 !now;
  calls := 0; now := 0.;
  Alcotest.(check bool) "deadline stops running child poll" false
    (Clamp.Database.poll_waitpid ~effects ~deadline:0.025 (fun () ->
         incr calls; `Running));
  Alcotest.(check bool) "deadline not exceeded" true (!now <= 0.025);
  calls := 0; now := 1.;
  Alcotest.(check bool) "exact deadline performs no WNOHANG" false
    (Clamp.Database.poll_waitpid ~effects ~deadline:1. (fun () ->
         incr calls; `Collected));
  Alcotest.(check int) "no wait at exact deadline" 0 !calls;
  now := 0.;
  Alcotest.(check bool) "ECHILD is terminal" true
    (Clamp.Database.poll_waitpid ~effects ~deadline:1. (fun () ->
         raise (Unix.Unix_error (Unix.ECHILD, "waitpid", ""))));
  Alcotest.(check bool) "other errors are not collected" false
    (Clamp.Database.poll_waitpid ~effects ~deadline:1. (fun () ->
         raise (Unix.Unix_error (Unix.EPERM, "waitpid", ""))))

let resolver_syscall_containment () =
  let open Clamp.Database in
  let real_effects : retry_effects =
    { now = Unix.gettimeofday; sleep = Unix.sleepf; jitter = (fun () -> 0.) } in
  let check_reason name expected = function
    | Error reason -> Alcotest.(check bool) name true (reason = expected)
    | Ok _ -> Alcotest.failf "%s unexpectedly resolved" name
  in
  let now_calls = ref 0 and forked = ref false in
  let deadline_effects =
    { real_effects with now = (fun () -> incr now_calls; if !now_calls = 1 then 0. else 1.) } in
  let pre_fork =
    { default_resolver_system with
      fork = (fun () -> forked := true; failwith "fork must not run") } in
  check_reason "expired pre-fork budget" `Timeout
    (resolve_host_with ~system:pre_fork ~effects:deadline_effects ~deadline:0.5
       "resolver.example");
  Alcotest.(check bool) "expired budget performs no fork" false !forked;

  let fd_count = Clamp.Secure_fs.descriptor_count in
  let before = fd_count () in
  let fork_failure =
    { default_resolver_system with
      fork = (fun () -> raise (Unix.Unix_error (Unix.EAGAIN, "fork", ""))) } in
  for _ = 1 to 32 do
    check_reason "fork failure" `Resolve
      (resolve_host_with ~system:fork_failure ~effects:real_effects
         ~deadline:(real_effects.now () +. 1.) "resolver.example")
  done;
  Alcotest.(check int) "fork failure closes both pipe descriptors" before (fd_count ());

  let kill_calls = ref 0 and wait_calls = ref 0 in
  let collected_system =
    { default_resolver_system with
      fork = (fun () -> 424242);
      kill = (fun _ _ ->
        incr kill_calls;
        if !kill_calls = 1 then raise (Unix.Unix_error (Unix.EINTR, "kill", "")));
      waitpid_nohang = (fun _ ->
        incr wait_calls;
        if !wait_calls = 1 then `Running else `Collected) } in
  let select_calls = ref 0 in
  let select_failure =
    { collected_system with
      select_read = (fun _ _ ->
        incr select_calls;
        if !select_calls = 1 then raise (Unix.Unix_error (Unix.EINTR, "select", ""))
        else raise (Unix.Unix_error (Unix.EBADF, "select", ""))) } in
  check_reason "select failure" `Resolve
    (resolve_host_with ~system:select_failure ~effects:real_effects
       ~deadline:(real_effects.now () +. 1.) "resolver.example");
  Alcotest.(check int) "select EINTR is retried" 2 !select_calls;
  Alcotest.(check int) "kill EINTR is retried" 2 !kill_calls;
  Alcotest.(check int) "wait polls to terminal state" 2 !wait_calls;
  let read_calls = ref 0 in
  let read_failure =
    { collected_system with kill = (fun _ _ -> ()); waitpid_nohang = (fun _ -> `Collected);
      select_read = (fun _ _ -> true);
      read = (fun _ _ _ _ ->
        incr read_calls;
        if !read_calls = 1 then raise (Unix.Unix_error (Unix.EINTR, "read", ""))
        else raise (Unix.Unix_error (Unix.EIO, "read", ""))) } in
  check_reason "read failure" `Resolve
    (resolve_host_with ~system:read_failure ~effects:real_effects
       ~deadline:(real_effects.now () +. 1.) "resolver.example");
  Alcotest.(check int) "read EINTR is retried" 2 !read_calls;
  Alcotest.(check int) "resolver syscall failures leak no descriptors" before (fd_count ());

  let descheduled_now = ref 0. and post_kill_waits = ref 0 and post_kill_kills = ref 0
  and cleanup_sleeps = ref 0 in
  let descheduled_effects : retry_effects =
    { now = (fun () -> !descheduled_now);
      sleep = (fun _ -> incr cleanup_sleeps);
      jitter = (fun () -> 0.) } in
  let post_kill_wait =
    { collected_system with
      kill = (fun _ _ -> incr post_kill_kills; descheduled_now := 1.);
      waitpid_nohang = (fun _ ->
        incr post_kill_waits;
        if !post_kill_waits = 1 then `Running else `Collected);
      select_read = (fun _ _ -> raise (Unix.Unix_error (Unix.EBADF, "select", ""))) } in
  check_reason "descheduled cleanup" `Resolve
    (resolve_host_with ~system:post_kill_wait ~effects:descheduled_effects
       ~deadline:0.5 "resolver.example");
  Alcotest.(check int) "no WNOHANG after kill crosses inherited deadline" 1 !post_kill_waits;
  Alcotest.(check int) "finalizer does not duplicate reap allowance" 1
    !post_kill_kills;
  Alcotest.(check int) "no cleanup sleep at or after expiry" 0 !cleanup_sleeps;

  descheduled_now := 0.;
  post_kill_waits := 0;
  post_kill_kills := 0;
  cleanup_sleeps := 0;
  let expired_before_cleanup =
    { post_kill_wait with
      select_read = (fun _ _ ->
        descheduled_now := 0.5;
        raise (Unix.Unix_error (Unix.EBADF, "select", ""))) } in
  check_reason "cleanup starts expired" `Resolve
    (resolve_host_with ~system:expired_before_cleanup ~effects:descheduled_effects
       ~deadline:0.5 "resolver.example");
  Alcotest.(check int) "expired cleanup performs no kill" 0 !post_kill_kills;
  Alcotest.(check int) "expired cleanup performs no WNOHANG" 0 !post_kill_waits;
  Alcotest.(check int) "expired cleanup performs no sleep" 0 !cleanup_sleeps;

  let stable_error =
    prepare_remote_url ~effects:real_effects ~deadline:(real_effects.now () +. 1.)
      ~resolver:(fun ~deadline host ->
        resolve_host_with ~system:{ default_resolver_system with
          pipe = (fun () -> raise (Unix.Unix_error (Unix.EMFILE, "pipe", "secret"))) }
          ~effects:real_effects ~deadline host)
      "postgresql://user:secret@resolver.example/db?sslmode=require&channel_binding=require"
  in
  (match stable_error with
  | Error error ->
      Alcotest.(check string) "stable setup error code" "database_unavailable" error.code;
      Alcotest.(check bool) "setup error is credential-free" false
        (String.contains error.message ':')
  | Ok _ -> Alcotest.fail "pipe failure unexpectedly prepared a URL");

  let parent = Unix.getpid () and parent_now = ref 0. and child = ref None in
  let marker_input, marker_output = Unix.pipe ~cloexec:true () in
  let injected_effects : retry_effects =
    { now = (fun () -> if Unix.getpid () = parent then !parent_now else 1.);
      sleep = (fun delay ->
        parent_now := !parent_now +. delay;
        Unix.sleepf (min 0.001 delay));
      jitter = (fun () -> 0.) } in
  let injected_system =
    { default_resolver_system with
      fork = (fun () ->
        let process = Unix.fork () in
        if process > 0 then child := Some process;
        process);
      resolve = (fun _ ->
        ignore (Unix.write marker_output (Bytes.of_string "x") 0 1);
        Some [ "127.0.0.1" ]) } in
  let injected_result = resolve_host_with ~system:injected_system ~effects:injected_effects
      ~deadline:0.5 "resolver.example" in
  let collected = match !child with
  | None -> Alcotest.fail "injected-expiry child was not created"
  | Some process ->
      let collected =
        try ignore (Unix.waitpid [ Unix.WNOHANG ] process); false with
        | Unix.Unix_error (Unix.ECHILD, _, _) -> true in
      if not collected then begin
        (try Unix.kill process Sys.sigkill with _ -> ());
        (try ignore (Unix.waitpid [] process) with _ -> ())
      end;
      collected in
  Unix.close marker_output;
  let marker = Bytes.create 1 in
  let marker_count = Unix.read marker_input marker 0 1 in
  Unix.close marker_input;
  check_reason "child-injected expiry" `Resolve injected_result;
  Alcotest.(check int) "expired child never invokes injected resolver" 0 marker_count;
  Alcotest.(check bool) "injected-expiry child is collected in budget" true collected;

  let child = ref None and parent_reads = ref 0 and parent_kills = ref 0
  and parent_waits = ref 0 in
  let marker_input, marker_output = Unix.pipe ~cloexec:true () in
  let descheduled_child_system =
    { default_resolver_system with
      fork = (fun () ->
        let process = Unix.fork () in
        if process = 0 then Unix.sleepf 0.03 else child := Some process;
        process);
      select_read = (fun _ _ -> Unix.sleepf 0.04; true);
      read = (fun descriptor bytes offset length ->
        incr parent_reads;
        Unix.read descriptor bytes offset length);
      kill = (fun process signal -> incr parent_kills; Unix.kill process signal);
      waitpid_nohang = (fun process ->
        incr parent_waits;
        default_resolver_system.waitpid_nohang process);
      resolve = (fun _ ->
        ignore (Unix.write marker_output (Bytes.of_string "x") 0 1);
        Some [ "127.0.0.1" ]) } in
  let started = real_effects.now () in
  let descheduled_result =
    resolve_host_with ~system:descheduled_child_system ~effects:real_effects
      ~deadline:(started +. 0.02) "resolver.example" in
  (match !child with
  | None -> Alcotest.fail "descheduled child was not created"
  | Some process ->
      let _, status = Unix.waitpid [] process in
      Alcotest.(check bool) "descheduled child exits through protocol" true
        (status = Unix.WEXITED 0));
  Unix.close marker_output;
  let marker = Bytes.create 1 in
  let marker_count = Unix.read marker_input marker 0 1 in
  Unix.close marker_input;
  check_reason "real child crosses inherited expiry" `Timeout descheduled_result;
  Alcotest.(check int) "descheduled child never invokes resolver" 0 marker_count;
  Alcotest.(check int) "parent performs no post-expiry read" 0 !parent_reads;
  Alcotest.(check int) "parent performs no post-expiry kill" 0 !parent_kills;
  Alcotest.(check int) "parent performs no post-expiry WNOHANG" 0 !parent_waits;

  let child = ref None and expired_kills = ref 0 and expired_waits = ref 0 in
  let slow_system =
    { default_resolver_system with
      fork = (fun () ->
        let process = Unix.fork () in
        if process > 0 then child := Some process;
        process);
      kill = (fun process signal ->
        incr expired_kills;
        Unix.kill process signal);
      waitpid_nohang = (fun process ->
        incr expired_waits;
        default_resolver_system.waitpid_nohang process);
      resolve = (fun _ -> Unix.sleepf 1.; Some [ "127.0.0.1" ]) } in
  let started = real_effects.now () in
  check_reason "expired resolver child" `Timeout
    (resolve_host_with ~system:slow_system ~effects:real_effects
       ~deadline:(started +. 0.2) "resolver.example");
  Alcotest.(check bool) "inherited resolver deadline is bounded" true
    (real_effects.now () -. started < 0.4);
  Alcotest.(check int) "reserved cleanup sends one child kill" 1 !expired_kills;
  Alcotest.(check bool) "reserved cleanup waits for child" true (!expired_waits >= 2);
  (match !child with
  | None -> Alcotest.fail "resolver child was not created"
  | Some process ->
      let collected =
        try ignore (Unix.waitpid [ Unix.WNOHANG ] process); false with
        | Unix.Unix_error (Unix.ECHILD, _, _) -> true in
      if not collected then begin
        (try Unix.kill process Sys.sigkill with _ -> ());
        (try ignore (Unix.waitpid [] process) with _ -> ())
      end;
      Alcotest.(check bool) "slow resolver child reaped inside inherited budget" true collected);

  let child = ref None and live_kills = ref 0 and live_waits = ref 0 in
  let live_system =
    { default_resolver_system with
      fork = (fun () ->
        let process = Unix.fork () in
        if process > 0 then child := Some process;
        process);
      kill = (fun process signal -> incr live_kills; Unix.kill process signal);
      waitpid_nohang = (fun process ->
        incr live_waits;
        default_resolver_system.waitpid_nohang process);
      resolve = (fun _ -> Some [ "127.0.0.1" ]) } in
  let result = resolve_host_with ~system:live_system ~effects:real_effects
      ~deadline:(real_effects.now () +. 0.5) "resolver.example" in
  (match result with
  | Ok [ "127.0.0.1" ] -> ()
  | Ok _ -> Alcotest.fail "live resolver returned unexpected addresses"
  | Error _ -> Alcotest.fail "live resolver failed within its inherited budget");
  Alcotest.(check bool) "live cleanup performs at least one wait" true (!live_waits >= 1);
  Alcotest.(check bool) "live cleanup sends at most one kill" true (!live_kills <= 1);
  (match !child with
  | None -> Alcotest.fail "live resolver child was not created"
  | Some process ->
      let collected =
        try ignore (Unix.waitpid [ Unix.WNOHANG ] process); false with
        | Unix.Unix_error (Unix.ECHILD, _, _) -> true in
      Alcotest.(check bool) "live resolver child reaped within inherited budget" true collected)

let local_database_identifier () =
  [ ""; "9database"; "name-with-dash"; "postgresql://host/db";
    "service=hostile"; "name?host=hostile"; String.make 64 'a' ]
  |> List.iter (fun database ->
      check_error_code "local_database_invalid"
        (Clamp.Database.migrate_local ~repo:"." ~database))

let () =
  Alcotest.run "Phase 3 database boundary"
    [ ("URL validation", [ Alcotest.test_case "remote policy" `Quick remote_url_validation ]);
      ("classification", [ Alcotest.test_case "retry and timeout" `Quick classification ]);
      ("retry", [ Alcotest.test_case "injected effects" `Quick retry_without_sleeping ]);
      ("absolute deadline", [ Alcotest.test_case "descheduling is bounded" `Quick
          absolute_connection_deadline ]);
      ("jitter", [ Alcotest.test_case "per-process reseeding" `Quick
          process_jitter_reseeds ]);
      ("connection deadline",
       [ Alcotest.test_case "resolver and address budget" `Quick
           resolution_deadline_without_sleeping;
         Alcotest.test_case "waitpid bounded nonblocking poll" `Quick
           waitpid_bounded_poll;
         Alcotest.test_case "resolver syscall containment and cleanup" `Quick
           resolver_syscall_containment ]);
      ("local target",
       [ Alcotest.test_case "database identifier rejects conninfo" `Quick
           local_database_identifier ]) ]
