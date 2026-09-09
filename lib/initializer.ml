type error = { code : string; message : string }

type created = {
  path : string;
  source_repository : string;
  runtime_revision : string;
}

let error code message = Error { code; message }
let exit_class _ = Exit_class.User_error

let sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let revision value =
  String.length value = 40
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let version value =
  value <> "" && String.length value <= 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' | '.' | '-' -> true | _ -> false)
       value

let https_url value =
  String.starts_with ~prefix:"https://" value
  && String.length value > 8 && String.length value <= 2048
  && String.for_all
       (function ' ' | '\t' | '\n' | '\r' -> false | _ -> true)
       value
  && not (String.contains value '@')

let random_hex () =
  let bytes = Bytes.create 16 in
  let descriptor =
    Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
  in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let rec fill offset =
        if offset < Bytes.length bytes then
          match Unix.read descriptor bytes offset (Bytes.length bytes - offset) with
          | 0 -> raise End_of_file
          | count -> fill (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
      in
      fill 0);
  let alphabet = "0123456789abcdef" in
  let result = Bytes.create 32 in
  Bytes.iteri
    (fun index byte ->
      Bytes.set result (index * 2) alphabet.[Char.code byte lsr 4];
      Bytes.set result ((index * 2) + 1) alphabet.[Char.code byte land 15])
    bytes;
  Bytes.unsafe_to_string result

let read_regular path =
  try
    let stat = Unix.lstat path in
    if stat.st_kind <> Unix.S_REG || stat.st_size > Limits.max_file_bytes then
      error "runtime_template_invalid" "A runtime template is not a bounded regular file."
    else
      let channel = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
          Ok (really_input_string channel (in_channel_length channel)))
  with _ ->
    error "runtime_template_missing" "A required runtime template is unavailable."

let write_file ?(mode = 0o600) path contents =
  let descriptor =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] mode
  in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let bytes = Bytes.unsafe_of_string contents in
      let rec write offset =
        if offset < Bytes.length bytes then
          let count = Unix.write descriptor bytes offset (Bytes.length bytes - offset) in
          if count = 0 then raise End_of_file else write (offset + count)
      in
      write 0;
      Unix.fchmod descriptor mode;
      Unix.fsync descriptor)

let rec remove_owned path =
  try
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_owned (Filename.concat path name));
        Unix.rmdir path
    | _ -> Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let mkdir path = Unix.mkdir path 0o700

let mkdirs root components =
  ignore
    (List.fold_left
       (fun parent component ->
         let path = Filename.concat parent component in
         if not (Sys.file_exists path) then mkdir path;
         path)
       root components)

let runtime_root = function
  | Some path -> path
  | None ->
      (match Sys.getenv_opt "CLAMP_RUNTIME_ROOT" with
      | Some path when path <> "" -> path
      | _ ->
          let executable = Unix.realpath Sys.executable_name in
          Filename.dirname (Filename.dirname executable))

let template root relative =
  read_regular (Filename.concat root ("share/clamp/templates/" ^ relative))

let git_environment =
    [| "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null";
       "HOME=/nonexistent"; "XDG_CONFIG_HOME=/nonexistent";
       "LANG=C"; "LC_ALL=C";
       "GIT_AUTHOR_NAME=Clamp Initializer";
       "GIT_AUTHOR_EMAIL=clamp@local.invalid";
       "GIT_COMMITTER_NAME=Clamp Initializer";
       "GIT_COMMITTER_EMAIL=clamp@local.invalid" |]

let run_git path arguments code message =
  let argv = Array.of_list ("/usr/bin/git" :: "-C" :: path :: arguments) in
  try
    let pid =
      Unix.create_process_env "/usr/bin/git" argv git_environment Unix.stdin
        Unix.stdout Unix.stderr
    in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> Ok ()
    | _ -> error code message
  with _ -> error "git_unavailable" "Git is required to initialize the private repository."

let git_init path =
  run_git path
    [ "init"; "--quiet"; "--template="; "--object-format=sha1";
      "--initial-branch=main" ]
    "git_init_failed" "Git could not initialize the private repository."

let git_commit path =
  Result.bind
    (run_git path [ "add"; "--all" ] "git_add_failed"
       "Git could not stage the initialized private repository.")
    (fun () ->
      run_git path
        [ "commit"; "--quiet"; "--no-gpg-sign"; "--no-verify";
          "--message=Initialize Clamp knowledge repository" ]
        "git_commit_failed"
        "Git could not commit the initialized private repository.")

let canonical_config source_repository =
  Printf.sprintf
    "schema_version: 1\nsource_repository: %s\ntimezone: Africa/Johannesburg\ninferred_writes: confirm\nembedding:\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n  model: openai/text-embedding-3-small\n  dimensions: 1536\n  max_input_bytes: 8000\n  provider_order: [openai]\n  allow_fallbacks: false\n  data_collection: deny\nretrieval:\n  candidate_limit: 100\n  result_limit: 10\n  semantic_weight: 0.70\n  recency_weight: 0.20\n  frequency_weight: 0.10\n  recency_half_life_days: 30\n  frequency_saturation_count: 100\n"
    source_repository

let create ~target ~source_repository ~runtime_version ~runtime_revision
    ~runtime_url ~runtime_sha256 ?runtime_root:root () =
  if not (Config.valid_source_repository source_repository) then
    error "source_repository_invalid" "The source repository identity is invalid."
  else if not (version runtime_version) then
    error "runtime_version_invalid" "The runtime version is invalid."
  else if not (revision runtime_revision) then
    error "runtime_revision_invalid" "The runtime revision must be 40 lowercase hexadecimal characters."
  else if not (https_url runtime_url) then
    error "runtime_url_invalid" "The runtime URL must be a credential-free HTTPS URL."
  else if not (sha256 runtime_sha256) then
    error "runtime_sha256_invalid" "The runtime SHA-256 must be 64 lowercase hexadecimal characters."
  else
    let target =
      if Filename.is_relative target then Filename.concat (Sys.getcwd ()) target
      else target
    in
    let parent = Filename.dirname target and name = Filename.basename target in
    if not (Secure_fs.valid_component name) then
      error "init_path_invalid" "The repository path must end in one portable component."
    else if Sys.file_exists target then
      error "init_target_exists" "The initialization target already exists."
    else
      let root = runtime_root root in
      let templates =
        [ ("setup", ".agents/setup", 0o700);
          ("resume", ".agents/resume", 0o700);
          ("skill.md", ".agents/skills/managing-clamp-knowledge/SKILL.md", 0o600);
          ("AGENTS.md", "AGENTS.md", 0o600);
          ("README.md", "README.md", 0o600);
          ("gitignore", ".gitignore", 0o600) ]
      in
      let loaded =
        List.fold_left
          (fun result (source, destination, mode) ->
            Result.bind result (fun values ->
                Result.map (fun contents -> (destination, mode, contents) :: values)
                  (template root source)))
          (Ok []) templates
      in
      Result.bind loaded (fun templates ->
          let parent_descriptor =
            try Ok (Secure_fs.open_directory parent)
            with _ -> error "init_parent_invalid" "The repository parent is not a safe directory."
          in
          Result.bind parent_descriptor (fun parent_descriptor ->
              Fun.protect ~finally:(fun () -> Unix.close parent_descriptor) (fun () ->
                  let temporary =
                    Printf.sprintf ".%s.clamp-init-%s" name (random_hex ())
                  in
                  let staged = Filename.concat parent temporary in
                  try
                    mkdir staged;
                    mkdirs staged [ ".agents"; "skills"; "managing-clamp-knowledge" ];
                    mkdirs staged [ "knowledge" ];
                    List.iter
                      (fun directory -> mkdirs staged [ "knowledge"; directory ])
                      [ "facts"; "preferences"; "people"; "projects";
                        "decisions"; "journal"; "tasks" ];
                    List.iter
                      (fun (destination, mode, contents) ->
                        write_file ~mode (Filename.concat staged destination) contents)
                      templates;
                    let lock =
                      Printf.sprintf
                        "version=%s\nrevision=%s\nurl=%s\nsha256=%s\n"
                        runtime_version runtime_revision runtime_url runtime_sha256
                    in
                    write_file (Filename.concat staged ".agents/clamp-runtime.lock") lock;
                    write_file (Filename.concat staged "clamp.yaml")
                      (canonical_config source_repository);
                    write_file (Filename.concat staged "TODO.md")
                      (Local.render_todo ~now:0. []);
                    (match Bundle.validate_checked staged with
                    | Error issue -> raise (Failure issue.message)
                    | Ok validation ->
                        if List.exists Diagnostic.is_error validation.diagnostics then
                          raise (Failure "generated repository did not validate"));
                    (match git_init staged with
                    | Error issue -> raise (Failure issue.message)
                    | Ok () -> ());
                    (match git_commit staged with
                    | Error issue -> raise (Failure issue.message)
                    | Ok () -> ());
                    Secure_fs.rename_noreplace parent_descriptor temporary
                      parent_descriptor name;
                    Unix.fsync parent_descriptor;
                    Ok { path = target; source_repository; runtime_revision }
                  with
                  | Unix.Unix_error (Unix.EEXIST, _, _) ->
                      remove_owned staged;
                      error "init_target_exists" "The initialization target already exists."
                  | failure ->
                      remove_owned staged;
                      error "init_failed"
                        (match failure with
                        | Failure message -> message
                        | _ -> "The private repository could not be initialized."))))
