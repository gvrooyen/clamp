(* This opt-in belongs only to tests, never to the consumer local-database API.
   The harness creates the private cluster and passes its exact root. No URL,
   ambient libpq default, or remote host is accepted here. *)
let root = Sys.getenv_opt "CLAMP_DISPOSABLE_DATABASE"

let native_target path =
  let fail () = failwith "Invalid private disposable database identity" in
  let path = Unix.realpath path in
  if not (String.starts_with ~prefix:"/private/tmp/clamp-db-" path) then fail ();
  let stat = Unix.lstat path in
  if stat.st_kind <> Unix.S_DIR || stat.st_uid <> Unix.geteuid ()
     || stat.st_perm <> 0o700 then fail ();
  let channel = open_in (Filename.concat path "port") in
  let port = Fun.protect ~finally:(fun () -> close_in channel)
      (fun () -> int_of_string (input_line channel)) in
  if port < 1024 || port > 65535 then fail ();
  let socket_dir = Filename.concat path "socket" in
  let data_directory = Filename.concat path "data" in
  let socket = Filename.concat socket_dir (Printf.sprintf ".s.PGSQL.%d" port) in
  if (Unix.lstat socket).st_kind <> Unix.S_SOCK then fail ();
  let connection = new Postgresql.connection ~host:socket_dir
      ~port:(string_of_int port) ~dbname:"postgres"
      ~user:(Unix.getpwuid (Unix.geteuid ())).pw_name () in
  Fun.protect ~finally:(fun () -> connection#finish) (fun () ->
      let rows = connection#exec
          "SELECT current_setting('data_directory'), current_setting('server_version_num'), current_setting('listen_addresses')" in
      if rows#getvalue 0 0 <> data_directory || rows#getvalue 0 1 <> "150019"
         || rows#getvalue 0 2 <> "127.0.0.1" then fail ());
  { Clamp.Database.socket_dir; port; data_directory }

let discover () =
  match root with
  | Some path -> Ok (native_target path)
  | None -> Clamp.Database.discover_local_target ()

let run action =
  match root with
  | None -> action ()
  | Some path -> Clamp.Database.For_tests.with_local_target (native_target path) action

let administer target database sql =
  match root with
  | None -> false
  | Some path ->
      let expected = native_target path in
      if expected <> target then failwith "Disposable target changed";
      let connection = new Postgresql.connection ~host:target.Clamp.Database.socket_dir
          ~port:(string_of_int target.port) ~dbname:database
          ~user:(Unix.getpwuid (Unix.geteuid ())).pw_name () in
      Fun.protect ~finally:(fun () -> connection#finish) (fun () ->
          ignore (connection#exec ~expect:[Postgresql.Command_ok] sql));
      true
