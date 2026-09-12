type failure_kind =
  | Validation
  | Authentication
  | Transient
  | Timeout
  | Sql
  | Internal

type finalization = Before_commit_dispatch | After_commit_dispatch

type error = {
  code : string;
  message : string;
  kind : failure_kind;
  finalization : finalization;
}

type retry_effects = {
  now : unit -> float;
  sleep : float -> unit;
  jitter : unit -> float;
}

type migration_report = {
  applied : string list;
  already_applied : string list;
  ledger_count : int;
}

type local_target = {
  socket_dir : string;
  port : int;
  data_directory : string;
}

type concept_row = {
  path : string;
  blob_hash : string;
  embedding_input_hash : string;
  concept_type : string;
  status : string;
  embedding_model : string;
  indexed_at : string;
}

type access_stats_row = {
  concept_path : string;
  last_accessed_at : string option;
  access_count : int64;
}

type index_state_row = {
  source_repository : string;
  source_ref : string;
  last_indexed_commit : string option;
  embedding_model : string;
  embedding_dimensions : int;
  last_indexed_at : string option;
}

let error kind code message =
  Error { kind; code; message; finalization = Before_commit_dispatch }

let exit_class (error : error) =
  match error.kind with
  | Validation | Sql -> Exit_class.User_error
  | Authentication -> Exit_class.Authentication
  | Transient | Timeout -> Exit_class.Transient_external
  | Internal -> Exit_class.Internal

let percent_decode value =
  let length = String.length value in
  let buffer = Buffer.create length in
  let hex = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> 10 + Char.code c - Char.code 'a'
    | 'A' .. 'F' as c -> 10 + Char.code c - Char.code 'A'
    | _ -> -1
  in
  let rec loop index =
    if index = length then Some (Buffer.contents buffer)
    else if value.[index] = '%' then
      if index + 2 >= length then None
      else
        let high = hex value.[index + 1] and low = hex value.[index + 2] in
        if high < 0 || low < 0 then None
        else begin
          Buffer.add_char buffer (Char.chr ((high * 16) + low));
          loop (index + 3)
        end
    else begin
      Buffer.add_char buffer (if value.[index] = '+' then ' ' else value.[index]);
      loop (index + 1)
    end
  in
  loop 0

let query_parameters url =
  match String.index_opt url '?' with
  | None -> Ok []
  | Some start ->
      let stop = Option.value (String.index_from_opt url (start + 1) '#') ~default:(String.length url) in
      let query = String.sub url (start + 1) (stop - start - 1) in
      let add parameter fields =
        let name, value =
          match String.index_opt parameter '=' with
          | None -> (parameter, "")
          | Some equal ->
              ( String.sub parameter 0 equal,
                String.sub parameter (equal + 1) (String.length parameter - equal - 1) )
        in
        match (percent_decode name, percent_decode value) with
        | Some name, Some value -> Ok ((String.lowercase_ascii name, value) :: fields)
        | _ -> error Validation "database_url_invalid" "Database URL contains invalid percent encoding."
      in
      List.fold_left
        (fun result parameter -> Result.bind result (add parameter))
        (Ok []) (if query = "" then [] else String.split_on_char '&' query)

let one_parameter name parameters =
  match List.filter_map (fun (key, value) -> if key = name then Some value else None) parameters with
  | [ value ] -> Ok value
  | [] -> error Validation "database_url_invalid" (name ^ " is required in the database URL.")
  | _ -> error Validation "database_url_invalid" (name ^ " must appear exactly once in the database URL.")

let optional_parameter name parameters =
  match List.filter_map (fun (key, value) -> if key = name then Some value else None) parameters with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ -> error Validation "database_url_invalid" (name ^ " must appear at most once in the database URL.")

type remote_host = { rendered : string; name : string }

let remote_hosts url =
  let valid_port value =
    value <> ""
    && String.for_all (function '0' .. '9' -> true | _ -> false) value
    && match int_of_string_opt value with
       | Some port -> port >= 1 && port <= 65535
       | None -> false
  in
  let valid_hostname value =
    let valid_edge = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
      | _ -> false
    in
    let valid_character = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
      | _ -> false
    in
    value <> "" && String.length value <= 253
    && List.for_all (fun label ->
           label <> "" && String.length label <= 63
           && valid_edge label.[0] && valid_edge label.[String.length label - 1]
           && String.for_all valid_character label)
         (String.split_on_char '.' value)
  in
  let valid_ipv6 value =
    value <> "" && String.contains value ':' && not (String.contains value '%')
    && (try ignore (Unix.inet_addr_of_string value); true with Failure _ -> false)
  in
  let scheme_end = match String.index_opt url ':' with Some index -> index + 3 | None -> 0 in
  let authority_end =
    let rec find index =
      if index = String.length url then index
      else match url.[index] with '/' | '?' | '#' -> index | _ -> find (index + 1)
    in find scheme_end
  in
  let authority = String.sub url scheme_end (authority_end - scheme_end) in
  let hosts_start = match String.rindex_opt authority '@' with
    | Some index -> index + 1
    | None -> 0
  in
  let host_list = String.sub authority hosts_start (String.length authority - hosts_start) in
  let rec split index bracket start entries =
    if index = String.length host_list then
      List.rev (String.sub host_list start (index - start) :: entries)
    else match host_list.[index] with
      | '[' when not bracket -> split (index + 1) true start entries
      | ']' when bracket -> split (index + 1) false start entries
      | ',' when not bracket ->
          split (index + 1) false (index + 1)
            (String.sub host_list start (index - start) :: entries)
      | _ -> split (index + 1) bracket start entries
  in
  let entries = if host_list = "" then [] else split 0 false 0 [] in
  let parse rendered =
    let length = String.length rendered in
    if length = 0 then None
    else if rendered.[0] = '[' then
      match String.index_opt rendered ']' with
      | None -> None
      | Some close ->
          let name = String.sub rendered 1 (close - 1) in
          let suffix = String.sub rendered (close + 1) (length - close - 1) in
          if not (valid_ipv6 name)
             || (suffix <> ""
             && (suffix.[0] <> ':'
                 || not (valid_port (String.sub suffix 1 (String.length suffix - 1)))))
          then None
          else Some { rendered; name }
    else
      let colon_count = String.fold_left (fun count character ->
          if character = ':' then count + 1 else count) 0 rendered in
      if colon_count > 1 then None
      else
        let name, port = match String.index_opt rendered ':' with
          | None -> (rendered, None)
          | Some index ->
              (String.sub rendered 0 index,
               Some (String.sub rendered (index + 1) (length - index - 1)))
        in
        if not (valid_hostname name)
           || Option.exists (fun port -> not (valid_port port)) port
        then None else Some { rendered; name }
  in
  if entries = [] || List.length entries > 8 then
    error Validation "database_url_invalid" "Database URL must contain between one and eight hosts."
  else
    match List.fold_left (fun result entry ->
        Result.bind result (fun hosts -> match parse entry with
          | Some host -> Ok (host :: hosts)
          | None -> error Validation "database_url_invalid" "Database URL host list is invalid."))
        (Ok []) entries with
    | Ok hosts -> Ok (List.rev hosts, scheme_end, authority_end, hosts_start)
    | Error _ as failure -> failure

let validate_remote_url url =
  if String.contains url '#' then
    error Validation "database_url_invalid" "Database URL must not contain a fragment."
  else if not (String.starts_with ~prefix:"postgresql://" url
               || String.starts_with ~prefix:"postgres://" url) then
    error Validation "database_url_invalid" "Database URL must use the postgres or postgresql scheme."
  else
    Result.bind (remote_hosts url) (fun _ ->
    Result.bind (query_parameters url) (fun parameters ->
        if List.exists
             (fun (name, _) -> List.mem name [ "options"; "host"; "hostaddr"; "port" ])
             parameters then
          error Validation "database_url_invalid"
            "Database URL must not override hosts, ports, or libpq options."
        else Result.bind (one_parameter "sslmode" parameters) (fun sslmode ->
            if not (List.mem (String.lowercase_ascii sslmode) [ "require"; "verify-ca"; "verify-full" ]) then
              error Validation "database_url_invalid" "Database URL must set sslmode=require or stronger."
            else
              Result.bind (one_parameter "channel_binding" parameters) (fun channel_binding ->
                  if String.lowercase_ascii channel_binding <> "require" then
                    error Validation "database_url_invalid" "Database URL must set channel_binding=require."
                  else
                    Result.bind (optional_parameter "connect_timeout" parameters) (function
                        | None -> Ok ()
                        | Some value ->
                            (match int_of_string_opt value with
                            | Some seconds when seconds >= 1 && seconds <= 5 -> Ok ()
                            | _ -> error Validation "database_url_invalid" "connect_timeout must be between 1 and 5 seconds."))))))

let contains text needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let classify_connection_message message =
  let message = String.lowercase_ascii message in
  if List.exists (contains message)
       [ "password authentication failed"; "no password supplied";
         "authentication method"; "certificate authentication failed";
         "channel binding required" ]
  then Authentication
  else if List.exists (contains message)
            [ "certificate verify failed"; "root certificate file";
              "invalid sslmode value"; "invalid connection option" ]
  then Validation
  else if List.exists (contains message)
            [ "timeout"; "timed out"; "could not connect"; "connection refused";
              "connection reset"; "server closed the connection";
              "network is unreachable"; "network unreachable";
              "network is down"; "network down";
              "no route to host"; "host is unreachable";
              "host is down"; "host down";
              "cannot assign requested address"; "address not available";
              "address family not supported"; "ai_family";
              "eaddrnotavail"; "enetdown"; "ehostdown"; "eafnosupport";
              "ssl syscall error: eof detected";
              "network dropped connection on reset"; "enetreset";
              "software caused connection abort"; "econnaborted";
              "the database system is starting up";
              "cannot connect now"; "could not translate host name" ]
  then Transient
  else Internal

let classify_query_message message =
  let message = String.lowercase_ascii message in
  if contains message "statement timeout" || contains message "canceling statement" then Timeout
  else Sql

external monotonic_now : unit -> float = "clamp_monotonic_now"

let make_process_jitter ~pid ~initialize () =
  let process = ref None and state = ref None in
  fun () ->
    let current = pid () in
    if !process <> Some current then begin
      process := Some current;
      state := Some (initialize ())
    end;
    match !state with
    | Some state -> Random.State.float state 1.
    | None -> assert false

let production_jitter =
  make_process_jitter ~pid:Unix.getpid ~initialize:Random.State.make_self_init ()

let default_effects =
  { now = monotonic_now; sleep = Unix.sleepf; jitter = production_jitter }

let retry_delay effects number =
  let base = min 4. (0.5 *. (2. ** float_of_int (number - 1))) in
  base +. (base *. 0.25 *. max 0. (min 1. (effects.jitter ())))

let child_deadline ~effects ~parent ~cap =
  let now = effects.now () in
  if now >= parent then None else Some (min parent (now +. max 0. cap))

let sleep_before_deadline ~effects ~deadline delay =
  let remaining = deadline -. effects.now () in
  if remaining <= 0. || delay >= remaining then false
  else begin
    effects.sleep (max 0. (min delay remaining));
    effects.now () < deadline
  end

let polling_ok_before_deadline ~effects ~deadline configure =
  if effects.now () >= deadline then false
  else begin
    configure ();
    effects.now () < deadline
  end

let retry ?(effects = default_effects) ?(max_attempts = 4) ?(max_elapsed_s = 20.) connect =
  let started = effects.now () in
  let rec attempt number =
    match connect () with
    | Ok _ as result -> result
    | Error ({ kind = Transient; _ } as failure)
      when number < max_attempts && effects.now () -. started < max_elapsed_s ->
        let delay = retry_delay effects number in
        if effects.now () +. delay -. started >= max_elapsed_s then Error failure
        else begin effects.sleep delay; attempt (number + 1) end
    | Error _ as result -> result
  in
  if max_attempts < 1 then error Internal "database_retry_invalid" "Database retry policy is invalid."
  else attempt 1

let protect_connection create use =
  match create () with
  | Error _ as result -> result
  | Ok connection ->
      Fun.protect ~finally:(fun () -> try connection#finish with _ -> ())
        (fun () -> use connection)

let connection_failure message =
  let kind = classify_connection_message message in
  error kind
    (match kind with
    | Authentication -> "database_authentication_failed"
    | Validation -> "database_connection_invalid"
    | Transient -> "database_unavailable"
    | _ -> "database_internal_error")
    (match kind with
    | Authentication -> "Database authentication failed."
    | Validation -> "Database connection configuration is invalid."
    | _ -> "Database connection failed.")

let connection_timeout () =
  error Timeout "database_connection_timeout" "Database connection timed out."

let stable_unique values =
  let seen = Hashtbl.create (List.length values) in
  List.filter (fun value ->
      if Hashtbl.mem seen value then false
      else (Hashtbl.add seen value (); true)) values

let poll_waitpid ~effects ~deadline wait =
  let rec collect () =
    if effects.now () >= deadline then false
    else
      try match wait () with
        | `Collected -> true
        | `Running ->
            let remaining = deadline -. effects.now () in
            if remaining <= 0.0001 then false
            else begin
              effects.sleep (min 0.01 (remaining /. 2.));
              collect ()
            end
      with
      | Unix.Unix_error (Unix.EINTR, _, _) -> collect ()
      | Unix.Unix_error (Unix.ECHILD, _, _) -> true
      | _ -> false
  in
  collect ()

type resolver_system = {
  pipe : unit -> Unix.file_descr * Unix.file_descr;
  fork : unit -> int;
  close : Unix.file_descr -> unit;
  set_nonblock : Unix.file_descr -> unit;
  select_read : Unix.file_descr -> float -> bool;
  read : Unix.file_descr -> bytes -> int -> int -> int;
  kill : int -> int -> unit;
  waitpid_nohang : int -> [ `Running | `Collected ];
  resolve : string -> string list option;
}

let default_resolver_system = {
  pipe = (fun () -> Unix.pipe ~cloexec:true ());
  fork = Unix.fork;
  close = Unix.close;
  set_nonblock = Unix.set_nonblock;
  select_read = (fun descriptor timeout ->
      let ready, _, _ = Unix.select [ descriptor ] [] [] timeout in
      ready <> []);
  read = Unix.read;
  kill = Unix.kill;
  waitpid_nohang = (fun process ->
      match Unix.waitpid [ Unix.WNOHANG ] process with
      | 0, _ -> `Running
      | _ -> `Collected);
  resolve = (fun host ->
      try
        let addresses =
          Unix.getaddrinfo host "5432" [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
          |> List.filter_map (fun address -> match address.Unix.ai_addr with
              | Unix.ADDR_INET (address, _) -> Some (Unix.string_of_inet_addr address)
              | Unix.ADDR_UNIX _ -> None)
          |> stable_unique
        in
        if addresses = [] || List.length addresses > 8 then None else Some addresses
      with _ -> None);
}

let resolve_host_with ~system ~effects ~deadline host =
  try Ok [ Unix.string_of_inet_addr (Unix.inet_addr_of_string host) ] with Failure _ ->
    if effects.now () >= deadline then Error `Timeout
    else
    match (try Ok (system.pipe ()) with _ -> Error `Resolve) with
    | Error _ as failure -> failure
    | Ok (input, output) ->
    let close descriptor = try system.close descriptor with _ -> () in
    if effects.now () >= deadline then begin
      close input;
      close output;
      Error `Timeout
    end else
    match (try Ok (system.fork ()) with _ -> Error `Resolve) with
    | Error _ as failure ->
        close input;
        close output;
        failure
    | Ok 0 ->
        (try
           system.close input;
           let channel = Unix.out_channel_of_descr output in
           let payload =
             if effects.now () >= deadline then None else system.resolve host in
           (try Marshal.to_channel channel payload []; flush channel with _ -> ());
           close_out_noerr channel
         with _ -> close output);
        Unix._exit 0
    | Ok process ->
        let input_open = ref true and output_open = ref true in
        let close_if_open descriptor open_ =
          if !open_ then
            try system.close descriptor; open_ := false with _ -> ()
        in
        let cleanup_started = ref false in
        let reaped = ref false in
        let work_started = effects.now () in
        let inherited_remaining = max 0. (deadline -. work_started) in
        let cleanup_reserve = min 0.1 (inherited_remaining *. 0.25) in
        let work_deadline = max work_started (deadline -. cleanup_reserve) in
        let reap ?(kill = false) () =
          if not !cleanup_started then begin
            cleanup_started := true;
            let now = effects.now () in
            if now < deadline then begin
              let cleanup_deadline = min deadline (now +. 0.25) in
              let live () = effects.now () < cleanup_deadline in
              let rec terminate attempts =
                if not (live ()) then false
                else
                  try system.kill process Sys.sigkill; true with
                  | Unix.Unix_error (Unix.EINTR, _, _) when attempts > 0 ->
                      terminate (attempts - 1)
                  | Unix.Unix_error (Unix.ESRCH, _, _) -> true
                  | _ -> false
              in
              let rec wait_once interrupted :
                  [ `Collected | `Running | `Expired | `Failed ] =
                if not (live ()) then `Expired
                else
                  try (system.waitpid_nohang process
                       :> [ `Collected | `Running | `Expired | `Failed ]) with
                  | Unix.Unix_error (Unix.EINTR, _, _) when interrupted < 3 ->
                      wait_once (interrupted + 1)
                  | Unix.Unix_error (Unix.ECHILD, _, _) -> `Collected
                  | _ -> `Failed
              in
              let collect_after_kill () =
                match wait_once 0 with
                | `Collected -> reaped := true
                | `Running when live () ->
                    if poll_waitpid ~effects ~deadline:cleanup_deadline
                         (fun () -> system.waitpid_nohang process) then
                      reaped := true
                | `Running | `Expired | `Failed -> ()
              in
              match wait_once 0 with
              | `Collected -> reaped := true
              | `Running when kill && terminate 3 -> collect_after_kill ()
              | `Running | `Expired | `Failed -> ()
            end
          end;
          !reaped
        in
        let parent_result () =
          try
            system.close output;
            output_open := false;
            system.set_nonblock input;
            let buffer = Buffer.create 256 and chunk = Bytes.create 256 in
            let rec read () =
              let remaining = work_deadline -. effects.now () in
              if remaining <= 0. then Error `Timeout
              else
                let ready =
                  try system.select_read input remaining
                  with
                  | Unix.Unix_error (Unix.EINTR, _, _) -> false
                  | _ -> raise Exit
                in
                if effects.now () >= work_deadline then Error `Timeout
                else if not ready then read ()
                else
                  try match system.read input chunk 0 (Bytes.length chunk) with
                    | 0 -> Ok (Buffer.contents buffer)
                    | count ->
                        if Buffer.length buffer + count > 4096 then Error `Invalid
                        else (Buffer.add_subbytes buffer chunk 0 count; read ())
                  with
                  | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
                      read ()
                  | _ -> Error `Resolve
            in
            match read () with
            | Error reason ->
                ignore (reap ~kill:true ());
                Error reason
            | Ok payload ->
                ignore (reap ~kill:true ());
                if effects.now () >= deadline then Error `Timeout
                else
                  try match (Marshal.from_string payload 0 : string list option) with
                    | Some addresses -> Ok addresses
                    | None -> Error `Resolve
                  with _ -> Error `Resolve
          with _ ->
            if reap ~kill:true () then Error `Resolve else Error `Resolve
        in
        Fun.protect
          ~finally:(fun () ->
            close_if_open input input_open;
            close_if_open output output_open;
            if not !cleanup_started then ignore (reap ~kill:true ()))
          parent_result

let resolve_host ~effects ~deadline host =
  resolve_host_with ~system:default_resolver_system ~effects ~deadline host

let percent_encode_query value =
  let buffer = Buffer.create (String.length value) in
  String.iter (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_') as character ->
          Buffer.add_char buffer character
      | character -> Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code character))) value;
  Buffer.contents buffer

let prepare_remote_url ?resolver ~effects ~deadline url =
  let resolver = Option.value resolver
      ~default:(fun ~deadline host -> resolve_host ~effects ~deadline host) in
  Result.bind (validate_remote_url url) (fun () ->
  Result.bind (remote_hosts url) (fun (hosts, scheme_end, authority_end, hosts_start) ->
      let rec resolve resolved count saw_timeout saw_failure = function
        | _ when effects.now () >= deadline -> connection_timeout ()
        | [] ->
            if resolved <> [] then Ok (List.rev resolved)
            else if saw_timeout then connection_timeout ()
            else if saw_failure then
              error Transient "database_unavailable" "Database host resolution failed."
            else connection_timeout ()
        | host :: rest ->
            let remaining = deadline -. effects.now () in
            let cap = remaining /. float_of_int (List.length (host :: rest)) in
            (match child_deadline ~effects ~parent:deadline ~cap with
            | None -> connection_timeout ()
            | Some host_deadline ->
            match resolver ~deadline:host_deadline host.name with
            | Ok addresses ->
                if effects.now () >= deadline then connection_timeout ()
                else
                  let addresses = stable_unique addresses in
                  let count = count + List.length addresses in
                  if count > 8 then
                    error Validation "database_url_invalid"
                      "Database URL resolves to more than eight addresses."
                  else
                    let resolved = List.fold_left (fun result address ->
                        (host.rendered, address) :: result) resolved addresses in
                    resolve resolved count saw_timeout saw_failure rest
            | Error `Timeout -> resolve resolved count true saw_failure rest
            | Error `Resolve -> resolve resolved count saw_timeout true rest
            | Error `Invalid ->
                error Validation "database_url_invalid"
                  "Database host resolves to an invalid address list.")
      in
      Result.map (fun resolved ->
          let authority = String.sub url scheme_end (authority_end - scheme_end) in
          let userinfo = String.sub authority 0 hosts_start in
          let rendered_hosts = String.concat "," (List.map fst resolved) in
          let hostaddrs =
            String.concat "," (List.map (fun (_, address) -> percent_encode_query address) resolved)
          in
          let before_fragment, fragment = match String.index_opt url '#' with
            | None -> (url, "")
            | Some index ->
                (String.sub url 0 index,
                 String.sub url index (String.length url - index))
          in
          let tail_without_fragment =
            String.sub before_fragment authority_end
              (String.length before_fragment - authority_end)
          in
          let deadline_tail = match String.index_opt tail_without_fragment '?' with
            | None -> tail_without_fragment
            | Some question ->
                let path = String.sub tail_without_fragment 0 question in
                let query = String.sub tail_without_fragment (question + 1)
                    (String.length tail_without_fragment - question - 1) in
                let parameters = String.split_on_char '&' query |> List.filter (fun parameter ->
                    let name = match String.index_opt parameter '=' with
                      | None -> parameter
                      | Some equal -> String.sub parameter 0 equal
                    in
                    match percent_decode name with
                    | Some name -> String.lowercase_ascii name <> "connect_timeout"
                    | None -> true)
                in
                path ^ (if parameters = [] then "" else "?" ^ String.concat "&" parameters)
          in
          let separator = if String.contains deadline_tail '?' then "&" else "?" in
          String.sub url 0 scheme_end ^ userinfo ^ rendered_hosts ^ deadline_tail
          ^ separator ^ "hostaddr=" ^ hostaddrs ^ "&connect_timeout=1" ^ fragment)
        (resolve [] 0 false false hosts)))

let remote_target_url url ~scheme_end ~authority_end ~hosts_start host address =
  let authority = String.sub url scheme_end (authority_end - scheme_end) in
  let userinfo = String.sub authority 0 hosts_start in
  let tail = String.sub url authority_end (String.length url - authority_end) in
  let path, raw_parameters = match String.index_opt tail '?' with
    | None -> (tail, [])
    | Some question ->
        (String.sub tail 0 question,
         String.sub tail (question + 1) (String.length tail - question - 1)
         |> String.split_on_char '&')
  in
  let retained = List.filter (fun parameter ->
      let name = match String.index_opt parameter '=' with
        | None -> parameter
        | Some equal -> String.sub parameter 0 equal
      in
      match percent_decode name with
      | Some name -> String.lowercase_ascii name <> "connect_timeout"
      | None -> false) raw_parameters in
  let query = String.concat "&" retained in
  String.sub url 0 scheme_end ^ userinfo ^ host.rendered ^ path ^ "?"
  ^ (if query = "" then "" else query ^ "&")
  ^ "hostaddr=" ^ percent_encode_query address ^ "&connect_timeout=1"

let connect ?(effects = default_effects) ?deadline ?(max_attempts = 4) create =
  let deadline = Option.value deadline ~default:(effects.now () +. 5.) in
  let wait connection status =
    let remaining = deadline -. effects.now () in
    if remaining <= 0. then false
    else
      let descriptor = connection#socket_descr in
      try
        let readable, writable = match status with
          | Postgresql.Polling_reading -> ([ descriptor ], [])
          | Postgresql.Polling_writing -> ([], [ descriptor ])
          | _ -> ([], [])
        in
        let ready_read, ready_write, _ =
          Unix.select readable writable [] (min remaining 0.25) in
        ready_read <> [] || ready_write <> [] || effects.now () < deadline
      with Unix.Unix_error (Unix.EINTR, _, _) -> effects.now () < deadline
  in
  let establish connection =
    let rec poll status =
      if effects.now () >= deadline then connection_timeout ()
      else match status with
      | Postgresql.Polling_ok ->
          if polling_ok_before_deadline ~effects ~deadline (fun () ->
              connection#set_nonblocking false;
              connection#set_notice_processing `Quiet) then
            Ok connection
          else connection_timeout ()
      | Postgresql.Polling_failed -> connection_failure connection#error_message
      | (Postgresql.Polling_reading | Postgresql.Polling_writing) as status ->
          if wait connection status && effects.now () < deadline then
            poll connection#connect_poll
          else connection_timeout ()
    in
    poll Postgresql.Polling_writing
  in
  let connect_once () =
      if effects.now () >= deadline then connection_timeout ()
      else
        try
          let connection = create () in
          (try
             match establish connection with
             | Ok _ as result -> result
             | Error _ as result ->
                 (try connection#finish with _ -> ());
                 result
           with failure ->
             (try connection#finish with _ -> ());
             raise failure)
        with
        | Postgresql.Error (Postgresql.Connection_failure message) ->
            connection_failure message
        | Postgresql.Error _ ->
            error Transient "database_unavailable" "Database connection failed."
        | _ ->
            error Internal "database_internal_error"
              "Database connection failed unexpectedly."
  in
  let rec attempt number =
    if effects.now () >= deadline then connection_timeout ()
    else
      let result = connect_once () in
      if effects.now () >= deadline then begin
        (match result with Ok connection -> (try connection#finish with _ -> ()) | Error _ -> ());
        connection_timeout ()
      end else match result with
      | Error ({ kind = Transient; _ } as failure) when number < max_attempts ->
          let delay = retry_delay effects number in
          if sleep_before_deadline ~effects ~deadline delay then attempt (number + 1)
          else if effects.now () >= deadline then connection_timeout () else Error failure
      | result -> result
  in
  if max_attempts < 1 then
    error Internal "database_retry_invalid" "Database retry policy is invalid."
  else attempt 1

let remote_connection_race_delay_s = 0.25

type pending_remote_connection = {
  connection : Postgresql.connection;
  mutable polling_status : Postgresql.polling_status;
}

let race_remote_connections ~effects ~deadline targets =
  let opened = ref [] in
  let forget pending =
    opened := List.filter
        (fun candidate -> candidate.connection != pending.connection) !opened
  in
  let close pending =
    forget pending;
    try pending.connection#finish with _ -> ()
  in
  let close_all () =
    let pending = !opened in
    opened := [];
    List.iter (fun candidate -> try candidate.connection#finish with _ -> ()) pending
  in
  let start target =
    try
      let connection =
        new Postgresql.connection ~conninfo:target ~startonly:true () in
      let pending = { connection; polling_status = Postgresql.Polling_writing } in
      opened := pending :: !opened;
      Ok pending
    with
    | Postgresql.Error (Postgresql.Connection_failure message) ->
        connection_failure message
    | Postgresql.Error _ ->
        error Transient "database_unavailable" "Database connection failed."
    | _ ->
        error Internal "database_internal_error"
          "Database connection failed unexpectedly."
  in
  let operation () =
    let rec inspect ready last_failure = function
      | [] -> `Continue (List.rev ready, last_failure)
      | pending :: rest ->
          match pending.polling_status with
          | Postgresql.Polling_ok ->
              if polling_ok_before_deadline ~effects ~deadline (fun () ->
                  pending.connection#set_nonblocking false;
                  pending.connection#set_notice_processing `Quiet) then begin
                forget pending;
                `Connected pending.connection
              end else
                `Failed (match connection_timeout () with Error failure -> failure | Ok _ -> assert false)
          | Postgresql.Polling_failed ->
              let failure =
                match connection_failure pending.connection#error_message with
                | Error failure -> failure
                | Ok _ -> assert false
              in
              close pending;
              (match failure.kind with
              | Transient | Timeout -> inspect ready (Some failure) rest
              | Validation | Authentication | Sql | Internal -> `Failed failure)
          | Postgresql.Polling_reading | Postgresql.Polling_writing ->
              inspect (pending :: ready) last_failure rest
    in
    let rec loop pending remaining next_launch last_failure =
      if effects.now () >= deadline then connection_timeout ()
      else
        match inspect [] last_failure pending with
        | `Connected connection -> Ok connection
        | `Failed failure -> Error failure
        | `Continue (pending, last_failure) ->
            let now = effects.now () in
            match remaining with
            | target :: rest when pending = [] || now >= next_launch ->
                (match start target with
                | Ok candidate ->
                    loop (pending @ [ candidate ]) rest
                      (now +. remote_connection_race_delay_s) last_failure
                | Error ({ kind = (Transient | Timeout); _ } as failure) ->
                    loop pending rest now (Some failure)
                | Error failure -> Error failure)
            | [] when pending = [] ->
                (match last_failure with
                | Some failure -> Error failure
                | None -> connection_timeout ())
            | _ ->
                let readable, writable =
                  List.fold_left (fun (readable, writable) candidate ->
                      let descriptor = candidate.connection#socket_descr in
                      match candidate.polling_status with
                      | Postgresql.Polling_reading -> (descriptor :: readable, writable)
                      | Postgresql.Polling_writing -> (readable, descriptor :: writable)
                      | Postgresql.Polling_failed | Postgresql.Polling_ok ->
                          (readable, writable))
                    ([], []) pending
                in
                let remaining_time = deadline -. now in
                let launch_wait =
                  if remaining = [] then remaining_time
                  else max 0. (next_launch -. now)
                in
                let timeout = min 0.25 (min remaining_time launch_wait) in
                if timeout <= 0. then loop pending remaining next_launch last_failure
                else
                  try
                    let ready_read, ready_write, _ =
                      Unix.select readable writable [] timeout in
                    List.iter (fun candidate ->
                        let descriptor = candidate.connection#socket_descr in
                        let ready = match candidate.polling_status with
                          | Postgresql.Polling_reading -> List.mem descriptor ready_read
                          | Postgresql.Polling_writing -> List.mem descriptor ready_write
                          | Postgresql.Polling_failed | Postgresql.Polling_ok -> false
                        in
                        if ready then
                          candidate.polling_status <- candidate.connection#connect_poll)
                      pending;
                    loop pending remaining next_launch last_failure
                  with Unix.Unix_error (Unix.EINTR, _, _) ->
                    loop pending remaining next_launch last_failure
    in
    loop [] targets (effects.now ()) None
  in
  try Fun.protect ~finally:close_all operation with
  | Postgresql.Error (Postgresql.Connection_failure message) ->
      connection_failure message
  | Postgresql.Error _ ->
      error Transient "database_unavailable" "Database connection failed."
  | _ ->
      error Internal "database_internal_error"
        "Database connection failed unexpectedly."

let local_environment_variables =
  [ "PGHOST"; "PGHOSTADDR"; "PGPORT"; "PGDATABASE"; "PGUSER";
    "PGPASSWORD"; "PGPASSFILE"; "PGSERVICE"; "PGSERVICEFILE";
    "PGSYSCONFDIR";
    "PGOPTIONS"; "PGAPPNAME"; "PGCONNECT_TIMEOUT"; "PGCLIENTENCODING";
    "PGDATESTYLE"; "PGTZ"; "PGGEQO"; "PGSSLMODE"; "PGREQUIRESSL";
    "PGSSLCERT"; "PGSSLKEY"; "PGSSLROOTCERT"; "PGSSLCRL";
    "PGSSLCRLDIR"; "PGSSLSNI"; "PGREQUIREPEER"; "PGCHANNELBINDING";
    "PGTARGETSESSIONATTRS"; "PGLOADBALANCEHOSTS" ]

let with_clean_local_environment operation =
  let saved = List.map (fun variable -> (variable, Sys.getenv_opt variable)) local_environment_variables in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (variable, value) ->
          match value with Some value -> Unix.putenv variable value | None -> Unix.unsetenv variable) saved)
    (fun () ->
      List.iter (fun (variable, _) -> Unix.unsetenv variable) saved;
      Unix.putenv "PGCONNECT_TIMEOUT" "5";
      operation ())

let read_process_line program arguments =
  try
    let channel = Unix.open_process_args_in program arguments in
    let output =
      Fun.protect ~finally:(fun () -> ()) (fun () ->
          let buffer = Buffer.create 128 in
          let chunk = Bytes.create 256 in
          let rec loop total =
            if total > 4096 then None
            else match input channel chunk 0 (Bytes.length chunk) with
              | 0 -> Some (Buffer.contents buffer)
              | count -> Buffer.add_subbytes buffer chunk 0 count; loop (total + count)
          in
          loop 0)
    in
    let status = Unix.close_process_in channel in
    match output, status with
    | Some output, Unix.WEXITED 0 -> Ok (String.trim output)
    | _ -> error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main cluster configuration is unavailable."
  with _ -> error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main cluster configuration is unavailable."

let unquote_setting value =
  let value = String.trim value in
  let length = String.length value in
  if length >= 2 && value.[0] = '\'' && value.[length - 1] = '\'' then
    String.sub value 1 (length - 2)
  else value

let local_setting name =
  let arguments = [| "/usr/bin/pg_conftool"; "15"; "main"; "show"; name |] in
  Result.bind (read_process_line "/usr/bin/pg_conftool" arguments) (fun output ->
      let prefix = name ^ " = " in
      if String.starts_with ~prefix output then
        Ok (String.sub output (String.length prefix) (String.length output - String.length prefix)
            |> unquote_setting)
      else error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main cluster configuration is invalid.")

let local_target_for_tests = ref None

let discover_local_target () =
  match !local_target_for_tests with
  | Some target -> Ok target
  | None ->
  Result.bind (local_setting "port") (fun port_text ->
      Result.bind (local_setting "unix_socket_directories") (fun socket_directories ->
          Result.bind (local_setting "data_directory") (fun data_directory ->
              let socket_dir = "/var/run/postgresql" in
              let expected_data_directory = "/var/lib/postgresql/15/main" in
              let configured_sockets =
                String.split_on_char ',' socket_directories
                |> List.map (fun value -> String.trim value |> unquote_setting)
              in
              match int_of_string_opt port_text with
              | Some port when port > 0 && port <= 65535
                               && List.mem socket_dir configured_sockets
                               && data_directory = expected_data_directory ->
                  let socket = Filename.concat socket_dir (Printf.sprintf ".s.PGSQL.%d" port) in
                  (try
                     if (Unix.lstat socket).st_kind <> Unix.S_SOCK then
                       error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main socket is unavailable."
                     else Ok { socket_dir; port; data_directory }
                   with Unix.Unix_error _ ->
                     error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main socket is unavailable.")
              | _ -> error Validation "local_cluster_unavailable" "Local PostgreSQL 15 main cluster configuration is invalid.")))

let connection_unusable (connection : Postgresql.connection) =
  try
    match connection#status with
    | Postgresql.Ok -> false
    | Postgresql.Bad
    | Connection_started
    | Connection_made
    | Connection_awaiting_response
    | Connection_auth_ok
    | Connection_setenv
    | Connection_ssl_startup -> true
  with _ -> true

let query_failure connection message =
  if classify_query_message message = Timeout then
    { kind = Timeout; code = "database_query_timeout";
      message = "Database query timed out.";
      finalization = Before_commit_dispatch }
  else if connection_unusable connection then
    { kind = Transient; code = "database_connection_lost";
      message = "Database connection was lost.";
      finalization = Before_commit_dispatch }
  else
    { kind = Sql; code = "database_sql_error";
      message = "Database rejected the operation.";
      finalization = Before_commit_dispatch }

let execute (connection : Postgresql.connection) ?(expect = [ Postgresql.Command_ok ]) ?params sql =
  try Ok (connection#exec ~expect ?params sql) with
  | Postgresql.Error (Postgresql.Unexpected_status (_, message, _)) ->
      Error (query_failure connection message)
  | Postgresql.Error (Postgresql.Connection_failure _) ->
      error Transient "database_connection_lost" "Database connection was lost."
  | Postgresql.Error _ -> error Sql "database_sql_error" "Database rejected the operation."
  | _ -> error Internal "database_internal_error" "Database operation failed unexpectedly."

let commit_dispatched connection ~commit_before_deadline =
  let finalization = ref Before_commit_dispatch in
  let with_finalization failure =
    { failure with finalization = !finalization }
  in
  let exception_failure = function
    | Postgresql.Error (Postgresql.Connection_failure _) ->
        { kind = Transient; code = "database_connection_lost";
          message = "Database connection was lost.";
          finalization = !finalization }
    | Postgresql.Error (Postgresql.Unexpected_status (_, message, _)) ->
        query_failure connection message |> with_finalization
    | Postgresql.Error _ when connection_unusable connection ->
        { kind = Transient; code = "database_connection_lost";
          message = "Database connection was lost.";
          finalization = !finalization }
    | Postgresql.Error _ ->
        { kind = Sql; code = "database_sql_error";
          message = "Database rejected the operation.";
          finalization = !finalization }
    | _ when connection_unusable connection ->
        { kind = Transient; code = "database_connection_lost";
          message = "Database connection was lost.";
          finalization = !finalization }
    | _ ->
        { kind = Internal; code = "database_internal_error";
          message = "Database operation failed unexpectedly.";
          finalization = !finalization }
  in
  let result_failure result =
    query_failure connection result#error |> with_finalization
  in
  try
    (* PQsendQuery only reports success after dispatch on a blocking libpq
       connection. Keep every setup/send failure on the pre-dispatch side. *)
    if connection#is_nonblocking then connection#set_nonblocking false;
    if not (commit_before_deadline ()) then
      Error
        { kind = Timeout; code = "database_commit_deadline_expired";
          message = "Database commit was not dispatched before its deadline.";
          finalization = !finalization }
    else begin
      connection#send_query "COMMIT";
      finalization := After_commit_dispatch;
      let rec consume count first_failure first_result =
        match connection#get_result with
        | None ->
            if count = 1 then
              (match first_failure, first_result with
              | Some failure, _ -> Error failure
              | None, Some result -> Ok result
              | None, None -> assert false)
            else if connection_unusable connection then
              Error
                { kind = Transient; code = "database_connection_lost";
                  message = "Database connection was lost.";
                  finalization = !finalization }
            else
              Error
                { kind = Internal; code = "database_internal_error";
                  message = "Database operation failed unexpectedly.";
                  finalization = !finalization }
        | Some result ->
            let failure =
              if result#status = Postgresql.Command_ok then first_failure
              else Some (result_failure result)
            in
            let first_result =
              if count = 0 && result#status = Postgresql.Command_ok then Some result
              else first_result
            in
            consume (count + 1) failure first_result
      in
      consume 0 None None
    end
  with exception_ -> Error (exception_failure exception_)

let rollback (connection : Postgresql.connection) =
  try ignore (connection#exec ~expect:[ Postgresql.Command_ok ] "ROLLBACK") with _ -> ()

let transaction connection ~statement_timeout_ms operation =
  Result.bind (execute connection "BEGIN") (fun _ ->
      match execute connection "SET LOCAL search_path = pg_catalog, public" with
      | Error failure -> rollback connection; Error failure
      | Ok _ ->
          (match execute connection
                   (Printf.sprintf "SET LOCAL statement_timeout = %d" statement_timeout_ms) with
          | Error failure -> rollback connection; Error failure
          | Ok _ ->
              (match operation connection with
              | Error failure -> rollback connection; Error failure
              | Ok value ->
                  match execute connection "COMMIT" with
                  | Ok _ -> Ok value
                  | Error failure -> rollback connection; Error failure)))

let retrieval_encoding connection =
  Result.bind
    (execute connection "SET LOCAL client_encoding = 'UTF8'")
    (fun _ ->
      Result.bind
        (execute connection ~expect:[ Postgresql.Tuples_ok ]
           "SELECT pg_catalog.current_setting('client_encoding')")
        (fun rows ->
          if rows#ntuples = 1 && rows#getvalue 0 0 = "UTF8" then Ok ()
          else
            error Internal "database_client_encoding_invalid"
              "Database retrieval client encoding is invalid."))

let retrieval_transaction connection ~statement_timeout_ms operation =
  transaction connection ~statement_timeout_ms (fun connection ->
      Result.bind (retrieval_encoding connection) (fun () -> operation connection))

let retrieval_transaction_result ?(repeatable_read = false) connection
    ~statement_timeout_ms ~commit_before_deadline operation =
  let begin_sql =
    if repeatable_read then "BEGIN ISOLATION LEVEL REPEATABLE READ" else "BEGIN"
  in
  Result.bind (execute connection begin_sql) (fun _ ->
      match execute connection "SET LOCAL search_path = pg_catalog, public" with
      | Error failure -> rollback connection; Error failure
      | Ok _ ->
          (match execute connection
                   (Printf.sprintf "SET LOCAL statement_timeout = %d" statement_timeout_ms) with
          | Error failure -> rollback connection; Error failure
          | Ok _ ->
              (match retrieval_encoding connection with
              | Error failure -> rollback connection; Error failure
              | Ok () ->
                  match operation connection with
                  | Error failure -> rollback connection; Error failure
                  | Ok (Error _ as failure) -> rollback connection; Ok failure
                  | Ok (Ok value) ->
                      match
                        commit_dispatched connection ~commit_before_deadline
                      with
                        | Ok _ -> Ok (Ok value)
                        | Error failure ->
                            if failure.finalization = Before_commit_dispatch
                               || failure.code <> "database_connection_lost" then
                              rollback connection;
                            Error failure)))

type migration = { position : int; version : string; checksum : string; sql : string }

external read_trusted_regular_file : string -> int -> string =
  "clamp_read_trusted_regular_file"

let trusted_0001_checksum =
  "b669a28b01e6f0a7336b2df63b3b743596a01ecbd42df4e493590fef91549ced"

let untrusted_0001 () =
  error Validation "migration_0001_untrusted"
    "Migration 0001 does not match its trusted identity."

let read_trusted_0001 path =
  try
    let sql = read_trusted_regular_file path Limits.max_file_bytes in
    let checksum = Digestif.SHA256.(to_hex (digest_string sql)) in
    if checksum = trusted_0001_checksum then Ok sql else untrusted_0001 ()
  with _ -> untrusted_0001 ()

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        let length = in_channel_length channel in
        if length > Limits.max_file_bytes then
          error Validation "migration_too_large" "Migration exceeds the 8 MiB safety limit."
        else Ok (really_input_string channel length))
  with Sys_error _ -> error Validation "migration_read_failed" "Migration file could not be read."

let migration_name name =
  if Str.string_match (Str.regexp "^\\([0-9][0-9][0-9][0-9]\\)_\\([a-z0-9_]+\\)\\.sql$") name 0
  then
    let number = int_of_string (Str.matched_group 1 name) in
    Some (number, String.sub name 0 (String.length name - 4))
  else None

let load_migrations directory =
  let trusted_path = Filename.concat directory "0001_enable_vector.sql" in
  Result.bind (read_trusted_0001 trusted_path) (fun trusted_0001 -> try
    let sql_files =
      Sys.readdir directory |> Array.to_list
      |> List.filter (fun name -> String.ends_with ~suffix:".sql" name)
    in
    let parsed =
      List.fold_left (fun result name ->
          Result.bind result (fun migrations ->
              match migration_name name with
              | Some (position, version) -> Ok ((position, version, Filename.concat directory name) :: migrations)
              | None -> error Validation "migration_sequence_invalid" "Migration filenames must use canonical ordered names."))
        (Ok []) sql_files
    in
    Result.bind parsed (fun migrations ->
        let migrations = List.sort (fun (left, _, _) (right, _, _) -> Int.compare left right) migrations in
        let rec validate expected = function
          | [] -> Ok migrations
          | (position, _, _) :: rest when position = expected -> validate (expected + 1) rest
          | _ -> error Validation "migration_sequence_invalid" "Migration numbers must form an unambiguous contiguous sequence."
        in
        Result.bind (validate 1 migrations) (fun migrations ->
            List.fold_left
              (fun result (position, version, path) ->
                Result.bind result (fun loaded ->
                    let sql =
                      if position = 1 && version = "0001_enable_vector" then
                        Ok trusted_0001
                      else read_file path
                    in
                    Result.map (fun sql ->
                        let checksum = Digestif.SHA256.(to_hex (digest_string sql)) in
                        { position; version; checksum; sql } :: loaded) sql))
              (Ok []) migrations
            |> Result.map List.rev))
  with Sys_error _ -> error Validation "migration_directory_missing" "Migration directory could not be read.")

let strip_transaction migration =
  if migration.version <> "0001_enable_vector" then Ok migration.sql
  else
    let lines = String.split_on_char '\n' migration.sql in
    let filtered = List.filter (fun line ->
        let trimmed = String.uppercase_ascii (String.trim line) in
        trimmed <> "BEGIN;" && trimmed <> "COMMIT;") lines in
    if List.length filtered + 2 <> List.length lines then
      error Validation "migration_0001_invalid" "Migration 0001 transaction wrapper is not in the expected form."
    else Ok (String.concat "\n" filtered)

let ledger_sql =
  "CREATE TABLE IF NOT EXISTS public.clamp_schema_migrations (\n\
   position pg_catalog.int4 PRIMARY KEY CHECK (position OPERATOR(pg_catalog.>) 0),\n\
   version pg_catalog.text NOT NULL UNIQUE,\n\
   checksum pg_catalog.bpchar(64) NOT NULL,\n\
   applied_at pg_catalog.timestamptz NOT NULL DEFAULT pg_catalog.now()\n\
   )"

let ledger_present connection =
  Result.bind
    (execute connection ~expect:[ Postgresql.Tuples_ok ]
       "SELECT pg_catalog.to_regclass('public.clamp_schema_migrations') IS NOT NULL")
    (fun result -> Ok (result#ntuples = 1 && result#getvalue 0 0 = "t"))

let lock_ledger connection =
  Result.map (fun _ -> ())
    (execute connection
       "LOCK TABLE public.clamp_schema_migrations IN ACCESS EXCLUSIVE MODE")

let ledger_shape connection =
  Result.bind
    (execute connection ~expect:[ Postgresql.Tuples_ok ]
       "SELECT pg_catalog.string_agg(a.attname || ':' || pg_catalog.format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull || ':' || coalesce(pg_catalog.pg_get_expr(d.adbin, d.adrelid), '-') || ':' || (a.attcollation OPERATOR(pg_catalog.=) t.typcollation) || ':' || coalesce(nullif(a.attidentity::pg_catalog.text,''),'-') || ':' || coalesce(nullif(a.attgenerated::pg_catalog.text,''),'-'), ',' ORDER BY a.attnum) FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) a.atttypid LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid OPERATOR(pg_catalog.=) a.attrelid AND d.adnum OPERATOR(pg_catalog.=) a.attnum WHERE a.attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped")
    (fun columns ->
      match columns#getvalue 0 0 with
      | "position:integer:true:-:true:-:-,version:text:true:-:true:-:-,checksum:character(64):true:-:true:-:-,applied_at:timestamp with time zone:true:now():true:-:-" -> Ok `Current
      | "version:text:true:-:true:-:-,checksum:character(64):true:-:true:-:-,applied_at:timestamp with time zone:true:now():true:-:-" -> Ok `Legacy
      | _ -> error Validation "migration_ledger_invalid"
               "Migration ledger has an unsupported schema.")

type ledger_constraint_row = {
  ledger_constraint_type : string;
  ledger_constraint_name : string;
  ledger_constraint_definition : string;
  ledger_constraint_key : string;
  ledger_constraint_key_dimensions : int;
  ledger_constraint_key_length : int;
  ledger_constraint_key_lower_bound : int;
  ledger_constraint_public_namespace : bool;
  ledger_constraint_validated : bool;
  ledger_constraint_enforced : bool option;
  ledger_constraint_period : bool option;
  ledger_constraint_deferrable : bool;
  ledger_constraint_deferred : bool;
  ledger_constraint_local : bool;
  ledger_constraint_inherited_count : int;
  ledger_constraint_no_inherit : bool;
  ledger_constraint_ancillary_canonical : bool;
}

let valid_ledger_constraints ~server_version_num shape rows =
  let ordinary, not_null =
    List.partition (fun row -> row.ledger_constraint_type <> "n") rows
  in
  let expected_ordinary = match shape with
    | `Current ->
        [ ("p", "PRIMARY KEY (\"position\")");
          ("u", "UNIQUE (version)");
          ("c", "CHECK ((\"position\" > 0))") ]
    | `Legacy -> [ ("p", "PRIMARY KEY (version)") ]
  in
  let ordinary_matches =
    List.length ordinary = List.length expected_ordinary
    && List.for_all (fun expected ->
        List.length (List.filter (fun row ->
            (row.ledger_constraint_type, row.ledger_constraint_definition) = expected) ordinary) = 1)
      expected_ordinary
  in
  let required_columns = match shape with
    | `Current -> [ ("position", "1", "NOT NULL \"position\"");
                    ("version", "2", "NOT NULL version");
                    ("checksum", "3", "NOT NULL checksum");
                    ("applied_at", "4", "NOT NULL applied_at") ]
    | `Legacy -> [ ("version", "1", "NOT NULL version");
                   ("checksum", "2", "NOT NULL checksum");
                   ("applied_at", "3", "NOT NULL applied_at") ]
  in
  let valid_not_null row column key definition =
    row.ledger_constraint_name = "clamp_schema_migrations_" ^ column ^ "_not_null"
    && row.ledger_constraint_definition = definition
    && row.ledger_constraint_key = key
    && row.ledger_constraint_key_dimensions = 1
    && row.ledger_constraint_key_length = 1
    && row.ledger_constraint_key_lower_bound = 1
    && row.ledger_constraint_public_namespace
    && row.ledger_constraint_validated && not row.ledger_constraint_deferrable
    && not row.ledger_constraint_deferred && row.ledger_constraint_local
    && row.ledger_constraint_inherited_count = 0
    && not row.ledger_constraint_no_inherit
    && row.ledger_constraint_enforced = Some true
    && row.ledger_constraint_period = Some false
    && row.ledger_constraint_ancillary_canonical
  in
  let not_null_matches =
    if server_version_num < 180_000 then not_null = []
    else List.length not_null = List.length required_columns
        && List.for_all (fun (column, key, definition) ->
            List.length (List.filter (fun row ->
                valid_not_null row column key definition)
                           not_null) = 1)
          required_columns
  in
  ordinary_matches && not_null_matches

let ledger_constraint_rows result =
  let bool row column = result#getvalue row column = "t" in
  List.init result#ntuples (fun row -> {
      ledger_constraint_type = result#getvalue row 0;
      ledger_constraint_name = result#getvalue row 1;
      ledger_constraint_definition = result#getvalue row 2;
      ledger_constraint_key = result#getvalue row 3;
      ledger_constraint_key_dimensions = int_of_string (result#getvalue row 4);
      ledger_constraint_key_length = int_of_string (result#getvalue row 5);
      ledger_constraint_key_lower_bound = int_of_string (result#getvalue row 6);
      ledger_constraint_public_namespace = bool row 7;
      ledger_constraint_validated = bool row 8;
      ledger_constraint_enforced =
        if result#getisnull row 9 then None else Some (bool row 9);
      ledger_constraint_period =
        if result#getisnull row 10 then None else Some (bool row 10);
      ledger_constraint_deferrable = bool row 11;
      ledger_constraint_deferred = bool row 12;
      ledger_constraint_local = bool row 13;
      ledger_constraint_inherited_count = int_of_string (result#getvalue row 14);
      ledger_constraint_no_inherit = bool row 15;
      ledger_constraint_ancillary_canonical = bool row 16;
    })

let ledger_constraint_query server_version_num =
  let pg18_projection =
    if server_version_num >= 180_000 then "conenforced,conperiod"
    else "NULL::pg_catalog.bool,NULL::pg_catalog.bool"
  in
  "SELECT contype::pg_catalog.text,conname::pg_catalog.text,pg_catalog.pg_get_constraintdef(oid),coalesce(conkey[1]::pg_catalog.text,''),coalesce(pg_catalog.array_ndims(conkey),0),coalesce(pg_catalog.array_length(conkey,1),0),coalesce(pg_catalog.array_lower(conkey,1),0),connamespace OPERATOR(pg_catalog.=) 'public'::pg_catalog.regnamespace,convalidated," ^
  pg18_projection ^
  ",condeferrable,condeferred,conislocal,coninhcount,connoinherit,(conparentid OPERATOR(pg_catalog.=) 0 AND contypid OPERATOR(pg_catalog.=) 0 AND conindid OPERATOR(pg_catalog.=) 0 AND confrelid OPERATOR(pg_catalog.=) 0 AND confupdtype OPERATOR(pg_catalog.=) ' ' AND confdeltype OPERATOR(pg_catalog.=) ' ' AND confmatchtype OPERATOR(pg_catalog.=) ' ' AND confkey IS NULL AND conpfeqop IS NULL AND conppeqop IS NULL AND conffeqop IS NULL AND confdelsetcols IS NULL AND conexclop IS NULL AND conbin IS NULL) FROM pg_catalog.pg_constraint WHERE conrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass ORDER BY contype,conname"

let validate_ledger_catalog connection shape =
  let structural_sql = match shape with
    | `Current ->
        "SELECT (SELECT relnamespace OPERATOR(pg_catalog.=) 'public'::pg_catalog.regnamespace AND relkind OPERATOR(pg_catalog.=) 'r' AND relpersistence OPERATOR(pg_catalog.=) 'p' AND NOT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass) AND (SELECT pg_catalog.count(*) OPERATOR(pg_catalog.=) 2 AND pg_catalog.count(*) FILTER (WHERE indisvalid AND indisready AND indislive AND indexprs IS NULL AND indpred IS NULL AND ((indisprimary AND indisunique AND indkey::pg_catalog.text OPERATOR(pg_catalog.=) (SELECT attnum::pg_catalog.text FROM pg_catalog.pg_attribute WHERE attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND attname OPERATOR(pg_catalog.=) 'position')) OR (NOT indisprimary AND indisunique AND indkey::pg_catalog.text OPERATOR(pg_catalog.=) (SELECT attnum::pg_catalog.text FROM pg_catalog.pg_attribute WHERE attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND attname OPERATOR(pg_catalog.=) 'version')))) OPERATOR(pg_catalog.=) 2 FROM pg_catalog.pg_index WHERE indrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass) AND NOT EXISTS (SELECT FROM pg_catalog.pg_trigger WHERE tgrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND NOT tgisinternal) AND NOT EXISTS (SELECT FROM pg_catalog.pg_rewrite WHERE ev_class OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND rulename OPERATOR(pg_catalog.<>) '_RETURN') AND (SELECT pg_catalog.strpos(adbin::pg_catalog.text, ':funcid ' || 'pg_catalog.now()'::pg_catalog.regprocedure::pg_catalog.oid || ' ') OPERATOR(pg_catalog.>) 0 FROM pg_catalog.pg_attrdef WHERE adrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND adnum OPERATOR(pg_catalog.=) (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND attname OPERATOR(pg_catalog.=) 'applied_at'))"
    | `Legacy ->
        "SELECT (SELECT relnamespace OPERATOR(pg_catalog.=) 'public'::pg_catalog.regnamespace AND relkind OPERATOR(pg_catalog.=) 'r' AND relpersistence OPERATOR(pg_catalog.=) 'p' AND NOT relrowsecurity AND NOT relforcerowsecurity FROM pg_catalog.pg_class WHERE oid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass) AND (SELECT pg_catalog.count(*) OPERATOR(pg_catalog.=) 1 AND pg_catalog.count(*) FILTER (WHERE indisprimary AND indisunique AND indisvalid AND indisready AND indislive AND indexprs IS NULL AND indpred IS NULL AND indkey::pg_catalog.text OPERATOR(pg_catalog.=) (SELECT attnum::pg_catalog.text FROM pg_catalog.pg_attribute WHERE attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND attname OPERATOR(pg_catalog.=) 'version')) OPERATOR(pg_catalog.=) 1 FROM pg_catalog.pg_index WHERE indrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass) AND NOT EXISTS (SELECT FROM pg_catalog.pg_trigger WHERE tgrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND NOT tgisinternal) AND NOT EXISTS (SELECT FROM pg_catalog.pg_rewrite WHERE ev_class OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND rulename OPERATOR(pg_catalog.<>) '_RETURN') AND (SELECT pg_catalog.strpos(adbin::pg_catalog.text, ':funcid ' || 'pg_catalog.now()'::pg_catalog.regprocedure::pg_catalog.oid || ' ') OPERATOR(pg_catalog.>) 0 FROM pg_catalog.pg_attrdef WHERE adrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND adnum OPERATOR(pg_catalog.=) (SELECT attnum FROM pg_catalog.pg_attribute WHERE attrelid OPERATOR(pg_catalog.=) 'public.clamp_schema_migrations'::pg_catalog.regclass AND attname OPERATOR(pg_catalog.=) 'applied_at'))"
  in
  Result.bind (execute connection structural_sql ~expect:[ Postgresql.Tuples_ok ]) (fun structural ->
      if structural#ntuples <> 1 || structural#getvalue 0 0 <> "t" then
        error Validation "migration_ledger_invalid"
          "Migration ledger catalog is not trusted."
      else
        Result.bind (execute connection ~expect:[ Postgresql.Tuples_ok ]
          "SELECT pg_catalog.current_setting('server_version_num')")
          (fun version ->
            try
              if version#ntuples <> 1 then raise Exit;
              let server_version_num = int_of_string (version#getvalue 0 0) in
              Result.bind
                (execute connection ~expect:[ Postgresql.Tuples_ok ]
                   (ledger_constraint_query server_version_num))
                (fun constraints ->
                  if valid_ledger_constraints ~server_version_num shape
                       (ledger_constraint_rows constraints)
                  then Ok ()
                  else error Validation "migration_ledger_invalid"
                      "Migration ledger catalog is not trusted.")
            with _ -> error Validation "migration_ledger_invalid"
                "Migration ledger catalog is not trusted."))

let validate_ledger_rows ledger ~position_column migrations =
  let rec validate row remaining unchanged =
    if row = ledger#ntuples then Ok (remaining, List.rev unchanged)
    else match remaining with
      | [] -> error Validation "migration_history_mismatch"
                "Migration ledger is not an exact prefix of repository migrations."
      | migration :: rest ->
          let offset = if position_column then 1 else 0 in
          let position_matches =
            not position_column
            || int_of_string_opt (ledger#getvalue row 0) = Some migration.position
          in
          let version = ledger#getvalue row offset
          and checksum = ledger#getvalue row (offset + 1) in
          if not position_matches || version <> migration.version then
            error Validation "migration_history_mismatch"
              "Migration ledger is not an exact prefix of repository migrations."
          else if checksum <> migration.checksum then
            error Validation "migration_checksum_mismatch"
              ("Refusing changed historical migration " ^ migration.version ^ ".")
          else validate (row + 1) rest (migration.version :: unchanged)
  in
  validate 0 migrations []

let upgrade_legacy_ledger connection migrations =
  Result.bind (validate_ledger_catalog connection `Legacy) (fun () ->
      Result.bind
          (execute connection ~expect:[ Postgresql.Tuples_ok ]
             "SELECT version, checksum FROM public.clamp_schema_migrations ORDER BY applied_at, version")
          (fun ledger ->
            Result.bind (validate_ledger_rows ledger ~position_column:false migrations)
              (fun (suffix, unchanged) ->
                Result.bind (execute connection
                   "ALTER TABLE public.clamp_schema_migrations RENAME TO clamp_schema_migrations_legacy_upgrade")
                  (fun _ -> Result.bind (execute connection ledger_sql) (fun _ ->
                      Result.bind (lock_ledger connection) (fun () ->
                          Result.bind (execute connection
                             "INSERT INTO public.clamp_schema_migrations(position,version,checksum,applied_at) SELECT pg_catalog.row_number() OVER (ORDER BY applied_at,version)::pg_catalog.int4,version,checksum,applied_at FROM public.clamp_schema_migrations_legacy_upgrade ORDER BY applied_at,version")
                            (fun _ -> Result.bind (execute connection
                               "DROP TABLE public.clamp_schema_migrations_legacy_upgrade")
                              (fun _ -> Result.bind
                                  (validate_ledger_catalog connection `Current)
                                  (fun () -> Ok (suffix, unchanged))))))))))

let read_current_ledger connection migrations =
  Result.bind (validate_ledger_catalog connection `Current) (fun () ->
      Result.bind
        (execute connection
           "SELECT position, version, checksum FROM public.clamp_schema_migrations ORDER BY position"
           ~expect:[ Postgresql.Tuples_ok ])
        (fun ledger -> validate_ledger_rows ledger ~position_column:true migrations))

let prepare_ledger connection migrations =
  Result.bind (ledger_present connection) (fun present ->
      let establish =
        if present then Ok ()
        else
          Result.bind (execute connection "SAVEPOINT clamp_ledger_create") (fun _ ->
              match execute connection ledger_sql with
              | Ok _ -> Result.map (fun _ -> ())
                          (execute connection "RELEASE SAVEPOINT clamp_ledger_create")
              | Error create_failure ->
                  Result.bind
                    (execute connection "ROLLBACK TO SAVEPOINT clamp_ledger_create")
                    (fun _ ->
                      Result.bind (ledger_present connection) (fun now_present ->
                          Result.bind
                            (execute connection "RELEASE SAVEPOINT clamp_ledger_create")
                            (fun _ -> if now_present then Ok () else Error create_failure))))
      in
      Result.bind establish (fun () ->
          Result.bind (lock_ledger connection) (fun () ->
              Result.bind (ledger_shape connection) (function
                | `Legacy -> upgrade_legacy_ledger connection migrations
                | `Current -> read_current_ledger connection migrations))))

let validate_final_ledger connection migrations =
  Result.bind (ledger_shape connection) (function
    | `Legacy -> error Validation "migration_ledger_invalid"
                   "Migration ledger remained in its legacy form."
    | `Current ->
        Result.bind (read_current_ledger connection migrations)
          (fun (remaining, unchanged) ->
            if remaining = [] && List.length unchanged = List.length migrations then Ok ()
            else error Validation "migration_history_mismatch"
                "Migration ledger is not the complete repository migration sequence."))

let verify_local_target connection target =
  Result.bind
    (execute connection ~expect:[ Postgresql.Tuples_ok ]
       "SELECT pg_catalog.current_setting('server_version_num'), pg_catalog.current_setting('port'), pg_catalog.inet_server_addr() IS NULL, pg_catalog.current_setting('data_directory')")
    (fun result ->
      try
        let version = int_of_string (result#getvalue 0 0) / 10_000 in
        let port = int_of_string (result#getvalue 0 1) in
        let unix_socket = result#getvalue 0 2 = "t" in
        let data_directory = result#getvalue 0 3 in
        if result#ntuples = 1 && version = 15 && port = target.port && unix_socket
           && data_directory = target.data_directory then Ok ()
        else error Validation "local_cluster_mismatch"
            "Connection is not the managed local PostgreSQL 15 main cluster."
      with _ -> error Validation "local_cluster_mismatch"
          "Connection is not the managed local PostgreSQL 15 main cluster.")

let validate_vector_extension connection =
  Result.bind
    (execute connection ~expect:[ Postgresql.Tuples_ok ]
       "SELECT pg_catalog.count(*) OPERATOR(pg_catalog.=) 1 AND pg_catalog.bool_and(e.extnamespace OPERATOR(pg_catalog.=) n.oid AND t.typnamespace OPERATOR(pg_catalog.=) n.oid AND td.deptype OPERATOR(pg_catalog.=) 'e' AND td.refobjid OPERATOR(pg_catalog.=) e.oid AND oc.opcnamespace OPERATOR(pg_catalog.=) n.oid AND am.amname OPERATOR(pg_catalog.=) 'hnsw' AND od.deptype OPERATOR(pg_catalog.=) 'e' AND od.refobjid OPERATOR(pg_catalog.=) e.oid) FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) 'public' AND n.oid OPERATOR(pg_catalog.=) e.extnamespace JOIN pg_catalog.pg_type t ON t.typname OPERATOR(pg_catalog.=) 'vector' AND t.typnamespace OPERATOR(pg_catalog.=) n.oid JOIN pg_catalog.pg_depend td ON td.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_type'::pg_catalog.regclass AND td.objid OPERATOR(pg_catalog.=) t.oid AND td.objsubid OPERATOR(pg_catalog.=) 0 AND td.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass JOIN pg_catalog.pg_opclass oc ON oc.opcname OPERATOR(pg_catalog.=) 'vector_cosine_ops' AND oc.opcnamespace OPERATOR(pg_catalog.=) n.oid JOIN pg_catalog.pg_am am ON am.oid OPERATOR(pg_catalog.=) oc.opcmethod AND am.amname OPERATOR(pg_catalog.=) 'hnsw' JOIN pg_catalog.pg_depend od ON od.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_opclass'::pg_catalog.regclass AND od.objid OPERATOR(pg_catalog.=) oc.oid AND od.objsubid OPERATOR(pg_catalog.=) 0 AND od.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass WHERE e.extname OPERATOR(pg_catalog.=) 'vector'")
    (fun result ->
      if result#ntuples = 1 && result#getvalue 0 0 = "t" then Ok ()
      else error Validation "vector_extension_invalid"
          "The vector extension does not have its trusted public catalog identity.")

let apply_migrations ?local_target connection migrations =
  transaction connection ~statement_timeout_ms:120_000 (fun connection ->
      let identity = match local_target with
        | None -> Ok ()
        | Some target -> verify_local_target connection target
      in
      Result.bind identity (fun () ->
        Result.bind
          (execute connection "SELECT pg_catalog.pg_advisory_xact_lock(739704321987654321)" ~expect:[ Postgresql.Tuples_ok ])
          (fun _ ->
          Result.bind (prepare_ledger connection migrations) (fun (suffix, unchanged) ->
                  let initial_vector_identity =
                    if List.mem "0001_enable_vector" unchanged then
                      validate_vector_extension connection
                    else Ok ()
                  in
                  let rec apply applied unchanged = function
                    | [] -> Ok { applied = List.rev applied; already_applied = unchanged;
                                 ledger_count = List.length unchanged + List.length applied }
                    | migration :: rest ->
                        Result.bind (strip_transaction migration) (fun sql ->
                            Result.bind (execute connection sql) (fun _ ->
                                Result.bind
                                  (if migration.position = 1 then validate_vector_extension connection
                                   else Ok ())
                                  (fun () ->
                                Result.bind
                                  (execute connection
                                     ~params:[| string_of_int migration.position; migration.version; migration.checksum |]
                                     ~expect:[ Postgresql.Tuples_ok ]
                                     "INSERT INTO public.clamp_schema_migrations(position, version, checksum) VALUES ($1, $2, $3) RETURNING position,version,checksum")
                                  (fun inserted ->
                                    if inserted#ntuples = 1
                                       && inserted#getvalue 0 0 = string_of_int migration.position
                                       && inserted#getvalue 0 1 = migration.version
                                       && inserted#getvalue 0 2 = migration.checksum then
                                      apply (migration.version :: applied) unchanged rest
                                    else error Validation "migration_ledger_write_invalid"
                                        "Migration ledger insert did not return its exact expected row."))))
                  in Result.bind initial_vector_identity (fun () ->
                    Result.bind (apply [] unchanged suffix) (fun report ->
                      Result.map (fun () -> report)
                        (validate_final_ledger connection migrations)))))))

let with_migrations directory operation =
  Result.bind (load_migrations directory) (fun migrations ->
      if migrations = [] || (List.hd migrations).position <> 1
                         || (List.hd migrations).version <> "0001_enable_vector" then
        error Validation "migration_sequence_invalid" "Migration sequence must begin with 0001_enable_vector."
      else operation migrations)

module For_tests = struct
  let with_local_target target action =
    if not (String.starts_with ~prefix:"/private/tmp/clamp-db-" target.socket_dir)
       || not (String.ends_with ~suffix:"/socket" target.socket_dir)
       || target.data_directory <> Filename.concat (Filename.dirname target.socket_dir) "data"
       || target.port < 1024 || target.port > 65535
    then invalid_arg "private disposable socket target required";
    let previous = !local_target_for_tests in
    Fun.protect ~finally:(fun () -> local_target_for_tests := previous)
      (fun () -> local_target_for_tests := Some target; action ())

  type nonrec ledger_constraint_row = ledger_constraint_row
  let ledger_constraint_row ~constraint_type ~name ~definition ~key
      ?(key_dimensions = 1) ?(key_length = 1) ?(key_lower_bound = 1)
      ?(public_namespace = true)
      ?(validated = true) ?(deferrable = false) ?(deferred = false)
      ?(local = true) ?(inherited_count = 0) ?(no_inherit = false)
      ?(enforced = Some true) ?(period = Some false)
      ?(ancillary_canonical = true) () =
    { ledger_constraint_type = constraint_type;
      ledger_constraint_name = name;
      ledger_constraint_definition = definition;
      ledger_constraint_key = key;
      ledger_constraint_key_dimensions = key_dimensions;
      ledger_constraint_key_length = key_length;
      ledger_constraint_key_lower_bound = key_lower_bound;
      ledger_constraint_public_namespace = public_namespace;
      ledger_constraint_validated = validated;
      ledger_constraint_enforced = enforced;
      ledger_constraint_period = period;
      ledger_constraint_deferrable = deferrable;
      ledger_constraint_deferred = deferred;
      ledger_constraint_local = local;
      ledger_constraint_inherited_count = inherited_count;
      ledger_constraint_no_inherit = no_inherit;
      ledger_constraint_ancillary_canonical = ancillary_canonical }
  let valid_ledger_constraints = valid_ledger_constraints
  let ledger_constraint_query = ledger_constraint_query
end

let with_remote_connection ~url operation =
  Result.bind (validate_remote_url url) (fun () ->
      let deadline = default_effects.now () +. 5. in
      Result.bind (remote_hosts url)
        (fun (hosts, scheme_end, authority_end, hosts_start) ->
              let rec connect_round round last_failure =
                let rec resolve_targets address_count targets last_failure = function
                  | [] ->
                      if targets = [] then
                        (match last_failure with
                        | Some failure -> Error failure
                        | None -> connection_timeout ())
                      else Ok (List.rev targets)
                  | _ when default_effects.now () >= deadline -> connection_timeout ()
                  | host :: rest_hosts ->
                      let remaining = deadline -. default_effects.now () in
                      let cap = remaining /.
                          (2. *. float_of_int (List.length (host :: rest_hosts))) in
                      (match child_deadline ~effects:default_effects ~parent:deadline ~cap with
                      | None -> connection_timeout ()
                      | Some resolve_deadline ->
                      match resolve_host ~effects:default_effects
                              ~deadline:resolve_deadline host.name with
                      | Error `Timeout ->
                          let failure =
                            { kind = Timeout; code = "database_connection_timeout";
                              message = "Database connection timed out.";
                              finalization = Before_commit_dispatch } in
                          resolve_targets address_count targets (Some failure) rest_hosts
                      | Error `Resolve ->
                          let failure =
                            { kind = Transient; code = "database_unavailable";
                              message = "Database host resolution failed.";
                              finalization = Before_commit_dispatch } in
                          resolve_targets address_count targets (Some failure) rest_hosts
                      | Error `Invalid ->
                          error Validation "database_url_invalid"
                            "Database host resolves to an invalid address list."
                      | Ok addresses ->
                          if default_effects.now () >= deadline then connection_timeout ()
                          else
                          let addresses = stable_unique addresses in
                          let address_count = address_count + List.length addresses in
                          if address_count > 8 then
                            error Validation "database_url_invalid"
                              "Database URL resolves to more than eight addresses."
                          else
                            let host_targets =
                              List.map (fun address ->
                                  remote_target_url url ~scheme_end ~authority_end
                                    ~hosts_start host address) addresses
                            in
                            resolve_targets address_count
                              (List.rev_append host_targets targets)
                              last_failure rest_hosts)
                in
                match resolve_targets 0 [] last_failure hosts with
                | Error _ as failure -> failure
                | Ok targets ->
                    match race_remote_connections ~effects:default_effects
                            ~deadline targets with
                    | Ok _ as connection -> connection
                    | Error ({ kind = (Transient | Timeout); _ } as failure)
                      when round < 4 && default_effects.now () < deadline ->
                        let delay = retry_delay default_effects round in
                        if sleep_before_deadline ~effects:default_effects
                             ~deadline delay then
                          connect_round (round + 1) (Some failure)
                        else connection_timeout ()
                    | Error _ as failure -> failure
              in
              protect_connection (fun () -> connect_round 1 None)
                operation))

let migrate_remote_from ~migrations_dir ~url =
  Result.bind (validate_remote_url url) (fun () ->
      with_migrations migrations_dir (fun migrations ->
          with_remote_connection ~url (fun connection ->
              apply_migrations connection migrations)))

let migrate_remote ~repo ~url =
  migrate_remote_from ~migrations_dir:(Filename.concat repo "db/migrations") ~url

let valid_local_database database =
  String.length database >= 1 && String.length database <= 63
  && (match database.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) database

let migrate_local_from ~migrations_dir ~database =
  if not (valid_local_database database) then
    error Validation "local_database_invalid" "Local database name is invalid."
  else with_migrations migrations_dir (fun migrations ->
      Result.bind (discover_local_target ()) (fun target ->
          let user = (Unix.getpwuid (Unix.geteuid ())).pw_name in
          with_clean_local_environment (fun () ->
                protect_connection
                  (fun () -> connect (fun () ->
                       new Postgresql.connection ~host:target.socket_dir
                         ~port:(string_of_int target.port) ~dbname:database ~user
                         ~startonly:true ()))
                  (fun connection ->
                    apply_migrations ~local_target:target connection migrations))))

let migrate_local ~repo ~database =
  migrate_local_from ~migrations_dir:(Filename.concat repo "db/migrations")
    ~database

let nullable result row column = if result#getisnull row column then None else Some (result#getvalue row column)

let conversion operation =
  try operation () with _ ->
    raise (Invalid_argument "database row conversion failed")

let rows result convert =
  try Ok (List.init result#ntuples (convert result)) with _ ->
    error Internal "database_row_invalid" "Database returned an invalid row."

let concept_rows result = rows result (fun result row -> conversion (fun () -> {
    path = result#getvalue row 0; blob_hash = result#getvalue row 1;
    embedding_input_hash = result#getvalue row 2; concept_type = result#getvalue row 3;
    status = result#getvalue row 4; embedding_model = result#getvalue row 5;
    indexed_at = result#getvalue row 6 }))

let access_stats_rows result = rows result (fun result row -> conversion (fun () -> {
    concept_path = result#getvalue row 0; last_accessed_at = nullable result row 1;
    access_count = Int64.of_string (result#getvalue row 2) }))

let index_state_row result =
  if result#ntuples = 0 then Ok None
  else if result#ntuples <> 1 then error Internal "database_row_invalid" "Database returned an invalid index state."
  else
    try Ok (Some { source_repository = result#getvalue 0 0; source_ref = result#getvalue 0 1;
                   last_indexed_commit = nullable result 0 2; embedding_model = result#getvalue 0 3;
                   embedding_dimensions = int_of_string (result#getvalue 0 4);
                   last_indexed_at = nullable result 0 5 })
    with _ -> error Internal "database_row_invalid" "Database returned an invalid index state."

module For_sync = struct
  let with_remote = with_remote_connection
  let execute = execute
  let transaction = transaction
end

module For_retrieval = struct
  let with_remote = with_remote_connection
  let execute = execute
  let transaction = retrieval_transaction
  let transaction_result = retrieval_transaction_result
end
