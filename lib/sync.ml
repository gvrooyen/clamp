open Exact_yaml

type counts = {
  added : int;
  metadata_updated : int;
  reembedded : int;
  unchanged : int;
  deleted : int;
}

type report = {
  commit : string;
  counts : counts;
  rebuilt : bool;
  diagnostics : Diagnostic.t list;
}
type error_kind = Validation | Authentication | Transient | Internal
type error = {
  kind : error_kind;
  code : string;
  message : string;
  diagnostics : Diagnostic.t list;
}

type classified_producer = {
  producer_code : string;
  producer_kind : error_kind;
  sync_fallback : bool;
}

let classified_producers =
  [ { producer_code = "database_direct_url_missing";
      producer_kind = Validation; sync_fallback = true };
    { producer_code = "database_authentication_failed";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "database_connection_timeout";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "database_query_timeout";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "database_connection_lost";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "database_unavailable";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "openrouter_api_key_missing";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "openrouter_authentication_failed";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "openrouter_network_error";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "openrouter_timeout";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "openrouter_rate_limited";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "openrouter_payment_required";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "openrouter_unavailable";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "git_auth_unavailable";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "git_auth_config_unsafe";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "git_auth_failed";
      producer_kind = Authentication; sync_fallback = true };
    { producer_code = "git_timeout";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "git_unavailable";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "git_failed";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "git_target_invalid";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "sync_already_running";
      producer_kind = Transient; sync_fallback = true };
    { producer_code = "git_remote_ref_unavailable";
      producer_kind = Transient; sync_fallback = false };
    { producer_code = "git_remote_ref_invalid";
      producer_kind = Transient; sync_fallback = false } ]

let producer code =
  List.find_opt (fun value -> value.producer_code = code) classified_producers

let raw_error ?(diagnostics = []) kind code message =
  { kind; code; message; diagnostics }

let make_error ?(diagnostics = []) kind code message =
  match producer code with
  | Some expected when expected.producer_kind = kind ->
      raw_error ~diagnostics kind code message
  | Some _ | None when kind = Authentication || kind = Transient ->
      raw_error Internal "sync_producer_contract_invalid"
        "A classified synchronization failure is missing from the production contract."
  | Some _ ->
      raw_error Internal "sync_producer_contract_invalid"
        "A classified synchronization failure has the wrong production kind."
  | None -> raw_error ~diagnostics kind code message

let error ?(diagnostics = []) kind code message =
  Error (make_error ~diagnostics kind code message)

let fallback_producers () =
  classified_producers
  |> List.filter_map (fun value ->
         if value.sync_fallback then
           Some (value.producer_code, value.producer_kind)
         else None)

let fallback_error ~code ~message =
  match producer code with
  | Some value when value.sync_fallback ->
      make_error value.producer_kind code message
  | Some _ | None ->
      raw_error Internal "sync_producer_contract_invalid"
        "The requested synchronization fallback producer is not in the production contract."

let exit_class error =
  match error.kind with
  | Validation -> Exit_class.User_error
  | Authentication -> Exit_class.Authentication
  | Transient -> Exit_class.Transient_external
  | Internal -> Exit_class.Internal

let cli_result error =
  let fallback =
    match producer error.code with
    | Some value
      when value.sync_fallback && value.producer_kind = error.kind ->
        [ ("fallback", `String "local_markdown_or_rg");
          ("semantic_equivalent", `Bool false) ]
    | Some _ | None -> []
  in
  let diagnostics =
    if error.diagnostics = [] then []
    else
      [ ( "diagnostics",
          `List (List.map Diagnostic.json error.diagnostics) ) ]
  in
  Cli_result.failure ~exit_class:(exit_class error) ~code:error.code
    ~message:error.message ~details:(`Assoc (fallback @ diagnostics))

let completion_code (report : report) =
  if report.diagnostics = [] then "sync_complete"
  else "sync_complete_with_warnings"

let database_error (failure : Database.error) =
  let kind =
    match failure.kind with
    | Database.Validation | Sql -> Validation
    | Authentication -> Authentication
    | Transient | Timeout -> Transient
    | Internal -> Internal
  in
  make_error kind failure.code failure.message

let of_database failure = Error (database_error failure)
let db result = Result.map_error database_error result
let ( let* ) = Result.bind

let openrouter_error (failure : Openrouter.error) =
  let kind =
    match failure.kind with
    | Openrouter.Authentication -> Authentication
    | Validation | Invalid_response | Response_too_large -> Validation
    | Rate_limited | Payment_required | Transient -> Transient
  in
  make_error kind failure.code failure.message

let bind_database result operation =
  match result with Ok value -> operation value | Error failure -> of_database failure

let maximum_git_output = 16 * 1024 * 1024

type process_output = { stdout : string; stderr : string; status : Unix.process_status }

external monotonic_now : unit -> float = "clamp_monotonic_now"
external waitid_exited_nowait : int -> bool = "clamp_waitid_exited_nowait"

type process_hooks = {
  before_pipe : int -> unit;
  child_setup_delay : float;
  after_fork : int -> unit;
  after_readiness_selectable : unit -> unit;
  before_ack_write : unit -> unit;
  before_ack_close : unit -> unit;
  after_spawn : int -> unit;
  before_waitpid : unit -> unit;
}

let default_process_hooks =
  { before_pipe = (fun _ -> ()); child_setup_delay = 0.;
    after_fork = (fun _ -> ()); after_readiness_selectable = (fun () -> ());
    before_ack_write = (fun () -> ()); before_ack_close = (fun () -> ());
    after_spawn = (fun _ -> ()); before_waitpid = (fun () -> ()) }

let isolated_process_environment ~home ~xdg_config_home extra =
  Array.of_list
    ([ "PATH=/usr/bin:/bin"; "HOME=" ^ home;
       "XDG_CONFIG_HOME=" ^ xdg_config_home;
       "LC_ALL=C"; "LANG=C"; "GIT_TERMINAL_PROMPT=0";
       "GIT_ASKPASS=/bin/false"; "SSH_ASKPASS=/bin/false";
       "GIT_OPTIONAL_LOCKS=0"; "GIT_CONFIG_NOSYSTEM=1";
       "GIT_CONFIG_SYSTEM=/dev/null"; "GIT_CONFIG_GLOBAL=/dev/null";
       "GIT_CONFIG_COUNT=0"; "GIT_NO_REPLACE_OBJECTS=1" ] @ extra)

let safe_process_environment =
  isolated_process_environment ~home:"/nonexistent"
    ~xdg_config_home:"/nonexistent" []

exception Process_error of error

let execute_process ~input ~environment ~timeout ~hooks ~program ~arguments
    ~maximum =
  let deadline = monotonic_now () +. timeout in
  let owned = ref [] and pid = ref None and session_confirmed = ref false in
  let reaped = ref false and cause = ref None in
  let output = Buffer.create 4096 and errors = Buffer.create 512 in
  let own descriptor = owned := descriptor :: !owned; descriptor in
  let forget descriptor =
    if List.mem descriptor !owned then begin
      owned := List.filter (( <> ) descriptor) !owned;
      true
    end else false
  in
  let close descriptor =
    if forget descriptor then
      try Unix.close descriptor with Unix.Unix_error _ -> ()
  in
  let close_checked descriptor =
    if forget descriptor then Unix.close descriptor
  in
  let close_all () = List.iter close !owned in
  let timeout_error () =
    make_error Transient "git_timeout" "Git operation timed out."
  in
  let unavailable_error () =
    make_error Transient "git_unavailable" "Git could not be executed."
  in
  let check_deadline () =
    if monotonic_now () >= deadline then raise (Process_error (timeout_error ()))
  in
  let remaining () = max 0. (deadline -. monotonic_now ()) in
  let wait_slice () = min 0.05 (remaining ()) in
  let rec reap ~bounded child =
    if not !reaped then
      try
        if bounded then check_deadline ();
        hooks.before_waitpid ();
        let _, status = Unix.waitpid [] child in
        reaped := true;
        if bounded then check_deadline ();
        status
      with Unix.Unix_error (Unix.EINTR, _, _) -> reap ~bounded child
         | Unix.Unix_error (Unix.ECHILD, _, _) ->
             reaped := true;
             Unix.WEXITED 127
    else Unix.WSIGNALED Sys.sigkill
  in
  let signal_owned_group child =
    let target = if !session_confirmed then -child else child in
    try Unix.kill target Sys.sigkill with Unix.Unix_error _ -> ()
  in
  let terminate_and_reap () =
    match !pid with
    | None -> ()
    | Some child when not !reaped ->
        signal_owned_group child;
        ignore (reap ~bounded:false child)
    | Some _ -> ()
  in
  let set_cause failure = if !cause = None then cause := Some failure in
  let pipe number =
    check_deadline ();
    hooks.before_pipe number;
    check_deadline ();
    let read_end, write_end = Unix.pipe ~cloexec:true () in
    (own read_end, own write_end)
  in
  let poll descriptors =
    check_deadline ();
    try
      let ready, _, _ = Unix.select descriptors [] [] (wait_slice ()) in
      check_deadline ();
      ready
    with Unix.Unix_error (Unix.EINTR, _, _) -> []
  in
  let rec await_exit child =
    check_deadline ();
    if waitid_exited_nowait child then check_deadline ()
    else begin ignore (poll []); await_exit child end
  in
  let status = ref None in
  (try
     if timeout < 0. || maximum < 0 then raise (Invalid_argument "process bounds");
     let stdout_read, stdout_write = pipe 1 in
     let stderr_read, stderr_write = pipe 2 in
     let ready_read, ready_write = pipe 3 in
     let ack_read, ack_write = pipe 4 in
     let input_pipe =
       Option.map (fun _ -> let read_end, write_end = pipe 5 in
                    (read_end, write_end)) input
     in
     let child = Unix.fork () in
     if child = 0 then begin
       try
         close_checked stdout_read; close_checked stderr_read;
         close_checked ready_read; close_checked ack_write;
         Option.iter (fun (_, write_end) -> close_checked write_end) input_pipe;
         if hooks.child_setup_delay > 0. then Unix.sleepf hooks.child_setup_delay;
         ignore (Unix.setsid ());
         let rec send_ready offset =
           if offset < 1 then
             try
               let count = Unix.write_substring ready_write "S" offset (1 - offset) in
               if count = 0 then raise End_of_file else send_ready (offset + count)
             with Unix.Unix_error (Unix.EINTR, _, _) -> send_ready offset
         in
         send_ready 0;
         let acknowledgement = Bytes.create 1 in
         let rec await_ack offset =
           if offset < 1 then
             try
               let count = Unix.read ack_read acknowledgement offset (1 - offset) in
               if count = 0 then raise End_of_file else await_ack (offset + count)
             with Unix.Unix_error (Unix.EINTR, _, _) -> await_ack offset
         in
         await_ack 0;
         if Bytes.get acknowledgement 0 <> 'A' then raise End_of_file;
         close_checked ready_write; close_checked ack_read;
         Option.iter
           (fun (read_end, _) ->
             Unix.dup2 read_end Unix.stdin;
             close_checked read_end)
           input_pipe;
         Unix.dup2 stdout_write Unix.stdout;
         Unix.dup2 stderr_write Unix.stderr;
         close_checked stdout_write; close_checked stderr_write;
         Unix.execve program arguments environment
       with _ -> Unix._exit 127
     end;
     pid := Some child;
     hooks.after_fork child;
     check_deadline ();
     close_checked ready_write; close_checked ack_read;
     close_checked stdout_write; close_checked stderr_write;
     Option.iter (fun (read_end, _) -> close_checked read_end) input_pipe;
     Unix.set_nonblock ready_read;
     Unix.set_nonblock ack_write;
     let marker = Bytes.create 1 in
     let rec await_session () =
       check_deadline ();
       if List.mem ready_read (poll [ ready_read ]) then begin
         hooks.after_readiness_selectable ();
         try
           match Unix.read ready_read marker 0 1 with
           | 1 when Bytes.get marker 0 = 'S' ->
               (* The child cannot execute before ACK, so the retained leader
                  PID can now safely anchor negative-PGID cleanup. *)
               session_confirmed := true
           | 0 -> raise (Process_error (unavailable_error ()))
           | _ -> await_session ()
         with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
           await_session ()
       end else await_session ()
     in
     await_session ();
     check_deadline ();
     close_checked ready_read;
     let rec send_ack offset =
       check_deadline ();
       if offset < 1 then
         try
           hooks.before_ack_write ();
           check_deadline ();
           let _, writable, _ =
             Unix.select [] [ ack_write ] [] (wait_slice ())
           in
           check_deadline ();
           if writable = [] then send_ack offset
           else
             let count = Unix.write_substring ack_write "A" offset (1 - offset) in
             if count = 0 then raise End_of_file else send_ack (offset + count)
         with
         | Unix.Unix_error
             ((Unix.EINTR | Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
             send_ack offset
     in
     send_ack 0;
     let ack_close_failure =
       try hooks.before_ack_close (); None with failure -> Some failure
     in
     close_checked ack_write;
     Option.iter raise ack_close_failure;
     check_deadline ();
     (try hooks.after_spawn child
      with failure ->
        ignore failure;
        if monotonic_now () >= deadline then
          raise (Process_error (timeout_error ()))
        else raise (Process_error (unavailable_error ())));
     check_deadline ();
     Unix.set_nonblock stdout_read; Unix.set_nonblock stderr_read;
     Option.iter (fun (_, write_end) -> Unix.set_nonblock write_end) input_pipe;
     let chunk = Bytes.create 65536 in
     let input_contents = Option.value input ~default:"" in
     let rec communicate open_reads input_open input_offset =
       check_deadline ();
       if open_reads = [] && not input_open then await_exit child
       else
           let write_descriptors =
             match input_pipe with
             | Some (_, write_end) when input_open -> [ write_end ]
             | _ -> []
           in
           let ready, writable, _ =
             try
               Unix.select open_reads write_descriptors [] (wait_slice ())
             with Unix.Unix_error (Unix.EINTR, _, _) -> [], [], []
           in
           check_deadline ();
           let input_open, input_offset =
             match input_pipe, write_descriptors with
             | Some (_, write_end), _ when input_open
                                         && List.mem write_end writable ->
                 (try
                    let remaining = String.length input_contents - input_offset in
                    let count =
                      Unix.write_substring write_end input_contents input_offset
                        remaining
                    in
                    let offset = input_offset + count in
                    if offset = String.length input_contents then begin
                      close write_end;
                      false, offset
                    end else true, offset
                  with
                  | Unix.Unix_error
                      ((Unix.EINTR | Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                      true, input_offset
                  | Unix.Unix_error (Unix.EPIPE, _, _) ->
                      close write_end;
                      false, input_offset)
             | _ -> input_open, input_offset
           in
           let read_one descriptor =
             if not (List.mem descriptor ready) then true
             else
               let destination = if descriptor = stdout_read then output else errors in
               try
                 match Unix.read descriptor chunk 0 (Bytes.length chunk) with
                 | 0 -> close descriptor; false
                 | count ->
                     if Buffer.length destination + count > maximum then
                       raise
                         (Process_error
                            { kind = Validation; code = "git_output_limit";
                              message = "Git output exceeded the safety limit.";
                               diagnostics = [] });
                     Buffer.add_subbytes destination chunk 0 count;
                     true
               with
               | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
                   true
           in
           communicate (List.filter read_one open_reads) input_open input_offset
     in
     let input_open =
       match input_pipe with
       | Some (_, write_end) when input_contents = "" -> close write_end; false
       | Some _ -> true
       | None -> false
     in
     communicate [ stdout_read; stderr_read ] input_open 0;
     (* Keep the unreaped leader as the process-group identity until every
        still-running descendant has received the terminal signal. *)
     signal_owned_group child;
     status := Some (reap ~bounded:true child)
   with
   | Process_error failure -> set_cause failure
   | _ ->
       if monotonic_now () >= deadline then set_cause (timeout_error ())
       else set_cause (unavailable_error ()));
  (match !cause with Some _ -> terminate_and_reap () | None -> ());
  close_all ();
  match !cause, !status with
  | Some failure, _ -> Error failure
  | None, Some status ->
      Ok { stdout = Buffer.contents output; stderr = Buffer.contents errors; status }
  | None, None -> Error (unavailable_error ())

let git_with ?(environment = safe_process_environment) ?(timeout = 30.)
    ?(hooks = default_process_hooks)
    ?(failure_kind = Transient) ?(failure_code = "git_failed") repo arguments maximum =
  let argv = Array.of_list ("git" :: "-C" :: repo :: arguments) in
  Result.bind
    (execute_process ~input:None ~environment ~program:"/usr/bin/git" ~arguments:argv
       ~maximum ~timeout ~hooks)
    (fun output ->
      match output.status with
      | Unix.WEXITED 0 -> Ok output.stdout
      | _ -> error failure_kind failure_code "Git operation failed.")

let git repo arguments maximum = git_with repo arguments maximum

let git_with_input repo arguments input maximum =
  let argv = Array.of_list ("git" :: "-C" :: repo :: arguments) in
  Result.bind
    (execute_process ~input:(Some input) ~environment:safe_process_environment
       ~program:"/usr/bin/git" ~arguments:argv ~maximum ~timeout:30.
       ~hooks:default_process_hooks)
    (fun output ->
      match output.status with
      | Unix.WEXITED 0 -> Ok output.stdout
      | _ -> error Transient "git_failed" "Git operation failed.")

type git_command_result = { output : string; succeeded : bool }

let git_status_with ?(environment = safe_process_environment) ?(timeout = 30.)
    repo arguments maximum =
  let argv = Array.of_list ("git" :: "-C" :: repo :: arguments) in
  Result.map
    (fun output ->
      { output = output.stdout;
        succeeded = output.status = Unix.WEXITED 0 })
    (execute_process ~input:None ~environment ~program:"/usr/bin/git" ~arguments:argv
       ~maximum ~timeout ~hooks:default_process_hooks)

let safe_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '_' | '-' | '.' | '+' -> true
  | _ -> false

let trusted_directory path =
  let stat = Unix.lstat path in
  let owner_ok = stat.st_uid = Unix.geteuid () || stat.st_uid = 0 in
  let writable = stat.st_perm land 0o022 <> 0 in
  let sticky_root = stat.st_uid = 0 && stat.st_perm land 0o1000 <> 0 in
  stat.st_kind = Unix.S_DIR && owner_ok && (not writable || sticky_root)

let trusted_amp_runtime ?(allow_loopback_amp_url = false) () =
  let unavailable () =
    error Authentication "git_auth_unavailable"
      "Authenticated Git access is unavailable."
  in
  match Sys.getenv_opt "AMP_BIN_DIR", Sys.getenv_opt "HOME",
        Sys.getenv_opt "AMP_API_KEY", Sys.getenv_opt "AMP_URL" with
  | Some bin_dir, Some home, Some api_key, Some amp_url ->
      (try
         if api_key = "" || Filename.is_relative bin_dir
            || Filename.is_relative home
            || bin_dir <> Filename.concat home ".amp/bin"
            || not (String.for_all safe_path_char bin_dir)
            || not (String.for_all safe_path_char home)
            || Unix.realpath bin_dir <> bin_dir || Unix.realpath home <> home
            || not (trusted_directory home) then raise Exit;
         Unix.access home [ Unix.W_OK; Unix.X_OK ];
         let helper = Filename.concat bin_dir "amp" in
         let helper_stat = Unix.lstat helper in
         if Unix.realpath helper <> helper
            || helper_stat.st_kind <> Unix.S_REG
            || (helper_stat.st_uid <> Unix.geteuid () && helper_stat.st_uid <> 0)
            || helper_stat.st_perm land 0o022 <> 0
            || helper_stat.st_perm land 0o111 = 0 then raise Exit;
         let rec validate_chain path =
           if path <> "/" then begin
             if not (trusted_directory path) then raise Exit;
             validate_chain (Filename.dirname path)
           end
         in
         validate_chain bin_dir;
         validate_chain home;
         let xdg_config_home = Filename.concat home ".config" in
         let config_exists =
           try ignore (Unix.lstat xdg_config_home); true
           with Unix.Unix_error (Unix.ENOENT, _, _) -> false
         in
         if config_exists then begin
           if Unix.realpath xdg_config_home <> xdg_config_home
              || not (trusted_directory xdg_config_home) then raise Exit;
           Unix.access xdg_config_home [ Unix.W_OK; Unix.X_OK ]
         end;
         let amp_url_ok =
           amp_url = "https://ampcode.com" || amp_url = "https://ampcode.com/"
           || (allow_loopback_amp_url
               && (String.starts_with ~prefix:"https://127.0.0.1:" amp_url
                   || String.starts_with ~prefix:"https://[::1]:" amp_url))
         in
         if not amp_url_ok || String.contains amp_url '\n'
            || String.contains amp_url '\r' then raise Exit;
         let environment =
           isolated_process_environment ~home ~xdg_config_home
             [ "AMP_API_KEY=" ^ api_key; "AMP_URL=" ^ amp_url ]
         in
         Ok (helper, environment)
       with _ -> unavailable ())
  | _ -> unavailable ()

let amp_remote source remote =
  String.starts_with ~prefix:"ampcode.com/" source
  && (remote = "https://" ^ source || remote = "https://" ^ source ^ ".git")

let dangerous_local_git_config repo =
  let* output = git repo [ "config"; "--local"; "--null"; "--list" ] (1024 * 1024) in
  let dangerous key =
    let key = String.lowercase_ascii key in
    String.starts_with ~prefix:"credential." key
    || String.starts_with ~prefix:"http." key
    || String.starts_with ~prefix:"url." key
    || String.starts_with ~prefix:"include." key
    || String.starts_with ~prefix:"includeif." key
    || key = "core.askpass" || key = "core.hookspath"
    || String.starts_with ~prefix:"remote.origin.proxy" key
    || key = "remote.origin.uploadpack"
  in
  let records = String.split_on_char '\000' output in
  let rec inspect = function
    | [] | [ "" ] -> Ok false
    | "" :: rest -> inspect rest
    | record :: rest ->
        (match String.index_opt record '\n' with
        | None -> error Validation "git_config_invalid"
                    "Repository Git configuration is invalid."
        | Some separator ->
            let key = String.sub record 0 separator in
            if dangerous key then Ok true else inspect rest)
  in
  inspect records

let amp_git ?(timeout = 30.) ?(allow_loopback_amp_url = false)
    repo remote arguments maximum =
  let* dangerous = dangerous_local_git_config repo in
  if dangerous then
    error Authentication "git_auth_config_unsafe"
      "Authenticated Git configuration is unsafe."
  else
    let* helper, environment =
      trusted_amp_runtime ~allow_loopback_amp_url ()
    in
    git_with ~environment ~timeout ~failure_kind:Authentication
      ~failure_code:"git_auth_failed" repo
      ([ "-c"; "credential.helper=";
         "-c"; "credential.helper=!" ^ helper ^ " git-credential-helper";
         "-c"; "credential.https://ampcode.com.useHttpPath=true";
         "-c"; "core.hooksPath=/dev/null";
         "-c"; "core.askPass=/bin/false";
         "-c"; "credential.interactive=false" ] @ arguments remote)
      maximum

let origin_urls repo =
  let split output =
    output |> String.split_on_char '\n'
    |> List.filter_map (fun value ->
           let value = String.trim value in
           if value = "" then None else Some value)
  in
  let* fetch = git repo [ "remote"; "get-url"; "--all"; "--"; "origin" ] 16384 in
  let* push =
    git repo [ "remote"; "get-url"; "--push"; "--all"; "--"; "origin" ]
      16384
  in
  Ok (split fetch, split push)

let remote_git_status ?(timeout = 30.) repo source remote arguments maximum =
  if not (amp_remote source remote) then
    git_status_with ~timeout repo (arguments remote) maximum
  else
    let* dangerous = dangerous_local_git_config repo in
    if dangerous then
      error Authentication "git_auth_config_unsafe"
        "Authenticated Git configuration is unsafe."
    else
      let* helper, environment = trusted_amp_runtime () in
      git_status_with ~environment ~timeout repo
        ([ "-c"; "credential.helper=";
           "-c"; "credential.helper=!" ^ helper ^ " git-credential-helper";
           "-c"; "credential.https://ampcode.com.useHttpPath=true";
           "-c"; "core.hooksPath=/dev/null";
           "-c"; "core.askPass=/bin/false";
           "-c"; "credential.interactive=false" ] @ arguments remote)
        maximum

let fetch_origin_main ?(force = true) repo source maximum =
  let* fetch_urls, _ = origin_urls repo in
  match fetch_urls with
  | [ remote ] ->
      let refspec =
        (if force then "+" else "")
        ^ "refs/heads/main:refs/remotes/origin/main"
      in
      let* result =
        remote_git_status repo source remote
          (fun target ->
            [ "fetch"; "--quiet"; "--no-tags"; "--no-auto-maintenance";
              "--recurse-submodules=no"; target; refspec ])
          maximum
      in
      if result.succeeded then Ok ()
      else if amp_remote source remote then
        error Authentication "git_auth_failed"
          "Authenticated Git operation failed."
      else error Transient "git_failed" "Git operation failed."
  | _ ->
      error Validation "git_remote_invalid"
        "The origin fetch remote must be exactly one URL."

let push_origin repo source refspec maximum =
  let* fetch_urls, push_urls = origin_urls repo in
  match fetch_urls, push_urls with
  | [ remote ], [ push_remote ] when remote = push_remote ->
      remote_git_status repo source remote
        (fun target ->
          [ "push"; "--porcelain"; "--no-verify"; target; refspec ])
        maximum
  | _ ->
      error Validation "git_remote_invalid"
        "The origin fetch and push remote must be one identical URL."

let valid_sha value =
  String.length value = 40
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let remote_branch_status repo source branch maximum =
  let refname = "refs/heads/" ^ branch in
  let valid_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '_' | '-' -> true
    | _ -> false
  in
  if branch = "" || String.starts_with ~prefix:"/" branch
     || String.ends_with ~suffix:"/" branch
     || not (String.for_all valid_character branch)
  then
    error Validation "git_remote_ref_invalid"
      "The remote branch name is invalid."
  else
    let* fetch_urls, _ = origin_urls repo in
    match fetch_urls with
    | [ remote ] ->
        let* result =
          remote_git_status repo source remote
            (fun target ->
              [ "ls-remote"; "--heads"; target; refname ])
            maximum
        in
        if not result.succeeded then
          if amp_remote source remote then
            error Authentication "git_auth_failed"
              "Authenticated Git operation failed."
          else
            error Transient "git_remote_ref_unavailable"
              "The remote branch could not be verified."
        else
          (match String.split_on_char '\n' result.output with
          | [ "" ] -> Ok None
          | [ record; "" ] | [ record ] ->
              (match String.split_on_char '\t' record with
              | [ commit; observed ] when valid_sha commit && observed = refname ->
                  Ok (Some commit)
              | _ ->
                  error Transient "git_remote_ref_invalid"
                    "The remote branch did not resolve safely.")
          | _ ->
              error Transient "git_remote_ref_invalid"
                "The remote branch did not resolve safely.")
    | _ ->
        error Validation "git_remote_invalid"
          "The origin fetch remote must be exactly one URL."

let authenticated_fetch repo source maximum =
  fetch_origin_main repo source maximum

let local_origin_main_with ?(timeout = 30.) ?(hooks = default_process_hooks) repo =
  Result.bind
    (git_with ~timeout ~hooks repo
       [ "rev-parse"; "--verify"; "refs/remotes/origin/main^{commit}" ] 128)
    (fun output ->
      let commit = String.trim output in
      if valid_sha commit then Ok commit
      else error Transient "git_target_invalid"
             "The local origin/main ref did not resolve to a commit.")

let local_origin_main ?timeout repo = local_origin_main_with ?timeout repo

let fetch_target repo source requested =
  let requested_valid = Option.for_all valid_sha requested in
  if not requested_valid then
    error Validation "sync_target_invalid" "Requested commit SHA is invalid."
  else Result.bind
    (authenticated_fetch repo source (1024 * 1024))
    (fun _ ->
      Result.bind
        (git repo [ "rev-parse"; "--verify"; "refs/remotes/origin/main^{commit}" ] 128)
        (fun output ->
          let commit = String.trim output in
          if not (valid_sha commit) then
            error Transient "git_target_invalid" "origin/main did not resolve to a commit."
          else
            match requested with
            | Some expected when expected <> commit ->
                error Validation "sync_target_mismatch"
                  "Requested commit is not the fetched origin/main tip."
            | _ -> Ok commit))

type tree_entry = { path : string; blob_hash : string; mode : string }

let parse_tree output =
  let records = String.split_on_char '\000' output in
  let parse record =
    if record = "" then Ok None
    else
      match String.index_opt record '\t' with
      | None -> error Validation "git_tree_invalid" "Git tree output was invalid."
      | Some tab ->
          let header = String.sub record 0 tab |> String.split_on_char ' ' in
          let path = String.sub record (tab + 1) (String.length record - tab - 1) in
          (match header with
          | [ mode; "blob"; blob_hash ] when valid_sha blob_hash ->
              Ok (Some { path; blob_hash; mode })
          | _ -> error Validation "git_tree_invalid" "Git tree contains an unsupported entry.")
  in
  List.fold_left
    (fun accumulated record ->
      Result.bind accumulated (fun values ->
          Result.map (function None -> values | Some value -> value :: values)
            (parse record)))
    (Ok []) records
  |> Result.map (List.sort (fun left right -> String.compare left.path right.path))

let tree repo commit =
  Result.bind
    (git repo [ "ls-tree"; "-r"; "-z"; "--full-tree"; commit; "--"; "knowledge" ]
       maximum_git_output)
    parse_tree

let parse_knowledge_root output =
      match String.split_on_char '\000' output with
      | [ "" ] -> Ok ()
      | [ record; "" ] ->
          (match String.index_opt record '\t' with
          | None ->
              error Validation "git_tree_invalid"
                "Git tree output was invalid."
          | Some tab ->
              let header =
                String.sub record 0 tab |> String.split_on_char ' '
              in
              let path =
                String.sub record (tab + 1) (String.length record - tab - 1)
              in
              let valid_mode mode =
                String.length mode = 6
                && String.for_all (fun value -> value >= '0' && value <= '7') mode
              in
              let valid_kind kind =
                kind <> ""
                && String.for_all (fun value -> value >= 'a' && value <= 'z') kind
              in
              (match header with
              | [ "040000"; "tree"; hash ]
                when path = "knowledge" && valid_sha hash -> Ok ()
              | [ (("100644" | "100755" | "120000") as mode); "blob"; hash ]
                when path = "knowledge" && valid_mode mode && valid_sha hash ->
                  error Validation "knowledge_not_directory"
                    "The target Git knowledge entry must be a directory."
              | [ "160000"; "commit"; hash ]
                when path = "knowledge" && valid_sha hash ->
                  error Validation "knowledge_not_directory"
                    "The target Git knowledge entry must be a directory."
              | [ mode; kind; hash ]
                when path = "knowledge" && valid_mode mode && valid_sha hash
                     && valid_kind kind ->
                  error Validation "git_tree_invalid"
                    "Git tree output was invalid."
              | _ ->
                  error Validation "git_tree_invalid"
                    "Git tree output was invalid."))
      | _ ->
          error Validation "git_tree_invalid"
            "Git tree output contained multiple root entries."

let knowledge_root repo commit =
  Result.bind
    (git repo [ "ls-tree"; "-z"; "--full-tree"; commit; "--"; "knowledge" ]
       1024)
    parse_knowledge_root

let require_sha1_repository repo =
  Result.bind (git repo [ "rev-parse"; "--show-object-format" ] 32)
    (fun output ->
      if String.trim output = "sha1" then Ok ()
      else
        error Validation "git_object_format_unsupported"
          "Clamp v1 synchronization requires a SHA-1 Git repository.")

let validate_tree_paths entries =
  let markdown =
    List.filter
      (fun (entry : tree_entry) -> String.ends_with ~suffix:".md" entry.path)
      entries
  in
  if List.length markdown > Limits.max_markdown_files then
    error Validation "markdown_file_limit"
      "Git tree exceeds the Markdown-file safety limit."
  else
    let exact_by_folded = Hashtbl.create (List.length markdown * 2) in
    let rec register_prefix parent = function
      | [] -> Ok ()
      | component :: rest ->
          if not (Concept.portable_component component) then
            error Validation "path_component_invalid"
              "Git knowledge path contains a non-UTF-8, non-portable, or URI-unsafe component."
          else
            let exact = if parent = "" then component else parent ^ "/" ^ component in
            let folded = String.lowercase_ascii exact in
            (match Hashtbl.find_opt exact_by_folded folded with
            | Some existing when existing <> exact ->
                error Validation "path_duplicate"
                  "Git knowledge path collides case-insensitively."
            | _ ->
                Hashtbl.replace exact_by_folded folded exact;
                register_prefix exact rest)
    in
    let rec register = function
      | [] -> Ok ()
      | (entry : tree_entry) :: rest ->
          Result.bind
            (register_prefix "" (String.split_on_char '/' entry.path))
            (fun () -> register rest)
    in
    register entries

let read_blob repo entry ~maximum ~limit_code ~limit_message =
  Result.bind (git repo [ "cat-file"; "-s"; entry.blob_hash ] 64) (fun size ->
      match int_of_string_opt (String.trim size) with
      | Some size when size > maximum ->
          error Validation limit_code limit_message
      | Some size when size >= 0 ->
          git repo [ "cat-file"; "blob"; entry.blob_hash ] maximum
      | _ ->
          error Validation "git_object_invalid"
            "Git reported an invalid object size.")

let config_at_commit repo commit =
  Result.bind
    (git repo [ "ls-tree"; "-z"; commit; "--"; "clamp.yaml" ] 1024)
    (fun output ->
      Result.bind (parse_tree output) (function
          | [ entry ] when entry.path = "clamp.yaml"
                           && (entry.mode = "100644" || entry.mode = "100755") ->
              Result.bind
                (read_blob repo entry ~maximum:Limits.max_file_bytes
                   ~limit_code:"config_file_size_limit"
                   ~limit_message:"Fetched clamp.yaml exceeds the 8 MiB safety limit.")
                (fun contents -> Ok contents)
          | [] ->
              error Validation "source_repository_missing"
                "Fetched clamp.yaml must configure source_repository."
          | _ ->
              error Validation "config_invalid"
                "Fetched clamp.yaml is not a regular root file."))

let source_repository_at_commit repo commit =
  Result.bind (config_at_commit repo commit) (fun contents ->
      match Config.source_repository contents with
      | Ok source ->
          (match Config.validate contents with
          | Ok () -> Ok source
          | Error _ ->
              error Validation "config_invalid"
                "Fetched clamp.yaml is invalid or incompatible.")
      | Error "source_repository_missing" ->
          error Validation "source_repository_missing"
            "Fetched clamp.yaml must configure source_repository."
      | Error _ ->
          error Validation "source_repository_invalid"
            "Fetched clamp.yaml source_repository is invalid.")

let local_config_at_commit repo commit =
  if valid_sha commit then
    Result.bind (config_at_commit repo commit) (fun contents ->
        match Config.validate contents with
        | Ok () -> Ok contents
        | Error _ ->
            error Validation "config_invalid"
              "Fetched clamp.yaml is invalid or incompatible.")
  else error Validation "git_target_invalid" "Local target commit SHA is invalid."

let basename path =
  match String.rindex_opt path '/' with
  | None -> path
  | Some index -> String.sub path (index + 1) (String.length path - index - 1)

let concept_id path =
  let prefix = "knowledge/" in
  if not (String.starts_with ~prefix path && String.ends_with ~suffix:".md" path)
  then None
  else
    Some
      (String.sub path (String.length prefix)
         (String.length path - String.length prefix - 3))

let reserved_name name =
  let lowered = String.lowercase_ascii name in
  lowered = "index.md" || lowered = "log.md"

let load_reserved_documents repo entries =
  let reserved =
    List.filter (fun entry -> reserved_name (basename entry.path)) entries
  in
  let rec load link_count sources = function
    | [] -> Ok (link_count, List.rev sources)
    | entry :: rest ->
        let name = basename entry.path in
        if name <> "index.md" && name <> "log.md" then
          error Validation "reserved_name_noncanonical"
            "A reserved Git document name has noncanonical case."
        else
          Result.bind
            (read_blob repo entry ~maximum:Limits.max_file_bytes
               ~limit_code:"reserved_size_limit"
               ~limit_message:"A reserved Git document exceeds the 8 MiB safety limit.")
            (fun contents ->
              let prefix = "knowledge/" in
              let relative =
                String.sub entry.path (String.length prefix)
                  (String.length entry.path - String.length prefix)
              in
              let validation = Bundle.validate_reserved_document ~relative contents in
              match validation.issues with
              | (code, message) :: _ -> error Validation code message
              | [] ->
                  let remaining = Limits.max_markdown_links - link_count in
                  let links, truncated =
                    Markdown_links.extract_bounded ~limit:(remaining + 1)
                      validation.body
                  in
                  let count = List.length links in
                  if remaining < 0 || truncated || count > remaining then
                    error Validation "markdown_link_limit"
                      "Git bundle exceeds the Markdown-link safety limit."
                  else
                    let source =
                      { Bundle.source_id =
                          String.sub relative 0 (String.length relative - 3);
                        relative; type_name = None; links }
                    in
                    load (link_count + count) (source :: sources) rest)
  in
  load 0 [] reserved

let scalar = function Scalar (String, value) -> Some value | _ -> None
let field name metadata = Exact_yaml.find name metadata

let json_of_yaml value =
  let rec convert = function
    | Scalar (String, value) | Scalar (Plain, value) -> Ok (`String value)
    | Scalar (Integer, value) ->
        Result.map (fun canonical -> `Intlit canonical)
          (Exact_yaml.canonical_number Integer value)
    | Scalar (Float, value) ->
        Result.map (fun canonical -> `Floatlit canonical)
          (Exact_yaml.canonical_number Float value)
    | Scalar (Bool, value) ->
        Ok (`Bool (List.mem (String.lowercase_ascii value) [ "true"; "yes"; "y"; "on" ]))
    | Scalar (Null, _) -> Ok `Null
    | Seq values ->
        List.fold_left
          (fun accumulated item ->
            Result.bind accumulated (fun converted ->
                Result.map (fun value -> value :: converted) (convert item)))
          (Ok []) values
        |> Result.map (fun values -> `List (List.rev values))
    | Map fields ->
        List.fold_left
          (fun accumulated (name, item) ->
            Result.bind accumulated (fun converted ->
                Result.map (fun value -> (name, value) :: converted) (convert item)))
          (Ok []) fields
        |> Result.map (fun fields -> `Assoc (List.rev fields))
  in
  convert value

let option_field name metadata = Option.bind (field name metadata) scalar

type indexed_concept = {
  path : string;
  blob_hash : string;
  parsed : Frontmatter.t;
  embedding_input : Embedding_input.t;
  concept_type : string;
  title : string option;
  description : string option;
  tags : string list;
  status : string;
  stale_after : string option;
  generated_by : string option;
  generated_at : string option;
  asserted_by : string option;
  verified_tier : string;
  task_state : string option;
  task_priority : string option;
  task_due_on : string option;
  task_due_at : string option;
  task_completed_at : string option;
  frontmatter_json : string;
}

let parse_concept path blob_hash contents =
  let id = Option.get (concept_id path) in
  if String.length contents > Limits.max_file_bytes then
    error Validation "concept_size_limit" "A Git concept exceeds the 8 MiB safety limit."
  else if not (Concept.concept_id id) then
    error Validation "concept_id_invalid" "A Git concept path is invalid."
  else
    match Frontmatter.parse contents with
    | Error _ -> error Validation "frontmatter_invalid" "A Git concept has invalid frontmatter."
    | Ok parsed ->
        (match Concept.validate parsed.metadata with
        | (field, _) :: _ ->
            error Validation "metadata_invalid"
              (Printf.sprintf "A Git concept has invalid metadata field %s." field)
        | [] ->
            match json_of_yaml parsed.metadata with
            | Error failure ->
                error Validation (Exact_yaml.numeric_error_code failure)
                  (Exact_yaml.numeric_error_message failure ^ ".")
            | Ok frontmatter_json -> match Embedding_input.make parsed with
            | Error failure ->
                error Validation (Embedding_input.error_code failure)
                  (Embedding_input.error_message failure)
            | Ok embedding_input ->
                let projection = Concept.index_projection parsed.metadata in
                Ok
                  { path = id; blob_hash; parsed; embedding_input;
                    concept_type = projection.concept_type;
                    title = projection.title;
                    description = projection.description;
                    tags = projection.tags; status = projection.status;
                    stale_after = projection.stale_after;
                    generated_by = projection.generated_by;
                    generated_at = projection.generated_at;
                    asserted_by = projection.asserted_by;
                    verified_tier = projection.verified_tier;
                    task_state = projection.task_state;
                    task_priority = projection.task_priority;
                    task_due_on = projection.task_due_on;
                    task_due_at = projection.task_due_at;
                    task_completed_at = projection.task_completed_at;
                    frontmatter_json = Yojson.to_string frontmatter_json })

let load_concepts repo entries =
  match
    List.find_opt
      (fun (entry : tree_entry) -> entry.mode <> "100644" && entry.mode <> "100755")
      entries
  with
  | Some _ ->
      error Validation "concept_not_regular"
        "The Git knowledge tree contains a non-regular entry."
  | None ->
  let markdown =
    List.filter
      (fun (entry : tree_entry) -> String.ends_with ~suffix:".md" entry.path)
      entries
  in
  if List.length markdown > Limits.max_markdown_files then
    error Validation "markdown_file_limit" "Git tree exceeds the Markdown-file safety limit."
  else
    List.fold_left
      (fun accumulated (entry : tree_entry) ->
        Result.bind accumulated (fun concepts ->
            let name = basename entry.path in
            if reserved_name name then
              if name = "index.md" || name = "log.md" then Ok concepts
              else
                error Validation "reserved_name_noncanonical"
                  "A reserved Git document name has noncanonical case."
            else
              match concept_id entry.path with
              | None -> Ok concepts
              | Some _ ->
                  Result.bind (git repo [ "cat-file"; "-s"; entry.blob_hash ] 64)
                    (fun size ->
                      match int_of_string_opt (String.trim size) with
                      | Some size when size > Limits.max_file_bytes ->
                          error Validation "concept_size_limit"
                            "A Git concept exceeds the 8 MiB safety limit."
                      | Some size when size >= 0 ->
                          Result.bind
                            (git repo [ "cat-file"; "blob"; entry.blob_hash ]
                               Limits.max_file_bytes)
                            (fun contents ->
                              Result.map (fun concept -> concept :: concepts)
                                (parse_concept entry.path entry.blob_hash contents))
                      | _ ->
                          error Validation "git_object_invalid"
                            "Git reported an invalid concept object size.")))
      (Ok []) markdown
    |> Result.map (List.sort (fun left right -> String.compare left.path right.path))

let validate_concept_set ~initial_link_count concepts =
  let ids = Hashtbl.create (List.length concepts) in
  let folded = Hashtbl.create (List.length concepts) in
  let fail code message = error Validation code message in
  let has_prefix prefix id =
    id = prefix || String.starts_with ~prefix:(prefix ^ "/") id
  in
  let task_path id =
    match String.split_on_char '/' id with
    | [ "tasks"; name ] ->
        (match String.index_opt name '-' with
        | Some 26 ->
            Bundle.ulid (String.sub name 0 26)
            && String.length name > 27
            && Str.string_match
                 (Str.regexp {|^[a-z0-9]+\(-[a-z0-9]+\)*$|})
                 (String.sub name 27 (String.length name - 27)) 0
        | _ -> false)
    | _ -> false
  in
  let journal_path id concept_type =
    match String.split_on_char '/' id with
    | [ "journal"; year; day ] ->
        String.length year = 4 && String.starts_with ~prefix:(year ^ "-") day
        && Concept.date day && concept_type = "journal"
    | _ -> false
  in
  let rec register = function
    | [] -> Ok ()
    | concept :: rest ->
        let lower = String.lowercase_ascii concept.path in
        if Hashtbl.mem folded lower then
          fail "concept_id_collision" "Git concept IDs collide under case folding."
        else begin
          Hashtbl.add folded lower ();
          Hashtbl.add ids concept.path ();
          let is_task_path = has_prefix "tasks" concept.path in
          let is_journal_path = has_prefix "journal" concept.path in
          if (is_task_path && not (task_path concept.path
                                   && concept.concept_type = "task"))
             || (not is_task_path && concept.concept_type = "task")
          then fail "task_path_invalid" "A Git task concept has an invalid path."
          else if
            (is_journal_path && not (journal_path concept.path concept.concept_type))
            || (not is_journal_path && concept.concept_type = "journal")
          then fail "journal_path_invalid" "A Git journal concept has an invalid path."
          else register rest
        end
  in
  let references concept =
    let metadata = concept.parsed.metadata in
    let clamp = field "clamp" metadata in
    let superseded = Option.bind clamp (option_field "superseded_by") in
    let dependencies =
      match
        Option.bind (Option.bind clamp (field "task")) (field "depends_on")
      with
      | Some (Seq values) -> List.filter_map scalar values
      | _ -> []
    in
    Option.to_list superseded @ dependencies
  in
  let rec validate_references = function
    | [] -> Ok ()
    | concept :: rest ->
        if List.exists (String.equal concept.path) (references concept) then
          fail "reference_self" "A Git concept references itself as a lifecycle relation."
        else if List.exists (fun target -> not (Hashtbl.mem ids target)) (references concept)
        then fail "reference_unresolved" "A Git concept lifecycle reference is unresolved."
        else validate_references rest
  in
  let rec validate_links count = function
    | [] -> Ok ()
    | concept :: rest ->
        let remaining = Limits.max_markdown_links - count in
        if remaining < 0 then fail "markdown_link_limit" "Git concepts exceed the Markdown-link safety limit."
        else
          let links, truncated =
            Markdown_links.extract_bounded ~limit:(remaining + 1) concept.parsed.body
          in
          if truncated || List.length links > remaining then
            fail "markdown_link_limit" "Git concepts exceed the Markdown-link safety limit."
          else validate_links (count + List.length links) rest
  in
  let* () = register concepts in
  let* () = validate_references concepts in
  validate_links initial_link_count concepts

type existing = {
  existing_path : string;
  existing_blob : string;
  existing_input : string;
  existing_model : string;
}

let existing_rows result =
  try
    Ok
      (List.init result#ntuples (fun row ->
           { existing_path = result#getvalue row 0;
             existing_blob = result#getvalue row 1;
             existing_input = result#getvalue row 2;
             existing_model = result#getvalue row 3 }))
  with _ -> error Internal "database_row_invalid" "Database returned an invalid concept row."

type update = Add of indexed_concept | Metadata of indexed_concept
            | Embed of indexed_concept | Unchanged

let vector_text values =
  let buffer = Buffer.create (Array.length values * 4) in
  Buffer.add_char buffer '[';
  Array.iteri
    (fun index value ->
      if index > 0 then Buffer.add_char buffer ',';
      Buffer.add_string buffer (Printf.sprintf "%.17g" value))
    values;
  Buffer.add_char buffer ']';
  Buffer.contents buffer

let nullable = function
  | None -> "null"
  | Some value -> Yojson.Safe.to_string (`String value)

let array_text values =
  let escape value =
    let buffer = Buffer.create (String.length value + 4) in
    String.iter
      (fun character ->
        if character = '\\' || character = '\"' then Buffer.add_char buffer '\\';
        Buffer.add_char buffer character)
      value;
    "\"" ^ Buffer.contents buffer ^ "\""
  in
  "{" ^ String.concat "," (List.map escape values) ^ "}"

let metadata_params concept =
  [| concept.path; concept.blob_hash; concept.embedding_input.sha256;
     concept.concept_type; nullable concept.title; nullable concept.description;
     array_text concept.tags; concept.parsed.body; concept.frontmatter_json;
     concept.status; nullable concept.stale_after; nullable concept.generated_by;
     nullable concept.generated_at; nullable concept.asserted_by;
     concept.verified_tier; nullable concept.task_state;
     nullable concept.task_priority; nullable concept.task_due_on;
     nullable concept.task_due_at; nullable concept.task_completed_at;
     Openrouter.canonical_identity |]

let metadata_sql =
  "UPDATE public.concepts SET blob_hash=$2,embedding_input_hash=$3,type=$4,title=($5::jsonb #>> '{}'),description=($6::jsonb #>> '{}'),tags=$7::text[],body=$8,frontmatter=$9::jsonb,status=$10,stale_after=($11::jsonb #>> '{}')::date,generated_by=($12::jsonb #>> '{}'),generated_at=($13::jsonb #>> '{}')::timestamptz,asserted_by=($14::jsonb #>> '{}'),verified_tier=$15,task_state=($16::jsonb #>> '{}'),task_priority=($17::jsonb #>> '{}'),task_due_on=($18::jsonb #>> '{}')::date,task_due_at=($19::jsonb #>> '{}')::timestamptz,task_completed_at=($20::jsonb #>> '{}')::timestamptz,embedding_model=$21,indexed_at=pg_catalog.now() WHERE path=$1"

let upsert_sql =
  "INSERT INTO public.concepts(path,blob_hash,embedding_input_hash,type,title,description,tags,body,frontmatter,status,stale_after,generated_by,generated_at,asserted_by,verified_tier,task_state,task_priority,task_due_on,task_due_at,task_completed_at,embedding_model,embedding,indexed_at) VALUES ($1,$2,$3,$4,($5::jsonb #>> '{}'),($6::jsonb #>> '{}'),$7::text[],$8,$9::jsonb,$10,($11::jsonb #>> '{}')::date,($12::jsonb #>> '{}'),($13::jsonb #>> '{}')::timestamptz,($14::jsonb #>> '{}'),$15,($16::jsonb #>> '{}'),($17::jsonb #>> '{}'),($18::jsonb #>> '{}')::date,($19::jsonb #>> '{}')::timestamptz,($20::jsonb #>> '{}')::timestamptz,$21,$22::vector,pg_catalog.now()) ON CONFLICT(path) DO UPDATE SET blob_hash=excluded.blob_hash,embedding_input_hash=excluded.embedding_input_hash,type=excluded.type,title=excluded.title,description=excluded.description,tags=excluded.tags,body=excluded.body,frontmatter=excluded.frontmatter,status=excluded.status,stale_after=excluded.stale_after,generated_by=excluded.generated_by,generated_at=excluded.generated_at,asserted_by=excluded.asserted_by,verified_tier=excluded.verified_tier,task_state=excluded.task_state,task_priority=excluded.task_priority,task_due_on=excluded.task_due_on,task_due_at=excluded.task_due_at,task_completed_at=excluded.task_completed_at,embedding_model=excluded.embedding_model,embedding=excluded.embedding,indexed_at=excluded.indexed_at"

let bounded_query connection ?params sql =
  Database.For_sync.transaction connection ~statement_timeout_ms:5000
    (fun connection ->
      Database.For_sync.execute connection ~expect:[ Postgresql.Tuples_ok ] ?params sql)

let try_lock connection source =
  let rec attempt remaining =
    bind_database
      (bounded_query connection ~params:[| source |]
         "SELECT pg_catalog.pg_try_advisory_lock(pg_catalog.hashtextextended($1,0))")
      (fun result ->
        if result#ntuples = 1 && result#getvalue 0 0 = "t" then Ok ()
        else if remaining = 0 then
          error Transient "sync_already_running" "Another synchronization is already running."
        else (Unix.sleepf 0.05; attempt (remaining - 1)))
  in
  attempt 10

let unlock connection source =
  ignore
    (bounded_query connection ~params:[| source |]
       "SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtextextended($1,0))")

let precheck_index_state connection =
  let* state_result =
    db
      (bounded_query connection
         "SELECT source_repository,source_ref,last_indexed_commit,embedding_model,embedding_dimensions,last_indexed_at FROM public.index_state WHERE id=1")
  in
  let* state = db (Database.index_state_row state_result) in
  match state with
  | Some _ -> Ok ()
  | None ->
      let* count =
        db
          (bounded_query connection "SELECT count(*) FROM public.concepts")
      in
      if count#ntuples = 1 && count#getvalue 0 0 = "0" then Ok ()
      else
        error Validation "index_state_missing"
          "Index identity is missing while derived concepts exist; an operator must intentionally clear the derived index before rebuilding."

let run_locked ~repo ~connection ~embed ~reembed ~allow_mass_deletion
    ~target_commit source =
  let* () = require_sha1_repository repo in
  let* commit = fetch_target repo source target_commit in
  let* fetched_source = source_repository_at_commit repo commit in
  let* () =
    if fetched_source = source then Ok ()
    else
      error Validation "source_repository_mismatch"
        "Fetched repository identity does not match the configured identity."
  in
  let* state_result =
    db
      (bounded_query connection
         "SELECT source_repository,source_ref,last_indexed_commit,embedding_model,embedding_dimensions,last_indexed_at FROM public.index_state WHERE id=1")
  in
  let* state = db (Database.index_state_row state_result) in
  let* () =
    match state with
    | Some row
      when row.source_repository <> source
           || row.source_repository <> fetched_source
           || row.source_ref <> "refs/heads/main" ->
        error Validation "source_repository_mismatch"
          "Configured repository identity does not match the index."
    | _ -> Ok ()
  in
  let* () = knowledge_root repo commit in
  let* entries = tree repo commit in
  let* () = validate_tree_paths entries in
  let* reserved_link_count, reserved_warning_sources =
    load_reserved_documents repo entries
  in
  let* concepts = load_concepts repo entries in
  let* () = validate_concept_set ~initial_link_count:reserved_link_count concepts in
  let warning_sources =
    reserved_warning_sources
    @ List.map
        (fun concept ->
          { Bundle.source_id = concept.path;
            relative = concept.path ^ ".md";
            type_name = Some concept.concept_type;
            links = Markdown_links.extract concept.parsed.body })
        concepts
  in
  let diagnostic_collector = Diagnostic.Collector.create () in
  let warning_diagnostics =
    Bundle.warning_diagnostics
      ~concept_ids:(List.map (fun concept -> concept.path) concepts)
      warning_sources
  in
  List.iter (Diagnostic.Collector.add diagnostic_collector) warning_diagnostics;
  let diagnostics = Diagnostic.Collector.diagnostics diagnostic_collector in
  let* () =
    if Diagnostic.Collector.exceeded diagnostic_collector then
      error ~diagnostics Validation "diagnostic_limit"
        "Git bundle exceeds the 1,000-diagnostic safety limit."
    else Ok ()
  in
  let* existing_result =
    db
      (bounded_query connection
         "SELECT path,blob_hash,embedding_input_hash,embedding_model FROM public.concepts ORDER BY path")
  in
  let* existing = existing_rows existing_result in
  let* () =
    if state = None && existing <> [] then
      error Validation "index_state_missing"
        "Index identity is missing while derived concepts exist; an operator must intentionally clear the derived index before rebuilding."
    else Ok ()
  in
  let existing_table = Hashtbl.create (List.length existing) in
  List.iter (fun row -> Hashtbl.add existing_table row.existing_path row) existing;
  let target_paths = Hashtbl.create (List.length concepts) in
  List.iter (fun concept -> Hashtbl.add target_paths concept.path ()) concepts;
  let deletes =
    List.filter (fun row -> not (Hashtbl.mem target_paths row.existing_path)) existing
  in
  let deletion_count = List.length deletes and existing_count = List.length existing in
  let* () =
    if not allow_mass_deletion && existing_count > 0
       && (concepts = [] || (deletion_count >= 10 && deletion_count * 2 > existing_count))
    then
      error Validation "mass_deletion_requires_approval"
        "Synchronization would delete a protected portion of the index."
    else Ok ()
  in
  let incompatible =
    match state with
    | Some row ->
        row.embedding_model <> Openrouter.canonical_identity
        || row.embedding_dimensions <> Openrouter.dimensions
    | None -> false
  in
  let plan =
    List.map
      (fun concept ->
        match Hashtbl.find_opt existing_table concept.path with
        | None -> Add concept
        | Some old
          when reembed || incompatible
               || old.existing_model <> Openrouter.canonical_identity
               || old.existing_input <> concept.embedding_input.sha256 ->
            Embed concept
        | Some old when old.existing_blob <> concept.blob_hash -> Metadata concept
        | Some _ -> Unchanged)
      concepts
  in
  let rec obtain accumulated = function
    | [] -> Ok (List.rev accumulated)
    | (Add concept | Embed concept) as action :: rest ->
        let* vector = embed concept.embedding_input.text in
        if Array.length vector <> Openrouter.dimensions
           || Array.exists (fun value -> not (Float.is_finite value)) vector
        then
          error Validation "embedding_dimensions_invalid"
            "Embedding fixture returned incompatible dimensions."
        else obtain ((action, Some (vector_text vector)) :: accumulated) rest
    | action :: rest -> obtain ((action, None) :: accumulated) rest
  in
  let* prepared = obtain [] plan in
  let apply connection =
    Result.bind
      (Database.For_sync.execute connection
         ~params:[| source; Openrouter.canonical_identity;
                    string_of_int Openrouter.dimensions |]
         "INSERT INTO public.index_state(id,source_repository,source_ref,embedding_model,embedding_dimensions) VALUES (1,$1,'refs/heads/main',$2,$3::int4) ON CONFLICT(id) DO NOTHING")
      (fun _ ->
        Result.bind
          (Database.For_sync.execute connection ~expect:[ Postgresql.Tuples_ok ]
             "SELECT source_repository,source_ref FROM public.index_state WHERE id=1 FOR UPDATE")
          (fun identity ->
            if identity#ntuples <> 1 || identity#getvalue 0 0 <> source
               || identity#getvalue 0 1 <> "refs/heads/main"
            then
              Error
                { Database.kind = Validation; code = "source_repository_mismatch";
                  message = "Configured repository identity does not match the index.";
                  finalization = Before_commit_dispatch }
            else
              let rec updates = function
                | [] -> Ok ()
                | (Unchanged, _) :: rest -> updates rest
                | (Metadata concept, _) :: rest ->
                    Result.bind
                      (Database.For_sync.execute connection
                         ~params:(metadata_params concept) metadata_sql)
                      (fun _ -> updates rest)
                | ((Add concept | Embed concept), Some vector) :: rest ->
                    let params = Array.append (metadata_params concept) [| vector |] in
                    Result.bind
                      (Database.For_sync.execute connection ~params upsert_sql)
                      (fun _ -> updates rest)
                | _ ->
                    Error
                      { Database.kind = Internal; code = "sync_plan_invalid";
                        message = "Synchronization plan was invalid.";
                        finalization = Before_commit_dispatch }
              in
              Result.bind (updates prepared) (fun () ->
                let rec remove = function
                  | [] -> Ok ()
                  | row :: rest ->
                      Result.bind
                        (Database.For_sync.execute connection
                           ~params:[| row.existing_path |]
                           "DELETE FROM public.concepts WHERE path=$1")
                        (fun _ -> remove rest)
                in
                Result.bind (remove deletes) (fun () ->
                  Result.map (fun _ -> ())
                    (Database.For_sync.execute connection
                       ~params:[| commit; Openrouter.canonical_identity;
                                  string_of_int Openrouter.dimensions |]
                       "UPDATE public.index_state SET last_indexed_commit=$1,embedding_model=$2,embedding_dimensions=$3::int4,last_indexed_at=pg_catalog.now() WHERE id=1")))))
  in
  let* () = db (Database.For_sync.transaction connection ~statement_timeout_ms:30000 apply) in
  let count predicate =
    List.fold_left
      (fun total (action, _) -> if predicate action then total + 1 else total)
      0 prepared
  in
  let counts =
    { added = count (function Add _ -> true | _ -> false);
      metadata_updated = count (function Metadata _ -> true | _ -> false);
      reembedded = count (function Embed _ -> true | _ -> false);
      unchanged = count (function Unchanged -> true | _ -> false);
      deleted = deletion_count }
  in
  Ok { commit; counts; rebuilt = existing = []; diagnostics }

let load_source_repository repo =
  let config_path = Filename.concat repo "clamp.yaml" in
  match Config.load_source_repository config_path with
  | Error "source_repository_missing" ->
      error Validation "source_repository_missing"
        "clamp.yaml must configure source_repository."
  | Error _ ->
      error Validation "source_repository_invalid"
        "clamp.yaml source_repository is invalid."
  | Ok source ->
      (match Config.load config_path with
      | Ok () -> Ok source
      | Error _ ->
          error Validation "config_invalid" "clamp.yaml is invalid or incompatible.")

let preflight_repository repo = Result.map (fun _ -> ()) (load_source_repository repo)

let run_with_connection ~repo ~connection ~embed ~reembed ~allow_mass_deletion
    ~target_commit =
  match load_source_repository repo with
  | Error _ as failure -> failure
  | Ok source ->
      Result.bind (try_lock connection source) (fun () ->
          Fun.protect ~finally:(fun () -> unlock connection source) (fun () ->
              let* () = precheck_index_state connection in
              run_locked ~repo ~connection ~embed ~reembed ~allow_mass_deletion
                ~target_commit source))

let production_embed text =
  match Sys.getenv_opt "OPENROUTER_API_KEY" with
  | None | Some "" ->
      error Authentication "openrouter_api_key_missing"
        "OPENROUTER_API_KEY is required when synchronization needs embeddings."
  | Some api_key ->
  match Openrouter.embed ~api_key text with
  | Ok embedding -> Ok embedding.values
  | Error failure -> Error (openrouter_error failure)

let run ~repo ~url ~reembed ~allow_mass_deletion ~target_commit =
  match load_source_repository repo with
  | Error _ as failure -> failure
  | Ok _ ->
      (match
            Database.For_sync.with_remote ~url (fun connection ->
                Ok
                  (run_with_connection ~repo ~connection
                     ~embed:production_embed ~reembed
                     ~allow_mass_deletion ~target_commit))
          with
          | Ok result -> result
          | Error failure -> of_database failure)

module For_test = struct
  type embedding = string -> (float array, error) result
  let database_error = database_error
  let openrouter_error = openrouter_error
  let run_with_connection = run_with_connection
  let run_process ~program ~arguments ~maximum ~timeout ~after_spawn =
    Result.map (fun output -> output.stdout)
      (execute_process ~input:None ~environment:safe_process_environment
         ~program ~arguments ~maximum ~timeout
         ~hooks:{ default_process_hooks with after_spawn })
  let run_process_with_hooks ~program ~arguments ~maximum ~timeout
      ~before_pipe ~child_setup_delay ~after_fork ~after_readiness_selectable
      ~before_ack_write ~before_ack_close ~after_spawn ~before_waitpid =
    let hooks =
      { before_pipe; child_setup_delay; after_fork; after_readiness_selectable;
        before_ack_write; before_ack_close; after_spawn; before_waitpid }
    in
    Result.map (fun output -> (output.stdout, output.status))
      (execute_process ~input:None ~environment:safe_process_environment
         ~program ~arguments ~maximum ~timeout ~hooks)
  let parse_knowledge_root = parse_knowledge_root
  let trusted_amp_runtime () =
    trusted_amp_runtime ~allow_loopback_amp_url:true ()
  let amp_remote = amp_remote
  let amp_git ~repo ~remote ~arguments ~maximum ~timeout =
    amp_git ~timeout ~allow_loopback_amp_url:true repo remote
      (fun remote -> arguments remote) maximum
  let local_origin_main_with_hooks ~repo ~timeout ~child_setup_delay ~after_fork =
    local_origin_main_with ~timeout
      ~hooks:{ default_process_hooks with child_setup_delay; after_fork } repo
end

module Git = struct
  type command_result = git_command_result = { output : string; succeeded : bool }
  let run = git
  let run_input = git_with_input
  let run_status ?timeout repo arguments maximum =
    git_status_with ?timeout repo arguments maximum
  let origin_urls = origin_urls
  let fetch_origin_main = fetch_origin_main
  let push_origin = push_origin
  let remote_branch_status = remote_branch_status
  let valid_sha = valid_sha
  let amp_remote = amp_remote
end
