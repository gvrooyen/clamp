type error = {
  code : string;
  message : string;
  details : Yojson.Safe.t;
  exit_class : Exit_class.t;
}

type success = {
  code : string;
  from_version : string;
  to_version : string;
  changed_paths : string list;
}

type generated_file = { path : string; mode : int; contents : string }

type entry_identity = { device : int64; inode : int64 }

type transaction_entry = {
  path : string;
  old_sha256 : string option;
  old_identity : entry_identity option;
  new_sha256 : string;
  mutable new_identity : entry_identity option;
  executable : bool;
  slot : string;
}

let ( let* ) = Result.bind

let failure ?(details = `Assoc []) exit_class code message =
  Error { code; message; details; exit_class }

let user ?details code message = failure ?details Exit_class.User_error code message
let conflict ?details code message = failure ?details Exit_class.Conflict code message
let internal ?details code message = failure ?details Exit_class.Internal code message

let sha256 contents = Digestif.SHA256.(to_hex (digest_string contents))

let random_hex () =
  let bytes = Bytes.create 16 in
  let descriptor = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let rec fill offset =
        if offset < Bytes.length bytes then
          match Unix.read descriptor bytes offset (Bytes.length bytes - offset) with
          | 0 -> raise End_of_file
          | count -> fill (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
      in
      fill 0);
  let hex = Digestif.SHA256.(to_hex (digest_bytes bytes)) in
  String.sub hex 0 32

let entry_identity (identity : Secure_fs.identity) =
  { device = identity.device; inode = identity.inode }

let same_entry_identity left right =
  left.device = right.device && left.inode = right.inode

let read_bounded path =
  try
    let observed = Unix.lstat path in
    if observed.st_kind <> Unix.S_REG || observed.st_size > Limits.max_file_bytes then
      internal ~details:(`Assoc [ ("cause", `String "entry_kind") ])
        "scaffold_upgrade_failed" "A scaffold template is not a bounded regular file."
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
          let opened = Unix.fstat descriptor in
          if opened.st_dev <> observed.st_dev || opened.st_ino <> observed.st_ino then
            internal ~details:(`Assoc [ ("cause", `String "identity") ])
              "scaffold_upgrade_failed" "A scaffold template changed while it was read."
          else
            let channel = Unix.in_channel_of_descr (Unix.dup descriptor) in
            Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
                Ok (really_input_string channel opened.st_size)))
  with _ ->
    internal ~details:(`Assoc [ ("cause", `String "entry_kind") ])
      "scaffold_upgrade_failed" "A required scaffold template is unavailable."

let template runtime_root name =
  read_bounded (Filename.concat runtime_root ("share/clamp/templates/" ^ name))

let manifest_contents version (files : generated_file list) =
  let entries =
    files
    |> List.sort (fun (left : generated_file) (right : generated_file) ->
           String.compare left.path right.path)
    |> List.map (fun (file : generated_file) ->
           `Assoc
             [ ("path", `String file.path);
               ("sha256", `String (sha256 file.contents));
               ("git_mode", `String (if file.mode land 0o100 <> 0 then "100755" else "100644")) ])
  in
  Yojson.Safe.to_string
    (`Assoc
      [ ("schema_version", `Int 1); ("scaffold_version", `String version);
        ("files", `List entries) ])
  ^ "\n"

let generated_files ~runtime_root ~lock ~version =
  let specifications =
    [ ("setup", ".agents/setup", 0o700);
      ("resume", ".agents/resume", 0o700);
      ("setup-local", ".agents/setup-local", 0o700);
      ("kb", ".agents/kb", 0o700);
      ("runtime_metadata.py", ".agents/runtime_metadata.py", 0o600);
      ("skill.md", ".agents/skills/managing-clamp-knowledge/SKILL.md", 0o600);
      ("AGENTS.md", "AGENTS.md", 0o600);
      ("README.md", "README.md", 0o600);
      ("gitignore", ".gitignore", 0o600) ]
  in
  let* files =
    List.fold_left
      (fun result (source, path, mode) ->
        let* values = result in
        let* contents = template runtime_root source in
        Ok ({ path; mode; contents } :: values))
      (Ok []) specifications
  in
  let files =
    { path = ".agents/clamp-runtime.lock"; mode = 0o600; contents = lock }
    :: List.rev files
  in
  let manifest = manifest_contents version files in
  Ok
    (files
    @ [ { path = ".agents/clamp-scaffold.json"; mode = 0o600;
          contents = manifest } ])

let current_uid = Secure_fs.effective_uid ()

let read_worktree_file root path ~executable =
  let absolute = Filename.concat root path in
  try
    let observed = Unix.lstat absolute in
    if observed.st_kind <> Unix.S_REG then Error `Kind
    else if observed.st_uid <> current_uid then Error `Owner
    else if observed.st_perm land 0o022 <> 0 then Error `Permissions
    else if (observed.st_perm land 0o100 <> 0) <> executable then Error `Permissions
    else if observed.st_size > Limits.max_file_bytes then Error `Size
    else
      let descriptor = Unix.openfile absolute [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
          let opened = Unix.fstat descriptor in
          if opened.st_dev <> observed.st_dev || opened.st_ino <> observed.st_ino then
            Error `Identity
          else
            let channel = Unix.in_channel_of_descr (Unix.dup descriptor) in
            Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
                let contents = really_input_string channel opened.st_size in
                let after = Unix.fstat descriptor in
                if after.st_size <> opened.st_size || after.st_mtime <> opened.st_mtime then
                  Error `Identity
                else Ok contents))
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Error `Missing
     | _ -> Error `Identity

let git_environment =
  [| "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null";
     "HOME=/nonexistent"; "XDG_CONFIG_HOME=/nonexistent"; "LANG=C"; "LC_ALL=C" |]

let git repo arguments =
  let argv = Array.of_list ("/usr/bin/git" :: "-C" :: repo :: arguments) in
  let stdout_channel, stdin_channel, error_channel =
    Unix.open_process_args_full "/usr/bin/git" argv git_environment
  in
  close_out_noerr stdin_channel;
  let read channel =
    let buffer = Buffer.create 256 and chunk = Bytes.create 4096 in
    let rec loop total =
      if total > 1_048_576 then raise Exit
      else
        match Stdlib.input channel chunk 0 (Bytes.length chunk) with
        | 0 -> Buffer.contents buffer
        | count -> Buffer.add_subbytes buffer chunk 0 count; loop (total + count)
    in
    loop 0
  in
  try
    let stdout = read stdout_channel and _stderr = read error_channel in
    match Unix.close_process_full (stdout_channel, stdin_channel, error_channel) with
    | Unix.WEXITED 0 -> Ok stdout
    | _ -> Error ()
  with _ ->
    ignore (Unix.close_process_full (stdout_channel, stdin_channel, error_channel));
    Error ()

let uname flag =
  try
    let channel =
      Unix.open_process_args_in "/usr/bin/uname" [| "/usr/bin/uname"; flag |]
    in
    let value = input_line channel in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> value
    | _ -> ""
  with _ -> ""

let canonical_root repo =
  try
    let root = Unix.realpath repo in
    match git root [ "rev-parse"; "--path-format=absolute"; "--show-toplevel" ] with
    | Ok value when Unix.realpath (String.trim value) = root -> Ok root
    | Ok _ -> internal ~details:(`Assoc [ ("cause", `String "root_mismatch") ])
                "scaffold_upgrade_failed" "The selected root is not the retained checkout."
    | Error () -> internal ~details:(`Assoc [ ("cause", `String "not_git_repository") ])
                    "scaffold_upgrade_failed" "The selected root is not a Git repository."
  with _ ->
    internal ~details:(`Assoc [ ("cause", `String "not_git_repository") ])
      "scaffold_upgrade_failed" "The selected root is not a Git repository."

let git_path root name =
  match git root [ "rev-parse"; "--path-format=absolute"; "--git-path"; name ] with
  | Ok value -> Some (String.trim value)
  | Error () -> None

let present path =
  try ignore (Unix.lstat path); true with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let quiescent root =
  match git root [ "status"; "--porcelain=v1"; "-z"; "--untracked-files=all" ] with
  | Error () -> internal ~details:(`Assoc [ ("cause", `String "not_git_repository") ])
                  "scaffold_upgrade_failed" "Git could not inspect the repository."
  | Ok paths when paths <> "" ->
      conflict ~details:(`Assoc [ ("state", `String "dirty_worktree") ])
        "scaffold_busy" "Scaffold upgrade requires a clean worktree."
  | Ok _ ->
      let merge = Option.exists present (git_path root "MERGE_HEAD") in
      let rebase =
        Option.exists present (git_path root "rebase-merge")
        || Option.exists present (git_path root "rebase-apply")
      in
      if merge then
        conflict ~details:(`Assoc [ ("state", `String "merge") ])
          "scaffold_busy" "A Git merge is active."
      else if rebase then
        conflict ~details:(`Assoc [ ("state", `String "rebase") ])
          "scaffold_busy" "A Git rebase is active."
      else
        match git root [ "for-each-ref"; "--format=%(refname)"; "refs/clamp/publish" ] with
        | Ok "" -> Ok ()
        | Ok _ ->
            conflict ~details:(`Assoc [ ("state", `String "publication_state") ])
              "scaffold_busy" "A retained publication operation must be resolved first."
        | Error () ->
            internal ~details:(`Assoc [ ("cause", `String "verify") ])
              "scaffold_upgrade_failed" "Publication state could not be inspected."

let legacy =
  [ (".agents/resume", true,
     "4dbcaa05812ebd0ff016e3efbdf329c5466c9ee24edf62dc1c14b7a62a0bc5cb");
    (".agents/setup", true,
     "1155bfedbf08b8a76e185e5a324ac6b07270bf650a01da21dab014dfef1f345c");
    (".agents/skills/managing-clamp-knowledge/SKILL.md", false,
     "c18b36a55792ca8b8504aac6e083cc474df79f7f37140b55d3dde1e0c33af4a4");
    (".gitignore", false,
     "3f542922e7680145916cfcf9e48a8eb149880630a90ec71bb59df19ae5d1c15d");
    ("AGENTS.md", false,
     "f0f09d96f49ae5a0479544abcb482aeefb8b35b32c36b8700b3b82c124fb421c");
    ("README.md", false,
     "fd5180900792a9592b0749102a5ce8c19063174d3192281323ae16c15c3468da") ]

let legacy_conflicts root =
  List.filter_map
    (fun (path, executable, expected) ->
      match read_worktree_file root path ~executable with
      | Ok contents when sha256 contents = expected -> None
      | _ -> Some path)
    legacy

let ensure_absent root paths =
  List.filter (fun path -> present (Filename.concat root path)) paths

let split_path path = String.split_on_char '/' path

type managed_parent = {
  relative : string;
  descriptor : Unix.file_descr;
  identity : Secure_fs.identity;
}

let same_inode (left : Secure_fs.identity) (right : Secure_fs.identity) =
  left.device = right.device && left.inode = right.inode

let parent_paths files =
  let rec ancestors path values =
    let parent = Filename.dirname path in
    if parent = "." then "" :: values else ancestors parent (parent :: values)
  in
  files
  |> List.concat_map (fun (file : generated_file) -> ancestors file.path [])
  |> List.sort_uniq (fun left right ->
         let depth value = List.length (split_path value) in
         match Int.compare (depth left) (depth right) with
         | 0 -> String.compare left right
         | order -> order)

let open_managed_parents root_descriptor files =
  let handles = ref
      [ { relative = ""; descriptor = root_descriptor;
          identity = Secure_fs.descriptor_identity root_descriptor } ] in
  let find relative =
    List.find (fun value -> value.relative = relative) !handles
  in
  try
    parent_paths files
    |> List.iter (fun relative ->
           if relative <> "" then begin
             let parent_relative = Filename.dirname relative in
             let parent_relative = if parent_relative = "." then "" else parent_relative in
             let parent = find parent_relative in
             let descriptor =
               Secure_fs.open_directory_at parent.descriptor (Filename.basename relative)
             in
             let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
             if owner <> current_uid || mode land 0o022 <> 0 then begin
               Unix.close descriptor;
               raise Exit
             end;
             handles :=
               { relative; descriptor;
                 identity = Secure_fs.descriptor_identity descriptor }
               :: !handles
           end);
    Ok !handles
  with _ ->
    List.iter
      (fun value -> if value.relative <> "" then Unix.close value.descriptor)
      !handles;
    internal ~details:(`Assoc [ ("cause", `String "identity") ])
      "scaffold_upgrade_failed" "A managed scaffold parent is unsafe."

let close_managed_parents handles =
  List.iter
    (fun value -> if value.relative <> "" then Unix.close value.descriptor)
    handles

let managed_parent_attached root handles handle =
  let root_handle = List.find (fun value -> value.relative = "") handles in
  let root_attached =
    try
      let observed = Unix.stat root in
      Int64.of_int observed.st_dev = root_handle.identity.device
      && Int64.of_int observed.st_ino = root_handle.identity.inode
    with _ -> false
  in
  let rec attached current =
    if current.relative = "" then root_attached
    else
      let parent_relative = Filename.dirname current.relative in
      let parent_relative = if parent_relative = "." then "" else parent_relative in
      let parent = List.find (fun value -> value.relative = parent_relative) handles in
      attached parent
      &&
      try
        let kind, identity =
          Secure_fs.inspect parent.descriptor (Filename.basename current.relative)
        in
        kind = Secure_fs.Directory && same_inode identity current.identity
      with _ -> false
  in
  attached handle

let with_parent root handles path action =
  match List.rev (split_path path) with
  | [] -> invalid_arg "empty scaffold path"
  | name :: reversed_parents ->
      let relative = String.concat "/" (List.rev reversed_parents) in
      let parent =
        List.find (fun value -> value.relative = relative) handles
      in
      if not (managed_parent_attached root handles parent) then
        raise Secure_fs.Rename_validation_failed;
      let result = action parent.descriptor name in
      if not (managed_parent_attached root handles parent) then
        raise Secure_fs.Rename_validation_failed;
      result

let descriptor_contents descriptor =
  let stat = Unix.fstat descriptor in
  if stat.st_kind <> Unix.S_REG || stat.st_size > Limits.max_file_bytes then None
  else
    let duplicate = Unix.dup descriptor in
    let channel = Unix.in_channel_of_descr duplicate in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        ignore (Unix.lseek duplicate 0 Unix.SEEK_SET);
        Some (really_input_string channel stat.st_size))

let entry_digest parent name =
  try
    let descriptor = Secure_fs.open_file_at parent name in
    Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
        Option.map sha256 (descriptor_contents descriptor))
  with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let entry_identity_at parent name =
  try
    let kind, identity = Secure_fs.inspect parent name in
    if kind = Secure_fs.Regular then Some (entry_identity identity) else None
  with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let entry_matches parent name digest identity =
  entry_digest parent name = Some digest
  &&
  match entry_identity_at parent name with
  | Some observed -> same_entry_identity observed identity
  | None -> false

let entry_absent_at parent name =
  try ignore (Secure_fs.inspect parent name); false
  with Unix.Unix_error (Unix.ENOENT, _, _) -> true

let read_managed_file root handles path ~executable =
  try
    with_parent root handles path (fun parent name ->
        let descriptor = Secure_fs.open_file_at parent name in
        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
            let observed = Unix.fstat descriptor in
            if observed.st_uid <> current_uid || observed.st_perm land 0o022 <> 0
               || (observed.st_perm land 0o100 <> 0) <> executable
            then Error `Permissions
            else
              match descriptor_contents descriptor with
              | Some contents -> Ok contents
              | None -> Error `Kind))
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Error `Missing
     | _ -> Error `Identity

let snapshot_managed_file root handles path ~executable =
  try
    with_parent root handles path (fun parent name ->
        let descriptor = Secure_fs.open_file_at parent name in
        try
          let observed = Unix.fstat descriptor in
          if observed.st_uid <> current_uid || observed.st_perm land 0o022 <> 0
             || (observed.st_perm land 0o100 <> 0) <> executable
          then begin Unix.close descriptor; Error `Permissions end
          else
            match descriptor_contents descriptor with
            | Some contents ->
                Ok (contents,
                    entry_identity (Secure_fs.descriptor_identity descriptor),
                    descriptor)
            | None -> Unix.close descriptor; Error `Kind
        with failure -> Unix.close descriptor; raise failure)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Error `Missing
     | _ -> Error `Identity

let after_file_create_hook = ref (fun (_ : string) -> ())

let write_at parent name mode contents =
  let descriptor = Secure_fs.create_file_at parent name in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      !after_file_create_hook name;
      let bytes = Bytes.unsafe_of_string contents in
      let rec loop offset =
        if offset < Bytes.length bytes then
          let count = Unix.write descriptor bytes offset (Bytes.length bytes - offset) in
          if count = 0 then raise End_of_file else loop (offset + count)
      in
      loop 0;
      Unix.fchmod descriptor mode;
      Secure_fs.fsync descriptor)

let entry_json entry =
  let identity_json = function
    | None -> `Null
    | Some value ->
        `Assoc
          [ ("device", `String (Int64.to_string value.device));
            ("inode", `String (Int64.to_string value.inode)) ]
  in
  `Assoc
    [ ("path", `String entry.path);
      ("old_sha256", match entry.old_sha256 with None -> `Null | Some value -> `String value);
      ("old_identity", identity_json entry.old_identity);
      ("new_sha256", `String entry.new_sha256);
      ("new_identity", identity_json entry.new_identity);
      ("executable", `Bool entry.executable); ("slot", `String entry.slot) ]

let record_json from_version to_version entries =
  Yojson.Safe.to_string
    (`Assoc
      [ ("schema_version", `Int 1); ("from_version", `String from_version);
        ("to_version", `String to_version);
        ("entries", `List (List.map entry_json entries)) ])
  ^ "\n"

let parse_record contents =
  let open Yojson.Safe.Util in
  try
    let value = Yojson.Safe.from_string contents in
    let fields = to_assoc value in
    let names = List.map fst fields |> List.sort String.compare in
    if names <> [ "entries"; "from_version"; "schema_version"; "to_version" ]
       || value |> member "schema_version" |> to_int <> 1
    then None
    else
      let parse entry =
        let names = to_assoc entry |> List.map fst |> List.sort String.compare in
        if names <>
           [ "executable"; "new_identity"; "new_sha256"; "old_identity";
             "old_sha256"; "path"; "slot" ]
        then raise Exit;
        let parse_identity = function
          | `Null -> None
          | `Assoc [ ("device", `String device); ("inode", `String inode) ]
          | `Assoc [ ("inode", `String inode); ("device", `String device) ] ->
              let device = Int64.of_string device and inode = Int64.of_string inode in
              if device < 0L || inode <= 0L then raise Exit;
              Some { device; inode }
          | _ -> raise Exit
        in
        let old_sha256 =
          match member "old_sha256" entry with
          | `Null -> None
          | `String value when Runtime_metadata.valid_sha256 value -> Some value
          | _ -> raise Exit
        in
        let path = entry |> member "path" |> to_string
        and new_sha256 = entry |> member "new_sha256" |> to_string
        and old_identity = entry |> member "old_identity" |> parse_identity
        and new_identity = entry |> member "new_identity" |> parse_identity
        and executable = entry |> member "executable" |> to_bool
        and slot = entry |> member "slot" |> to_string in
        if not (Runtime_metadata.valid_sha256 new_sha256)
           || not (Runtime_metadata.valid_relative_path path)
           || not (Secure_fs.valid_component slot)
        then raise Exit;
        if Option.is_some old_sha256 <> Option.is_some old_identity then raise Exit;
        { path; old_sha256; old_identity; new_sha256; new_identity;
          executable; slot }
      in
      let entries = value |> member "entries" |> to_list |> List.map parse in
      if entries = [] || List.length entries > 100 then None
      else Some (value |> member "from_version" |> to_string,
                 value |> member "to_version" |> to_string, entries)
  with _ -> None

let install_hook = ref (fun (_ : string) -> ())
exception Simulated_interruption
let after_install_hook = ref (fun (_ : string) -> ())
let after_commit_hook = ref (fun () -> ())
let after_cleanup_rename_hook = ref (fun () -> ())
let after_cleanup_entry_hook = ref (fun (_ : string) -> ())
let after_preparation_record_hook = ref (fun () -> ())
let after_record_exchange_hook = ref (fun () -> ())
let before_initial_record_hook = ref (fun () -> ())

module For_test = struct
  let with_install_hook hook action =
    let previous = !install_hook in
    install_hook := hook;
    Fun.protect ~finally:(fun () -> install_hook := previous) action

  let with_interruption_after count action =
    let observed = ref 0 and previous = !after_install_hook in
    after_install_hook := (fun _ ->
        incr observed;
        if !observed = count then raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_install_hook := previous) action

  let with_commit_interruption action =
    let previous = !after_commit_hook in
    after_commit_hook := (fun () -> raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_commit_hook := previous) action

  let with_cleanup_interruption action =
    let previous = !after_cleanup_rename_hook in
    after_cleanup_rename_hook := (fun () -> raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_cleanup_rename_hook := previous) action

  let with_cleanup_entry_interruption name action =
    let previous = !after_cleanup_entry_hook in
    after_cleanup_entry_hook :=
      (fun observed ->
        if observed = name || String.starts_with ~prefix:name observed then
          raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_cleanup_entry_hook := previous) action

  let with_preparation_interruption action =
    let previous = !after_preparation_record_hook in
    after_preparation_record_hook := (fun () -> raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_preparation_record_hook := previous) action

  let with_record_exchange_interruption action =
    let previous = !after_record_exchange_hook in
    after_record_exchange_hook := (fun () -> raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_record_exchange_hook := previous) action

  let with_slot_creation_interruption action =
    let previous = !after_file_create_hook in
    after_file_create_hook :=
      (fun name ->
        if String.starts_with ~prefix:"slot-" name then
          raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> after_file_create_hook := previous) action

  let with_initial_record_interruption action =
    let previous = !before_initial_record_hook in
    before_initial_record_hook := (fun () -> raise Simulated_interruption);
    Fun.protect ~finally:(fun () -> before_initial_record_hook := previous) action
end

let all_targets_match root handles entries ~new_state =
  List.for_all
    (fun entry ->
      with_parent root handles entry.path (fun parent name ->
          if new_state then
            match entry.new_identity with
            | Some identity -> entry_matches parent name entry.new_sha256 identity
            | None -> false
          else
            match entry.old_sha256, entry.old_identity with
            | Some digest, Some identity -> entry_matches parent name digest identity
            | None, None -> entry_absent_at parent name
            | _ -> false))
    entries

let transaction_name = "scaffold-upgrade"
let preparing_name = "scaffold-upgrade-preparing"
let preparing_cleanup_name = "scaffold-upgrade-preparing-cleanup"
let cleanup_name = "scaffold-upgrade-cleanup"
let cleanup_record_name = "scaffold-upgrade-cleanup-record.json"
let rollback_record_name = "scaffold-upgrade-rollback-record.json"

let clamp_attached root handles clamp_descriptor =
  let root_handle = List.find (fun value -> value.relative = "") handles in
  managed_parent_attached root handles root_handle
  &&
  try
    let kind, identity = Secure_fs.inspect root_handle.descriptor ".clamp" in
    kind = Secure_fs.Directory
    && same_inode identity (Secure_fs.descriptor_identity clamp_descriptor)
  with _ -> false

let transaction_attached root handles clamp_descriptor transaction_descriptor
    transaction_identity name =
  clamp_attached root handles clamp_descriptor
  &&
  try
    let kind, identity = Secure_fs.inspect clamp_descriptor name in
    kind = Secure_fs.Directory && same_inode identity transaction_identity
    && same_inode identity (Secure_fs.descriptor_identity transaction_descriptor)
  with _ -> false

let remove_recorded_file ~validate parent name digest identity =
  let descriptor = Secure_fs.open_file_at parent name in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      if entry_digest parent name <> Some digest
         || not
              (same_entry_identity (entry_identity (Secure_fs.descriptor_identity descriptor))
                 identity)
      then raise Secure_fs.Rename_validation_failed;
      Secure_fs.remove_file_at ~validate parent name descriptor
        (Secure_fs.descriptor_identity descriptor))

let replace_record parent contents ~validate =
  let next = "record-next.json" in
  write_at parent next 0o600 contents;
  Secure_fs.fsync parent;
  let old_digest = Option.get (entry_digest parent "record.json") in
  let old_identity = Option.get (entry_identity_at parent "record.json") in
  let new_digest = sha256 contents in
  let new_identity = Option.get (entry_identity_at parent next) in
  Secure_fs.rename_exchange_checked parent next parent "record.json"
    ~validate:(fun () ->
      validate ()
      && entry_matches parent "record.json" old_digest old_identity
      && entry_matches parent next new_digest new_identity);
  Secure_fs.fsync parent;
  !after_record_exchange_hook ();
  remove_recorded_file ~validate parent next old_digest old_identity

let cleanup_transaction root handles clamp_descriptor transaction_descriptor
    transaction_identity entries ~new_state ~name =
  let attached_name = ref name in
  let base_validate () =
    clamp_attached root handles clamp_descriptor
    && all_targets_match root handles entries ~new_state
  in
  let validate () =
    base_validate ()
    && transaction_attached root handles clamp_descriptor transaction_descriptor
         transaction_identity !attached_name
  in
  let marker_name = if new_state then cleanup_record_name else rollback_record_name in
  let record_contents =
    match entry_digest transaction_descriptor "record.json" with
    | Some _ ->
        let descriptor = Secure_fs.open_file_at transaction_descriptor "record.json" in
        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
            Option.get (descriptor_contents descriptor))
    | None ->
        let descriptor = Secure_fs.open_file_at clamp_descriptor marker_name in
        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
            Option.get (descriptor_contents descriptor))
  in
  if entry_absent_at clamp_descriptor marker_name then begin
    write_at clamp_descriptor marker_name 0o600 record_contents;
    Secure_fs.fsync clamp_descriptor
  end else if entry_digest clamp_descriptor marker_name <> Some (sha256 record_contents)
  then raise Secure_fs.Rename_validation_failed;
  if name = transaction_name then begin
    Secure_fs.rename_noreplace_checked clamp_descriptor transaction_name
      clamp_descriptor cleanup_name
      ~validate:(fun () ->
        validate ()
        && not (entry_absent_at clamp_descriptor transaction_name)
        && entry_absent_at clamp_descriptor cleanup_name);
    attached_name := cleanup_name;
    Secure_fs.fsync clamp_descriptor;
    !after_cleanup_rename_hook ()
  end else if name <> cleanup_name then invalid_arg "unknown scaffold transaction";
  List.iter
    (fun entry ->
      let expected =
        if new_state then
          match entry.old_sha256, entry.old_identity with
          | Some digest, Some identity -> Some (digest, identity)
          | None, None -> None
          | _ -> raise Secure_fs.Rename_validation_failed
        else Option.map (fun identity -> entry.new_sha256, identity) entry.new_identity
      in
      match expected with
      | None ->
          if not (entry_absent_at transaction_descriptor entry.slot) then begin
            let identity = Option.get (entry_identity_at transaction_descriptor entry.slot) in
            remove_recorded_file ~validate transaction_descriptor entry.slot
              entry.new_sha256 identity;
            !after_cleanup_entry_hook entry.slot
          end
      | Some (digest, identity) ->
          if not (entry_absent_at transaction_descriptor entry.slot) then begin
            remove_recorded_file ~validate transaction_descriptor entry.slot digest identity;
            !after_cleanup_entry_hook entry.slot
          end)
    entries;
  (match entry_digest transaction_descriptor "record-next.json" with
  | None -> ()
  | Some digest ->
      let identity = Option.get (entry_identity_at transaction_descriptor "record-next.json") in
      remove_recorded_file ~validate transaction_descriptor "record-next.json" digest identity;
      !after_cleanup_entry_hook "record-next.json");
  (match entry_digest transaction_descriptor "COMMITTED" with
  | None -> ()
  | Some digest ->
      let identity = Option.get (entry_identity_at transaction_descriptor "COMMITTED") in
      remove_recorded_file ~validate transaction_descriptor "COMMITTED" digest identity;
      !after_cleanup_entry_hook "COMMITTED");
  (match entry_digest transaction_descriptor "record.json" with
  | None -> ()
  | Some digest ->
      let identity = Option.get (entry_identity_at transaction_descriptor "record.json") in
      remove_recorded_file ~validate transaction_descriptor "record.json" digest identity;
      !after_cleanup_entry_hook "record.json");
  if not (validate ()) then raise Secure_fs.Rename_validation_failed;
  let observed_kind, observed_identity =
    Secure_fs.inspect clamp_descriptor cleanup_name
  in
  if observed_kind <> Secure_fs.Directory
     || not (same_inode observed_identity transaction_identity)
  then raise Secure_fs.Rename_validation_failed;
  let watch = Secure_fs.watch_directory_removal transaction_descriptor in
  Fun.protect ~finally:(fun () -> Secure_fs.close_directory_removal watch) (fun () ->
      Secure_fs.rmdir_at clamp_descriptor cleanup_name;
      Secure_fs.fsync clamp_descriptor;
      if not (base_validate () && entry_absent_at clamp_descriptor cleanup_name
              && Secure_fs.directory_removal_observed watch)
      then raise Secure_fs.Rename_validation_failed);
  let marker_digest = sha256 record_contents in
  let marker_identity = Option.get (entry_identity_at clamp_descriptor marker_name) in
  remove_recorded_file
    ~validate:(fun () -> base_validate () && entry_absent_at clamp_descriptor cleanup_name)
    clamp_descriptor marker_name marker_digest marker_identity;
  base_validate ()

let rollback root handles transaction_descriptor entries ~validate =
  let foreign = ref [] in
  List.iter
    (fun entry ->
      with_parent root handles entry.path (fun parent name ->
          let target = entry_digest parent name
          and slot = entry_digest transaction_descriptor entry.slot in
          match entry.old_sha256, entry.old_identity, entry.new_identity with
          | Some old, Some old_identity, Some new_identity
            when validate ()
                 && entry_matches parent name entry.new_sha256 new_identity
                 && entry_matches transaction_descriptor entry.slot old old_identity ->
              Secure_fs.rename_exchange_checked transaction_descriptor entry.slot
                parent name
                ~validate:(fun () ->
                  validate ()
                  && entry_matches parent name entry.new_sha256 new_identity
                  && entry_matches transaction_descriptor entry.slot old old_identity);
              Secure_fs.fsync parent;
              Secure_fs.fsync transaction_descriptor
          | Some old, Some old_identity, Some new_identity
            when validate () && entry_matches parent name old old_identity
                 && entry_matches transaction_descriptor entry.slot
                      entry.new_sha256 new_identity -> ()
          | None, None, Some new_identity
            when validate ()
                 && entry_matches parent name entry.new_sha256 new_identity
                 && slot = None ->
              Secure_fs.rename_noreplace_checked parent name transaction_descriptor
                entry.slot
                ~validate:(fun () ->
                  validate ()
                  && entry_matches parent name entry.new_sha256 new_identity
                  && entry_digest transaction_descriptor entry.slot = None);
              Secure_fs.fsync parent;
              Secure_fs.fsync transaction_descriptor
          | None, None, Some new_identity
            when validate () && target = None
                 && entry_matches transaction_descriptor entry.slot
                      entry.new_sha256 new_identity -> ()
          | _ -> foreign := entry.path :: !foreign))
    (List.rev entries);
  if !foreign = [] && validate ()
     && all_targets_match root handles entries ~new_state:false
  then Ok () else Error (List.sort_uniq String.compare !foreign)

let recover root handles clamp_descriptor transaction_descriptor transaction_name_value
    transaction_identity =
  let record_parent, record_name =
    if entry_absent_at transaction_descriptor "record.json" then
      if not (entry_absent_at clamp_descriptor cleanup_record_name) then
        clamp_descriptor, cleanup_record_name
      else clamp_descriptor, rollback_record_name
    else transaction_descriptor, "record.json"
  in
  match entry_digest record_parent record_name with
  | None ->
      conflict
        ~details:(`Assoc
          [ ("state", `String "transaction_recovery");
            ("paths", `List [ `String ".clamp/scaffold-upgrade" ]) ])
        "scaffold_recovery_required" "A scaffold transaction record is missing."
  | Some _ ->
      let record =
        let descriptor = Secure_fs.open_file_at record_parent record_name in
        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
            Option.bind (descriptor_contents descriptor) parse_record)
      in
      (match record with
      | None ->
          conflict
            ~details:(`Assoc
              [ ("state", `String "transaction_recovery");
                ("paths", `List [ `String ".clamp/scaffold-upgrade/record.json" ]) ])
            "scaffold_recovery_required" "The scaffold transaction record is invalid."
      | Some (from_version, to_version, entries) ->
          let rollback_cleanup =
            not (entry_absent_at clamp_descriptor rollback_record_name)
          in
          let committed =
            entry_digest transaction_descriptor "COMMITTED" <> None
            || all_targets_match root handles entries ~new_state:true
          in
          let preparing =
            List.exists (fun entry -> Option.is_none entry.new_identity) entries
          in
          if preparing then
            if all_targets_match root handles entries ~new_state:false
               && (try
                     cleanup_transaction root handles clamp_descriptor
                       transaction_descriptor transaction_identity entries ~new_state:false
                       ~name:transaction_name_value
                   with _ -> false)
            then
              conflict
                ~details:(`Assoc
                  [ ("state", `String "transaction_recovery");
                    ("paths", `List (List.map (fun entry -> `String entry.path) entries)) ])
                "scaffold_recovery_required"
                "An interrupted scaffold preparation was removed; rerun the command."
            else
              conflict
                ~details:(`Assoc
                  [ ("state", `String "foreign_replacement");
                    ("paths", `List (List.map (fun entry -> `String entry.path) entries)) ])
                "scaffold_recovery_required"
                "An interrupted scaffold preparation cannot be safely removed."
          else if rollback_cleanup then
            if all_targets_match root handles entries ~new_state:false
               && (try
                     cleanup_transaction root handles clamp_descriptor
                       transaction_descriptor transaction_identity entries ~new_state:false
                       ~name:transaction_name_value
                   with _ -> false)
            then
              conflict
                ~details:(`Assoc
                  [ ("state", `String "transaction_recovery");
                    ("paths", `List (List.map (fun entry -> `String entry.path) entries)) ])
                "scaffold_recovery_required"
                "An interrupted scaffold upgrade was rolled back; rerun the command."
            else
              conflict
                ~details:(`Assoc
                  [ ("state", `String "foreign_replacement");
                    ("paths", `List (List.map (fun entry -> `String entry.path) entries)) ])
                "scaffold_recovery_required"
                "A rollback cleanup transaction cannot be safely finalized."
          else if committed then
            if all_targets_match root handles entries ~new_state:true
               && (try
                     cleanup_transaction root handles clamp_descriptor
                       transaction_descriptor transaction_identity entries ~new_state:true
                       ~name:transaction_name_value
                   with _ -> false)
            then Ok (`Committed (from_version, to_version, entries))
            else
              conflict
                ~details:(`Assoc
                  [ ("state", `String "foreign_replacement");
                    ("paths", `List (List.map (fun value -> `String value.path) entries)) ])
                "scaffold_recovery_required"
                "A committed scaffold transaction cannot be safely finalized."
          else
            match
              rollback root handles transaction_descriptor entries
                ~validate:(fun () ->
                  transaction_attached root handles clamp_descriptor
                    transaction_descriptor transaction_identity transaction_name_value)
            with
            | Error paths ->
                conflict
                  ~details:(`Assoc
                    [ ("state", `String "foreign_replacement");
                      ("paths", `List (List.map (fun value -> `String value) paths)) ])
                  "scaffold_recovery_required"
                  "A foreign replacement prevents scaffold recovery."
            | Ok () ->
                if cleanup_transaction root handles clamp_descriptor
                     transaction_descriptor transaction_identity entries ~new_state:false
                     ~name:transaction_name_value
                then
                  conflict
                    ~details:(`Assoc
                      [ ("state", `String "transaction_recovery");
                        ("paths", `List [ `String ".clamp/scaffold-upgrade" ]) ])
                    "scaffold_recovery_required"
                    "An interrupted scaffold upgrade was rolled back; rerun the command."
                else
                  internal ~details:(`Assoc [ ("cause", `String "rollback") ])
                    "scaffold_upgrade_failed" "Scaffold rollback could not be verified.")

let recover_cleanup_record root handles clamp_descriptor marker_name ~new_state =
  let descriptor = Secure_fs.open_file_at clamp_descriptor marker_name in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      match Option.bind (descriptor_contents descriptor) parse_record with
      | Some (from_version, to_version, entries)
        when entry_absent_at clamp_descriptor transaction_name
             && entry_absent_at clamp_descriptor cleanup_name
             && clamp_attached root handles clamp_descriptor
             && all_targets_match root handles entries ~new_state ->
          let identity = Secure_fs.descriptor_identity descriptor in
          Secure_fs.remove_file_at
            ~validate:(fun () ->
              clamp_attached root handles clamp_descriptor
              && all_targets_match root handles entries ~new_state
              && entry_absent_at clamp_descriptor transaction_name
              && entry_absent_at clamp_descriptor cleanup_name)
            clamp_descriptor marker_name descriptor identity;
          if new_state then Ok (`Committed (from_version, to_version, entries))
          else Ok (`Rolled_back entries)
      | _ ->
          conflict
            ~details:(`Assoc
              [ ("state", `String "transaction_recovery");
                ("paths", `List
                  [ `String (".clamp/" ^ marker_name) ]) ])
            "scaffold_recovery_required"
            "The scaffold cleanup record cannot be safely finalized.")

let recover_preparing root handles clamp_descriptor preparing_descriptor
    preparing_identity name =
  let validate () =
    clamp_attached root handles clamp_descriptor
    && entry_absent_at clamp_descriptor transaction_name
  in
  try
    if name = preparing_name then begin
      Secure_fs.rename_noreplace_checked clamp_descriptor preparing_name
        clamp_descriptor preparing_cleanup_name
        ~validate:(fun () ->
          validate ()
          && transaction_attached root handles clamp_descriptor preparing_descriptor
               preparing_identity preparing_name
          && entry_absent_at clamp_descriptor preparing_cleanup_name);
      Secure_fs.fsync clamp_descriptor
    end else if name <> preparing_cleanup_name then invalid_arg "unknown preparation state";
    Secure_fs.remove_quarantined_tree_at ~validate clamp_descriptor
      preparing_cleanup_name preparing_descriptor preparing_identity;
    conflict
      ~details:(`Assoc
        [ ("state", `String "transaction_recovery");
          ("paths", `List [ `String (".clamp/" ^ name) ]) ])
      "scaffold_recovery_required"
      "An interrupted scaffold preparation was removed; rerun the command."
  with _ ->
    conflict
      ~details:(`Assoc
        [ ("state", `String "foreign_replacement");
          ("paths", `List [ `String (".clamp/" ^ name) ]) ])
      "scaffold_recovery_required"
      "An interrupted scaffold preparation cannot be safely removed."

let ensure_clamp root root_descriptor =
  try
    let descriptor = Secure_fs.open_directory_at root_descriptor ".clamp" in
    let owner, mode = Secure_fs.descriptor_owner_mode descriptor in
    if owner <> current_uid || mode land 0o077 <> 0 then begin
      Unix.close descriptor;
      raise Exit
    end;
    Ok (None, descriptor)
  with Unix.Unix_error (Unix.ENOENT, _, _) ->
    (try
       let created = Secure_fs.mkdir_private_at root_descriptor ".clamp" in
       Secure_fs.fsync root_descriptor;
       Ok (Some created, Secure_fs.open_directory_at root_descriptor ".clamp")
     with _ -> internal ~details:(`Assoc [ ("cause", `String "install") ])
                 "scaffold_upgrade_failed" "The private operation directory could not be created.")
     | _ -> internal ~details:(`Assoc [ ("cause", `String "permissions") ])
              "scaffold_upgrade_failed" "The private operation directory is unsafe."

let current_matches root files =
  List.for_all
    (fun (file : generated_file) ->
      match read_worktree_file root file.path
              ~executable:(file.mode land 0o100 <> 0) with
      | Ok contents -> contents = file.contents
      | Error _ -> false)
    files

let generated_conflicts root files =
  List.filter_map
    (fun (file : generated_file) ->
      match read_worktree_file root file.path
              ~executable:(file.mode land 0o100 <> 0) with
      | Ok contents when contents = file.contents -> None
      | _ -> Some file.path)
    files

let perform root handles clamp_descriptor files ~old_lock from_version to_version =
  let transaction_descriptor =
    try
      let created =
        Secure_fs.mkdir_private_at clamp_descriptor preparing_name
      in
      Ok (created, Secure_fs.open_directory_at clamp_descriptor preparing_name)
    with Unix.Unix_error (Unix.EEXIST, _, _) ->
      conflict
        ~details:(`Assoc
          [ ("state", `String "transaction_recovery");
            ("paths", `List [ `String ".clamp/scaffold-upgrade-preparing" ]) ])
        "scaffold_recovery_required" "A scaffold preparation already exists."
       | _ -> internal ~details:(`Assoc [ ("cause", `String "install") ])
                "scaffold_upgrade_failed" "The scaffold transaction could not be created."
  in
  let* transaction_witness, transaction_descriptor = transaction_descriptor in
  let transaction_identity = Secure_fs.descriptor_identity transaction_descriptor in
  if not
       (same_inode (Secure_fs.descriptor_identity transaction_witness)
          transaction_identity)
  then raise Secure_fs.Rename_validation_failed;
  let attached_name = ref preparing_name in
  let private_attached () =
    transaction_attached root handles clamp_descriptor transaction_descriptor
      transaction_identity !attached_name
  in
  let published = ref false in
  let committed = ref false in
  Fun.protect
    ~finally:(fun () ->
      Unix.close transaction_descriptor;
      Unix.close transaction_witness)
    (fun () ->
    let retained_originals = ref [] in
    Fun.protect
      ~finally:(fun () ->
        List.iter (fun descriptor -> try Unix.close descriptor with _ -> ())
          !retained_originals)
      (fun () ->
      let expected_old path =
        if path = ".agents/clamp-runtime.lock" then Some (sha256 old_lock)
        else
          List.find_map
            (fun (legacy_path, _, digest) ->
              if legacy_path = path then Some digest else None)
            legacy
      in
      let entries =
        List.mapi
          (fun index (file : generated_file) ->
            match snapshot_managed_file root handles file.path
                    ~executable:(file.mode land 0o100 <> 0), expected_old file.path with
            | Ok (contents, identity, descriptor), Some expected
              when sha256 contents = expected ->
                retained_originals := descriptor :: !retained_originals;
                Ok
                  { path = file.path; old_sha256 = Some expected;
                    old_identity = Some identity; new_sha256 = sha256 file.contents;
                    new_identity = None;
                    executable = file.mode land 0o100 <> 0;
                    slot = Printf.sprintf "slot-%03d-%s" index (random_hex ()) }
            | Ok (_, _, descriptor), _ ->
                Unix.close descriptor;
                Error file.path
            | Error `Missing, None ->
                Ok
                  { path = file.path; old_sha256 = None; old_identity = None;
                    new_sha256 = sha256 file.contents; new_identity = None;
                    executable = file.mode land 0o100 <> 0;
                    slot = Printf.sprintf "slot-%03d-%s" index (random_hex ()) }
            | Error _, _ -> Error file.path)
          files
      in
      let invalid =
        List.filter_map (function Error value -> Some value | Ok _ -> None) entries
      in
      if invalid <> [] then
        (try
           if not (private_attached ()) then
             raise Secure_fs.Rename_validation_failed;
           Secure_fs.rename_noreplace_checked clamp_descriptor !attached_name
             clamp_descriptor cleanup_name ~validate:private_attached;
           Secure_fs.fsync clamp_descriptor;
           let cleanup_attached () =
             clamp_attached root handles clamp_descriptor
             &&
             try
               let kind, identity = Secure_fs.inspect clamp_descriptor cleanup_name in
               kind = Secure_fs.Directory && same_inode identity transaction_identity
             with _ -> false
           in
           Secure_fs.remove_quarantined_tree_at ~validate:cleanup_attached
             clamp_descriptor cleanup_name transaction_descriptor transaction_identity;
           conflict
             ~details:(`Assoc
               [ ("paths", `List (List.map (fun path -> `String path) invalid)) ])
             "scaffold_owner_modified"
             "A scaffold entry changed before transaction preparation."
         with _ ->
           conflict
             ~details:(`Assoc
               [ ("state", `String "transaction_recovery");
                 ("paths", `List [ `String ".clamp/scaffold-upgrade" ]) ])
             "scaffold_recovery_required"
             "The unprepared scaffold transaction could not be safely removed.")
      else
      let entries =
        List.filter_map (function Ok value -> Some value | Error _ -> None) entries
      in
      try
        Secure_fs.fsync clamp_descriptor;
        !before_initial_record_hook ();
        write_at transaction_descriptor "record.json" 0o600
          (record_json from_version to_version entries);
        Secure_fs.fsync transaction_descriptor;
        !after_preparation_record_hook ();
        List.iter2
          (fun entry file ->
            write_at transaction_descriptor entry.slot file.mode file.contents;
            entry.new_identity <- entry_identity_at transaction_descriptor entry.slot;
            replace_record transaction_descriptor
              (record_json from_version to_version entries)
              ~validate:private_attached)
          entries files;
        Secure_fs.rename_noreplace_checked clamp_descriptor preparing_name
          clamp_descriptor transaction_name ~validate:private_attached;
        attached_name := transaction_name;
        Secure_fs.fsync clamp_descriptor;
        published := true;
        List.iter
          (fun entry ->
            (!install_hook) entry.path;
            with_parent root handles entry.path (fun parent name ->
                (match entry.old_sha256, entry.old_identity, entry.new_identity with
                 | Some old, Some old_identity, Some new_identity ->
                     Secure_fs.rename_exchange_checked transaction_descriptor entry.slot
                       parent name
                       ~validate:(fun () ->
                         private_attached ()
                         && entry_matches parent name old old_identity
                         && entry_matches transaction_descriptor entry.slot
                              entry.new_sha256 new_identity);
                     if not
                          (entry_matches parent name entry.new_sha256 new_identity
                           && entry_matches transaction_descriptor entry.slot old
                                old_identity)
                     then raise Secure_fs.Rename_validation_failed
                 | None, None, Some new_identity ->
                     Secure_fs.rename_noreplace_checked transaction_descriptor entry.slot
                       parent name
                       ~validate:(fun () ->
                         private_attached ()
                         && entry_digest parent name = None
                         && entry_matches transaction_descriptor entry.slot
                              entry.new_sha256 new_identity);
                     if not (entry_matches parent name entry.new_sha256 new_identity)
                     then raise Secure_fs.Rename_validation_failed
                 | _ -> raise Secure_fs.Rename_validation_failed);
                if not (private_attached ()) then
                  raise Secure_fs.Rename_validation_failed;
                Secure_fs.fsync parent;
                Secure_fs.fsync transaction_descriptor;
                (!after_install_hook) entry.path))
          entries;
        if not (all_targets_match root handles entries ~new_state:true) then
          raise Secure_fs.Rename_validation_failed;
        write_at transaction_descriptor "COMMITTED" 0o600 "committed\n";
        Secure_fs.fsync transaction_descriptor;
        committed := true;
        !after_commit_hook ();
        if not
             (cleanup_transaction root handles clamp_descriptor
                transaction_descriptor transaction_identity entries ~new_state:true
                ~name:transaction_name)
        then raise Secure_fs.Rename_validation_failed;
        Ok
          { code = "scaffold_upgrade_complete"; from_version; to_version;
            changed_paths = List.map (fun (file : generated_file) -> file.path) files }
      with Simulated_interruption -> raise Simulated_interruption
         | _ ->
        if not !published then
          conflict
            ~details:(`Assoc
              [ ("state", `String "transaction_recovery");
                ("paths", `List [ `String ".clamp/scaffold-upgrade-preparing" ]) ])
            "scaffold_recovery_required"
            "The interrupted scaffold preparation requires recovery."
        else if !committed then
          conflict
            ~details:(`Assoc
              [ ("state", `String "transaction_recovery");
                ("paths", `List [ `String ".clamp/scaffold-upgrade-cleanup" ]) ])
            "scaffold_recovery_required"
            "The committed scaffold update requires cleanup recovery."
        else (match
          rollback root handles transaction_descriptor entries
            ~validate:private_attached
        with
        | Ok () ->
            let cleaned =
              try
                cleanup_transaction root handles clamp_descriptor
                  transaction_descriptor transaction_identity entries ~new_state:false
                  ~name:transaction_name
              with _ -> false
            in
            if cleaned then
              internal ~details:(`Assoc [ ("cause", `String "install") ])
                "scaffold_upgrade_failed" "The scaffold update failed and was rolled back."
            else
              internal ~details:(`Assoc [ ("cause", `String "rollback") ])
                "scaffold_upgrade_failed" "The scaffold update could not be rolled back safely."
        | Error paths ->
            conflict
              ~details:(`Assoc
                [ ("state", `String "foreign_replacement");
                  ("paths", `List (List.map (fun path -> `String path) paths)) ])
              "scaffold_recovery_required"
              "A foreign replacement prevents scaffold rollback.")))

let upgrade ~repo ~runtime_root ~runtime_version ~runtime_revision ~manifest_url
    ~manifest_sha256 =
  if not (Runtime_metadata.valid_version runtime_version)
     || not (Runtime_metadata.valid_revision runtime_revision)
     || not (Runtime_metadata.valid_sha256 manifest_sha256)
  then
    user ~details:(`Assoc [ ("cause", `String "value") ])
      "runtime_lock_v2_invalid" "The target v2 runtime lock is invalid."
  else
    let lock : Runtime_metadata.v2_lock =
      { version = runtime_version; revision = runtime_revision; manifest_url;
        manifest_sha256 }
    in
    let lock_contents = Runtime_metadata.serialize_lock lock in
    let target =
      match uname "-s", uname "-m" with
      | "Linux", "x86_64" -> "linux-x86_64"
      | "Darwin", "arm64" -> "macos-arm64"
      | _ -> "unsupported"
    in
    let* _ =
      match Runtime_metadata.parse_lock ~target lock_contents with
      | Ok value -> Ok value
      | Error error ->
          user ~details:(`Assoc [ ("cause", `String "schema") ]) error.code error.message
    in
    let* files = generated_files ~runtime_root ~lock:lock_contents ~version:runtime_version in
    let* root = canonical_root repo in
    let root_descriptor =
      try Ok (Secure_fs.open_directory root)
      with _ -> internal ~details:(`Assoc [ ("cause", `String "root_mismatch") ])
                  "scaffold_upgrade_failed" "The repository root is unsafe."
    in
    let* root_descriptor = root_descriptor in
    Fun.protect ~finally:(fun () -> Unix.close root_descriptor) (fun () ->
        try
          Secure_fs.flock root_descriptor true;
          Fun.protect ~finally:(fun () -> Secure_fs.funlock root_descriptor) (fun () ->
              let* handles = open_managed_parents root_descriptor files in
              Fun.protect ~finally:(fun () -> close_managed_parents handles) (fun () ->
               let* clamp_witness, clamp_descriptor = ensure_clamp root root_descriptor in
               if
                 Option.exists
                   (fun witness ->
                     not
                       (same_inode (Secure_fs.descriptor_identity witness)
                          (Secure_fs.descriptor_identity clamp_descriptor)))
                   clamp_witness
               then raise Secure_fs.Rename_validation_failed;
               Fun.protect
                 ~finally:(fun () ->
                   Unix.close clamp_descriptor;
                   Option.iter Unix.close clamp_witness)
                 (fun () ->
                  let open_named name =
                    try Some (name, Secure_fs.open_directory_at clamp_descriptor name)
                    with Unix.Unix_error (Unix.ENOENT, _, _) -> None
                  in
                  let transaction =
                    match open_named cleanup_name with
                    | Some value -> Some value
                    | None -> open_named transaction_name
                  in
                  let* recovered =
                    match
                      match open_named preparing_cleanup_name with
                      | Some value -> Some value
                      | None -> open_named preparing_name
                    with
                    | Some (name, descriptor) ->
                        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
                            recover_preparing root handles clamp_descriptor descriptor
                              (Secure_fs.descriptor_identity descriptor) name)
                    | None -> (match transaction with
                    | None ->
                        if not (entry_absent_at clamp_descriptor cleanup_record_name) then
                          recover_cleanup_record root handles clamp_descriptor
                            cleanup_record_name ~new_state:true
                        else if not (entry_absent_at clamp_descriptor rollback_record_name) then
                          recover_cleanup_record root handles clamp_descriptor
                            rollback_record_name ~new_state:false
                        else Ok `None
                    | Some (name, descriptor) ->
                        Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
                            recover root handles clamp_descriptor descriptor name
                              (Secure_fs.descriptor_identity descriptor)))
                  in
                  match recovered with
                  | `Committed (from_version, to_version, entries) ->
                    Ok
                      { code = "scaffold_upgrade_complete"; from_version; to_version;
                        changed_paths = List.map (fun entry -> entry.path) entries }
                  | `Rolled_back entries ->
                    conflict
                      ~details:(`Assoc
                        [ ("state", `String "transaction_recovery");
                          ("paths", `List
                            (List.map (fun entry -> `String entry.path) entries)) ])
                      "scaffold_recovery_required"
                      "An interrupted scaffold upgrade was rolled back; rerun the command."
                  | `None ->
                   let* () = quiescent root in
                   if current_matches root files then
                     Ok
                       { code = "scaffold_already_current";
                         from_version = runtime_version; to_version = runtime_version;
                         changed_paths = [] }
                   else
                    let lock_path = Filename.concat root ".agents/clamp-runtime.lock" in
                    let* old_lock =
                      match read_bounded lock_path with
                      | Ok contents -> Ok contents
                      | Error _ ->
                          user ~details:(`Assoc [ ("cause", `String "schema") ])
                            "runtime_lock_v2_invalid" "The existing runtime lock is invalid."
                    in
                    let* parsed =
                      match Runtime_metadata.parse_lock ~target:"linux-x86_64" old_lock with
                      | Ok value -> Ok value
                      | Error error ->
                          user ~details:(`Assoc [ ("cause", `String "schema") ])
                            error.code error.message
                    in
                    match parsed with
                    | Runtime_metadata.V2 _ when old_lock = lock_contents ->
                        conflict
                          ~details:(`Assoc
                            [ ("paths", `List
                                (generated_conflicts root files
                                 |> List.map (fun path -> `String path))) ])
                          "scaffold_owner_modified"
                          "Generated v2 scaffold files differ from their recorded identity."
                    | Runtime_metadata.V2 value ->
                        user
                          ~details:(`Assoc [ ("source_version", `String value.version) ])
                          "scaffold_source_unsupported"
                          "This v2 scaffold does not match the requested generated identity."
                    | Runtime_metadata.V1 value when value.version <> "0.1.4" ->
                        user
                          ~details:(`Assoc [ ("source_version", `String value.version) ])
                          "scaffold_source_unsupported"
                          "Only the exact 0.1.4 generated scaffold is supported."
                    | Runtime_metadata.V1 value ->
                        let conflicts =
                          legacy_conflicts root
                          @ ensure_absent root
                              [ ".agents/kb"; ".agents/setup-local";
                                ".agents/runtime_metadata.py";
                                ".agents/clamp-scaffold.json" ]
                          |> List.sort_uniq String.compare
                        in
                        if conflicts <> [] then
                          conflict
                            ~details:(`Assoc
                              [ ("paths", `List
                                  (List.map (fun path -> `String path) conflicts)) ])
                            "scaffold_owner_modified"
                            "Generated scaffold files differ from the exact 0.1.4 identity."
                        else perform root handles clamp_descriptor files
                               ~old_lock value.version runtime_version)))
        with Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
          conflict ~details:(`Assoc [ ("state", `String "transaction_recovery") ])
            "scaffold_busy" "Another repository operation holds the root lock."
           | Simulated_interruption -> raise Simulated_interruption
           | _ ->
          internal ~details:(`Assoc [ ("cause", `String "verify") ])
            "scaffold_upgrade_failed" "The scaffold upgrade failed safely.")
