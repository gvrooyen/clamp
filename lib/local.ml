open Exact_yaml

module String_set = Set.Make (String)

type error = { code : string; message : string }
type task_due = Due_on of string | Due_at of string * Timedesc.Timestamp.t
type task = {
  id : string;
  doc : Frontmatter.t;
  state : string;
  priority : string;
  title : string;
  due : task_due option;
}

let error code message = Error { code; message }
let ( let* ) result continuation = Result.bind result continuation
let scalar value = Scalar (String, value)
let string = function Scalar (String, value) -> Some value | _ -> None
let find = Exact_yaml.find
let set key value = function
  | Map fields -> Map ((key, value) :: List.remove_assoc key fields)
  | value -> value
let remove key = function
  | Map fields -> Map (List.remove_assoc key fields)
  | value -> value
let close_noerr descriptor = try Unix.close descriptor with _ -> ()
exception Private_cleanup_uncertain

let clock = ref Unix.gettimeofday
let now () = !clock ()

type operation = Temp_create | Write | File_fsync | Rename | Dir_fsync | Unlink
  | Rollback | Mkdir | Directory_open | Mode_repair | Private_revalidate | Rmdir
let operation_hook = ref (fun (_ : operation) -> ())
let final_gate_failure_hook = ref (fun () -> ())
type ownership_phase =
  | Before_target_install
  | After_target_exchange
  | Before_target_restore
  | Before_target_restore_capture
  | After_target_restore_capture
  | Before_temp_cleanup
  | After_temp_capture
  | After_directory_create
  | Before_directory_cleanup
  | After_directory_capture
  | Before_private_destruct
let ownership_hook = ref (fun (_ : ownership_phase) -> ())
let perform operation action = !operation_hook operation; action ()
let rename_noreplace ~validate olddir oldname newdir newname =
  !operation_hook Rename;
  try Secure_fs.rename_noreplace_checked ~validate olddir oldname newdir newname
  with Secure_fs.Rename_validation_failed -> raise Private_cleanup_uncertain
let rename_exchange ~validate olddir oldname newdir newname =
  !operation_hook Rename;
  try Secure_fs.rename_exchange_checked ~validate olddir oldname newdir newname
  with Secure_fs.Rename_validation_failed -> raise Private_cleanup_uncertain
let fsync_file descriptor = perform File_fsync (fun () -> Unix.fsync descriptor)
let fsync_dir descriptor = perform Dir_fsync (fun () -> Unix.fsync descriptor)
let mkdir_private_path directory name =
  perform Mkdir (fun () -> Secure_fs.mkdir_private_at directory name)
let open_directory_at directory name =
  perform Directory_open (fun () -> Secure_fs.open_directory_at directory name)
let recovery_attempts = 4

let rec retry remaining action =
  try action () with exception_value ->
    if remaining <= 1 then raise exception_value
    else
      match exception_value with
      | Secure_fs.Rename_validation_failed | Private_cleanup_uncertain ->
          raise exception_value
      | _ -> retry (remaining - 1) action

let uncertain () =
  error "rollback_state_uncertain"
    "Could not verify local state after a failed mutation."

let final_uncertain () =
  error "rollback_state_uncertain_after_cleanup"
    "Could not verify local state after a failed mutation."

let exit_class (issue : error) =
  if
    List.mem issue.code
      [ "rollback_state_uncertain"; "write_failed"; "lock_failed";
        "repository_changed"; "ulid_collision"; "atomic_rename_unavailable" ]
  then Exit_class.Internal
  else Exit_class.User_error

let utc_timestamp time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let johannesburg_tm time = Unix.gmtime (time +. 7200.)

let johannesburg_date_at time =
  let tm = johannesburg_tm time in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday

let timestamp () = utc_timestamp (now ())
let johannesburg_date () = johannesburg_date_at (now ())

let write_all descriptor contents =
  !operation_hook Write;
  let bytes = Bytes.of_string contents in
  let rec loop offset =
    if offset < Bytes.length bytes then
      match Unix.write descriptor bytes offset (Bytes.length bytes - offset) with
      | 0 -> raise End_of_file
      | count -> loop (offset + count)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
  in
  loop 0

let read_descriptor descriptor expected =
  match Safe_file.read_descriptor ~expected descriptor with
  | Ok contents -> Ok contents
  | Error issue -> error (Safe_file.code issue) (Safe_file.message issue ^ ".")

let read path =
  let directory_name = Filename.dirname path and name = Filename.basename path in
  if String.contains directory_name '\000' || not (Secure_fs.valid_component name) then
    error "invalid_input_path" "Input path is malformed."
  else try
    let directory = Secure_fs.open_directory directory_name in
    Fun.protect ~finally:(fun () -> close_noerr directory) (fun () ->
        let kind, expected = Secure_fs.inspect directory name in
        if kind <> Secure_fs.Regular then
          error "file_not_regular" "File must be regular and not a symlink."
        else
          Result.bind
            (read_descriptor (Secure_fs.open_file_at directory name) expected)
            (fun contents ->
              if Frontmatter.valid_utf8 contents then Ok contents
              else error "invalid_utf8" "Input must be UTF-8."))
  with Sys_error _ | Unix.Unix_error _ ->
    error "file_unreadable" "File is missing or unreadable."

let read_at directory name =
  try
    let kind, expected = Secure_fs.inspect directory name in
    if kind <> Secure_fs.Regular then
      error "file_not_regular" "Managed files must be regular and not symlinks."
    else read_descriptor (Secure_fs.open_file_at directory name) expected
  with Unix.Unix_error (Unix.ENOENT, _, _) -> error "file_not_found" "Managed file does not exist."
     | Unix.Unix_error _ | Sys_error _ ->
         error "file_unreadable" "Managed file is unreadable."

let read_at_optional directory name =
  match read_at directory name with
  | Ok contents -> Ok (Some contents)
  | Error { code = "file_not_found"; _ } -> Ok None
  | Error issue -> Error issue

let same_entry (left : Secure_fs.identity) (right : Secure_fs.identity) =
  left.device = right.device && left.inode = right.inode

let repository_guard = ref (fun () -> true)

let with_repo repo action =
  try
    let root = Secure_fs.open_directory repo in
    Fun.protect ~finally:(fun () -> close_noerr root) (fun () ->
        let original = Secure_fs.descriptor_identity root in
        let original_owner, original_mode =
          Secure_fs.descriptor_owner_mode root
        in
        let original_euid = Secure_fs.effective_uid () in
        let unchanged () =
          try
            let reopened = Secure_fs.open_directory repo in
            Fun.protect ~finally:(fun () -> close_noerr reopened) (fun () ->
                let owner, mode = Secure_fs.descriptor_owner_mode reopened in
                original_owner = original_euid
                && Secure_fs.effective_uid () = original_euid
                && owner = original_owner && mode = original_mode
                && same_entry original (Secure_fs.descriptor_identity root)
                && same_entry original (Secure_fs.descriptor_identity reopened))
          with _ -> false
        in
        let previous_guard = !repository_guard in
        let result = Fun.protect ~finally:(fun () -> repository_guard := previous_guard)
            (fun () ->
              repository_guard := unchanged;
              try action root
              with Secure_fs.Atomic_rename_unavailable ->
                error "atomic_rename_unavailable"
                  "Required atomic rename semantics are unavailable."
                 | Unix.Unix_error _ | Sys_error _ | Failure _ ->
                     error "write_failed" "Local operation failed.")
        in
        match result with
        | Error { code = "rollback_state_uncertain_after_cleanup"; _ } ->
            uncertain ()
        | Error { code = "rollback_state_uncertain"; _ } as result -> result
        | (Ok _ | Error _) as result ->
            if unchanged () then result
            else error "repository_changed"
                   "Repository root changed during the operation.")
  with Unix.Unix_error _ | Sys_error _ ->
    error "repository_unreadable" "Repository root is unreadable or unsafe."
     | Secure_fs.Atomic_rename_unavailable ->
         error "atomic_rename_unavailable"
           "Required atomic rename semantics are unavailable."

let with_root_lock ~exclusive root action =
  match Secure_fs.flock root exclusive with
  | () ->
      Fun.protect ~finally:(fun () -> try Secure_fs.funlock root with _ -> ()) action
  | exception (Unix.Unix_error _ | Sys_error _ | Failure _) ->
      error "lock_failed" "Could not acquire the repository mutation lock."

let with_lock root action = with_root_lock ~exclusive:true root action

let with_shared_repo repo action =
  with_repo repo (fun root ->
      with_root_lock ~exclusive:false root (fun () -> action root))

let with_exclusive_repo repo action =
  with_repo repo (fun root ->
      with_root_lock ~exclusive:true root (fun () -> action root))

let entry_absent directory name =
  try ignore (Secure_fs.inspect directory name); false
  with Unix.Unix_error (Unix.ENOENT, _, _) -> true
     | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false

let inspect_identity directory name =
  try Some (snd (Secure_fs.inspect directory name))
  with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let temp_name _basename =
  let bytes = Bytes.create 16 in
  let descriptor = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
      let rec fill offset =
        if offset < Bytes.length bytes then
          match Unix.read descriptor bytes offset (Bytes.length bytes - offset) with
          | 0 -> raise End_of_file
          | count -> fill (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
      in
      fill 0);
  let hex = "0123456789abcdef" in
  let output = Bytes.create 32 in
  Bytes.iteri (fun i byte ->
      Bytes.set output (i * 2) hex.[Char.code byte lsr 4];
      Bytes.set output (i * 2 + 1) hex.[Char.code byte land 15]) bytes;
  ".clamp-" ^ Bytes.unsafe_to_string output ^ ".tmp"

type retained_chain_entry = {
  chain_name : string;
  chain_identity : Secure_fs.identity;
  chain_descriptor : Unix.file_descr;
  chain_owner : int;
  chain_mode : int;
}

let retain_chain_entry name descriptor =
  let retained = Unix.dup ~cloexec:true descriptor in
  try
    let identity = Secure_fs.descriptor_identity retained in
    let owner, mode = Secure_fs.descriptor_owner_mode retained in
    if owner <> Secure_fs.effective_uid () then begin
      close_noerr retained;
      None
    end else
      Some
        { chain_name = name; chain_identity = identity;
          chain_descriptor = retained; chain_owner = owner; chain_mode = mode }
  with exception_value ->
    close_noerr retained;
    raise exception_value

let chain_descriptor_valid entry =
  let owner, mode = Secure_fs.descriptor_owner_mode entry.chain_descriptor in
  same_entry (Secure_fs.descriptor_identity entry.chain_descriptor)
    entry.chain_identity
  && owner = entry.chain_owner && owner = Secure_fs.effective_uid ()
  && mode = entry.chain_mode

let close_chain chain =
  List.iter (fun entry -> close_noerr entry.chain_descriptor) chain

let revalidate_chain root chain =
  let rec walk parent = function
    | [] -> true
    | entry :: rest ->
        (try
           let kind, observed = Secure_fs.inspect parent entry.chain_name in
           if kind <> Secure_fs.Directory
              || not (same_entry observed entry.chain_identity)
              || not (chain_descriptor_valid entry)
           then false
           else
             let opened = Secure_fs.open_directory_at parent entry.chain_name in
             Fun.protect ~finally:(fun () -> close_noerr opened) (fun () ->
                 let owner, mode = Secure_fs.descriptor_owner_mode opened in
                 same_entry (Secure_fs.descriptor_identity opened)
                   entry.chain_identity
                 && owner = entry.chain_owner
                 && owner = Secure_fs.effective_uid ()
                 && mode = entry.chain_mode
                 && walk opened rest)
         with Unix.Unix_error _ | Sys_error _ -> false)
  in
  !repository_guard () && walk root chain

type private_kind = Private_file | Private_directory
type ownership_state = Prepared | Captured | Installed | Removed_durable

type private_directory_cleanup_proof =
  | Parent_chain
  | Parent_mode
  | Removed_directory_nlink
  | Quarantine_absence

let private_directory_cleanup_proof_hook =
  ref (fun (_ : private_directory_cleanup_proof) (_ : bool) -> ())

type retained_descriptor = {
  retained_descriptor : Unix.file_descr;
  retained_identity : Secure_fs.identity;
  mutable retained_open : bool;
}

type completion_witness = {
  completion_check : unit -> bool;
  completion_failure : error;
  completion_enforce_on_error : bool;
  completion_close : unit -> unit;
}

type public_witness_descriptor = {
  witness_descriptor : Unix.file_descr;
  witness_identity : Secure_fs.identity;
  witness_owner : int;
  witness_mode : int;
  witness_links : int option;
}

type transaction = {
  root : Unix.file_descr;
  root_identity : Secure_fs.identity;
  clamp : Unix.file_descr;
  clamp_identity : Secure_fs.identity;
  transactions : Unix.file_descr;
  transactions_identity : Secure_fs.identity;
  directory : Unix.file_descr;
  name : string;
  identity : Secure_fs.identity;
  mutable retained : retained_descriptor list;
  mutable completion_witnesses : completion_witness list;
  mutable preinstall_witnesses : (unit -> bool) list;
  mutable cleanup_uncertain : bool;
}

type private_entry = {
  mutable private_name : string;
  descriptor : Unix.file_descr;
  identity : Secure_fs.identity;
  kind : private_kind;
  required_mode : int;
  expected_owner : int;
  expected_mode : int;
  expected_links : int option;
  mutable ownership : ownership_state;
  mutable contents : string option;
}

type private_snapshot = {
  snapshot_contents : string;
  snapshot_descriptor : Unix.file_descr;
  snapshot_identity : Secure_fs.identity;
  snapshot_mode : int;
  snapshot_links : int;
}

type installed_entry = {
  prepared : private_entry;
  snapshot : private_snapshot option;
  public_directory : Unix.file_descr;
  public_name : string;
  mutable installed : bool;
  mutable receipt : bool;
}

let random_component prefix =
  let generated = temp_name prefix in
  prefix ^ String.sub generated 7 32

let retain_descriptor transaction descriptor =
  transaction.retained <-
    { retained_descriptor = descriptor;
      retained_identity = Secure_fs.descriptor_identity descriptor;
      retained_open = true }
    :: transaction.retained

let release_retained transaction descriptor =
  match
    List.find_opt
      (fun retained -> retained.retained_descriptor = descriptor)
      transaction.retained
  with
  | Some retained when retained.retained_open ->
      retained.retained_open <- false;
      close_noerr retained.retained_descriptor
  | Some _ -> ()
  | None -> close_noerr descriptor

let close_retained transaction =
  List.iter
    (fun retained ->
      if retained.retained_open then begin
        retained.retained_open <- false;
        close_noerr retained.retained_descriptor
      end)
    transaction.retained;
  transaction.retained <- []

let close_completion_witnesses transaction =
  List.iter
    (fun witness -> witness.completion_close ())
    transaction.completion_witnesses;
  transaction.completion_witnesses <- []

let private_descriptor ~mode:required_mode descriptor =
  let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
  owner = Secure_fs.effective_uid () && mode = required_mode

let path_matches_descriptor parent name kind descriptor identity =
  try
    let observed_kind, observed = Secure_fs.inspect parent name in
    observed_kind = kind && same_entry observed identity
    && same_entry (Secure_fs.descriptor_identity descriptor) identity
  with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false

let cleanup_created_entry ?(validate_parent = fun () -> true) parent name kind
    descriptor identity =
  try
    let expected_kind =
      match kind with Private_file -> Secure_fs.Regular | Private_directory -> Secure_fs.Directory
    in
    let expected_owner, expected_mode = Secure_fs.descriptor_owner_mode descriptor in
    let expected_links =
      match kind with
      | Private_file -> Some (Secure_fs.descriptor_link_count descriptor)
      | Private_directory -> None
    in
    let expected_contents =
      match kind with
      | Private_directory -> None
      | Private_file ->
          let duplicate = Unix.dup ~cloexec:true descriptor in
          Fun.protect ~finally:(fun () -> close_noerr duplicate) (fun () ->
              ignore (Unix.lseek duplicate 0 Unix.SEEK_SET);
              match read_descriptor duplicate identity with
              | Ok contents -> Some contents
              | Error _ -> raise Private_cleanup_uncertain)
    in
    let descriptor_exact () =
      let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
      same_entry identity (Secure_fs.descriptor_identity descriptor)
      && owner = expected_owner && owner = Secure_fs.effective_uid ()
      && mode = expected_mode
      && Option.fold ~none:true
           ~some:(fun expected ->
             Secure_fs.descriptor_link_count descriptor = expected)
           expected_links
      && Option.fold ~none:true
           ~some:(fun expected ->
             let duplicate = Unix.dup ~cloexec:true descriptor in
             Fun.protect ~finally:(fun () -> close_noerr duplicate) (fun () ->
                 ignore (Unix.lseek duplicate 0 Unix.SEEK_SET);
                 match read_descriptor duplicate identity with
                 | Ok actual -> actual = expected
                 | Error _ -> false))
           expected_contents
    in
    if not
         (validate_parent ()
          && path_matches_descriptor parent name expected_kind descriptor identity
          && descriptor_exact ())
    then false
    else
      let quarantine = random_component "quarantine-" in
      rename_noreplace
        ~validate:(fun () ->
          validate_parent () && entry_absent parent quarantine
          && path_matches_descriptor parent name expected_kind descriptor identity
          && descriptor_exact ())
        parent name parent quarantine;
      if not
           (path_matches_descriptor parent quarantine expected_kind descriptor identity)
      then false
      else begin
        (match kind with
        | Private_file -> Secure_fs.unlink_at parent quarantine
        | Private_directory -> Secure_fs.rmdir_at parent quarantine);
        retry recovery_attempts (fun () -> fsync_dir parent);
        validate_parent () && entry_absent parent quarantine
        && Secure_fs.descriptor_link_count descriptor = 0
      end
  with _ -> false

let create_private_directory ?(validate_parent = fun () -> true) parent name =
  if not (validate_parent ()) then raise Private_cleanup_uncertain;
  match mkdir_private_path parent name with
  | exception Secure_fs.Private_creation_unwitnessed -> uncertain ()
  | exception (Unix.Unix_error (Unix.EEXIST, _, _) as exception_value) ->
      raise exception_value
  | exception (Unix.Unix_error _ | Sys_error _) ->
      error "write_failed" "Could not create Clamp private state."
  | descriptor ->
      let identity = Secure_fs.descriptor_identity descriptor in
      let transfer = ref false in
      Fun.protect
        ~finally:(fun () -> if not !transfer then close_noerr descriptor)
        (fun () ->
          try
            perform Directory_open (fun () ->
                if not
                     (path_matches_descriptor parent name Secure_fs.Directory descriptor
                        identity
                      && fst (Secure_fs.descriptor_owner_mode descriptor)
                         = Secure_fs.effective_uid ())
                then raise Private_cleanup_uncertain);
            perform Mode_repair (fun () -> Secure_fs.chmod_descriptor descriptor 0o700);
            perform Private_revalidate (fun () ->
                if not
                     (path_matches_descriptor parent name Secure_fs.Directory descriptor
                        identity
                      && private_descriptor ~mode:0o700 descriptor)
                then raise Private_cleanup_uncertain);
            transfer := true;
            Ok (descriptor, identity)
          with exception_value ->
            let clean =
              cleanup_created_entry ~validate_parent parent name Private_directory
                descriptor identity
            in
            if clean then begin
              ignore exception_value;
              error "write_failed" "Could not create Clamp private state."
            end
            else uncertain ())

let ensure_private_directory ?(validate_parent = fun () -> true) parent name =
  let open_existing () =
    if not (validate_parent ()) then raise Private_cleanup_uncertain;
    match Secure_fs.inspect parent name with
    | Secure_fs.Directory, expected ->
        let descriptor = Secure_fs.open_directory_at parent name in
        let transfer = ref false in
        Fun.protect
          ~finally:(fun () -> if not !transfer then close_noerr descriptor)
          (fun () ->
            if validate_parent ()
               && same_entry expected (Secure_fs.descriptor_identity descriptor)
               && private_descriptor ~mode:0o700 descriptor
            then begin
              let result = Ok descriptor in
              transfer := true;
              result
            end
            else uncertain ())
    | _ -> uncertain ()
  in
  try
    open_existing ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      (try match create_private_directory ~validate_parent parent name with
       | Error issue -> Error issue
       | Ok (path_descriptor, identity) ->
         Fun.protect ~finally:(fun () -> close_noerr path_descriptor) (fun () ->
         try
         fsync_dir parent;
         if not (validate_parent ()) then raise Private_cleanup_uncertain;
         let descriptor = open_directory_at parent name in
         if validate_parent ()
            && path_matches_descriptor parent name Secure_fs.Directory descriptor identity
            && private_descriptor ~mode:0o700 descriptor
         then Ok descriptor
         else begin
           close_noerr descriptor;
           if
             cleanup_created_entry ~validate_parent parent name Private_directory
               path_descriptor identity
           then error "write_failed" "Could not create Clamp private state."
           else uncertain ()
         end
       with Unix.Unix_error _ | Sys_error _ | Failure _ ->
         if
           cleanup_created_entry ~validate_parent parent name Private_directory
             path_descriptor identity
         then error "write_failed" "Could not create Clamp private state."
         else uncertain ())
       with Unix.Unix_error (Unix.EEXIST, _, _) ->
         (try
            fsync_dir parent;
            if not (validate_parent ()) then raise Private_cleanup_uncertain;
            open_existing ()
          with Unix.Unix_error _ | Sys_error _ | Failure _ -> uncertain ()))
  | Unix.Unix_error _ | Sys_error _ -> uncertain ()

let capture_and_remove_private_directory ?(validate_parent = fun () -> true)
    parent name descriptor identity =
  try
    let quarantine = random_component "quarantine-" in
    rename_noreplace
      ~validate:(fun () ->
        validate_parent () && entry_absent parent quarantine
        && path_matches_descriptor parent name Secure_fs.Directory descriptor identity
        && private_descriptor ~mode:0o700 descriptor)
      parent name parent quarantine;
    !ownership_hook Before_private_destruct;
    !operation_hook Rmdir;
    (match inspect_identity parent quarantine with
    | Some captured
      when validate_parent () && private_descriptor ~mode:0o700 parent
           && same_entry captured identity
           && same_entry identity (Secure_fs.descriptor_identity descriptor)
           && private_descriptor ~mode:0o700 descriptor -> ()
    | _ -> raise Exit);
    Secure_fs.rmdir_at parent quarantine;
    retry recovery_attempts (fun () -> fsync_dir parent);
    let evaluate predicate = try predicate () with _ -> false in
    let parent_chain = evaluate validate_parent in
    let parent_mode =
      evaluate (fun () -> private_descriptor ~mode:0o700 parent)
    in
    let removed_directory_nlink =
      evaluate (fun () -> Secure_fs.descriptor_link_count descriptor = 0)
    in
    let quarantine_absence =
      evaluate (fun () -> entry_absent parent quarantine)
    in
    !private_directory_cleanup_proof_hook Parent_chain parent_chain;
    !private_directory_cleanup_proof_hook Parent_mode parent_mode;
    !private_directory_cleanup_proof_hook Removed_directory_nlink
      removed_directory_nlink;
    !private_directory_cleanup_proof_hook Quarantine_absence quarantine_absence;
    parent_chain && parent_mode && removed_directory_nlink
    && quarantine_absence
  with _ -> false

let create_transaction root =
  let root_identity = Secure_fs.descriptor_identity root in
  let root_owner, root_mode = Secure_fs.descriptor_owner_mode root in
  let root_valid () =
    !repository_guard ()
    && same_entry root_identity (Secure_fs.descriptor_identity root)
    && Secure_fs.descriptor_owner_mode root = (root_owner, root_mode)
  in
  Result.bind (ensure_private_directory ~validate_parent:root_valid root ".clamp")
    (fun clamp ->
      let transfer_clamp = ref false in
      Fun.protect ~finally:(fun () -> if not !transfer_clamp then close_noerr clamp)
        (fun () ->
          let clamp_identity = Secure_fs.descriptor_identity clamp in
          let clamp_chain_valid () =
            root_valid ()
            && private_descriptor ~mode:0o700 clamp
            && same_entry clamp_identity (Secure_fs.descriptor_identity clamp)
            && match inspect_identity root ".clamp" with
               | Some observed -> same_entry observed clamp_identity
               | None -> false
          in
          match
            ensure_private_directory ~validate_parent:clamp_chain_valid clamp
              "transactions"
          with
          | Error issue -> Error issue
          | Ok transactions ->
          let transfer_transactions = ref false in
          Fun.protect
            ~finally:(fun () ->
              if not !transfer_transactions then close_noerr transactions)
            (fun () ->
          let transactions_identity = Secure_fs.descriptor_identity transactions in
          let private_parent_chain_valid () =
            let linked parent name descriptor identity =
              same_entry identity (Secure_fs.descriptor_identity descriptor)
              && private_descriptor ~mode:0o700 descriptor
              && match inspect_identity parent name with
                 | Some observed -> same_entry observed identity
                 | None -> false
            in
            !repository_guard ()
            && same_entry root_identity (Secure_fs.descriptor_identity root)
            && linked root ".clamp" clamp clamp_identity
            && linked clamp "transactions" transactions transactions_identity
          in
          let rec create remaining =
            if remaining = 0 then
              error "write_failed" "Could not allocate a private transaction."
            else
              let name = random_component "tx-" in
              let made = ref false in
              let clean_unopened_transaction () =
                try
                  let kind, identity = Secure_fs.inspect transactions name in
                  if kind <> Secure_fs.Directory then false
                  else
                    let directory =
                      retry recovery_attempts (fun () ->
                          open_directory_at transactions name)
                    in
                    Fun.protect ~finally:(fun () -> close_noerr directory)
                      (fun () ->
                        same_entry identity
                          (Secure_fs.descriptor_identity directory)
                        && private_descriptor ~mode:0o700 directory
                        && capture_and_remove_private_directory
                             ~validate_parent:private_parent_chain_valid
                             transactions name directory identity)
                with _ -> false
              in
              try
                let path_descriptor, created_identity =
                  match
                    create_private_directory
                      ~validate_parent:private_parent_chain_valid transactions name
                  with
                  | Ok created -> created
                  | Error issue ->
                      if issue.code = "rollback_state_uncertain" then
                        raise Private_cleanup_uncertain
                      else raise (Failure issue.message)
                in
                made := true;
                let identity = created_identity in
                let directory =
                  try open_directory_at transactions name
                  with exception_value ->
                    let clean =
                      cleanup_created_entry
                        ~validate_parent:private_parent_chain_valid transactions name
                        Private_directory path_descriptor identity
                    in
                    close_noerr path_descriptor;
                    if clean then raise exception_value
                    else raise Private_cleanup_uncertain
                in
                close_noerr path_descriptor;
                let transfer_directory = ref false in
                Fun.protect
                  ~finally:(fun () ->
                    if not !transfer_directory then close_noerr directory)
                  (fun () ->
                  let opened_identity = Secure_fs.descriptor_identity directory in
                  if not (same_entry identity opened_identity
                          && private_descriptor ~mode:0o700 directory)
                  then raise Private_cleanup_uncertain;
                  try
                   (match inspect_identity transactions name with
                   | Some observed when same_entry observed opened_identity -> ()
                   | _ -> raise Private_cleanup_uncertain);
                   fsync_dir transactions;
                   let result =
                     Ok { root; root_identity; clamp; clamp_identity; transactions;
                          transactions_identity; directory; name;
                          identity = opened_identity; retained = [];
                          completion_witnesses = []; preinstall_witnesses = [];
                          cleanup_uncertain = false }
                   in
                   transfer_directory := true;
                   result
                  with _ ->
                   let clean =
                     capture_and_remove_private_directory
                       ~validate_parent:private_parent_chain_valid transactions name
                       directory opened_identity
                   in
                   if clean then
                     error "write_failed" "Could not allocate a private transaction."
                   else uncertain ())
              with
              | Unix.Unix_error (Unix.EEXIST, _, _) -> create (remaining - 1)
              | Private_cleanup_uncertain -> uncertain ()
              | Unix.Unix_error _ | Sys_error _ | Failure _ ->
                  if !made then
                    if clean_unopened_transaction () then
                      error "write_failed" "Could not allocate a private transaction."
                    else uncertain ()
                  else error "write_failed" "Could not allocate a private transaction."
          in
          let result = create 16 in
          match result with
          | Ok _ ->
              transfer_transactions := true;
              transfer_clamp := true;
              result
          | Error _ -> result)))

let transaction_chain_valid transaction =
  let linked parent name descriptor identity =
    same_entry identity (Secure_fs.descriptor_identity descriptor)
    && private_descriptor ~mode:0o700 descriptor
    && match inspect_identity parent name with Some observed -> same_entry observed identity | None -> false
  in
  !repository_guard ()
  && same_entry transaction.root_identity (Secure_fs.descriptor_identity transaction.root)
  && linked transaction.root ".clamp" transaction.clamp transaction.clamp_identity
  && linked transaction.clamp "transactions" transaction.transactions transaction.transactions_identity
  && linked transaction.transactions transaction.name transaction.directory transaction.identity

let transaction_ancestors_valid transaction =
  let linked parent name descriptor identity =
    same_entry identity (Secure_fs.descriptor_identity descriptor)
    && private_descriptor ~mode:0o700 descriptor
    && match inspect_identity parent name with
       | Some observed -> same_entry observed identity
       | None -> false
  in
  !repository_guard ()
  && same_entry transaction.root_identity (Secure_fs.descriptor_identity transaction.root)
  && linked transaction.root ".clamp" transaction.clamp transaction.clamp_identity
  && linked transaction.clamp "transactions" transaction.transactions
       transaction.transactions_identity

let registered_inputs_valid transaction =
  List.for_all (fun check -> try check () with _ -> false)
    transaction.preinstall_witnesses

let final_public_gate transaction ~validate ~exact () =
  let valid =
    try
      transaction_chain_valid transaction
      && registered_inputs_valid transaction
      && validate () && exact ()
    with _ -> false
  in
  if not valid then (try !final_gate_failure_hook () with _ -> ());
  valid

let final_rename_noreplace transaction ~validate ~exact olddir oldname newdir
    newname =
  rename_noreplace ~validate:(final_public_gate transaction ~validate ~exact)
    olddir oldname newdir newname

let final_rename_exchange transaction ~validate ~exact olddir oldname newdir
    newname =
  rename_exchange ~validate:(final_public_gate transaction ~validate ~exact)
    olddir oldname newdir newname

let transaction_empty transaction =
  try
    let empty = ref true in
    Secure_fs.iter_entries transaction.directory (fun _ -> empty := false);
    !empty
  with _ -> false

let remove_transaction transaction =
  if not
       (transaction_chain_valid transaction && registered_inputs_valid transaction
        && transaction_empty transaction)
  then false
  else
    capture_and_remove_private_directory
      ~validate_parent:(fun () ->
        transaction_ancestors_valid transaction
        && registered_inputs_valid transaction)
      transaction.transactions transaction.name transaction.directory transaction.identity

let with_transaction root action =
  Result.bind (create_transaction root) (fun transaction ->
      let result =
        try action transaction
        with Secure_fs.Atomic_rename_unavailable ->
          error "atomic_rename_unavailable"
            "Required atomic rename semantics are unavailable."
           | Private_cleanup_uncertain -> uncertain ()
           | Unix.Unix_error _ | Sys_error _ | Failure _ ->
               error "write_failed" "Local transaction failed."
      in
      let inputs_valid = registered_inputs_valid transaction in
      let clean = inputs_valid && remove_transaction transaction in
      let private_final =
        clean && transaction_ancestors_valid transaction
        && entry_absent transaction.transactions transaction.name
        && Secure_fs.descriptor_link_count transaction.directory = 0
      in
      let witness_failure =
        if private_final then
          List.find_opt
            (fun witness ->
              (match result with
              | Ok _ -> true
              | Error _ -> witness.completion_enforce_on_error)
              && not (witness.completion_check ()))
            transaction.completion_witnesses
        else None
      in
      close_completion_witnesses transaction;
      close_retained transaction;
      close_noerr transaction.directory;
      close_noerr transaction.transactions;
      close_noerr transaction.clamp;
      if not inputs_valid then uncertain ()
      else if not private_final || transaction.cleanup_uncertain then final_uncertain ()
      else
        match witness_failure with
        | Some _ -> final_uncertain ()
        | None -> result)

let private_contents_match entry =
  match entry.contents with
  | None -> true
  | Some expected ->
      (try
         let observed = Secure_fs.descriptor_identity entry.descriptor in
         if not (same_entry observed entry.identity) then false
         else
           let duplicate = Unix.dup ~cloexec:true entry.descriptor in
           ignore (Unix.lseek duplicate 0 Unix.SEEK_SET);
           match read_descriptor duplicate observed with
           | Ok contents -> contents = expected
           | Error _ -> false
       with Unix.Unix_error _ | Sys_error _ -> false)

let private_matches transaction entry =
  match inspect_identity transaction.directory entry.private_name with
  | Some identity ->
      let owner, mode = Secure_fs.descriptor_owner_mode entry.descriptor in
      same_entry identity entry.identity
      && same_entry (Secure_fs.descriptor_identity entry.descriptor) entry.identity
      && owner = entry.expected_owner
      && owner = Secure_fs.effective_uid ()
      && mode = entry.expected_mode
      && private_contents_match entry
      && Option.fold ~none:true
           ~some:(fun expected ->
             Secure_fs.descriptor_link_count entry.descriptor = expected)
           entry.expected_links
  | None -> false

let remove_private transaction entry =
  if entry.ownership = Removed_durable then true
  else
    let removed = ref false in
    let remaining_links = ref None in
    let removal_is_proven () =
      entry_absent transaction.directory entry.private_name
      && match entry.kind with
         | Private_directory ->
             Secure_fs.descriptor_link_count entry.descriptor = 0
         | Private_file ->
             (match (entry.expected_links, !remaining_links) with
             | Some baseline, remaining ->
                 let expected = Option.value remaining ~default:(baseline - 1) in
                 same_entry (Secure_fs.descriptor_identity entry.descriptor)
                   entry.identity
                 && private_descriptor ~mode:entry.required_mode entry.descriptor
                 && private_contents_match entry
                 && Secure_fs.descriptor_link_count entry.descriptor = expected
             | None, _ -> false)
    in
    try
      retry recovery_attempts (fun () ->
          if not !removed then begin
            if not (transaction_chain_valid transaction) then raise Exit;
            !ownership_hook Before_temp_cleanup;
            if removal_is_proven () then removed := true
            else begin
              let quarantine = random_component "quarantine-" in
              final_rename_noreplace transaction ~validate:(fun () -> true)
                ~exact:(fun () ->
                  private_matches transaction entry
                  && entry_absent transaction.directory quarantine)
                transaction.directory entry.private_name transaction.directory
                quarantine;
              !ownership_hook After_temp_capture;
              if not (same_entry entry.identity (Secure_fs.descriptor_identity entry.descriptor))
              then raise Exit;
              entry.private_name <- quarantine;
              entry.ownership <- Captured;
              !ownership_hook Before_private_destruct;
              (match entry.kind with
              | Private_file ->
                  !operation_hook Unlink;
                  if not (private_matches transaction entry
                          && private_descriptor ~mode:entry.required_mode entry.descriptor
                          && private_contents_match entry
                          && Option.exists
                               (fun expected ->
                                 Secure_fs.descriptor_link_count entry.descriptor
                                 = expected)
                               entry.expected_links)
                  then raise Exit;
                  remaining_links :=
                    Option.map (fun expected -> expected - 1) entry.expected_links;
                  Secure_fs.unlink_at transaction.directory entry.private_name
              | Private_directory ->
                  !ownership_hook Before_directory_cleanup;
                  !operation_hook Rmdir;
                  if not (private_matches transaction entry
                          && private_descriptor ~mode:0o700 entry.descriptor)
                  then raise Exit;
                  Secure_fs.rmdir_at transaction.directory entry.private_name);
              removed := true
            end
          end;
          fsync_dir transaction.directory);
      if !removed && removal_is_proven () then begin
        entry.ownership <- Removed_durable;
        release_retained transaction entry.descriptor;
        true
      end else false
    with _ -> false

let prepare_private_file transaction contents =
  let rec attempt remaining =
    if remaining = 0 then error "write_failed" "Could not allocate a private file."
    else
      let name = random_component "file-" in
      try
        let descriptor =
          perform Temp_create (fun () -> Secure_fs.create_file_at transaction.directory name)
        in
        let identity = Secure_fs.descriptor_identity descriptor in
        (try
           perform Mode_repair (fun () ->
               if not
                    (path_matches_descriptor transaction.directory name
                       Secure_fs.Regular descriptor identity
                     && fst (Secure_fs.descriptor_owner_mode descriptor)
                        = Secure_fs.effective_uid ())
               then raise Private_cleanup_uncertain;
               Secure_fs.chmod_descriptor descriptor 0o600);
           perform Private_revalidate (fun () ->
               if not
                    (path_matches_descriptor transaction.directory name
                       Secure_fs.Regular descriptor identity
                     && private_descriptor ~mode:0o600 descriptor)
               then raise Private_cleanup_uncertain)
         with exception_value ->
           let clean =
             cleanup_created_entry
               ~validate_parent:(fun () -> transaction_chain_valid transaction)
               transaction.directory name Private_file descriptor identity
           in
           close_noerr descriptor;
           if clean then begin
             ignore exception_value;
             raise (Failure "private file mode repair failed")
           end
           else raise Private_cleanup_uncertain);
        let expected_owner, expected_mode =
          Secure_fs.descriptor_owner_mode descriptor
        in
        let entry =
          { private_name = name; descriptor;
            identity;
            kind = Private_file; required_mode = 0o600;
            expected_owner; expected_mode;
            expected_links = Some 1;
            ownership = Prepared; contents = None }
        in
        retain_descriptor transaction descriptor;
        (try
           write_all descriptor contents;
           fsync_file descriptor;
           entry.contents <- Some contents;
           Ok entry
         with exception_value ->
           if remove_private transaction entry then
             error "write_failed" "Atomic local write preparation failed."
           else begin
             ignore exception_value;
             uncertain ()
           end)
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (remaining - 1)
      | Unix.Unix_error _ | Sys_error _ | End_of_file | Failure _ ->
          error "write_failed" "Atomic local write preparation failed."
  in
  attempt 16

let snapshot_private transaction directory basename =
  let result =
    try
      let kind, identity = Secure_fs.inspect directory basename in
      if kind <> Secure_fs.Regular then
        error "file_not_regular" "Managed files must be regular and not symlinks."
      else
        let descriptor = Secure_fs.open_file_at directory basename in
        let transferred = ref false in
        Fun.protect
          ~finally:(fun () -> if not !transferred then close_noerr descriptor)
          (fun () ->
            if not (same_entry identity (Secure_fs.descriptor_identity descriptor)) then
              error "repository_changed" "Managed target changed while it was opened."
            else
              let duplicate =
                try Ok (Unix.dup ~cloexec:true descriptor)
                with Unix.Unix_error _ | Sys_error _ ->
                  error "write_failed" "Could not retain the managed target."
              in
              match duplicate with
              | Error issue -> Error issue
              | Ok duplicate -> match read_descriptor duplicate identity with
              | Error issue -> Error issue
              | Ok contents ->
                  let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
                  if owner <> Secure_fs.effective_uid () then
                    error "repository_changed" "Managed target ownership is unsafe."
                  else
                    let links = Secure_fs.descriptor_link_count descriptor in
                    retain_descriptor transaction descriptor;
                    transferred := true;
                    Ok (Some { snapshot_contents = contents;
                             snapshot_descriptor = descriptor;
                             snapshot_identity = identity; snapshot_mode = mode;
                             snapshot_links = links }))
    with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
       | Unix.Unix_error _ | Sys_error _ ->
           error "file_unreadable" "Managed target is unreadable."
  in
  (match result with Error _ -> transaction.cleanup_uncertain <- true | Ok _ -> ());
  result

let public_matches_descriptor ?expected_owner ?expected_mode ?expected_links
    directory name descriptor expected_contents =
  try
    let retained = Secure_fs.descriptor_identity descriptor in
    let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
    let owner_mode_match =
      Option.fold ~none:true ~some:(fun expected -> owner = expected) expected_owner
      && Option.fold ~none:true ~some:(fun expected -> mode = expected) expected_mode
      && owner = Secure_fs.effective_uid ()
    in
    let links_match =
      Option.fold ~none:true
        ~some:(fun expected ->
          Secure_fs.descriptor_link_count descriptor = expected)
        expected_links
    in
    match inspect_identity directory name with
    | Some identity when same_entry identity retained ->
        owner_mode_match && links_match && (match expected_contents with
        | None ->
            (match inspect_identity directory name with
            | Some after -> same_entry after retained
            | None -> false)
        | Some expected ->
            let opened = Secure_fs.open_file_at directory name in
            (match read_descriptor opened retained with
            | Error _ -> false
            | Ok actual ->
                actual = expected
                && match inspect_identity directory name with
                   | Some after -> same_entry after retained
                   | None -> false))
    | _ -> false
  with Unix.Unix_error _ | Sys_error _ -> false

let public_matches_prepared directory name prepared =
  public_matches_descriptor ~expected_owner:prepared.expected_owner
    ~expected_mode:prepared.expected_mode ?expected_links:prepared.expected_links
    directory name prepared.descriptor prepared.contents

let descriptor_contents descriptor identity =
  let duplicate = Unix.dup ~cloexec:true descriptor in
  Fun.protect ~finally:(fun () -> close_noerr duplicate) (fun () ->
      ignore (Unix.lseek duplicate 0 Unix.SEEK_SET);
      match read_descriptor duplicate identity with
      | Ok contents -> contents
      | Error _ -> raise Private_cleanup_uncertain)

let witness_uncertain =
  { code = "rollback_state_uncertain";
    message = "Could not verify local state after a failed mutation." }

let capture_public_witness_descriptor ?expected_links opened descriptor =
  let copy = Unix.dup ~cloexec:true descriptor in
  opened := copy :: !opened;
  let identity = Secure_fs.descriptor_identity copy in
  let owner, mode = Secure_fs.descriptor_owner_mode copy in
  if owner <> Secure_fs.effective_uid () then raise Private_cleanup_uncertain;
  Option.iter
    (fun expected ->
      if Secure_fs.descriptor_link_count copy <> expected then
        raise Private_cleanup_uncertain)
    expected_links;
  { witness_descriptor = copy; witness_identity = identity;
    witness_owner = owner; witness_mode = mode; witness_links = expected_links }

let public_witness_descriptor_valid expected =
  let owner, mode = Secure_fs.descriptor_owner_mode expected.witness_descriptor in
  same_entry (Secure_fs.descriptor_identity expected.witness_descriptor)
    expected.witness_identity
  && owner = expected.witness_owner
  && owner = Secure_fs.effective_uid ()
  && mode = expected.witness_mode
  && Option.fold ~none:true
       ~some:(fun links ->
         Secure_fs.descriptor_link_count expected.witness_descriptor = links)
       expected.witness_links

let revalidate_public_witness_chain root root_state chain =
  let rec walk parent = function
    | [] -> true
    | (name, expected) :: rest ->
        (try
           let kind, observed = Secure_fs.inspect parent name in
           if kind <> Secure_fs.Directory
              || not (same_entry observed expected.witness_identity)
              || not (public_witness_descriptor_valid expected)
           then false
           else
             let opened = Secure_fs.open_directory_at parent name in
             Fun.protect ~finally:(fun () -> close_noerr opened) (fun () ->
                 let owner, mode = Secure_fs.descriptor_owner_mode opened in
                 same_entry (Secure_fs.descriptor_identity opened)
                   expected.witness_identity
                 && owner = expected.witness_owner
                 && owner = Secure_fs.effective_uid ()
                 && mode = expected.witness_mode
                 && walk opened rest)
         with Unix.Unix_error _ | Sys_error _ -> false)
  in
  !repository_guard () && public_witness_descriptor_valid root_state
  && walk root chain

let public_witness_file_valid directory name target expected_contents =
  public_witness_descriptor_valid target
  && public_matches_descriptor directory.witness_descriptor name
       target.witness_descriptor (Some expected_contents)
  && public_witness_descriptor_valid directory

let register_public_witness ?(enforce_on_error = false) ?expected_owner
    ?expected_mode ?expected_links transaction root chain directory name target
    expected_contents =
  let opened = ref [] in
  try
    let root_state = capture_public_witness_descriptor opened root in
    let retained_chain =
      List.map
        (fun entry ->
          let state =
            capture_public_witness_descriptor opened entry.chain_descriptor
          in
          if not (same_entry entry.chain_identity state.witness_identity)
             || state.witness_owner <> entry.chain_owner
             || state.witness_mode <> entry.chain_mode
          then
            raise Private_cleanup_uncertain;
          (entry.chain_name, state))
        chain
    in
    let retained_directory = capture_public_witness_descriptor opened directory in
    let retained_target =
      capture_public_witness_descriptor ?expected_links opened target
    in
    Option.iter
      (fun owner ->
        if retained_target.witness_owner <> owner then
          raise Private_cleanup_uncertain)
      expected_owner;
    Option.iter
      (fun mode ->
        if retained_target.witness_mode <> mode then
          raise Private_cleanup_uncertain)
      expected_mode;
    let close () = List.iter close_noerr !opened; opened := [] in
    let check () =
      try
        revalidate_public_witness_chain root root_state retained_chain
        && public_witness_file_valid retained_directory name retained_target
             expected_contents
      with _ -> false
    in
    transaction.completion_witnesses <-
      { completion_check = check; completion_failure = witness_uncertain;
        completion_enforce_on_error = enforce_on_error;
        completion_close = close }
      :: transaction.completion_witnesses
  with exception_value ->
    List.iter close_noerr !opened;
    raise exception_value

let register_absence_witness transaction root chain directory name =
  let opened = ref [] in
  try
    let root_state = capture_public_witness_descriptor opened root in
    let retained_chain =
      List.map
        (fun entry ->
          let state =
            capture_public_witness_descriptor opened entry.chain_descriptor
          in
          if not (same_entry entry.chain_identity state.witness_identity)
             || state.witness_owner <> entry.chain_owner
             || state.witness_mode <> entry.chain_mode
          then
            raise Private_cleanup_uncertain;
          (entry.chain_name, state))
        chain
    in
    let retained_directory = capture_public_witness_descriptor opened directory in
    let close () = List.iter close_noerr !opened; opened := [] in
    let check () =
      try
        revalidate_public_witness_chain root root_state retained_chain
        && public_witness_descriptor_valid retained_directory
        && entry_absent retained_directory.witness_descriptor name
      with _ -> false
    in
    transaction.completion_witnesses <-
      { completion_check = check;
        completion_failure = witness_uncertain;
        completion_enforce_on_error = true;
        completion_close = close }
      :: transaction.completion_witnesses
  with exception_value ->
    List.iter close_noerr !opened;
    raise exception_value

let register_initial_state_witness transaction root chain directory name = function
  | None ->
      (try register_absence_witness transaction root chain directory name
       with _ -> raise Private_cleanup_uncertain)
  | Some snapshot ->
      let opened = ref [] in
      (try
         let root_state = capture_public_witness_descriptor opened root in
         let retained_chain =
           List.map
             (fun entry ->
               let state =
                 capture_public_witness_descriptor opened entry.chain_descriptor
               in
               if not (same_entry entry.chain_identity state.witness_identity)
                  || state.witness_owner <> entry.chain_owner
                  || state.witness_mode <> entry.chain_mode
               then
                 raise Private_cleanup_uncertain;
               (entry.chain_name, state))
             chain
         in
         let retained_directory =
           capture_public_witness_descriptor opened directory
         in
         let retained_target =
           capture_public_witness_descriptor
             ~expected_links:snapshot.snapshot_links opened
             snapshot.snapshot_descriptor
         in
         let close () = List.iter close_noerr !opened; opened := [] in
         let check () =
           try
             revalidate_public_witness_chain root root_state retained_chain
             && retained_target.witness_mode = snapshot.snapshot_mode
             && public_witness_file_valid retained_directory name retained_target
                  snapshot.snapshot_contents
           with _ -> false
         in
         transaction.completion_witnesses <-
           { completion_check = check;
             completion_failure = witness_uncertain;
             completion_enforce_on_error = true;
             completion_close = close }
           :: transaction.completion_witnesses
       with exception_value ->
         List.iter close_noerr !opened;
         ignore exception_value;
         raise Private_cleanup_uncertain)

let release_initial_state transaction root chain directory name snapshot =
  register_initial_state_witness transaction root chain directory name snapshot;
  Option.iter
    (fun old -> release_retained transaction old.snapshot_descriptor)
    snapshot

let snapshot_matches_private directory name = function
  | None -> entry_absent directory name
  | Some snapshot ->
      public_matches_descriptor ~expected_owner:(Secure_fs.effective_uid ())
        ~expected_mode:snapshot.snapshot_mode
        ~expected_links:snapshot.snapshot_links directory name
        snapshot.snapshot_descriptor (Some snapshot.snapshot_contents)
      && private_descriptor ~mode:snapshot.snapshot_mode
           snapshot.snapshot_descriptor

type install_outcome =
  | Install_ok of installed_entry
  | Install_failed of installed_entry option * error

let install_private transaction ~validate directory basename prepared snapshot =
  if not (!repository_guard () && transaction_chain_valid transaction) then
    Install_failed (None,
      { code = "rollback_state_uncertain";
        message = "Could not verify local state after a failed mutation." })
  else if not (validate ()) then
    Install_failed (None,
      { code = "repository_changed";
        message = "Managed path changed during the operation." })
  else if not (snapshot_matches_private directory basename snapshot) then
    Install_failed (None,
      { code = "rollback_state_uncertain";
        message = "Could not verify local state after a failed mutation." })
  else
    let installed_state = ref None in
    try
      !ownership_hook Before_target_install;
      let final_install_gate () =
        private_matches transaction prepared
        && snapshot_matches_private directory basename snapshot
      in
      let exchanged = Option.is_some snapshot in
      (match snapshot with
      | None ->
          final_rename_noreplace transaction ~validate
            ~exact:final_install_gate transaction.directory
            prepared.private_name directory basename
      | Some _ ->
          final_rename_exchange transaction ~validate
            ~exact:final_install_gate transaction.directory
            prepared.private_name directory basename);
      prepared.ownership <- Installed;
      let receipt = Option.is_some snapshot in
      let installed_entry =
        { prepared; snapshot; public_directory = directory; public_name = basename;
          installed = true; receipt }
      in
      installed_state := Some installed_entry;
      if exchanged then !ownership_hook After_target_exchange;
      fsync_dir directory;
      let operation_valid =
        !repository_guard () && transaction_chain_valid transaction
      in
      let path_valid = validate () in
      let requested_is_public =
        public_matches_prepared directory basename prepared
      in
      let public_valid = operation_valid && path_valid && requested_is_public in
      let receipt_valid =
        match snapshot with
        | None -> entry_absent transaction.directory prepared.private_name
        | Some old ->
            snapshot_matches_private transaction.directory prepared.private_name
              (Some old)
      in
      if public_valid && receipt_valid then begin
        Install_ok installed_entry
      end
      else if Option.is_some snapshot && public_valid && not receipt_valid then begin
        (* The entry captured by EXCHANGE was not the snapshot we opened.  Move
           it aside privately, then atomically capture the current public leaf.
           Restore only into an absent public name, so a newer winner is never
           overwritten while retaining every captured entry as evidence. *)
        let captured = Secure_fs.open_file_at transaction.directory prepared.private_name in
        let current = ref None in
        Fun.protect
          ~finally:(fun () ->
            Option.iter close_noerr !current;
            close_noerr captured)
          (fun () ->
           let captured_identity = Secure_fs.descriptor_identity captured in
           let captured_owner, captured_mode =
             Secure_fs.descriptor_owner_mode captured
           in
           let captured_links = Secure_fs.descriptor_link_count captured in
           let captured_contents = descriptor_contents captured captured_identity in
           let foreign_name = random_component "displaced-" in
           try
           if not (transaction_chain_valid transaction && validate ()
                   && same_entry captured_identity
                        (Secure_fs.descriptor_identity captured))
           then raise Exit;
           final_rename_noreplace transaction ~validate
             ~exact:(fun () ->
               entry_absent transaction.directory foreign_name
               && public_matches_descriptor ~expected_owner:captured_owner
                    ~expected_mode:captured_mode ~expected_links:captured_links
                    transaction.directory prepared.private_name captured
                    (Some captured_contents))
             transaction.directory prepared.private_name transaction.directory
             foreign_name;
           fsync_dir transaction.directory;
           if not (transaction_chain_valid transaction && validate ()
                   && public_matches_descriptor transaction.directory foreign_name
                        captured None)
           then raise Exit;
           final_rename_noreplace transaction ~validate
             ~exact:(fun () ->
               public_matches_prepared directory basename prepared
               && entry_absent transaction.directory prepared.private_name)
             directory basename transaction.directory prepared.private_name;
           prepared.ownership <- Captured;
           installed_entry.installed <- false;
           installed_entry.receipt <- false;
           fsync_dir transaction.directory;
           let current_descriptor =
             Secure_fs.open_file_at transaction.directory prepared.private_name
           in
           current := Some current_descriptor;
           let current_identity = Secure_fs.descriptor_identity current_descriptor in
           let current_owner, current_mode =
             Secure_fs.descriptor_owner_mode current_descriptor
           in
           let current_links = Secure_fs.descriptor_link_count current_descriptor in
           let current_contents =
             descriptor_contents current_descriptor current_identity
           in
           let current_is_requested =
             public_matches_prepared transaction.directory prepared.private_name prepared
           in
           let restore_name, restore_descriptor, restore_owner, restore_mode,
               restore_links, restore_contents =
             if current_is_requested then
               (foreign_name, captured, captured_owner, captured_mode,
                captured_links, captured_contents)
             else
               (prepared.private_name, current_descriptor, current_owner,
                current_mode, current_links, current_contents)
           in
           (try
              final_rename_noreplace transaction ~validate
                ~exact:(fun () ->
                  entry_absent directory basename
                  && public_matches_descriptor ~expected_owner:restore_owner
                       ~expected_mode:restore_mode ~expected_links:restore_links
                       transaction.directory restore_name restore_descriptor
                       (Some restore_contents))
                transaction.directory restore_name directory basename;
              fsync_dir directory;
              fsync_dir transaction.directory
            with Unix.Unix_error (Unix.EEXIST, _, _) ->
              fsync_dir directory;
              fsync_dir transaction.directory);
           if not
                (public_matches_descriptor directory basename restore_descriptor None
                 || not (entry_absent directory basename))
           then raise Exit;
           close_noerr current_descriptor;
           current := None;
           Install_failed
             (Some installed_entry,
              { code = "rollback_state_uncertain";
                message = "Could not verify local state after a failed mutation." })
         with _ ->
           Install_failed
             (Some installed_entry,
              { code = "rollback_state_uncertain";
                message = "Could not verify local state after a failed mutation." }))
      end else
        Install_failed
          (Some installed_entry,
           if operation_valid && not path_valid && requested_is_public
              && receipt_valid
           then
             { code = "repository_changed";
               message = "Managed path changed during the operation." }
           else
             { code = "write_failed";
               message = "Atomic local installation failed." })
    with Secure_fs.Atomic_rename_unavailable -> raise Secure_fs.Atomic_rename_unavailable
       | Private_cleanup_uncertain ->
           Install_failed
             (!installed_state,
              { code = "rollback_state_uncertain";
                message = "Could not verify local state after a failed mutation." })
       | Unix.Unix_error (Unix.EEXIST, _, _) when Option.is_none snapshot ->
           Install_failed
             (None,
              { code = "rollback_state_uncertain";
                message = "Managed target appeared during atomic installation." })
       | Unix.Unix_error _ | Sys_error _ | Failure _ ->
           Install_failed (!installed_state,
             { code = "write_failed"; message = "Atomic local installation failed." })

let remove_snapshot_receipt transaction installed =
  match installed.snapshot with
  | None -> true
  | Some snapshot ->
      let receipt =
        { private_name = installed.prepared.private_name;
          descriptor = snapshot.snapshot_descriptor;
          identity = snapshot.snapshot_identity; kind = Private_file;
          required_mode = snapshot.snapshot_mode;
          expected_owner = Secure_fs.effective_uid ();
          expected_mode = snapshot.snapshot_mode;
          expected_links = Some snapshot.snapshot_links;
          ownership = Captured; contents = Some snapshot.snapshot_contents }
      in
      let removed = remove_private transaction receipt in
      if removed then installed.receipt <- false;
      removed

let finish_install transaction ~validate ~on_success installed =
  on_success installed.prepared.descriptor;
  let old_removed = remove_snapshot_receipt transaction installed in
  let current =
    validate ()
    && public_matches_prepared installed.public_directory installed.public_name
         installed.prepared
  in
  if old_removed && current then begin
    release_retained transaction installed.prepared.descriptor;
    true
  end else false

let restore_foreign_capture transaction ~validate installed =
  try
    let captured =
      match installed.prepared.kind with
      | Private_file ->
          Secure_fs.open_file_at transaction.directory installed.prepared.private_name
      | Private_directory ->
          Secure_fs.open_directory_at transaction.directory installed.prepared.private_name
    in
    let captured_identity = Secure_fs.descriptor_identity captured in
    let captured_owner, captured_mode = Secure_fs.descriptor_owner_mode captured in
    let captured_links, captured_contents =
      match installed.prepared.kind with
      | Private_file ->
          (Some (Secure_fs.descriptor_link_count captured),
           Some (descriptor_contents captured captured_identity))
      | Private_directory -> (None, None)
    in
    let restored =
      try
        final_rename_noreplace transaction ~validate
          ~exact:(fun () ->
            entry_absent installed.public_directory installed.public_name
            && public_matches_descriptor ~expected_owner:captured_owner
                 ~expected_mode:captured_mode ?expected_links:captured_links
                 transaction.directory installed.prepared.private_name captured
                 captured_contents)
          transaction.directory installed.prepared.private_name
          installed.public_directory installed.public_name;
        fsync_dir installed.public_directory;
        public_matches_descriptor installed.public_directory installed.public_name
          captured None
        && same_entry captured_identity (Secure_fs.descriptor_identity captured)
      with _ -> false
    in
    close_noerr captured;
    restored
  with _ -> false

let register_rollback_witness transaction root chain installed snapshot =
  register_public_witness ~enforce_on_error:true
    ~expected_links:snapshot.snapshot_links transaction root chain
    installed.public_directory installed.public_name snapshot.snapshot_descriptor
    snapshot.snapshot_contents

let register_install_rollback_witness transaction root chain installed =
  match installed.snapshot with
  | Some snapshot ->
      register_rollback_witness transaction root chain installed snapshot
  | None ->
      register_absence_witness transaction root chain installed.public_directory
        installed.public_name

let rollback_install transaction ~validate ~on_rollback installed =
  let prepared = installed.prepared in
  try
    retry recovery_attempts (fun () -> !operation_hook Rollback);
    !ownership_hook Before_target_restore;
    match installed.snapshot with
      | None ->
          if not
               (public_matches_prepared installed.public_directory installed.public_name
                  prepared)
          then false
          else begin
            retry recovery_attempts (fun () ->
                final_rename_noreplace transaction ~validate
                  ~exact:(fun () ->
                    public_matches_prepared installed.public_directory
                         installed.public_name prepared
                    && entry_absent transaction.directory prepared.private_name)
                  installed.public_directory installed.public_name
                  transaction.directory prepared.private_name);
            !ownership_hook After_target_restore_capture;
            prepared.ownership <- Captured;
            retry recovery_attempts (fun () ->
                fsync_dir installed.public_directory);
            installed.installed <- false;
            if private_matches transaction prepared then begin
              let removed =
                remove_private transaction prepared
                && validate ()
                && entry_absent installed.public_directory installed.public_name
              in
              if removed then on_rollback installed;
              removed
            end
            else begin
              ignore (restore_foreign_capture transaction ~validate installed);
              false
            end
          end
      | Some snapshot ->
          if not installed.receipt
             || not
                  (public_matches_prepared installed.public_directory installed.public_name
                     prepared)
             || not
                  (public_matches_descriptor transaction.directory prepared.private_name
                     ~expected_owner:(Secure_fs.effective_uid ())
                     ~expected_mode:snapshot.snapshot_mode
                     ~expected_links:snapshot.snapshot_links
                     snapshot.snapshot_descriptor (Some snapshot.snapshot_contents))
             || not
                  (private_descriptor ~mode:snapshot.snapshot_mode
                     snapshot.snapshot_descriptor)
          then false
          else begin
            let receipt_name = prepared.private_name in
            let quarantine_name = random_component "rollback-" in
            !ownership_hook Before_target_restore_capture;
            retry recovery_attempts (fun () ->
                final_rename_noreplace transaction ~validate
                  ~exact:(fun () ->
                    public_matches_prepared installed.public_directory
                         installed.public_name prepared
                    && public_matches_descriptor
                         ~expected_owner:(Secure_fs.effective_uid ())
                         ~expected_mode:snapshot.snapshot_mode
                         ~expected_links:snapshot.snapshot_links
                         transaction.directory prepared.private_name
                         snapshot.snapshot_descriptor
                         (Some snapshot.snapshot_contents)
                    && entry_absent transaction.directory quarantine_name)
                  installed.public_directory installed.public_name
                  transaction.directory quarantine_name);
            let captured_requested =
              public_matches_prepared transaction.directory quarantine_name prepared
            in
            if not captured_requested then begin
              (* A foreign replacement won the race after the earlier check.
                 Put it back only if the public name is still absent; otherwise
                 retain it in the transaction without overwriting either entry. *)
              (try
                 final_rename_noreplace transaction ~validate
                   ~exact:(fun () ->
                     public_matches_prepared transaction.directory
                          quarantine_name prepared
                     && entry_absent installed.public_directory
                          installed.public_name)
                   transaction.directory quarantine_name
                   installed.public_directory installed.public_name;
                 retry recovery_attempts (fun () ->
                     fsync_dir installed.public_directory)
               with _ -> ());
              release_retained transaction snapshot.snapshot_descriptor;
              false
            end else begin
              prepared.private_name <- quarantine_name;
              prepared.ownership <- Captured;
              retry recovery_attempts (fun () ->
                  final_rename_noreplace transaction ~validate
                    ~exact:(fun () ->
                      public_matches_descriptor
                           ~expected_owner:(Secure_fs.effective_uid ())
                           ~expected_mode:snapshot.snapshot_mode
                           ~expected_links:snapshot.snapshot_links
                           transaction.directory receipt_name
                           snapshot.snapshot_descriptor
                           (Some snapshot.snapshot_contents)
                      && public_matches_prepared transaction.directory
                           quarantine_name prepared
                      && entry_absent installed.public_directory
                           installed.public_name)
                    transaction.directory receipt_name
                    installed.public_directory installed.public_name);
              installed.receipt <- false;
              !ownership_hook After_target_restore_capture;
              retry recovery_attempts (fun () ->
                  fsync_dir installed.public_directory);
              installed.installed <- false;
              let snapshot_is_restored () =
                public_matches_descriptor ~expected_links:snapshot.snapshot_links
                  installed.public_directory installed.public_name
                  snapshot.snapshot_descriptor
                  (Some snapshot.snapshot_contents)
                && private_descriptor ~mode:snapshot.snapshot_mode
                     snapshot.snapshot_descriptor
              in
              let restored = snapshot_is_restored () in
              let requested_removed =
                if restored && private_matches transaction prepared then
                  remove_private transaction prepared
                else begin
                  if private_matches transaction prepared then
                    ignore (remove_private transaction prepared);
                  false
                end
              in
              let final = restored && requested_removed && snapshot_is_restored () in
              if final then on_rollback installed;
              release_retained transaction snapshot.snapshot_descriptor;
              final
            end
          end
  with _ -> false

let atomic_replace_private_snapshot transaction ?(validate = fun () -> true)
    ?(on_success = fun _ -> ()) ?(on_rollback = fun _ -> ())
    ?(on_preinstall_failure = fun _ -> ()) directory basename snapshot contents =
  let release_initial () =
    on_preinstall_failure snapshot;
    Option.iter
      (fun old -> release_retained transaction old.snapshot_descriptor)
      snapshot
  in
  match prepare_private_file transaction contents with
      | Error issue ->
          release_initial ();
          Error issue
      | Ok prepared ->
          let outcome =
            try install_private transaction ~validate directory basename prepared snapshot
            with Secure_fs.Atomic_rename_unavailable ->
              let cleaned = remove_private transaction prepared in
              release_initial ();
              if cleaned then raise Secure_fs.Atomic_rename_unavailable
              else raise Private_cleanup_uncertain
          in
          (match outcome with
          | Install_failed (None, issue) ->
              let cleaned = remove_private transaction prepared in
              release_initial ();
              if cleaned then Error issue else uncertain ()
          | Install_failed (Some installed, issue) ->
              if rollback_install transaction ~validate ~on_rollback installed then
                Error issue
              else uncertain ()
          | Install_ok installed ->
              (try
                 if finish_install transaction ~validate ~on_success installed then Ok ()
                 else if rollback_install transaction ~validate ~on_rollback installed then
                   error "write_failed" "Atomic local write failed and was rolled back."
                 else uncertain ()
               with _ ->
                 if rollback_install transaction ~validate ~on_rollback installed then
                   error "write_failed" "Atomic local write failed and was rolled back."
                 else uncertain ()))

let atomic_replace_private transaction ?(validate = fun () -> true)
    ?(on_success = fun _ -> ()) ?(on_rollback = fun _ -> ())
    ?(on_preinstall_failure = fun _ -> ()) directory basename contents =
  Result.bind (snapshot_private transaction directory basename) (fun snapshot ->
      atomic_replace_private_snapshot transaction ~validate ~on_success ~on_rollback
        ~on_preinstall_failure directory basename snapshot contents)

type created_private_directory = {
  created_parent : Unix.file_descr;
  created_name : string;
  created_descriptor : Unix.file_descr;
  created_identity : Secure_fs.identity;
  mutable created_parent_valid : unit -> bool;
  mutable created_absence_witness : unit -> unit;
}

let remove_created_private ?(validate = fun () -> true) transaction created =
  let close_items items =
    List.iter
      (fun item ->
        release_retained transaction item.created_descriptor;
        close_noerr item.created_parent)
      items
  in
  let rec remove = function
    | [] -> true
    | item :: rest ->
        let receipt_name = random_component "dir-" in
        let captured =
          try
            final_rename_noreplace transaction
              ~validate:item.created_parent_valid
              ~exact:(fun () ->
                public_matches_descriptor
                     ~expected_owner:(Secure_fs.effective_uid ())
                     ~expected_mode:0o700 item.created_parent item.created_name
                     item.created_descriptor None
                && entry_absent transaction.directory receipt_name)
              item.created_parent item.created_name transaction.directory
              receipt_name;
            !ownership_hook After_directory_capture;
            fsync_dir item.created_parent;
            true
          with _ -> false
        in
        if not captured then begin
          release_retained transaction item.created_descriptor;
          close_noerr item.created_parent;
          close_items rest;
          false
        end else
          let private_entry =
            { private_name = receipt_name; descriptor = item.created_descriptor;
              identity = item.created_identity; kind = Private_directory;
              required_mode = 0o700;
              expected_owner = Secure_fs.effective_uid (); expected_mode = 0o700;
              expected_links = None;
              ownership = Captured; contents = None }
          in
          if private_matches transaction private_entry then begin
            let removed = remove_private transaction private_entry in
            let parent_valid =
              item.created_parent_valid ()
              && entry_absent item.created_parent item.created_name
            in
            if removed && parent_valid && rest = [] then
              item.created_absence_witness ();
            close_noerr item.created_parent;
            if not removed then begin
              release_retained transaction item.created_descriptor;
              close_items rest
            end;
            removed && parent_valid && remove rest
          end
          else begin
            (try
               final_rename_noreplace transaction
                 ~validate:item.created_parent_valid
                 ~exact:(fun () ->
                   private_matches transaction private_entry
                   && entry_absent item.created_parent item.created_name)
                 transaction.directory receipt_name item.created_parent
                 item.created_name;
               fsync_dir item.created_parent
             with _ -> ());
            release_retained transaction item.created_descriptor;
            close_noerr item.created_parent;
            close_items rest;
            false
          end
  in
  if transaction_chain_valid transaction && validate () then remove created
  else begin close_items created; false end

let close_created_private transaction created =
  List.iter (fun item ->
      release_retained transaction item.created_descriptor;
      close_noerr item.created_parent) created

let rollback_staged_directory transaction ~validate ~on_rollback parent name entry =
  try
    if public_matches_descriptor parent name entry.descriptor None then begin
      final_rename_noreplace transaction ~validate
        ~exact:(fun () ->
          public_matches_descriptor
               ~expected_owner:(Secure_fs.effective_uid ()) ~expected_mode:0o700
               parent name entry.descriptor None
          && entry_absent transaction.directory entry.private_name)
        parent name transaction.directory entry.private_name;
      entry.ownership <- Captured;
      fsync_dir parent;
      if private_matches transaction entry then begin
        let removed =
          remove_private transaction entry && validate () && entry_absent parent name
        in
        if removed then on_rollback ();
        removed
      end
      else begin
        let installed =
          { prepared = entry; snapshot = None; public_directory = parent;
            public_name = name; installed = false; receipt = false }
        in
        ignore (restore_foreign_capture transaction ~validate installed);
        false
      end
    end else false
  with _ -> false

let open_or_create_directory_private transaction ~root ~chain parent name =
  let validate () = revalidate_chain root chain in
  let on_rollback () =
    register_absence_witness transaction root chain parent name
  in
  try
    match Secure_fs.inspect parent name with
    | Secure_fs.Directory, identity ->
        let opened = open_directory_at parent name in
        if same_entry identity (Secure_fs.descriptor_identity opened) then
          Ok (opened, None)
        else begin close_noerr opened; uncertain () end
    | _ -> error "path_unsafe" "Managed path contains a non-directory or symlink."
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      let staged_name = random_component "dir-" in
      (try
         let path_descriptor, identity =
           match
             create_private_directory
               ~validate_parent:(fun () -> transaction_chain_valid transaction)
               transaction.directory staged_name
           with
           | Ok created -> created
           | Error issue ->
               if issue.code = "rollback_state_uncertain" then
                 raise Private_cleanup_uncertain
               else raise (Failure issue.message)
         in
         let staged =
           try Secure_fs.open_directory_at transaction.directory staged_name
           with exception_value ->
             let clean =
               cleanup_created_entry
                 ~validate_parent:(fun () -> transaction_chain_valid transaction)
                 transaction.directory staged_name Private_directory path_descriptor
                 identity
             in
             close_noerr path_descriptor;
             if clean then raise exception_value else raise Private_cleanup_uncertain
         in
         close_noerr path_descriptor;
         retain_descriptor transaction staged;
         if not (same_entry identity (Secure_fs.descriptor_identity staged)) then
           raise Private_cleanup_uncertain;
         let private_entry =
           { private_name = staged_name; descriptor = staged; identity;
             kind = Private_directory; required_mode = 0o700;
             expected_owner = Secure_fs.effective_uid (); expected_mode = 0o700;
             expected_links = None;
             ownership = Prepared; contents = None }
         in
         (try
            fsync_dir transaction.directory;
            !ownership_hook After_directory_create;
            final_rename_noreplace transaction ~validate
              ~exact:(fun () ->
                private_matches transaction private_entry
                && entry_absent parent name)
              transaction.directory staged_name parent name;
            private_entry.ownership <- Installed;
            fsync_dir parent;
            if public_matches_descriptor parent name staged None then begin
              let opened = Unix.dup ~cloexec:true staged in
              (try
                 let retained_parent = Unix.dup ~cloexec:true parent in
                 Ok
                   (opened,
                    Some { created_parent = retained_parent;
                           created_name = name; created_descriptor = staged;
                           created_identity = identity;
                           created_parent_valid = (fun () -> true);
                           created_absence_witness = (fun () -> ()) })
               with exception_value ->
                 close_noerr opened;
                 raise exception_value)
            end
            else if
              rollback_staged_directory transaction ~validate ~on_rollback parent name
                private_entry
            then
              error "write_failed" "Could not verify a managed directory installation."
            else uncertain ()
          with
          | Unix.Unix_error (Unix.EEXIST, _, _) ->
              if not (remove_private transaction private_entry) then uncertain ()
              else
                (match Secure_fs.inspect parent name with
                | Secure_fs.Directory, expected ->
                    fsync_dir parent;
                    let opened = open_directory_at parent name in
                    if same_entry expected (Secure_fs.descriptor_identity opened) then
                      Ok (opened, None)
                    else begin close_noerr opened; uncertain () end
                | _ -> error "path_unsafe" "Managed path is unsafe.")
          | Secure_fs.Atomic_rename_unavailable ->
              if remove_private transaction private_entry then
                raise Secure_fs.Atomic_rename_unavailable
              else raise Private_cleanup_uncertain
          | Unix.Unix_error _ | Sys_error _ | Failure _ ->
              let clean =
                match private_entry.ownership with
                | Installed ->
                    rollback_staged_directory transaction ~validate ~on_rollback parent
                      name private_entry
                | _ -> remove_private transaction private_entry
              in
              if clean then
                error "write_failed" "Could not create a managed directory."
              else uncertain ())
       with Secure_fs.Atomic_rename_unavailable -> raise Secure_fs.Atomic_rename_unavailable
          | Private_cleanup_uncertain -> raise Private_cleanup_uncertain
          | Unix.Unix_error _ | Sys_error _ | Failure _ ->
              error "write_failed" "Could not create a managed directory.")
  | Unix.Unix_error _ | Sys_error _ ->
      error "path_unsafe" "Managed path is unreadable or unsafe."

let open_concept_parent_private transaction root id =
  if not (Concept.concept_id id) then
    error "invalid_concept_id" "A valid concept ID is required."
  else
    let components = String.split_on_char '/' id in
    Result.bind
      (open_or_create_directory_private transaction ~root ~chain:[] root "knowledge")
      (fun (knowledge, first_created) ->
        Option.iter
          (fun item ->
            item.created_parent_valid <- (fun () -> !repository_guard ());
            item.created_absence_witness <-
              (fun () ->
                register_absence_witness transaction root [] item.created_parent
                  item.created_name))
          first_created;
        let created = ref (Option.to_list first_created) in
        let chain = ref [] in
        let retain name descriptor =
          try
            match retain_chain_entry name descriptor with
            | Some entry -> chain := entry :: !chain; true
            | None -> false
          with _ -> false
        in
        let initial_retained = retain "knowledge" knowledge in
        let rec descend current = function
          | [ base ] -> Ok (current, base ^ ".md", !created, List.rev !chain)
          | component :: rest ->
              let parent_chain = List.rev !chain in
              (match
                 open_or_create_directory_private transaction ~root
                   ~chain:parent_chain current component
               with
              | Error issue ->
                  close_noerr current;
                  let cleaned =
                    remove_created_private
                      ~validate:(fun () -> revalidate_chain root (List.rev !chain))
                      transaction !created
                  in
                  close_chain !chain;
                  if cleaned then Error issue else uncertain ()
              | Ok (next, made) ->
                  Option.iter
                    (fun item ->
                      item.created_parent_valid <-
                        (fun () -> revalidate_chain root parent_chain);
                      item.created_absence_witness <-
                        (fun () ->
                          register_absence_witness transaction root parent_chain
                            item.created_parent item.created_name))
                    made;
                  Option.iter (fun item -> created := item :: !created) made;
                  if retain component next then begin
                    close_noerr current;
                    descend next rest
                  end else begin
                    close_noerr next;
                    close_noerr current;
                    let cleaned =
                      remove_created_private
                        ~validate:(fun () -> revalidate_chain root (List.rev !chain))
                        transaction !created
                    in
                    close_chain !chain;
                    if cleaned then
                      error "write_failed" "Could not retain a managed directory."
                    else uncertain ()
                  end)
          | [] -> assert false
        in
        if initial_retained then descend knowledge components
        else begin
          close_noerr knowledge;
          let cleaned =
            remove_created_private
              ~validate:(fun () -> revalidate_chain root (List.rev !chain))
              transaction !created
          in
          close_chain !chain;
          if cleaned then
            error "write_failed" "Could not retain a managed directory."
          else uncertain ()
        end)

type retained_concept = {
  retained_directory : Unix.file_descr;
  retained_name : string;
  retained_chain : retained_chain_entry list;
  retained_snapshot : private_snapshot option;
}

let after_existing_read_hook = ref (fun () -> ())

let close_retained_concept retained =
  close_chain retained.retained_chain;
  close_noerr retained.retained_directory

let open_retained_concept transaction root id =
  if not (Concept.concept_id id) then
    error "invalid_concept_id" "A valid concept ID is required."
  else
    let components = String.split_on_char '/' id in
    let chain = ref [] in
    let retain name descriptor =
      try
        match retain_chain_entry name descriptor with
        | Some entry -> chain := entry :: !chain; Ok ()
        | None -> error "repository_changed" "Managed directory ownership is unsafe."
      with Unix.Unix_error _ | Sys_error _ ->
        error "write_failed" "Could not retain a managed directory."
    in
    let fail issue current =
      Option.iter close_noerr current;
      close_chain !chain;
      Error issue
    in
    let rec descend current = function
      | [ base ] ->
          let retained_chain = List.rev !chain in
          let name = base ^ ".md" in
          (match snapshot_private transaction current name with
          | Error issue -> fail issue (Some current)
          | Ok snapshot ->
              (try
                 if Option.is_some snapshot then !after_existing_read_hook ();
                 Ok
                   (Some
                      { retained_directory = current; retained_name = name;
                        retained_chain; retained_snapshot = snapshot })
               with _ ->
                 fail
                   { code = "write_failed";
                     message = "Could not retain the managed target." }
                   (Some current)))
      | component :: rest ->
          (try
             let next = open_directory_at current component in
             (match retain component next with
             | Ok () ->
                 close_noerr current;
                 descend next rest
             | Error issue ->
                 close_noerr next;
                 fail issue (Some current))
           with
           | Unix.Unix_error (Unix.ENOENT, _, _) ->
               close_noerr current;
               close_chain !chain;
               Ok None
           | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ ->
               fail
                 { code = "path_unsafe";
                   message = "Managed path is unreadable or unsafe." }
                 (Some current))
      | [] -> assert false
    in
    try
      let knowledge = open_directory_at root "knowledge" in
      (match retain "knowledge" knowledge with
      | Ok () -> descend knowledge components
      | Error issue ->
          close_noerr knowledge;
          close_chain !chain;
          Error issue)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> close_chain !chain; Ok None
    | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ ->
        close_chain !chain;
        error "path_unsafe" "Managed path is unreadable or unsafe."

let parse_document contents =
  if String.length contents > Limits.max_file_bytes then
    error "file_size_limit" "Input exceeds the 8 MiB safety limit."
  else if not (Frontmatter.valid_utf8 contents) then
    error "invalid_utf8" "Input must be UTF-8."
  else
    match Frontmatter.parse contents with
    | Ok document -> Ok document
    | Error _ -> error "frontmatter_invalid" "Input document frontmatter is invalid."

let validate_managed_output ~name contents =
  if String.length contents > Limits.max_file_bytes then
    error "file_size_limit" (name ^ " exceeds the 8 MiB safety limit.")
  else if not (Frontmatter.valid_utf8 contents) then
    error "invalid_utf8" (name ^ " must be UTF-8.")
  else Ok contents

let type_name document = Option.bind (find "type" document.Frontmatter.metadata) string

let write_configuration_at root =
  Result.bind (read_at root "clamp.yaml") (fun contents ->
      match Config.validate contents with
      | Error _ -> error "config_invalid" "Configuration is invalid."
      | Ok () ->
          match Exact_yaml.parse contents with
          | Ok yaml ->
              let human_authority =
                Option.value ~default:Config.default_human_authority
                  (Option.bind (find "human_authority" yaml) string)
              in
              (match Option.bind (find "inferred_writes" yaml) string with
              | Some ("confirm" | "auto_draft" as policy) ->
                  Ok (policy, human_authority)
              | _ -> assert false)
          | Error _ -> assert false)

let validate_authority_shape ~claim ~confirmed =
  match (claim, confirmed) with
  | "explicit", true ->
      error "contradictory_authority" "--confirmed is only valid for inferred claims."
  | ("explicit" | "inferred"), _ -> Ok ()
  | _ -> error "invalid_claim" "--claim must be explicit or inferred."

let authorize root ~claim ~confirmed =
  Result.bind (validate_authority_shape ~claim ~confirmed) (fun () ->
      Result.bind (write_configuration_at root) (fun (policy, human_authority) ->
          match claim with
          | "explicit" -> Ok (`Explicit, false, human_authority)
          | "inferred" ->
              if policy = "confirm" && not confirmed then
                error "confirmation_required" "Inferred writes require confirmation."
              else
                Ok
                  (`Inferred, policy = "auto_draft" && not confirmed,
                   human_authority)
          | _ -> assert false))

let verification_events metadata =
  match find "verified" metadata with
  | None -> []
  | Some (Seq values) -> values
  | Some value -> [ value ]

let canonicalize root ~claim ~confirmed ~old supplied =
  let clamp =
    match find "clamp" supplied.Frontmatter.metadata with
    | Some (Map _ as clamp) -> clamp
    | _ -> Map []
  in
  let metadata_without_generated =
    supplied.metadata |> remove "generated" |> remove "verified"
  in
  let metadata_with_status =
    match old with
    | None -> set "status" (scalar "stable") metadata_without_generated
    | Some previous ->
        (match find "status" previous.Frontmatter.metadata with
        | Some status -> set "status" status metadata_without_generated
        | None -> remove "status" metadata_without_generated)
  in
  let classification_clamp =
    match old with
    | None -> clamp
    | Some previous ->
        (match Option.bind (find "clamp" previous.Frontmatter.metadata)
                 (find "asserted_by") with
        | Some asserted_by -> set "asserted_by" asserted_by clamp
        | None -> remove "asserted_by" clamp)
  in
  let candidate =
    { supplied with
      Frontmatter.metadata =
        set "clamp" classification_clamp metadata_with_status }
  in
  let preserve =
    match old with
    | Some previous
      when Concept.classify_verification previous candidate
           = Concept.Preserve_verification -> true
    | _ -> false
  in
  Result.bind (authorize root ~claim ~confirmed)
    (fun (authority, auto_draft, human_authority) ->
      let time = timestamp () in
      let asserted_by =
        match authority with `Explicit -> human_authority | `Inferred -> "amp/agent"
      in
      let persisted_clamp =
        if preserve then classification_clamp
        else set "asserted_by" (scalar asserted_by) clamp
      in
      let metadata_without_generated =
        metadata_with_status
        |> set "clamp" persisted_clamp
      in
      let metadata_without_generated =
        if auto_draft && Option.is_none old then
          set "status" (scalar "draft") metadata_without_generated
        else metadata_without_generated
      in
      let generated =
        match old with
        | Some previous when preserve -> find "generated" previous.metadata
        | _ -> Some (Map [ ("by", scalar "amp/agent"); ("at", scalar time) ])
      in
      let metadata = match generated with
        | Some value -> set "generated" value metadata_without_generated
        | None -> metadata_without_generated
      in
      let preserved =
        if preserve then
          match old with Some previous -> verification_events previous.metadata | None -> []
        else []
      in
      let confirmed_event =
        match (authority, confirmed) with
        | `Inferred, true when not preserve ->
            [ Map [ ("by", scalar human_authority); ("at", scalar time) ] ]
        | _ -> []
      in
      let events = preserved @ confirmed_event in
      let metadata = if events = [] then metadata else set "verified" (Seq events) metadata in
      Ok { supplied with Frontmatter.metadata })

let validate_document document =
  match Concept.validate document.Frontmatter.metadata with
  | [] -> Ok ()
  | _ -> error "concept_invalid" "Canonical concept metadata is invalid."

let canonical_document_bytes document =
  let contents = Frontmatter.serialize document in
  Result.bind (validate_managed_output ~name:"Canonical concept" contents)
    (fun contents ->
      Result.bind (parse_document contents) (fun reparsed ->
          Result.bind (validate_document reparsed) (fun () -> Ok contents)))

let validate_unknown ~allow document =
  match type_name document with
  | Some kind when not (List.mem kind Concept.known_types) && not allow ->
      error "unknown_type_requires_authorization"
        "Unknown type requires --allow-unknown-type."
  | _ -> Ok ()

let parse_existing = function
  | None -> Ok None
  | Some contents -> Result.map Option.some (parse_document contents)

let task_of id doc =
  if type_name doc <> Some "task" then None
  else
    match Option.bind (find "clamp" doc.metadata) (find "task") with
    | Some (Map _ as metadata) ->
        let state = Option.value (Option.bind (find "state" metadata) string) ~default:"todo" in
        let priority = Option.value (Option.bind (find "priority" metadata) string) ~default:"normal" in
        let title = Option.value (Option.bind (find "title" doc.metadata) string) ~default:id in
        let due =
          match Option.bind (find "due_at" metadata) string with
          | Some value ->
              (match Timedesc.Timestamp.of_iso8601 value with
              | Ok instant -> Some (Due_at (value, instant))
              | Error _ -> None)
          | None -> Option.map (fun value -> Due_on value) (Option.bind (find "due_on" metadata) string)
        in
        Some { id; doc; state; priority; title; due }
    | _ -> None

let valid_ulid value =
  String.length value = 26 && value.[0] <= '7'
  && String.for_all
       (fun character ->
         String.contains "0123456789ABCDEFGHJKMNPQRSTVWXYZ" character)
       value

let valid_slug value =
  value <> ""
  && Str.string_match (Str.regexp {|^[a-z0-9]+\(-[a-z0-9]+\)*$|}) value 0

let task_path id =
  match String.split_on_char '/' id with
  | [ "tasks"; name ] ->
      (match String.index_opt name '-' with
      | Some 26 ->
          valid_ulid (String.sub name 0 26) && String.length name > 27
          && valid_slug (String.sub name 27 (String.length name - 27))
      | _ -> false)
  | _ -> false

exception Markdown_file_limit

type task_read_phase =
  | After_task_root_inspect
  | After_task_knowledge_inspect
  | After_task_directory_inspect
  | After_task_member_inspect
  | After_task_member_read
  | After_task_directory_reenumerated

let task_read_hook = ref (fun (_ : task_read_phase) -> ())

let task_digest contents =
  Digestif.SHA256.(to_raw_string (digest_string contents))

let exact_identity (left : Secure_fs.identity) right = left = right

type compact_task_member = {
  compact_name : string;
  compact_kind : Secure_fs.kind;
  compact_identity : Secure_fs.identity;
  compact_owner : int option;
  compact_mode : int option;
  compact_links : int option;
  compact_digest : string option;
  compact_task : task option;
}

let inspect_task_members directory =
  let names = ref [] in
  Secure_fs.iter_entries directory (fun name -> names := name :: !names);
  List.sort String.compare !names
  |> List.map (fun name ->
         let kind, identity = Secure_fs.inspect directory name in
         (name, kind, identity))

let read_task_member ?(after_open = fun () -> ()) directory
    (name, kind, inspected) =
  if not (String.ends_with ~suffix:".md" name) then begin
    let descriptor = Secure_fs.open_path_at directory name in
    Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
        let opened = Secure_fs.descriptor_identity descriptor in
        let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
        if not (exact_identity inspected opened) then
          raise Private_cleanup_uncertain;
        Ok
          { compact_name = name; compact_kind = kind;
            compact_identity = inspected; compact_owner = Some owner;
            compact_mode = Some mode; compact_links = None;
            compact_digest = None; compact_task = None })
  end else
    match kind with
    | Secure_fs.Directory ->
        let descriptor = Secure_fs.open_path_at directory name in
        Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
            let opened = Secure_fs.descriptor_identity descriptor in
            let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
            if not (exact_identity inspected opened) then
              raise Private_cleanup_uncertain;
            Ok
              { compact_name = name; compact_kind = kind;
                compact_identity = inspected; compact_owner = Some owner;
                compact_mode = Some mode; compact_links = None; compact_digest = None;
                compact_task = None })
    | Secure_fs.Symlink | Secure_fs.Other ->
        error "file_not_regular"
          "Managed files must be regular and not symlinks."
    | Secure_fs.Regular ->
        let descriptor = Secure_fs.open_file_at directory name in
        let opened = Secure_fs.descriptor_identity descriptor in
        let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
        let links = Secure_fs.descriptor_link_count descriptor in
        if not (exact_identity inspected opened)
           || owner <> Secure_fs.effective_uid ()
        then begin
          close_noerr descriptor;
          raise Private_cleanup_uncertain
        end;
        after_open ();
        (match read_descriptor descriptor inspected with
        | Error ({ code = "file_size_limit"; _ } as issue) -> Error issue
        | Error _ -> raise Private_cleanup_uncertain
        | Ok contents ->
            Result.bind (parse_document contents) (fun document ->
                let stem = String.sub name 0 (String.length name - 3) in
                let id = "tasks/" ^ stem in
                if Concept.validate document.metadata <> [] || not (task_path id) then
                  error "task_invalid" "A task file is not a valid task concept."
                else
                  match task_of id document with
                  | None ->
                      error "task_invalid" "A task file is not a valid task concept."
                  | Some task ->
                      Ok
                        { compact_name = name; compact_kind = kind;
                          compact_identity = inspected; compact_owner = Some owner;
                          compact_mode = Some mode;
                          compact_links = Some links;
                          compact_digest = Some (task_digest contents);
                          compact_task = Some task }))

let compact_member_matches directory expected =
  try
    let kind, identity = Secure_fs.inspect directory expected.compact_name in
    if kind <> expected.compact_kind
       || not (exact_identity identity expected.compact_identity)
    then false
    else
      match expected.compact_digest with
      | None ->
          let descriptor =
            Secure_fs.open_path_at directory expected.compact_name
          in
          Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
              let opened = Secure_fs.descriptor_identity descriptor in
              let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
              exact_identity opened expected.compact_identity
              && Some owner = expected.compact_owner
              && Some mode = expected.compact_mode)
      | Some digest ->
          let descriptor = Secure_fs.open_file_at directory expected.compact_name in
          let opened = Secure_fs.descriptor_identity descriptor in
          let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
          if not (exact_identity opened expected.compact_identity)
             || Some owner <> expected.compact_owner
             || Some mode <> expected.compact_mode
             || Some (Secure_fs.descriptor_link_count descriptor)
                <> expected.compact_links
          then begin
            close_noerr descriptor;
            false
          end else
            match read_descriptor descriptor expected.compact_identity with
            | Ok contents -> task_digest contents = digest
            | Error _ -> false
  with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false

let compact_members_match directory expected =
  try
    let observed = inspect_task_members directory in
    let membership_matches =
      List.length observed = List.length expected
      && List.for_all2
           (fun (name, kind, identity) member ->
             name = member.compact_name && kind = member.compact_kind
             && exact_identity identity member.compact_identity)
           observed expected
    in
    membership_matches
    && List.for_all (compact_member_matches directory) expected
  with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false

let count_markdown_files_at knowledge =
  let count = ref 0 in
  let rec walk directory =
    Secure_fs.iter_entries directory (fun name ->
        match Secure_fs.inspect directory name with
        | Secure_fs.Regular, _ when String.ends_with ~suffix:".md" name ->
            incr count;
            if !count > Limits.max_markdown_files then raise Markdown_file_limit
        | Secure_fs.Directory, _ ->
            let child = Secure_fs.open_directory_at directory name in
            Fun.protect ~finally:(fun () -> close_noerr child) (fun () -> walk child)
        | _ -> ())
  in
  walk knowledge;
  !count

let enforce_markdown_file_limit root =
  match Secure_fs.inspect root "knowledge" with
  | Secure_fs.Directory, _ ->
      let knowledge = Secure_fs.open_directory_at root "knowledge" in
      Fun.protect ~finally:(fun () -> close_noerr knowledge) (fun () ->
          count_markdown_files_at knowledge)
  | _ -> 0
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> 0

let load_tasks_at root =
  try
    let root_identity = Secure_fs.descriptor_identity root in
    let root_owner, root_mode = Secure_fs.descriptor_owner_mode root in
    !task_read_hook After_task_root_inspect;
    if not (same_entry root_identity (Secure_fs.descriptor_identity root))
       || Secure_fs.descriptor_owner_mode root <> (root_owner, root_mode)
       || root_owner <> Secure_fs.effective_uid ()
    then raise Private_cleanup_uncertain;
    match Secure_fs.inspect root "knowledge" with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
    | kind, _ when kind <> Secure_fs.Directory ->
        error "path_unsafe" "knowledge must be a directory."
    | _, knowledge_identity ->
      let () = !task_read_hook After_task_knowledge_inspect in
      let knowledge = Secure_fs.open_directory_at root "knowledge" in
      Fun.protect ~finally:(fun () -> close_noerr knowledge) (fun () ->
            let knowledge_owner, knowledge_mode =
              Secure_fs.descriptor_owner_mode knowledge
            in
            if not (same_entry knowledge_identity (Secure_fs.descriptor_identity knowledge))
               || knowledge_owner <> Secure_fs.effective_uid ()
            then raise Private_cleanup_uncertain;
            match Secure_fs.inspect knowledge "tasks" with
            | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                ignore (count_markdown_files_at knowledge);
                if
                  entry_absent knowledge "tasks"
                  && same_entry knowledge_identity
                       (Secure_fs.descriptor_identity knowledge)
                  && Secure_fs.descriptor_owner_mode knowledge
                     = (knowledge_owner, knowledge_mode)
                  && (match inspect_identity root "knowledge" with
                     | Some identity -> same_entry identity knowledge_identity
                     | None -> false)
                  && same_entry root_identity
                       (Secure_fs.descriptor_identity root)
                  && Secure_fs.descriptor_owner_mode root = (root_owner, root_mode)
                then Ok []
                else uncertain ()
            | kind, _ when kind <> Secure_fs.Directory ->
                error "path_unsafe" "knowledge/tasks must be a directory."
            | _, tasks_identity ->
              let () = !task_read_hook After_task_directory_inspect in
              let directory = Secure_fs.open_directory_at knowledge "tasks" in
              Fun.protect
                ~finally:(fun () -> close_noerr directory)
                (fun () ->
                  let tasks_owner, tasks_mode =
                    Secure_fs.descriptor_owner_mode directory
                  in
                  if not (same_entry tasks_identity (Secure_fs.descriptor_identity directory))
                     || tasks_owner <> Secure_fs.effective_uid ()
                  then raise Private_cleanup_uncertain;
                  ignore (count_markdown_files_at knowledge);
                  let membership = inspect_task_members directory in
                  let rec capture accumulated = function
                    | [] -> Ok (List.rev accumulated)
                    | ((name, kind, _) as observed) :: rest ->
                        if String.ends_with ~suffix:".md" name
                           && kind = Secure_fs.Regular
                        then !task_read_hook After_task_member_inspect;
                        Result.bind
                          (read_task_member
                             ~after_open:(fun () ->
                               !task_read_hook After_task_member_read)
                             directory observed)
                          (fun member -> capture (member :: accumulated) rest)
                  in
                  Result.bind (capture [] membership) (fun members ->
                      let after = inspect_task_members directory in
                      !task_read_hook After_task_directory_reenumerated;
                      if List.length after <> List.length membership
                         || not
                              (List.for_all2
                                 (fun (left_name, left_kind, left_identity)
                                      (right_name, right_kind, right_identity) ->
                                   left_name = right_name
                                   && left_kind = right_kind
                                   && exact_identity left_identity right_identity)
                                 membership after)
                         || Secure_fs.descriptor_owner_mode directory
                            <> (tasks_owner, tasks_mode)
                         || Secure_fs.descriptor_owner_mode knowledge
                            <> (knowledge_owner, knowledge_mode)
                         || not
                              (match inspect_identity root "knowledge" with
                              | Some identity -> same_entry identity knowledge_identity
                              | None -> false)
                         || not
                              (match inspect_identity knowledge "tasks" with
                              | Some identity -> same_entry identity tasks_identity
                              | None -> false)
                         || not
                              (same_entry root_identity
                                 (Secure_fs.descriptor_identity root))
                         || Secure_fs.descriptor_owner_mode root
                            <> (root_owner, root_mode)
                         || not (compact_members_match directory members)
                      then
                        error "repository_changed"
                          "Task files changed while they were read."
                      else
                        Ok (List.filter_map (fun member -> member.compact_task) members))))
  with Markdown_file_limit -> error "markdown_file_limit" "Task files exceed the fixed Markdown file limit."
     | Private_cleanup_uncertain
     | Unix.Unix_error (Unix.ENOENT, _, _) ->
         error "repository_changed" "Task files changed while they were read."
     | Unix.Unix_error _ ->
         error "file_unreadable" "Task files are unreadable."

(* A TODO is derived from more than the task documents which happened to parse.  In
   particular, a non-Markdown directory entry is evidence about the input set too.
   Keep this snapshot descriptor-backed until the transaction has been removed. *)
type task_input_file = {
  input_name : string;
  input_identity : Secure_fs.identity;
  input_owner : int;
  input_mode : int;
  input_links : int;
  input_digest : string;
  input_task : task;
}

type task_input_target =
  string * [ `Absent | `Present ] * (Unix.file_descr * string) option

type task_input_gate_phase =
  | Task_input_initial
  | Task_input_transition of task_input_target
  | Task_input_committed of task_input_target
  | Task_input_rollback of task_input_target
  | Task_input_restored

type task_input_witness = {
  input_root : public_witness_descriptor;
  mutable input_knowledge : public_witness_descriptor option;
  mutable input_tasks : public_witness_descriptor option;
  input_names : string list;
  input_members : compact_task_member list;
  input_files : task_input_file list;
  input_opened : Unix.file_descr list ref;
  input_knowledge_initially_absent : bool;
  input_tasks_initially_absent : bool;
  mutable input_target : task_input_target option;
  mutable input_restored_target : string option;
  mutable input_gate_phase : task_input_gate_phase;
  mutable input_sticky : bool;
}

exception Task_input_error of error
exception Initial_task_knowledge_absent of public_witness_descriptor
exception Initial_task_directory_absent of
  public_witness_descriptor * public_witness_descriptor

type task_input_capture_phase =
  | After_task_directory_retained
  | After_task_directory_enumerated
  | After_task_member_opened
  | Before_task_member_revalidate

let task_input_capture_hook = ref (fun (_ : task_input_capture_phase) -> ())

let task_input_close witness =
  List.iter close_noerr !(witness.input_opened);
  witness.input_opened := []

let task_input_file_matches directory file =
  !task_input_capture_hook Before_task_member_revalidate;
  compact_member_matches directory
    { compact_name = file.input_name; compact_kind = Secure_fs.Regular;
      compact_identity = file.input_identity;
      compact_owner = Some file.input_owner; compact_mode = Some file.input_mode;
      compact_links = Some file.input_links;
      compact_digest = Some file.input_digest; compact_task = Some file.input_task }

let task_input_restored_file_matches directory file =
  try
    let kind, identity = Secure_fs.inspect directory file.input_name in
    if kind <> Secure_fs.Regular || not (same_entry identity file.input_identity) then
      false
    else
      let descriptor = Secure_fs.open_file_at directory file.input_name in
      let opened = Secure_fs.descriptor_identity descriptor in
      let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
      if not (same_entry opened file.input_identity)
         || owner <> file.input_owner || mode <> file.input_mode
         || Secure_fs.descriptor_link_count descriptor <> file.input_links
      then begin
        close_noerr descriptor;
        false
      end else
        match read_descriptor descriptor opened with
        | Ok contents -> task_digest contents = file.input_digest
        | Error _ -> false
  with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false

let task_input_state_matches ?target ?restored_target ?transient_target witness root =
  let valid () =
    match witness.input_knowledge with
    | None ->
        !repository_guard ()
        && public_witness_descriptor_valid witness.input_root
        && entry_absent witness.input_root.witness_descriptor "knowledge"
    | Some knowledge ->
      revalidate_public_witness_chain root witness.input_root
        [ ("knowledge", knowledge) ]
      &&
      match witness.input_tasks with
      | None -> entry_absent knowledge.witness_descriptor "tasks"
      | Some directory ->
        public_witness_descriptor_valid directory
        && (match Secure_fs.inspect knowledge.witness_descriptor "tasks" with
           | Secure_fs.Directory, identity -> same_entry identity directory.witness_identity
           | _ -> false)
        &&
        let observed = inspect_task_members directory.witness_descriptor in
        let names = List.map (fun (name, _, _) -> name) observed in
        let expected_names =
          match transient_target with
          | Some name -> List.filter (fun candidate -> candidate <> name) witness.input_names
          | None -> (match target with
          | Some (name, `Absent, _) when not (List.mem name witness.input_names) ->
              List.sort String.compare (name :: witness.input_names)
          | _ -> witness.input_names)
        in
        names = expected_names
        && List.for_all
             (fun member ->
               if transient_target = Some member.compact_name then true
               else match target with
               | Some (target_name, _, _)
                 when target_name = member.compact_name -> true
               | _ ->
                   (match restored_target with
                   | Some target_name when target_name = member.compact_name ->
                       (match
                          List.find_opt
                            (fun file -> file.input_name = target_name)
                            witness.input_files
                        with
                       | Some file ->
                           task_input_restored_file_matches
                             directory.witness_descriptor file
                       | None -> false)
                   | _ ->
                       compact_member_matches directory.witness_descriptor member))
             witness.input_members
        && List.for_all
             (fun file ->
               if transient_target = Some file.input_name then true
               else match target with
               | Some (name, _, Some (descriptor, bytes)) when name = file.input_name ->
                   public_matches_descriptor ~expected_links:1
                     directory.witness_descriptor name descriptor (Some bytes)
               | _ ->
                   (match restored_target with
                   | Some name when name = file.input_name ->
                       task_input_restored_file_matches directory.witness_descriptor file
                   | _ -> task_input_file_matches directory.witness_descriptor file))
             witness.input_files
        &&
        match target with
        | Some (name, _, Some (descriptor, bytes)) ->
            let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
            owner = Secure_fs.effective_uid () && mode = 0o600
            && public_matches_descriptor ~expected_links:1
                 directory.witness_descriptor name descriptor (Some bytes)
        | Some (name, `Absent, None) -> entry_absent directory.witness_descriptor name
        | _ -> true
  in
  try valid () with _ -> false

let task_input_matches ?target witness root =
  let result = task_input_state_matches ?target witness root in
  if not result then witness.input_sticky <- true;
  result && not witness.input_sticky

let task_input_transition_matches witness root target =
  if witness.input_sticky then false
  else
    (* Evaluate both permitted states before making a mismatch sticky: after
       the target rename the initial state is expected not to match. *)
    let result =
      (match witness.input_target with
      | Some (name, _, _) ->
          task_input_state_matches ~restored_target:name witness root
      | None -> task_input_state_matches witness root)
      || task_input_state_matches ~target witness root
    in
    if not result then witness.input_sticky <- true;
    result

let task_input_completion_matches witness root =
  if witness.input_knowledge_initially_absent && witness.input_target = None then
    !repository_guard ()
    && public_witness_descriptor_valid witness.input_root
    && entry_absent witness.input_root.witness_descriptor "knowledge"
    && not witness.input_sticky
  else if witness.input_tasks_initially_absent && witness.input_target = None then
    (match witness.input_knowledge with
    | Some knowledge ->
        revalidate_public_witness_chain root witness.input_root
          [ ("knowledge", knowledge) ]
        && entry_absent knowledge.witness_descriptor "tasks"
        && not witness.input_sticky
    | None -> false)
  else
    let result =
      task_input_state_matches ?target:witness.input_target
        ?restored_target:witness.input_restored_target witness root
    in
    result && not witness.input_sticky

let task_input_staged_ancestor_rollback_matches witness root =
  if witness.input_knowledge_initially_absent then
    !repository_guard ()
    && public_witness_descriptor_valid witness.input_root
    &&
    (entry_absent witness.input_root.witness_descriptor "knowledge"
     || match witness.input_knowledge with
        | Some knowledge ->
            revalidate_public_witness_chain root witness.input_root
              [ ("knowledge", knowledge) ]
            && entry_absent knowledge.witness_descriptor "tasks"
        | None -> false)
  else if witness.input_tasks_initially_absent then
    match witness.input_knowledge with
    | Some knowledge ->
        revalidate_public_witness_chain root witness.input_root
          [ ("knowledge", knowledge) ]
        && entry_absent knowledge.witness_descriptor "tasks"
    | None -> false
  else false

let task_input_gate_matches witness root =
  if witness.input_sticky then false
  else
    let matches = task_input_state_matches witness root in
    let result =
      match witness.input_gate_phase with
      | Task_input_initial ->
          matches || task_input_staged_ancestor_rollback_matches witness root
      | Task_input_transition target ->
          matches || task_input_state_matches ~target witness root
          || task_input_staged_ancestor_rollback_matches witness root
      | Task_input_committed target ->
          task_input_state_matches ~target witness root
      | Task_input_rollback ((name, _, _) as target) ->
          task_input_state_matches ~target witness root
          || task_input_state_matches ~restored_target:name witness root
          || task_input_state_matches ~transient_target:name witness root
          || task_input_staged_ancestor_rollback_matches witness root
      | Task_input_restored -> task_input_completion_matches witness root
    in
    if not result then witness.input_sticky <- true;
    result

let capture_task_input transaction root =
  let opened = ref [] in
  let capture descriptor = capture_public_witness_descriptor opened descriptor in
  let register witness =
    if not (task_input_matches witness root) then raise Private_cleanup_uncertain;
    transaction.preinstall_witnesses <-
      (fun () -> task_input_gate_matches witness root)
      :: transaction.preinstall_witnesses;
    transaction.completion_witnesses <-
      { completion_check = (fun () -> task_input_completion_matches witness root);
        completion_failure = witness_uncertain; completion_enforce_on_error = true;
        completion_close = (fun () -> task_input_close witness) }
      :: transaction.completion_witnesses;
    ()
  in
  let absent root_state knowledge knowledge_absent =
    let witness =
      { input_root = root_state; input_knowledge = knowledge; input_tasks = None;
        input_names = []; input_members = []; input_files = [];
        input_opened = opened;
        input_knowledge_initially_absent = knowledge_absent;
        input_tasks_initially_absent = true; input_target = None;
        input_restored_target = None;
        input_gate_phase = Task_input_initial;
        input_sticky = false }
    in
    register witness;
    Ok ([], Some witness)
  in
  try
    let root_state = capture root in
    let knowledge_identity =
      match Secure_fs.inspect root "knowledge" with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        raise (Initial_task_knowledge_absent root_state)
    | Secure_fs.Directory, identity -> identity
    | _ ->
        raise
          (Task_input_error
             { code = "path_unsafe";
               message = "knowledge must be a directory." })
    in
    let knowledge_descriptor = Secure_fs.open_directory_at root "knowledge" in
    opened := knowledge_descriptor :: !opened;
    let knowledge = capture knowledge_descriptor in
    if not (same_entry knowledge_identity knowledge.witness_identity) then
      raise Private_cleanup_uncertain;
    let tasks_identity =
      match Secure_fs.inspect knowledge_descriptor "tasks" with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        raise (Initial_task_directory_absent (root_state, knowledge))
    | Secure_fs.Directory, identity -> identity
    | _ ->
        raise
          (Task_input_error
             { code = "path_unsafe";
               message = "knowledge/tasks must be a directory." })
    in
    let tasks_descriptor = Secure_fs.open_directory_at knowledge_descriptor "tasks" in
    opened := tasks_descriptor :: !opened;
    let tasks_state = capture tasks_descriptor in
    if not (same_entry tasks_identity tasks_state.witness_identity) then
      raise Private_cleanup_uncertain;
    ignore (enforce_markdown_file_limit root);
    !task_input_capture_hook After_task_directory_retained;
    let membership = inspect_task_members tasks_descriptor in
    let names = List.map (fun (name, _, _) -> name) membership in
    !task_input_capture_hook After_task_directory_enumerated;
    let rec capture_files accumulated = function
      | [] -> Ok (List.rev accumulated)
      | observed :: rest ->
          Result.bind
            (read_task_member
               ~after_open:(fun () ->
                 !task_input_capture_hook After_task_member_opened)
               tasks_descriptor observed)
            (fun member -> capture_files (member :: accumulated) rest)
    in
    let members =
      match capture_files [] membership with
      | Ok members -> members
      | Error issue -> raise (Task_input_error issue)
    in
    if inspect_task_members tasks_descriptor <> membership then
      raise Private_cleanup_uncertain;
    let files =
      List.filter_map
        (fun member ->
          match
            (member.compact_kind, member.compact_owner, member.compact_mode,
             member.compact_links,
             member.compact_digest, member.compact_task)
          with
          | Secure_fs.Regular, Some owner, Some mode, Some links, Some digest,
            Some task ->
              Some
                { input_name = member.compact_name;
                  input_identity = member.compact_identity; input_owner = owner;
                  input_mode = mode; input_links = links; input_digest = digest;
                  input_task = task }
          | _ -> None)
        members
    in
    let witness =
      { input_root = root_state; input_knowledge = Some knowledge;
        input_tasks = Some tasks_state; input_names = names;
        input_members = members; input_files = files;
        input_opened = opened; input_knowledge_initially_absent = false;
        input_tasks_initially_absent = false;
        input_target = None; input_restored_target = None;
        input_gate_phase = Task_input_initial;
        input_sticky = false }
    in
    register witness;
    Ok (List.map (fun file -> file.input_task) files, Some witness)
  with
  | Initial_task_knowledge_absent root_state ->
      (try
         ignore (enforce_markdown_file_limit root);
         absent root_state None true
       with
       | Markdown_file_limit ->
         List.iter close_noerr !opened;
         error "markdown_file_limit"
           "Task files exceed the fixed Markdown file limit."
       | exception_value ->
         List.iter close_noerr !opened;
         ignore exception_value;
         uncertain ())
  | Initial_task_directory_absent (root_state, knowledge) ->
      (try
         ignore (enforce_markdown_file_limit root);
         absent root_state (Some knowledge) false
       with
       | Markdown_file_limit ->
         List.iter close_noerr !opened;
         error "markdown_file_limit"
           "Task files exceed the fixed Markdown file limit."
       | exception_value ->
         List.iter close_noerr !opened;
         ignore exception_value;
         uncertain ())
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      List.iter close_noerr !opened;
      uncertain ()
  | Markdown_file_limit ->
      List.iter close_noerr !opened;
      error "markdown_file_limit"
        "Task files exceed the fixed Markdown file limit."
  | Task_input_error issue ->
      List.iter close_noerr !opened;
      Error issue
  | exception_value ->
      List.iter close_noerr !opened;
      ignore exception_value;
      uncertain ()

let tasks repo = with_shared_repo repo load_tasks_at

let list_tasks repo =
  with_repo repo (fun root -> with_root_lock ~exclusive:false root (fun () -> load_tasks_at root))

let priority_rank = function "urgent" -> 0 | "high" -> 1 | "normal" -> 2 | _ -> 3

let due_sort_key = function
  | None -> max_float
  | Some (Due_at (_, instant)) -> Timedesc.Timestamp.to_float_s instant
  | Some (Due_on date) ->
      (match Timedesc.Timestamp.of_iso8601 (date ^ "T00:00:00+02:00") with
      | Ok instant -> Timedesc.Timestamp.to_float_s instant
      | Error _ -> max_float)

let compare_task left right =
  compare
    ( priority_rank left.priority,
      due_sort_key left.due,
      String.lowercase_ascii left.title,
      left.id )
    ( priority_rank right.priority,
      due_sort_key right.due,
      String.lowercase_ascii right.title,
      right.id )

let markdown_label value =
  let output = Buffer.create (String.length value + 16) in
  let whitespace = ref false in
  String.iter
    (fun character ->
      if Char.code character <= 0x20 || character = '\127' then whitespace := true
      else begin
        if !whitespace && Buffer.length output > 0 then Buffer.add_char output ' ';
        whitespace := false;
        match character with
        | '<' -> Buffer.add_string output "&lt;"
        | '>' -> Buffer.add_string output "&gt;"
        | '&' -> Buffer.add_string output "&amp;"
        | ('\\' | '`' | '*' | '_' | '[' | ']' as punctuation) ->
            Buffer.add_char output '\\'; Buffer.add_char output punctuation
        | character -> Buffer.add_char output character
      end)
    value;
  Buffer.contents output

let due_display = function
  | Due_on value -> value
  | Due_at (_, instant) ->
      let tm = johannesburg_tm (Timedesc.Timestamp.to_float_s instant) in
      Printf.sprintf "%04d-%02d-%02d %02d:%02d SAST" (tm.tm_year + 1900)
        (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min

let task_is_overdue ~now = function
  | None -> false
  | Some (Due_at (_, instant)) -> Timedesc.Timestamp.to_float_s instant < now
  | Some (Due_on date) -> date < johannesburg_date_at now

let is_unverified_draft task =
  Option.bind (find "status" task.doc.metadata) string = Some "draft"
  && verification_events task.doc.metadata = []

let render_todo ~now tasks =
  let active task =
    List.mem task.state [ "doing"; "blocked"; "todo" ]
    && Option.bind (find "status" task.doc.metadata) string <> Some "deprecated"
  in
  let section state heading =
    let selected =
      tasks |> List.filter (fun task -> active task && task.state = state)
      |> List.sort compare_task
    in
    let lines =
      selected
      |> List.map (fun task ->
             let overdue = if task_is_overdue ~now task.due then " **OVERDUE**" else "" in
             let draft = if is_unverified_draft task then " **DRAFT · UNVERIFIED**" else "" in
             let due =
               match task.due with None -> "" | Some value -> " – due " ^ due_display value
             in
             Printf.sprintf "- [%s](knowledge/%s.md)%s%s%s `%s`\n"
               (markdown_label task.title) task.id overdue draft due task.priority)
      |> String.concat ""
    in
    "## " ^ heading ^ "\n\n" ^ if lines = "" then "_None._\n" else lines
  in
  "<!-- GENERATED by kb todo; DO NOT EDIT. -->\n# TODO\n\n"
  ^ section "doing" "Doing" ^ "\n" ^ section "blocked" "Blocked" ^ "\n"
  ^ section "todo" "Todo"

type transaction_phase =
  | After_task_prepared
  | After_task_input_render
  | After_todo_prepared
  | After_task_renamed
  | After_todo_renamed

let transaction_hook = ref (fun (_ : transaction_phase) -> ())

let paired_task_write_private ?retained transaction root ~id ~document ~task_contents =
  Result.bind (capture_task_input transaction root) (fun (existing_tasks, input_witness) ->
      let replacement = Option.get (task_of id document) in
      let tasks = replacement :: List.filter (fun task -> task.id <> id) existing_tasks in
      let todo_contents = render_todo ~now:(now ()) tasks in
      Result.bind (validate_managed_output ~name:"Generated TODO" todo_contents)
        (fun todo_contents ->
          let location =
            match retained with
            | Some retained ->
                Ok
                  (retained.retained_directory, retained.retained_name, [],
                   retained.retained_chain, retained.retained_snapshot, false)
            | None ->
                Result.map
                  (fun (directory, name, created, chain) ->
                    (directory, name, created, chain, None, true))
                  (open_concept_parent_private transaction root id)
          in
          Result.bind location
            (fun (task_directory, task_name, created, chain, retained_snapshot,
                  owns_location) ->
              Fun.protect
                ~finally:(fun () ->
                  if owns_location then begin
                    close_chain chain;
                    close_noerr task_directory
                  end)
                (fun () ->
                  let validate_chain () = revalidate_chain root chain in
                  Option.iter
                    (fun witness ->
                      if witness.input_tasks = None then begin
                        if witness.input_knowledge = None then begin
                          let knowledge_descriptor =
                            match
                              List.find_opt
                                (fun entry -> entry.chain_name = "knowledge") chain
                            with
                            | Some entry -> entry.chain_descriptor
                            | None -> raise Private_cleanup_uncertain
                          in
                          let created_knowledge =
                            List.exists
                              (fun item ->
                                item.created_name = "knowledge"
                                && same_entry item.created_identity
                                     (Secure_fs.descriptor_identity
                                        knowledge_descriptor))
                              created
                          in
                          if not created_knowledge then begin
                            witness.input_sticky <- true;
                            raise Private_cleanup_uncertain
                          end;
                          witness.input_knowledge <-
                            Some
                              (capture_public_witness_descriptor
                                 witness.input_opened knowledge_descriptor)
                        end;
                        let created_tasks =
                          List.exists
                            (fun item ->
                              item.created_name = "tasks"
                              && same_entry item.created_identity
                                   (Secure_fs.descriptor_identity task_directory))
                            created
                        in
                        if not created_tasks then begin
                          witness.input_sticky <- true;
                          raise Private_cleanup_uncertain
                        end;
                        let state =
                          capture_public_witness_descriptor witness.input_opened
                            task_directory
                        in
                        witness.input_tasks <- Some state
                      end)
                    input_witness;
                  let target_initial =
                    if List.mem task_name
                         (Option.fold ~none:[] ~some:(fun witness -> witness.input_names)
                            input_witness)
                    then `Present else `Absent
                  in
                  let validate_task_input target =
                    match input_witness with
                    | None -> true
                    | Some witness ->
                        (match witness.input_target with
                        | None -> task_input_transition_matches witness root target
                        | Some committed ->
                            task_input_transition_matches witness root committed)
                  in
                  let task_rollback installed =
                    Option.iter
                      (fun witness ->
                        witness.input_target <- None;
                        witness.input_restored_target <-
                          (match target_initial with
                          | `Present -> Some task_name
                          | `Absent -> None);
                        if created = [] then
                          witness.input_gate_phase <- Task_input_restored)
                      input_witness;
                    if created = [] then
                      register_install_rollback_witness transaction root chain
                        installed
                  in
                  let todo_rollback installed =
                    register_install_rollback_witness transaction root [] installed
                  in
                  let result =
                    Result.bind
                      (match retained with
                      | Some _ -> Ok retained_snapshot
                      | None -> snapshot_private transaction task_directory task_name)
                      (fun task_snapshot ->
                        let release_task_initial () =
                          if created = [] then
                            release_initial_state transaction root chain task_directory
                              task_name task_snapshot
                          else
                            Option.iter
                              (fun old ->
                                release_retained transaction old.snapshot_descriptor)
                              task_snapshot
                        in
                        match snapshot_private transaction root "TODO.md" with
                        | Error issue ->
                            release_task_initial ();
                            Error issue
                        | Ok todo_snapshot ->
                            let release_todo_initial () =
                              release_initial_state transaction root [] root "TODO.md"
                                todo_snapshot
                            in
                            let release_initials () =
                              release_task_initial ();
                              release_todo_initial ()
                            in
                            match prepare_private_file transaction task_contents with
                            | Error issue ->
                                release_initials ();
                                Error issue
                            | Ok task_prepared ->
                                let retained_target =
                                  Unix.dup ~cloexec:true task_prepared.descriptor
                                in
                                Option.iter
                                  (fun witness ->
                                    witness.input_opened :=
                                      retained_target :: !(witness.input_opened))
                                  input_witness;
                                let target =
                                  (task_name, target_initial,
                                   Some (retained_target, task_contents))
                                in
                                Option.iter
                                  (fun witness ->
                                    witness.input_gate_phase <-
                                      Task_input_transition target)
                                  input_witness;
                                let rollback_task installed =
                                  Option.iter
                                    (fun witness ->
                                      witness.input_gate_phase <-
                                        Task_input_rollback target)
                                    input_witness;
                                  rollback_install transaction
                                    ~validate:validate_chain
                                    ~on_rollback:task_rollback installed
                                in
                                let task_phase_ok =
                                  try
                                    !transaction_hook After_task_prepared;
                                    validate_task_input target
                                  with _ -> false
                                in
                                if not task_phase_ok then begin
                                  let clean = remove_private transaction task_prepared in
                                  release_initials ();
                                  if clean then
                                    error "write_failed" "Task and TODO preparation failed."
                                  else uncertain ()
                                end else
                                (match prepare_private_file transaction todo_contents with
                                | Error issue ->
                                    let clean = remove_private transaction task_prepared in
                                    release_initials ();
                                    if clean then Error issue else uncertain ()
                                | Ok todo_prepared ->
                                    let fail_before_todo issue task_install =
                                      let task_clean =
                                        match task_install with
                                        | None ->
                                            release_task_initial ();
                                            remove_private transaction task_prepared
                                        | Some installed -> rollback_task installed
                                      in
                                      let todo_clean = remove_private transaction todo_prepared in
                                      release_todo_initial ();
                                      if not (task_clean && todo_clean) then uncertain ()
                                      else if not (validate_chain ()) then
                                        error "repository_changed"
                                          "Managed path changed during the operation."
                                      else Error issue
                                    in
                                    let todo_phase_ok =
                                      try !transaction_hook After_todo_prepared; true
                                      with _ -> false
                                    in
                                    let task_outcome =
                                      try
                                        if todo_phase_ok then
                                          install_private transaction
                                            ~validate:validate_chain
                                            task_directory task_name task_prepared task_snapshot
                                        else
                                          Install_failed
                                            (None,
                                             { code = "write_failed";
                                               message = "Task and TODO preparation failed." })
                                      with Secure_fs.Atomic_rename_unavailable ->
                                        Install_failed
                                          (None,
                                           { code = "atomic_rename_unavailable";
                                             message = "Required atomic rename semantics are unavailable." })
                                    in
                                    (match task_outcome with
                                    | Install_failed (task_install, issue) ->
                                        fail_before_todo issue task_install
                                    | Install_ok task_install ->
                                        Option.iter
                                          (fun witness ->
                                            witness.input_target <- Some target;
                                            witness.input_restored_target <- None;
                                            witness.input_gate_phase <-
                                              Task_input_committed target)
                                          input_witness;
                                        let task_phase_ok =
                                          try !transaction_hook After_task_renamed; true
                                          with _ -> false
                                        in
                                        let todo_outcome =
                                          try
                                            if task_phase_ok then
                                              install_private transaction
                                                ~validate:validate_chain
                                                root "TODO.md" todo_prepared todo_snapshot
                                            else
                                              Install_failed
                                                (None,
                                                 { code = "write_failed";
                                                   message = "Task and TODO update failed." })
                                          with Secure_fs.Atomic_rename_unavailable ->
                                            Install_failed
                                              (None,
                                               { code = "atomic_rename_unavailable";
                                                 message = "Required atomic rename semantics are unavailable." })
                                        in
                                        (match todo_outcome with
                                        | Install_failed (todo_install, issue) ->
                                            let todo_clean =
                                              match todo_install with
                                              | None ->
                                                  release_todo_initial ();
                                                  remove_private transaction todo_prepared
                                              | Some installed ->
                                                  rollback_install transaction
                                                    ~validate:validate_chain
                                                    ~on_rollback:todo_rollback installed
                                            in
                                            let task_clean = rollback_task task_install in
                                            if not (todo_clean && task_clean) then uncertain ()
                                            else if not (validate_chain ()) then
                                              error "repository_changed"
                                                "Managed path changed during the operation."
                                            else Error issue
                                        | Install_ok todo_install ->
                                            let todo_phase_ok =
                                              try !transaction_hook After_todo_renamed; true
                                              with _ -> false
                                            in
                                            let installed_valid = todo_phase_ok &&
                                              validate_chain ()
                                              && validate_task_input target
                                              && public_matches_prepared task_directory
                                                   task_name task_prepared
                                              && public_matches_prepared root "TODO.md"
                                                   todo_prepared
                                            in
                                            let witnesses_registered =
                                              if not installed_valid then false
                                              else
                                                try
                                                  register_public_witness transaction
                                                    ~expected_owner:task_prepared.expected_owner
                                                    ~expected_mode:task_prepared.expected_mode
                                                    ~expected_links:1
                                                    root chain task_directory
                                                    task_name task_prepared.descriptor
                                                    task_contents;
                                                  register_public_witness transaction
                                                    ~expected_owner:todo_prepared.expected_owner
                                                    ~expected_mode:todo_prepared.expected_mode
                                                    ~expected_links:1
                                                    root [] root "TODO.md"
                                                    todo_prepared.descriptor todo_contents;
                                                  true
                                                with _ -> false
                                            in
                                            if not (installed_valid && witnesses_registered) then
                                              let todo_clean =
                                                rollback_install transaction
                                                  ~validate:validate_chain
                                                  ~on_rollback:todo_rollback todo_install
                                              in
                                              let task_clean = rollback_task task_install in
                                              if todo_clean && task_clean then
                                                if not (validate_chain ()) then
                                                  error "repository_changed"
                                                    "Managed path changed during the operation."
                                                else
                                                  error "write_failed"
                                                    "Task and TODO update failed and was rolled back."
                                              else uncertain ()
                                            else
                                              (let task_old_clean =
                                                remove_snapshot_receipt transaction task_install
                                              in
                                              let todo_old_clean =
                                                remove_snapshot_receipt transaction todo_install
                                              in
                                              if task_old_clean && todo_old_clean
                                                 && validate_chain ()
                                                 && transaction_chain_valid transaction
                                                 && public_matches_prepared task_directory
                                                      task_name task_prepared
                                                 && public_matches_prepared root "TODO.md"
                                                      todo_prepared
                                              then begin
                                                release_retained transaction
                                                  task_prepared.descriptor;
                                                release_retained transaction
                                                  todo_prepared.descriptor;
                                                Ok ()
                                              end else uncertain ())))))
                  in
                  match result with
                  | Ok () as success -> close_created_private transaction created; success
                  | Error issue when created = [] -> Error issue
                  | Error issue ->
                      if remove_created_private ~validate:validate_chain transaction created
                      then begin
                        Option.iter
                          (fun witness ->
                            witness.input_gate_phase <- Task_input_restored)
                          input_witness;
                        Error issue
                      end
                      else uncertain ()))))

let reserved_concept_id id =
  let name = String.lowercase_ascii (Filename.basename id ^ ".md") in
  name = "index.md" || name = "log.md"

type semantic_entry = {
  semantic_path : string;
  semantic_kind : Secure_fs.kind;
  semantic_identity : Secure_fs.identity;
  semantic_owner_mode : (int * int) option;
  semantic_bytes : string option;
}

(* Policy, namespace membership and reference resolution are authorization
   inputs, not disposable validation reads.  Retain one descriptor-backed view
   of the complete public Markdown namespace (apart from the output leaf) and
   the policy file until the transaction has been durably removed.  The broad
   witness deliberately keeps this mechanism generic: future concept-existence
   predicates cannot accidentally become unwitnessed. *)
let register_semantic_read_set ?(read_paths = []) transaction root ~target =
  let opened = ref [] in
  let markdown_count = ref 0 in
  let target = "knowledge/" ^ target ^ ".md" in
  let read_paths = String_set.of_list read_paths in
  let digest bytes = Digestif.SHA256.(to_raw_string (digest_string bytes)) in
  let rec scan_directory directory prefix =
    let names = ref [] in
    Secure_fs.iter_entries directory (fun name -> names := name :: !names);
    List.sort String.compare !names
    |> List.concat_map (fun name ->
           let path = if prefix = "" then name else prefix ^ "/" ^ name in
           if path = target then []
           else
             let kind, identity = Secure_fs.inspect directory name in
             match kind with
             | Secure_fs.Directory ->
                 let child = Secure_fs.open_directory_at directory name in
                 let owner_mode = Secure_fs.descriptor_owner_mode child in
                 if not
                      (same_entry identity (Secure_fs.descriptor_identity child))
                    || fst owner_mode <> Secure_fs.effective_uid ()
                 then begin
                   close_noerr child;
                   raise Private_cleanup_uncertain
                 end;
                 let descendants =
                   Fun.protect ~finally:(fun () -> close_noerr child) (fun () ->
                       scan_directory child path)
                 in
                 { semantic_path = path; semantic_kind = kind;
                   semantic_identity = identity; semantic_owner_mode = Some owner_mode;
                   semantic_bytes = None }
                 :: descendants
             | Secure_fs.Regular ->
                 if String.ends_with ~suffix:".md" name then incr markdown_count;
                 let descriptor = Secure_fs.open_file_at directory name in
                 let owner_mode = Secure_fs.descriptor_owner_mode descriptor in
                 if not
                      (same_entry identity
                         (Secure_fs.descriptor_identity descriptor))
                    || fst owner_mode <> Secure_fs.effective_uid ()
                 then begin
                   close_noerr descriptor;
                   raise Private_cleanup_uncertain
                 end;
                 let bytes =
                   if String_set.mem path read_paths then
                     match read_descriptor (Unix.dup ~cloexec:true descriptor) identity with
                     | Ok value -> Some (digest value)
                     | Error _ ->
                         close_noerr descriptor;
                         raise Private_cleanup_uncertain
                   else None
                 in
                 close_noerr descriptor;
                 [ { semantic_path = path; semantic_kind = kind;
                     semantic_identity = identity; semantic_owner_mode = Some owner_mode;
                     semantic_bytes = bytes } ]
             | Secure_fs.Symlink | Secure_fs.Other ->
                 [ { semantic_path = path; semantic_kind = kind;
                     semantic_identity = identity; semantic_owner_mode = None;
                     semantic_bytes = None } ])
  in
  let capture () =
    let root_identity = Secure_fs.descriptor_identity root in
    let root_owner_mode = Secure_fs.descriptor_owner_mode root in
    if fst root_owner_mode <> Secure_fs.effective_uid () then
      raise Private_cleanup_uncertain;
    let config =
      match Secure_fs.inspect root "clamp.yaml" with
      | Secure_fs.Regular, identity ->
          let descriptor = Secure_fs.open_file_at root "clamp.yaml" in
          opened := descriptor :: !opened;
          let owner_mode = Secure_fs.descriptor_owner_mode descriptor in
          if not
               (same_entry identity (Secure_fs.descriptor_identity descriptor))
             || fst owner_mode <> Secure_fs.effective_uid ()
          then raise Private_cleanup_uncertain;
          let bytes =
            match read_descriptor (Unix.dup ~cloexec:true descriptor) identity with
            | Ok value -> Some (digest value)
            | Error _ -> raise Private_cleanup_uncertain
          in
          [ { semantic_path = "clamp.yaml"; semantic_kind = Secure_fs.Regular;
              semantic_identity = identity; semantic_owner_mode = Some owner_mode;
              semantic_bytes = bytes } ]
      | kind, identity ->
          [ { semantic_path = "clamp.yaml"; semantic_kind = kind;
              semantic_identity = identity; semantic_owner_mode = None;
              semantic_bytes = None } ]
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
    in
    let knowledge =
      match Secure_fs.inspect root "knowledge" with
      | Secure_fs.Directory, identity ->
          let directory = Secure_fs.open_directory_at root "knowledge" in
          opened := directory :: !opened;
          let owner_mode = Secure_fs.descriptor_owner_mode directory in
          if not
               (same_entry identity (Secure_fs.descriptor_identity directory))
             || fst owner_mode <> Secure_fs.effective_uid ()
          then raise Private_cleanup_uncertain;
          let entry =
            { semantic_path = "knowledge"; semantic_kind = Secure_fs.Directory;
              semantic_identity = identity;
              semantic_owner_mode = Some owner_mode;
              semantic_bytes = None }
          in
          entry :: scan_directory directory "knowledge"
      | kind, identity ->
          [ { semantic_path = "knowledge"; semantic_kind = kind;
              semantic_identity = identity; semantic_owner_mode = None;
              semantic_bytes = None } ]
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
    in
    (root_identity, root_owner_mode, config @ knowledge)
  in
  try
    let root_identity, root_owner_mode, entries = capture () in
    if !markdown_count >= Limits.max_markdown_files then begin
      List.iter close_noerr !opened;
      error "markdown_file_limit" "Knowledge files exceed the fixed Markdown file limit."
    end else begin
      let sticky = ref false in
      let baseline_paths = List.map (fun entry -> entry.semantic_path) entries in
      let intended_new_ancestor path =
        path <> target && String.starts_with ~prefix:(path ^ "/") target
        && not (List.mem path baseline_paths)
      in
      let entry_equal left right =
        left.semantic_path = right.semantic_path
        && left.semantic_kind = right.semantic_kind
        && same_entry left.semantic_identity right.semantic_identity
        && left.semantic_owner_mode = right.semantic_owner_mode
        && left.semantic_bytes = right.semantic_bytes
      in
      let check () =
        if !sticky then false
        else
          let valid =
            try
              let current_opened = !opened in
              opened := [];
              markdown_count := 0;
              let current_root, current_mode, current =
                Fun.protect
                  ~finally:(fun () ->
                    List.iter close_noerr !opened;
                    opened := current_opened)
                  capture
              in
              let current =
                List.filter
                  (fun entry -> not (intended_new_ancestor entry.semantic_path))
                  current
              in
              same_entry root_identity current_root && root_owner_mode = current_mode
              && List.length entries = List.length current
              && List.for_all2 entry_equal entries current
            with _ -> false
          in
          if not valid then sticky := true;
          valid
      in
      transaction.completion_witnesses <-
        { completion_check = check; completion_failure = witness_uncertain;
          completion_enforce_on_error = true;
          completion_close = (fun () -> List.iter close_noerr !opened; opened := []) }
        :: transaction.completion_witnesses;
      transaction.preinstall_witnesses <- check :: transaction.preinstall_witnesses;
      Ok ()
    end
  with _ ->
    List.iter close_noerr !opened;
    uncertain ()

let read_concept_optional root id =
  try
    let knowledge = Secure_fs.open_directory_at root "knowledge" in
    Fun.protect ~finally:(fun () -> close_noerr knowledge) (fun () ->
        let descriptor = Secure_fs.open_beneath knowledge (id ^ ".md") in
        Result.map Option.some
          (read_descriptor descriptor (Secure_fs.descriptor_identity descriptor)))
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
     | Unix.Unix_error (Unix.ELOOP, _, _) ->
         error "file_not_regular" "Managed files must be regular and not symlinks."
     | Invalid_argument _ -> error "invalid_concept_id" "A valid concept ID is required."
     | Unix.Unix_error _ -> error "file_unreadable" "Managed file is unreadable."

let casefold_collision root id =
  let components = String.split_on_char '/' id in
  let components =
    match List.rev components with
    | leaf :: rest -> List.rev ((leaf ^ ".md") :: rest)
    | [] -> []
  in
  let rec check directory = function
    | [] -> false
    | expected :: rest ->
        let folded = String.lowercase_ascii expected in
        let exact = ref false and collision = ref false in
        Secure_fs.iter_entries directory (fun name ->
            if String.lowercase_ascii name = folded then
              if name = expected then exact := true else collision := true);
        if !collision then true
        else if not !exact || rest = [] then false
        else
            (match Secure_fs.inspect directory expected with
            | Secure_fs.Directory, _ ->
                let child = Secure_fs.open_directory_at directory expected in
                Fun.protect ~finally:(fun () -> close_noerr child)
                  (fun () -> check child rest)
            | _ -> false)
  in
  try
    let knowledge = Secure_fs.open_directory_at root "knowledge" in
    Fun.protect ~finally:(fun () -> close_noerr knowledge)
      (fun () -> check knowledge components)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let validate_mutation_target root ~id ~task_add document =
  let kind = type_name document in
  if not (Concept.concept_id id) then
    error "invalid_concept_id" "A valid concept ID is required."
  else if reserved_concept_id id then
    error "reserved_concept_id" "index.md and log.md are reserved documents."
  else if casefold_collision root id then
    error "casefold_collision" "Concept path collides under case folding."
  else
    let task_namespace = id = "tasks" || String.starts_with ~prefix:"tasks/" id in
    let journal_namespace = id = "journal" || String.starts_with ~prefix:"journal/" id in
    if task_namespace <> (kind = Some "task") then
      error "concept_type_path_mismatch" "Concept type does not match its namespace."
    else if journal_namespace <> (kind = Some "journal") then
      error "concept_type_path_mismatch" "Concept type does not match its namespace."
    else if kind = Some "task" && not (task_path id) then
      error "task_path_invalid" "Task concepts require their generated canonical path."
    else if kind = Some "journal" &&
      (match String.split_on_char '/' id with
       | [ "journal"; year; day ] ->
           not (String.length year = 4 && String.starts_with ~prefix:(year ^ "-") day
                && Concept.date day)
       | _ -> true)
    then
      error "journal_path_invalid" "Journal concepts require their canonical date path."
    else Ok ()

let concept_exists root id =
  if not (Concept.concept_id id) || reserved_concept_id id then false
  else
    try
      let knowledge = Secure_fs.open_directory_at root "knowledge" in
      Fun.protect ~finally:(fun () -> close_noerr knowledge) (fun () ->
          let descriptor = Secure_fs.open_beneath knowledge (id ^ ".md") in
          let expected = Secure_fs.descriptor_identity descriptor in
          match Safe_file.read_descriptor ~expected descriptor with
          | Error _ -> false
          | Ok contents ->
              (match Frontmatter.parse contents with
              | Ok document -> Concept.validate document.metadata = []
              | Error _ -> false))
    with Unix.Unix_error _ | Invalid_argument _ -> false

let validate_references root ~id (document : Frontmatter.t) =
  let dependencies =
    match
      Option.bind
        (Option.bind (find "clamp" document.metadata) (find "task"))
        (find "depends_on")
    with
    | Some (Seq values) -> List.filter_map string values
    | _ -> []
  in
  if List.exists (String.equal id) dependencies then
    error "dependency_self" "A task cannot depend on itself."
  else if not (List.for_all (concept_exists root) dependencies) then
    error "dependency_unresolved" "A task dependency does not resolve."
  else
    let superseded_by =
      Option.bind
        (Option.bind (find "clamp" document.metadata) (find "superseded_by"))
        string
    in
    match superseded_by with
    | Some target when target = id ->
        error "superseded_by_self" "A concept cannot supersede itself."
    | Some target when not (concept_exists root target) ->
        error "superseded_by_unresolved" "The replacement concept does not exist."
    | _ -> Ok ()

let validate_self_references ~id (document : Frontmatter.t) =
  let dependencies =
    match
      Option.bind
        (Option.bind (find "clamp" document.metadata) (find "task"))
        (find "depends_on")
    with
    | Some (Seq values) -> List.filter_map string values
    | _ -> []
  in
  if List.exists (String.equal id) dependencies then
    error "dependency_self" "A task cannot depend on itself."
  else
    let superseded_by =
      Option.bind
        (Option.bind (find "clamp" document.metadata) (find "superseded_by"))
        string
    in
    match superseded_by with
    | Some target when target = id ->
        error "superseded_by_self" "A concept cannot supersede itself."
    | _ -> Ok ()

let semantic_reference_paths (document : Frontmatter.t) =
  let dependencies =
    match
      Option.bind
        (Option.bind (find "clamp" document.metadata) (find "task"))
        (find "depends_on")
    with
    | Some (Seq values) -> List.filter_map string values
    | _ -> []
  in
  let superseded_by =
    Option.bind
      (Option.bind (find "clamp" document.metadata) (find "superseded_by"))
      string
  in
  dependencies @ Option.to_list superseded_by
  |> List.sort_uniq String.compare
  |> List.map (fun id -> "knowledge/" ^ id ^ ".md")

let task_lifecycle document =
  match Option.bind (find "clamp" document.Frontmatter.metadata) (find "task") with
  | Some task -> (find "state" task, find "completed_at" task)
  | None -> (None, None)

let write_document ?retained transaction root ~id ~old ~task_add ~allow_lifecycle
    document =
  if Option.is_none old
     && enforce_markdown_file_limit root >= Limits.max_markdown_files
  then
    error "markdown_file_limit" "Knowledge files exceed the fixed Markdown file limit."
  else Result.bind (validate_self_references ~id document) (fun () ->
      Result.bind (validate_document document) (fun () ->
      Result.bind (validate_references root ~id document)
        (fun () ->
          let was_task = Option.exists (fun old -> type_name old = Some "task") old in
          let is_task = type_name document = Some "task" in
          if Option.is_some old && was_task <> is_task then
            error "concept_type_change_forbidden"
              "Editing a concept to or from type task is not supported."
          else if is_task && Option.is_none old && not task_add then
            error "task_command_required"
              "Create tasks with kb task add so Clamp can allocate their stable ID."
          else if is_task && Option.is_none old
                  && task_lifecycle document <> (Some (scalar "todo"), None)
          then
            error "task_initial_state_invalid"
              "New tasks must start in todo without completed_at."
          else if is_task && Option.is_some old && not allow_lifecycle
                  && task_lifecycle document <> task_lifecycle (Option.get old)
          then
            error "task_lifecycle_edit_forbidden"
              "Use task lifecycle commands to change state or completed_at."
          else
            Result.bind (canonical_document_bytes document) (fun contents ->
                if is_task || was_task then
                  if not (task_path id) then
                    error "task_path_invalid" "Task concepts require a tasks/<ULID>-<slug> ID."
                  else
                    paired_task_write_private ?retained transaction root ~id ~document
                      ~task_contents:contents
                else
                  match retained with
                  | Some retained ->
                      atomic_replace_private_snapshot transaction
                        ~validate:(fun () ->
                          revalidate_chain root retained.retained_chain)
                        ~on_preinstall_failure:
                          (register_initial_state_witness transaction root
                             retained.retained_chain retained.retained_directory
                             retained.retained_name)
                        ~on_rollback:(fun installed ->
                          register_install_rollback_witness transaction root
                            retained.retained_chain installed)
                        ~on_success:(fun target ->
                          register_public_witness transaction
                            ~expected_owner:(Secure_fs.effective_uid ())
                            ~expected_mode:0o600
                            ~expected_links:1
                            root retained.retained_chain
                            retained.retained_directory retained.retained_name
                            target contents)
                        retained.retained_directory retained.retained_name
                        retained.retained_snapshot contents
                  | None ->
                  Result.bind (open_concept_parent_private transaction root id)
                    (fun (directory, name, created, chain) ->
                      Fun.protect
                        ~finally:(fun () -> close_chain chain; close_noerr directory)
                        (fun () ->
                          match
                            atomic_replace_private transaction
                              ~validate:(fun () -> revalidate_chain root chain)
                              ~on_preinstall_failure:
                                (fun snapshot ->
                                  if created = [] then
                                    register_initial_state_witness transaction root
                                      chain directory name snapshot)
                              ~on_rollback:(fun installed ->
                                if created = [] then
                                  register_install_rollback_witness transaction root
                                    chain installed)
                              ~on_success:(fun target ->
                                register_public_witness transaction
                                  ~expected_owner:(Secure_fs.effective_uid ())
                                  ~expected_mode:0o600
                                  ~expected_links:1
                                  root chain directory name target contents)
                              directory name contents
                          with
                          | Ok () as result ->
                              close_created_private transaction created;
                              result
                          | Error issue ->
                              if remove_created_private
                                   ~validate:(fun () -> revalidate_chain root chain)
                                   transaction created
                              then Error issue
                              else uncertain ()))))))

type mutation_disposition = Created | Updated
type mutation_result = { id : string; disposition : mutation_disposition }

let mutate_with_mode ~task_add ~repo ~id ~contents ~claim ~confirmed
    ~allow_unknown ~create =
  let* supplied = parse_document contents in
  let* () = validate_unknown ~allow:allow_unknown supplied in
  with_repo repo (fun root ->
      with_lock root (fun () ->
          with_transaction root (fun transaction ->
              let* id =
                match (type_name supplied, create) with
                | Some "journal", true ->
                    let date = johannesburg_date () in
                    let today = "journal/" ^ String.sub date 0 4 ^ "/" ^ date in
                    if id = "" || id = today then Ok today
                    else
                      error "journal_id_not_today"
                        "A supplied journal ID must be today's canonical ID."
                | Some "journal", false -> Ok id
                | _, _ -> Ok id
              in
              let* () =
                register_semantic_read_set
                  ~read_paths:(semantic_reference_paths supplied)
                  transaction root ~target:id
              in
              let* () = validate_mutation_target root ~id ~task_add supplied in
              let* retained = open_retained_concept transaction root id in
              Fun.protect
                ~finally:(fun () -> Option.iter close_retained_concept retained)
                (fun () ->
                  let previous =
                    Option.bind retained (fun retained ->
                        Option.map
                          (fun snapshot -> snapshot.snapshot_contents)
                          retained.retained_snapshot)
                  in
                  let* old = parse_existing previous in
                  if
                    create && Option.is_some old
                    && type_name supplied <> Some "journal"
                  then error "concept_exists" "Concept already exists."
                  else if (not create) && Option.is_none old then
                    error "concept_not_found" "Concept does not exist."
                  else
                    let* document = canonicalize root ~claim ~confirmed ~old supplied in
                    let* () =
                      write_document ?retained transaction root ~id ~old ~task_add
                        ~allow_lifecycle:false document
                    in
                    Ok
                      { id;
                        disposition =
                          (if Option.is_some old then Updated else Created) }))))

let mutate_with_outcome ~repo ~id ~contents ~claim ~confirmed ~allow_unknown
    ~create =
  mutate_with_mode ~task_add:false ~repo ~id ~contents ~claim ~confirmed
    ~allow_unknown ~create

let mutate ~repo ~id ~contents ~claim ~confirmed ~allow_unknown ~create =
  Result.map (fun result -> result.id)
    (mutate_with_outcome ~repo ~id ~contents ~claim ~confirmed ~allow_unknown
       ~create)

let update ?(allow_lifecycle = false) ?(update_generated = true)
    ?(authorize_change = fun _ _ _ -> Ok ()) ?(skip_unchanged = false) repo id transform =
  with_repo repo (fun root ->
      with_lock root (fun () ->
          with_transaction root (fun transaction ->
              if not (Concept.concept_id id) || reserved_concept_id id then
                error "invalid_concept_id"
                  "A valid non-reserved concept ID is required."
              else let* () = register_semantic_read_set transaction root ~target:id in
                let* retained = open_retained_concept transaction root id in
                Fun.protect
                  ~finally:(fun () ->
                    Option.iter close_retained_concept retained)
                  (fun () ->
                    let existing =
                      Option.bind retained (fun retained ->
                          Option.map
                            (fun snapshot -> snapshot.snapshot_contents)
                            retained.retained_snapshot)
                    in
                    let* contents =
                      match existing with
                      | Some value -> Ok value
                      | None ->
                          error "file_not_found" "Managed file does not exist."
                    in
                    let* old = parse_document contents in
                    let* (changed : Frontmatter.t) = transform root old in
                    let* () =
                      register_semantic_read_set
                        ~read_paths:(semantic_reference_paths changed)
                        transaction root ~target:id
                    in
                    let* () = authorize_change root old changed in
                    if skip_unchanged && changed = old then
                      (match retained with
                      | Some retained
                        when revalidate_chain root retained.retained_chain ->
                          (match retained.retained_snapshot with
                          | Some snapshot ->
                              register_public_witness transaction
                                ~expected_links:snapshot.snapshot_links
                                root retained.retained_chain
                                retained.retained_directory retained.retained_name
                                snapshot.snapshot_descriptor
                                snapshot.snapshot_contents;
                              Ok id
                          | None -> uncertain ())
                      | Some _ ->
                          error "repository_changed"
                            "Managed path changed during the operation."
                      | None -> uncertain ())
                    else
                      let document =
                        if update_generated then
                          let generated =
                            Map
                              [
                                ("by", scalar "amp/agent");
                                ("at", scalar (timestamp ()));
                              ]
                          in
                          {
                            changed with
                            metadata =
                              set "generated" generated changed.metadata;
                          }
                        else changed
                      in
                      let* () =
                        validate_mutation_target root ~id ~task_add:false
                          document
                      in
                      let* () =
                        write_document ?retained transaction root ~id
                          ~old:(Some old) ~task_add:false ~allow_lifecycle
                          document
                      in
                      Ok id))))

let verify ~authority repo id =
  match authority with
  | None ->
      error "verification_authority_required"
        "--verification-authority user-explicit is required."
  | Some "user-explicit" ->
      update ~update_generated:false repo id (fun root document ->
          let* _, human_authority = write_configuration_at root in
          let event =
            Map
              [ ("by", scalar human_authority);
                ("at", scalar (timestamp ())) ]
          in
          Ok
            { document with
              metadata =
                set "verified"
                  (Seq (verification_events document.metadata @ [ event ]))
                  document.metadata })
  | Some _ ->
      error "invalid_verification_authority"
        "--verification-authority must be user-explicit."

let deprecate_checked ~claim ~confirmed repo id superseded_by =
  match superseded_by with
  | Some replacement when replacement = id ->
      error "superseded_by_self" "A concept cannot supersede itself."
  | _ ->
      let relation document =
        Option.bind
          (Option.bind (find "clamp" document.Frontmatter.metadata) (find "superseded_by"))
          string
      in
      let authorize_change root old transformed =
        Result.bind (validate_authority_shape ~claim ~confirmed) (fun () ->
            let old_status = Option.bind (find "status" old.Frontmatter.metadata) string in
            let new_status = Option.bind (find "status" transformed.Frontmatter.metadata) string in
            if relation old = relation transformed && old_status = new_status then Ok ()
            else Result.map (fun _ -> ()) (authorize root ~claim ~confirmed))
      in
      update ~authorize_change ~skip_unchanged:true repo id (fun root document ->
          let clamp = Option.value (find "clamp" document.metadata) ~default:(Map []) in
          let previous_relation = relation document in
          let next_relation =
            match superseded_by with None -> previous_relation | Some value -> Some value
          in
          if Option.bind (find "status" document.metadata) string = Some "deprecated"
             && next_relation = previous_relation
          then Ok document
          else
          let relationship_changed = next_relation <> previous_relation in
          let* human_authority =
            if relationship_changed then
              Result.map snd (write_configuration_at root)
            else Ok Config.default_human_authority
          in
          let clamp =
            match superseded_by with
            | None -> clamp
            | Some replacement -> set "superseded_by" (scalar replacement) clamp
          in
          let clamp =
            if relationship_changed then
              set "asserted_by"
                (scalar (if claim = "explicit" then human_authority else "amp/agent"))
                clamp
            else clamp
          in
          let transformed =
            { document with
              metadata =
                document.metadata
                |> set "status" (scalar "deprecated")
                |> set "clamp" clamp }
          in
          let metadata =
            if previous_relation = next_relation then transformed.metadata
            else
              match Concept.classify_verification document transformed with
              | Concept.Preserve_verification -> transformed.metadata
              | Concept.Clear_verification -> remove "verified" transformed.metadata
          in
          let metadata =
            if previous_relation <> next_relation
               && claim = "inferred" && confirmed then
              let event =
                Map
                  [ ("by", scalar human_authority);
                    ("at", scalar (timestamp ())) ]
              in
              set "verified" (Seq (verification_events metadata @ [ event ])) metadata
            else metadata
          in
          Ok { transformed with metadata })

let random_bytes count =
  let bytes = Bytes.create count in
  let descriptor = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () ->
      let rec loop offset =
        if offset < count then
          match Unix.read descriptor bytes offset (count - offset) with
          | 0 -> raise End_of_file
          | read -> loop (offset + read)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
      in
      loop 0);
  bytes

let ulid_with ~now_ms ~entropy =
  let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ" in
  let milliseconds = now_ms () and bytes = entropy 10 in
  if Bytes.length bytes <> 10 then invalid_arg "ULID entropy must be exactly 80 bits";
  if milliseconds < 0L || milliseconds > 281474976710655L then
    invalid_arg "ULID timestamp out of range";
  let output = Bytes.make 26 '0' in
  let value = ref milliseconds in
  for index = 9 downto 0 do
    Bytes.set output index alphabet.[Int64.to_int (Int64.logand !value 31L)];
    value := Int64.shift_right_logical !value 5
  done;
  let accumulator = ref 0 and bits = ref 0 and index = ref 10 in
  Bytes.iter
    (fun character ->
      accumulator := (!accumulator lsl 8) lor Char.code character;
      bits := !bits + 8;
      while !bits >= 5 do
        bits := !bits - 5;
        Bytes.set output !index alphabet.[(!accumulator lsr !bits) land 31];
        incr index
      done)
    bytes;
  Bytes.unsafe_to_string output

let ulid () =
  ulid_with ~now_ms:(fun () -> Int64.of_float (now () *. 1000.)) ~entropy:random_bytes

let slug title =
  let output = Buffer.create 48 and separator = ref false in
  String.iter
    (fun character ->
      let character = Char.lowercase_ascii character in
      if
        ((character >= 'a' && character <= 'z')
        || (character >= '0' && character <= '9'))
        && Buffer.length output < 48
      then begin
        if !separator && Buffer.length output > 0 && Buffer.length output < 47 then
          Buffer.add_char output '-';
        separator := false;
        if Buffer.length output < 48 then Buffer.add_char output character
      end
      else separator := true)
    title;
  if Buffer.length output = 0 then "task" else Buffer.contents output

let add_task ~repo ~contents ~claim ~confirmed =
  Result.bind (parse_document contents) (fun document ->
      if type_name document <> Some "task" then
        error "task_type_required" "Task input must be a complete type: task document."
      else if task_lifecycle document <> (Some (scalar "todo"), None) then
        error "task_initial_state_invalid"
          "New tasks must start in todo without completed_at."
      else
        let title = Option.value (Option.bind (find "title" document.metadata) string) ~default:"task" in
        let rec attempt remaining =
          if remaining = 0 then error "ulid_collision" "Could not allocate a unique task ID."
          else
            let id = "tasks/" ^ ulid () ^ "-" ^ slug title in
            match
              mutate_with_mode ~task_add:true ~repo ~id ~contents ~claim ~confirmed
                ~allow_unknown:false ~create:true
            with
            | Error { code = "concept_exists"; _ } -> attempt (remaining - 1)
            | result -> Result.map (fun result -> result.id) result
        in
        attempt 16)

let transition_allowed current target =
  match (current, target) with
  | ("todo" | "blocked"), "doing"
  | ("todo" | "doing"), "blocked"
  | ("todo" | "doing" | "blocked"), ("done" | "cancelled") -> true
  | _ -> false

let valid_closure_authority = function
  | "performed-and-verified" | "user-explicit" | "confirmed" -> true
  | _ -> false

let transition ?closure_authority repo id target =
  if target = "done"
     && not (Option.exists valid_closure_authority closure_authority)
  then error "closure_authority_required" "A valid closure authority is required."
  else
  update ~allow_lifecycle:true repo id (fun _ document ->
      match task_of id document with
      | None -> error "not_a_task" "Concept is not a task."
      | Some task when not (transition_allowed task.state target) ->
          error "invalid_task_transition" "The requested task transition is invalid."
      | Some _ ->
          let clamp = Option.get (find "clamp" document.metadata) in
          let task = Option.get (find "task" clamp) |> set "state" (scalar target) in
          let task =
            if target = "done" then set "completed_at" (scalar (timestamp ())) task
            else remove "completed_at" task
          in
          Ok { document with metadata = set "clamp" (set "task" task clamp) document.metadata })

let todo_at root =
  with_transaction root (fun transaction ->
      Result.bind (capture_task_input transaction root) (fun (tasks, input_witness) ->
          let contents = render_todo ~now:(now ()) tasks in
          Result.bind (validate_managed_output ~name:"Generated TODO" contents)
            (fun contents ->
              let hook_ok =
                try !transaction_hook After_task_input_render; true with _ -> false
              in
              if not hook_ok then error "write_failed" "TODO preparation failed."
              else
              Result.bind
                (atomic_replace_private transaction
                   ~validate:(fun () ->
                     Option.fold ~none:true
                       ~some:(fun witness -> task_input_matches witness root)
                       input_witness)
                   ~on_preinstall_failure:
                     (register_initial_state_witness transaction root [] root
                        "TODO.md")
                   ~on_rollback:(fun installed ->
                     register_install_rollback_witness transaction root []
                       installed)
                   ~on_success:(fun target ->
                     register_public_witness transaction
                       ~expected_owner:(Secure_fs.effective_uid ())
                       ~expected_mode:0o600
                       ~expected_links:1
                       root [] root "TODO.md" target contents)
                   root "TODO.md" contents)
                (fun () -> Ok contents))))

let todo repo =
  with_exclusive_repo repo (fun root -> todo_at root)

let with_read_lock_if_present root action =
  with_root_lock ~exclusive:false root action

type optional_todo_read_phase = After_todo_inspect | After_todo_opened
let optional_todo_read_hook = ref (fun (_ : optional_todo_read_phase) -> ())

(* Absence is established only by the first lookup.  Once an entry has been
   observed, every failure is evidence of a race rather than ordinary drift. *)
let read_optional_todo_snapshot root =
  match Secure_fs.inspect root "TODO.md" with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | kind, inspected ->
   (try
    if kind <> Secure_fs.Regular then
      error "file_not_regular" "Managed files must be regular and not symlinks."
    else begin
      !optional_todo_read_hook After_todo_inspect;
      let descriptor = Secure_fs.open_file_at root "TODO.md" in
      let retained = Unix.dup ~cloexec:true descriptor in
      Fun.protect ~finally:(fun () -> close_noerr retained) (fun () ->
          let owner, mode = Secure_fs.descriptor_owner_mode retained in
          if not (same_entry inspected (Secure_fs.descriptor_identity retained))
             || owner <> Secure_fs.effective_uid ()
          then begin close_noerr descriptor; uncertain () end
          else begin
            !optional_todo_read_hook After_todo_opened;
            match read_descriptor descriptor inspected with
            | Error _ -> uncertain ()
            | Ok bytes ->
                let owner_after, mode_after =
                  Secure_fs.descriptor_owner_mode retained
                in
                (match Secure_fs.inspect root "TODO.md" with
                | Secure_fs.Regular, final
                  when same_entry final inspected && owner_after = owner
                       && mode_after = mode -> Ok (Some bytes)
                | _ -> uncertain ())
          end)
    end
    with Unix.Unix_error _ | Sys_error _ -> uncertain ())

let todo_drift_at root =
  let rec stable_snapshot remaining =
    Result.bind (load_tasks_at root) (fun before ->
        let expected = render_todo ~now:(now ()) before in
        Result.bind (read_optional_todo_snapshot root) (fun actual ->
            Result.bind (load_tasks_at root) (fun after ->
                let check = render_todo ~now:(now ()) after in
                if expected = check then Ok (actual <> Some expected)
                else if remaining > 0 then stable_snapshot (remaining - 1)
                else
                  error "repository_changed"
                    "Task files changed while TODO drift was checked.")))
  in
  stable_snapshot 2

let todo_drift repo =
  with_repo repo (fun root ->
      with_read_lock_if_present root (fun () -> todo_drift_at root))

let set_policy repo value =
  if not (List.mem value [ "confirm"; "auto_draft" ]) then
    error "invalid_policy" "Policy must be confirm or auto_draft."
  else
    with_repo repo (fun root ->
        with_lock root (fun () ->
          with_transaction root (fun transaction ->
            match snapshot_private transaction root "clamp.yaml" with
            | Error issue -> Error issue
            | Ok None ->
                transaction.cleanup_uncertain <- true;
                error "file_not_found" "Configuration does not exist."
            | Ok (Some snapshot as initial) ->
                let fail issue =
                  release_initial_state transaction root [] root "clamp.yaml" initial;
                  Error issue
                in
                match Exact_yaml.parse snapshot.snapshot_contents with
                | Error _ ->
                    fail { code = "config_invalid";
                           message = "Configuration is invalid." }
                | Ok yaml ->
                    let output =
                      Exact_yaml.to_string
                        (set "inferred_writes" (scalar value) yaml)
                    in
                    (match Config.validate output with
                    | Error _ ->
                        fail { code = "config_invalid";
                               message = "Configuration is invalid." }
                    | Ok () ->
                        (match validate_managed_output ~name:"Configuration" output with
                        | Error issue -> fail issue
                        | Ok output ->
                            atomic_replace_private_snapshot transaction
                              ~on_preinstall_failure:
                                (register_initial_state_witness transaction root [] root
                                   "clamp.yaml")
                              ~on_rollback:(fun installed ->
                                register_install_rollback_witness transaction root []
                                  installed)
                              ~on_success:(fun target ->
                                register_public_witness
                                  ~expected_owner:(Secure_fs.effective_uid ())
                                  ~expected_mode:0o600 ~expected_links:1 transaction root [] root
                                  "clamp.yaml" target output)
                              root "clamp.yaml" initial output)))))

module For_test = struct
  let with_clock value action =
    let previous = !clock in
    Fun.protect ~finally:(fun () -> clock := previous) (fun () -> clock := value; action ())

  let with_transaction_hook hook action =
    let previous = !transaction_hook in
    Fun.protect
      ~finally:(fun () -> transaction_hook := previous)
      (fun () -> transaction_hook := hook; action ())

  let with_operation_hook hook action =
    let previous = !operation_hook in
    Fun.protect ~finally:(fun () -> operation_hook := previous)
      (fun () -> operation_hook := hook; action ())

  let with_final_gate_failure_hook hook action =
    let previous = !final_gate_failure_hook in
    Fun.protect
      ~finally:(fun () -> final_gate_failure_hook := previous)
      (fun () -> final_gate_failure_hook := hook; action ())

  let with_ownership_hook hook action =
    let previous = !ownership_hook in
    Fun.protect ~finally:(fun () -> ownership_hook := previous)
      (fun () -> ownership_hook := hook; action ())

  let with_after_existing_read_hook hook action =
    let previous = !after_existing_read_hook in
    Fun.protect ~finally:(fun () -> after_existing_read_hook := previous)
      (fun () -> after_existing_read_hook := hook; action ())

  let with_private_directory_cleanup_proof_hook hook action =
    let previous = !private_directory_cleanup_proof_hook in
    Fun.protect
      ~finally:(fun () -> private_directory_cleanup_proof_hook := previous)
      (fun () -> private_directory_cleanup_proof_hook := hook; action ())

  let with_task_input_capture_hook hook action =
    let previous = !task_input_capture_hook in
    Fun.protect
      ~finally:(fun () -> task_input_capture_hook := previous)
      (fun () -> task_input_capture_hook := hook; action ())

  let with_task_read_hook hook action =
    let previous = !task_read_hook in
    Fun.protect ~finally:(fun () -> task_read_hook := previous)
      (fun () -> task_read_hook := hook; action ())

  let with_optional_todo_read_hook hook action =
    let previous = !optional_todo_read_hook in
    Fun.protect ~finally:(fun () -> optional_todo_read_hook := previous)
      (fun () -> optional_todo_read_hook := hook; action ())
end
