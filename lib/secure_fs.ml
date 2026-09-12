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
external unsafe_fsync : Unix.file_descr -> unit = "clamp_fsync"
external descriptor_count : unit -> int = "clamp_descriptor_count"
type directory_removal
external watch_directory_removal : Unix.file_descr -> directory_removal
  = "clamp_watch_directory_removal"
external directory_removal_observed : directory_removal -> bool
  = "clamp_directory_removal_observed"
external close_directory_removal : directory_removal -> unit
  = "clamp_close_directory_removal"

let fsync_error_hook = ref (fun (_ : Unix.file_descr) -> ())
let fsync descriptor = !fsync_error_hook descriptor; unsafe_fsync descriptor

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

let same_entry left right =
  left.device = right.device && left.inode = right.inode

let same_identity left right = left = right

let random_component () =
  let bytes = Bytes.create 16 in
  let source = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close source) (fun () ->
      let rec fill offset =
        if offset < Bytes.length bytes then
          match Unix.read source bytes offset (Bytes.length bytes - offset) with
          | 0 -> raise End_of_file
          | count -> fill (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
      in
      fill 0);
  let result = Buffer.create 46 in
  Buffer.add_string result ".clamp-remove-";
  Bytes.iter
    (fun byte ->
      Buffer.add_string result (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents result

let entry_absent parent name =
  try ignore (inspect parent name); false
  with Unix.Unix_error (Unix.ENOENT, _, _) -> true

let entry_matches parent name expected_kind expected_identity descriptor =
  try
    let kind, identity = inspect parent name in
    kind = expected_kind && same_entry identity expected_identity
    && same_entry (descriptor_identity descriptor) expected_identity
  with _ -> false

let rec remove_tree_at ~validate parent name retained expected_identity =
  let kind, observed = inspect parent name in
  if not (same_entry observed expected_identity) then
    raise Rename_validation_failed;
  if not (validate ())
     || not (entry_matches parent name kind expected_identity retained)
  then raise Rename_validation_failed;
  (match kind with
  | Directory ->
      chmod_descriptor retained 0o700
  | _ -> ());
  let quarantine = random_component () in
  rename_noreplace_checked parent name parent quarantine
    ~validate:(fun () ->
      validate () && entry_matches parent name kind expected_identity retained
      && entry_absent parent quarantine);
  if not
       (validate () && entry_absent parent name
        && entry_matches parent quarantine kind expected_identity retained)
  then raise Rename_validation_failed;
  match kind with
  | Directory ->
      let directory = open_directory_at parent quarantine in
      Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
          if not (same_entry expected_identity (descriptor_identity directory)) then
            raise Rename_validation_failed;
          fsync directory;
          if not
               (validate () && entry_absent parent name
                && entry_matches parent quarantine Directory expected_identity
                     retained)
          then raise Rename_validation_failed;
          let entries = ref [] in
          iter_entries directory (fun child -> entries := child :: !entries);
          let descendant_guard () =
            validate () && entry_absent parent name
            && entry_matches parent quarantine Directory expected_identity retained
          in
          List.sort String.compare !entries
          |> List.iter (fun child ->
                 let _, identity = inspect directory child in
                 let descriptor = open_path_at directory child in
                 Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
                     remove_tree_at ~validate:descendant_guard directory child
                       descriptor identity));
          if not
               (validate () && entry_absent parent name
                && entry_matches parent quarantine Directory expected_identity
                     retained)
          then raise Rename_validation_failed;
          let watch = watch_directory_removal retained in
          Fun.protect ~finally:(fun () -> close_directory_removal watch) (fun () ->
              rmdir_at parent quarantine;
              fsync parent;
              if not
                   (validate () && entry_absent parent name
                    && entry_absent parent quarantine
                    && directory_removal_observed watch)
              then raise Rename_validation_failed))
  | Regular | Symlink | Other ->
      let links = descriptor_link_count retained in
      unlink_at parent quarantine;
      fsync parent;
      if not
           (validate () && entry_absent parent name
            && entry_absent parent quarantine
            && descriptor_link_count retained = max 0 (links - 1))
      then raise Rename_validation_failed

type tree_snapshot = {
  tree_identity : identity;
  tree_entries : (string * kind * identity * tree_snapshot option) list;
}

let sync_tree_error_hook = ref (fun () -> ())

let sync_tree path =
  !sync_tree_error_hook ();
  let close_noerr descriptor =
    try Unix.close descriptor with Unix.Unix_error _ -> ()
  in
  let rec tree_matches_directory directory snapshot =
    let entries = ref [] in
    iter_entries directory (fun name -> entries := name :: !entries);
    let names = List.sort String.compare !entries in
    List.map (fun (name, _, _, _) -> name) snapshot.tree_entries = names
    && same_entry snapshot.tree_identity (descriptor_identity directory)
    && List.for_all
         (fun (name, expected_kind, expected_identity, child) ->
           try
             let kind, identity = inspect directory name in
             if kind <> expected_kind || not (same_identity identity expected_identity)
             then false
             else
               match child with
               | None -> true
               | Some child ->
                   let descriptor = open_directory_at directory name in
                   Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
                       tree_matches_directory descriptor child)
           with _ -> false)
         snapshot.tree_entries
  and sync_directory directory =
    let root_identity = descriptor_identity directory in
    let entries = ref [] in
    iter_entries directory (fun name -> entries := name :: !entries);
    let synchronized =
      List.sort String.compare !entries
      |> List.map (fun name ->
           let kind, identity = inspect directory name in
           match kind with
           | Regular ->
               let descriptor = open_file_at directory name in
               Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
                   if not (same_identity identity (descriptor_identity descriptor)) then
                     raise Rename_validation_failed;
                   fsync descriptor;
                   let observed_kind, observed = inspect directory name in
                   if observed_kind <> Regular || not (same_identity identity observed) then
                     raise Rename_validation_failed);
               (name, kind, identity, None)
           | Directory ->
               let descriptor = open_directory_at directory name in
               let child =
                 Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
                     if not (same_identity identity (descriptor_identity descriptor)) then
                       raise Rename_validation_failed;
                     let child = sync_directory descriptor in
                     let observed_kind, observed = inspect directory name in
                     if observed_kind <> Directory || not (same_identity identity observed) then
                       raise Rename_validation_failed;
                     child)
               in
               (name, kind, identity, Some child)
           | Symlink | Other -> raise Rename_validation_failed);
    in
    let snapshot = { tree_identity = root_identity; tree_entries = synchronized } in
    fsync directory;
    if not (tree_matches_directory directory snapshot) then
      raise Rename_validation_failed;
    snapshot
  in
  let root = open_directory path in
  Fun.protect ~finally:(fun () -> close_noerr root) (fun () -> sync_directory root)

let tree_matches descriptor snapshot =
  let close_noerr descriptor =
    try Unix.close descriptor with Unix.Unix_error _ -> ()
  in
  let rec matches directory snapshot =
    let entries = ref [] in
    iter_entries directory (fun name -> entries := name :: !entries);
    List.map (fun (name, _, _, _) -> name) snapshot.tree_entries
    = List.sort String.compare !entries
    && same_entry snapshot.tree_identity (descriptor_identity directory)
    && List.for_all
         (fun (name, expected_kind, expected_identity, child) ->
           try
             let kind, identity = inspect directory name in
             kind = expected_kind && same_identity identity expected_identity
             && match child with
                | None -> true
                | Some child ->
                    let descriptor = open_directory_at directory name in
                    Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
                        matches descriptor child)
           with _ -> false)
         snapshot.tree_entries
  in
  try matches descriptor snapshot with _ -> false

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

  let with_fsync_error_hook hook action =
    let previous = !fsync_error_hook in
    Fun.protect ~finally:(fun () -> fsync_error_hook := previous)
      (fun () -> fsync_error_hook := hook; action ())

  let with_sync_tree_error_hook hook action =
    let previous = !sync_tree_error_hook in
    Fun.protect ~finally:(fun () -> sync_tree_error_hook := previous)
      (fun () -> sync_tree_error_hook := hook; action ())
end
