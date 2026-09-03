type kind = Regular | Directory | Symlink | Other

exception Atomic_rename_unavailable
exception Private_creation_unwitnessed
exception Rename_validation_failed

type identity = {
  device : int64;
  inode : int64;
  size : int64;
  modified_seconds : int64;
  modified_nanoseconds : int;
  changed_seconds : int64;
  changed_nanoseconds : int;
}

external unsafe_open_directory : string -> Unix.file_descr = "clamp_open_directory"
external unsafe_open_directory_at : Unix.file_descr -> string -> Unix.file_descr
  = "clamp_open_directory_at"
external unsafe_open_file_at : Unix.file_descr -> string -> Unix.file_descr
  = "clamp_open_file_at"
external unsafe_open_path_at : Unix.file_descr -> string -> Unix.file_descr
  = "clamp_open_path_at"
external unsafe_create_file_at : Unix.file_descr -> string -> Unix.file_descr = "clamp_create_file_at"
external unsafe_flock : Unix.file_descr -> bool -> unit = "clamp_flock"
external funlock : Unix.file_descr -> unit = "clamp_funlock"
external unsafe_mkdir_at : Unix.file_descr -> string -> unit = "clamp_mkdir_at"
external unsafe_mkdir_private_at : Unix.file_descr -> string -> Unix.file_descr
  = "clamp_mkdir_private_at"
external chmod_descriptor : Unix.file_descr -> int -> unit
  = "clamp_chmod_descriptor"
external unsafe_rename_noreplace : Unix.file_descr -> string -> Unix.file_descr -> string -> unit = "clamp_rename_noreplace"
external unsafe_rename_exchange : Unix.file_descr -> string -> Unix.file_descr -> string -> unit = "clamp_rename_exchange"
external unsafe_unlink_at : Unix.file_descr -> string -> unit = "clamp_unlink_at"
external unsafe_rmdir_at : Unix.file_descr -> string -> unit = "clamp_rmdir_at"
type directory_stream

external open_directory_stream : Unix.file_descr -> directory_stream
  = "clamp_open_directory_stream"
external directory_stream_next : directory_stream -> string option
  = "clamp_directory_stream_next"
external close_directory_stream : directory_stream -> unit
  = "clamp_close_directory_stream"
external stat_at :
  Unix.file_descr ->
  string ->
  int * int64 * int64 * int64 * int64 * int * int64 * int
  = "clamp_stat_at"
external stat_descriptor :
  Unix.file_descr -> int * int64 * int64 * int64 * int64 * int * int64 * int
  = "clamp_stat_descriptor"
external descriptor_link_count : Unix.file_descr -> int = "clamp_descriptor_link_count"
external descriptor_owner_mode : Unix.file_descr -> int * int
  = "clamp_descriptor_owner_mode"
external effective_uid : unit -> int = "clamp_effective_uid"

let identity
    (_, device, inode, size, modified_seconds, modified_nanoseconds,
      changed_seconds, changed_nanoseconds) =
  { device; inode; size; modified_seconds; modified_nanoseconds; changed_seconds;
    changed_nanoseconds }

let valid_component component =
  component <> "" && component <> "." && component <> ".."
  && not (String.contains component '/') && not (String.contains component '\000')

let require_component component =
  if not (valid_component component) then
    invalid_arg "unsafe relative path component"

let open_directory path =
  if String.contains path '\000' then invalid_arg "directory path contains NUL";
  unsafe_open_directory path

let open_directory_at directory name =
  require_component name;
  unsafe_open_directory_at directory name

let open_file_at directory name =
  require_component name;
  unsafe_open_file_at directory name

let open_path_at directory name =
  require_component name;
  unsafe_open_path_at directory name

let create_file_at directory name = require_component name; unsafe_create_file_at directory name
let mkdir_at directory name = require_component name; unsafe_mkdir_at directory name
let mkdir_private_at directory name =
  require_component name;
  try unsafe_mkdir_private_at directory name
  with Failure _ ->
    raise Private_creation_unwitnessed
let rename_error_hook = ref (fun () -> ())
let flock_error_hook = ref (fun () -> ())
let flock descriptor exclusive = !flock_error_hook (); unsafe_flock descriptor exclusive
let atomic_rename action =
  try
    !rename_error_hook ();
    action ()
  with
  | Unix.Unix_error ((Unix.ENOSYS | Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
      raise Atomic_rename_unavailable

let checked_atomic_rename ~validate action =
  (try !rename_error_hook () with
  | Unix.Unix_error ((Unix.ENOSYS | Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
      raise Atomic_rename_unavailable);
  let valid = try validate () with _ -> false in
  if not valid then raise Rename_validation_failed;
  try action () with
  | Unix.Unix_error ((Unix.ENOSYS | Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
      raise Atomic_rename_unavailable

let rename_noreplace_checked ~validate olddir oldname newdir newname =
  require_component oldname;
  require_component newname;
  checked_atomic_rename ~validate (fun () ->
      unsafe_rename_noreplace olddir oldname newdir newname)

let rename_exchange_checked ~validate olddir oldname newdir newname =
  require_component oldname;
  require_component newname;
  checked_atomic_rename ~validate (fun () ->
      unsafe_rename_exchange olddir oldname newdir newname)

let rename_noreplace olddir oldname newdir newname =
  rename_noreplace_checked ~validate:(fun () -> true) olddir oldname newdir newname

let rename_exchange olddir oldname newdir newname =
  rename_exchange_checked ~validate:(fun () -> true) olddir oldname newdir newname
let unlink_at directory name = require_component name; unsafe_unlink_at directory name
let rmdir_at directory name = require_component name; unsafe_rmdir_at directory name

let inspect directory name =
  require_component name;
  let result = stat_at directory name in
  let kind, _, _, _, _, _, _, _ = result in
  let kind =
    match kind with 0 -> Regular | 1 -> Directory | 2 -> Symlink | _ -> Other
  in
  (kind, identity result)

let descriptor_identity descriptor = identity (stat_descriptor descriptor)

let iter_entries directory callback =
  let stream = open_directory_stream directory in
  Fun.protect
    ~finally:(fun () -> close_directory_stream stream)
    (fun () ->
      let rec loop () =
        match directory_stream_next stream with
        | None -> ()
        | Some name ->
            callback name;
            loop ()
      in
      loop ())

let open_beneath root relative =
  let components = String.split_on_char '/' relative in
  if
    components = []
    || List.exists (fun component -> not (valid_component component)) components
  then invalid_arg "relative path contains an unsafe component";
  let close_noerr descriptor = try Unix.close descriptor with Unix.Unix_error _ -> () in
  let rec descend current = function
    | [ filename ] ->
        let file =
          try open_file_at current filename
          with exception_value ->
            close_noerr current;
            raise exception_value
        in
        (match Unix.close current with
        | () -> file
        | exception exception_value ->
            close_noerr file;
            raise exception_value)
    | directory :: rest ->
        let next =
          try open_directory_at current directory
          with exception_value ->
            close_noerr current;
            raise exception_value
        in
        (match Unix.close current with
        | () -> descend next rest
        | exception exception_value ->
            close_noerr next;
            raise exception_value)
    | [] -> assert false
  in
  descend (Unix.dup ~cloexec:true root) components

module For_test = struct
  let with_rename_error_hook hook action =
    let previous = !rename_error_hook in
    Fun.protect ~finally:(fun () -> rename_error_hook := previous)
      (fun () -> rename_error_hook := hook; action ())

  let with_flock_error_hook hook action =
    let previous = !flock_error_hook in
    Fun.protect ~finally:(fun () -> flock_error_hook := previous)
      (fun () -> flock_error_hook := hook; action ())
end
