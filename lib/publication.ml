type error_kind =
  | Validation
  | Conflict
  | Authentication
  | Transient
  | Stale
  | Internal

type error = {
  kind : error_kind;
  code : string;
  message : string;
  published : bool;
  preserved : bool;
  preservation_pending : bool;
  cleanup_pending : bool;
  commit : string option;
  branch : string option;
  paths : string list;
  cause : string option;
  cleanup_cause : string option;
  diagnostics : Diagnostic.t list;
}

type report = {
  commit : string;
  sync : Sync.report;
}

type hooks = {
  before_push : attempt:int -> refspec:string -> unit;
  after_preservation_proven : branch:string -> commit:string -> unit;
  after_main_push : commit:string -> unit;
  before_sync : commit:string -> unit;
  now : unit -> float;
}

let default_hooks =
  { before_push = (fun ~attempt:_ ~refspec:_ -> ());
    after_preservation_proven = (fun ~branch:_ ~commit:_ -> ());
    after_main_push = (fun ~commit:_ -> ());
    before_sync = (fun ~commit:_ -> ());
    now = Unix.gettimeofday }

let maximum_git_output = 16 * 1024 * 1024
let ( let* ) = Result.bind

let failure ?commit ?branch ?cause ?cleanup_cause ?(paths = [])
    ?(diagnostics = []) ?(published = false) ?(preserved = false)
    ?(preservation_pending = false) ?(cleanup_pending = false) kind code message =
  Error
    { kind; code; message; published; preserved; preservation_pending;
      cleanup_pending; commit; branch; paths; cause; cleanup_cause; diagnostics }

let exit_class error =
  match error.kind with
  | Validation -> Exit_class.User_error
  | Conflict -> Exit_class.Conflict
  | Authentication -> Exit_class.Authentication
  | Transient -> Exit_class.Transient_external
  | Stale -> Exit_class.Stale_index
  | Internal -> Exit_class.Internal

let error_details error =
  let optional name convert = function
    | None -> []
    | Some value -> [ (name, convert value) ]
  in
  `Assoc
    ([ ("published", `Bool error.published) ]
     @ (if error.preserved then
          [ ("preserved", `Bool true);
            ("cleanup_pending", `Bool error.cleanup_pending) ]
        else [])
     @ (if error.preservation_pending then
          [ ("preservation_pending", `Bool true) ]
        else [])
     @ optional "commit" (fun value -> `String value) error.commit
     @ optional "branch" (fun value -> `String value) error.branch
     @ (if error.paths = [] then []
        else
          [ ("paths", `List (List.map (fun path -> `String path) error.paths)) ])
     @ optional "cause" (fun value -> `String value) error.cause
     @ optional "cleanup_cause" (fun value -> `String value)
         error.cleanup_cause
     @ (if error.diagnostics = [] then []
        else
          [ ( "diagnostics",
              `List (List.map Diagnostic.json error.diagnostics) ) ]))

let of_sync (error : Sync.error) =
  let kind =
    match error.kind with
    | Sync.Validation -> Validation
    | Authentication -> Authentication
    | Transient -> Transient
    | Internal -> Internal
  in
  { kind; code = error.code; message = error.message; published = false;
    preserved = false; preservation_pending = false; cleanup_pending = false;
    commit = None; branch = None; paths = []; cause = None; cleanup_cause = None;
    diagnostics = error.diagnostics }

let of_local (error : Local.error) =
  let kind =
    if Local.exit_class error = Exit_class.Internal then Internal else Validation
  in
  { kind; code = error.code; message = error.message; published = false;
    preserved = false; preservation_pending = false; cleanup_pending = false;
    commit = None; branch = None; paths = []; cause = None;
    cleanup_cause = None; diagnostics = [] }

let valid_thread_id value =
  let hyphens = [ 10; 15; 20; 25 ] in
  String.length value = 38
  && String.starts_with ~prefix:"T-" value
  &&
  let rec characters index =
    if index = String.length value then true
    else
      let character = value.[index] in
      let valid =
        if index < 2 then true
        else if List.mem index hyphens then character = '-'
        else
          match character with
          | '0' .. '9' | 'a' .. 'f' -> true
          | _ -> false
      in
      valid && characters (index + 1)
  in
  characters 0

let managed_path path =
  path = "clamp.yaml" || path = "TODO.md"
  || String.starts_with ~prefix:"knowledge/" path

let task_path path = String.starts_with ~prefix:"knowledge/tasks/" path

let nul_records output =
  output |> String.split_on_char '\000'
  |> List.filter (fun value -> value <> "")
  |> List.sort_uniq String.compare

let lines output =
  output |> String.split_on_char '\n'
  |> List.filter_map (fun value ->
         let value = String.trim value in
         if value = "" then None else Some value)

let git repo arguments maximum =
  Result.map_error of_sync (Sync.Git.run repo arguments maximum)

let git_input repo arguments input maximum =
  Result.map_error of_sync (Sync.Git.run_input repo arguments input maximum)

let git_status repo arguments maximum =
  Result.map_error of_sync (Sync.Git.run_status repo arguments maximum)

let git_paths repo arguments =
  let rec with_nul = function
    | [] -> [ "-z" ]
    | "--" :: rest -> "-z" :: "--" :: rest
    | argument :: rest -> argument :: with_nul rest
  in
  Result.map nul_records (git repo (with_nul arguments) maximum_git_output)

let resolve_object repo revision =
  let* output = git repo [ "rev-parse"; "--verify"; revision ] 128 in
  let object_id = String.trim output in
  if Sync.Git.valid_sha object_id then Ok object_id
  else failure Transient "git_target_invalid" "Git did not resolve a valid object."

let resolve_commit repo revision =
  let* output =
    git repo [ "rev-parse"; "--verify"; revision ^ "^{commit}" ] 128
  in
  let commit = String.trim output in
  if Sync.Git.valid_sha commit then Ok commit
  else failure Transient "git_target_invalid" "Git did not resolve a valid commit."

let current_head repo = resolve_commit repo "HEAD"

let tree_of repo revision =
  let* output =
    git repo [ "rev-parse"; "--verify"; revision ^ "^{tree}" ] 128
  in
  let tree = String.trim output in
  if Sync.Git.valid_sha tree then Ok tree
  else failure Internal "git_tree_invalid" "Git did not resolve a valid tree."

let rebase_in_progress repo =
  let present name =
    let* output =
      git repo
        [ "rev-parse"; "--path-format=absolute"; "--git-path"; name ]
        4096
    in
    let path = String.trim output in
    try Ok ((Unix.lstat path).st_kind = Unix.S_DIR)
    with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  in
  let* merge = present "rebase-merge" in
  if merge then Ok true else present "rebase-apply"

let state_prefix thread_id = "refs/clamp/publish/" ^ thread_id ^ "/"
let original_ref thread_id = state_prefix thread_id ^ "original"
let current_ref thread_id = state_prefix thread_id ^ "state"

type preservation_state =
  | Preservation_not_started
  | Preservation_legacy_unresolved
  | Preservation_push_pending of string
  | Preservation_proven of string

type state = {
  thread_id : string;
  original : string;
  races : int;
  conflicts : string list;
  conflict_baseline : (string * string) list;
  preservation : preservation_state;
  state_object : string;
}

type state_version = V1 | V2 | V3

let state_magic = "clamp-publish-state-v3"

let preservation_fields = function
  | Preservation_not_started -> [ "none"; "" ]
  | Preservation_legacy_unresolved -> [ "legacy_unresolved"; "" ]
  | Preservation_push_pending branch -> [ "push_pending"; branch ]
  | Preservation_proven branch -> [ "proven"; branch ]

let state_body races preservation conflicts baseline =
  String.concat "\000"
    (state_magic :: string_of_int races :: preservation_fields preservation
     @ string_of_int (List.length conflicts) :: conflicts
     @ string_of_int (List.length baseline)
     :: List.concat_map (fun (path, digest) -> [ path; digest ]) baseline
     @ [ "" ])

let rec take count values =
  if count = 0 then Some ([], values)
  else
    match values with
    | [] -> None
    | value :: rest ->
        Option.map (fun (selected, remaining) -> value :: selected, remaining)
          (take (count - 1) rest)

let parse_baseline count values =
  let rec parse remaining accumulated values =
    if remaining = 0 then Some (List.rev accumulated, values)
    else
      match values with
      | path :: digest :: rest ->
          parse (remaining - 1) ((path, digest) :: accumulated) rest
      | _ -> None
  in
  parse count [] values

let parse_state_payload version races_text preservation conflict_count_text rest =
  match int_of_string_opt races_text, int_of_string_opt conflict_count_text with
      | Some races, Some conflict_count
        when conflict_count >= 0
             && conflict_count <= Limits.max_markdown_files + 2 ->
          (match take conflict_count rest with
          | Some (conflicts, baseline_count_text :: rest) ->
              (match int_of_string_opt baseline_count_text with
              | Some baseline_count
                when baseline_count >= 0
                     && baseline_count <= Limits.max_markdown_files + 2 ->
                  (match parse_baseline baseline_count rest with
                  | Some (baseline, [ "" ])
                    when races >= 0 && races <= 3
                         && conflicts = List.sort_uniq String.compare conflicts
                         && List.for_all
                              (fun path -> managed_path path && path <> "TODO.md")
                              conflicts
                         && baseline
                            = List.sort_uniq
                                (fun (left, _) (right, _) ->
                                  String.compare left right)
                                baseline
                         && List.for_all
                              (fun (path, digest) ->
                                path <> "" && String.length digest = 64
                                && String.for_all
                                     (function
                                       | '0' .. '9' | 'a' .. 'f' -> true
                                       | _ -> false)
                                     digest)
                              baseline ->
                      Some
                        (version, races, preservation, conflicts, baseline)
                  | _ -> None)
              | _ -> None)
          | _ -> None)
      | _ -> None

let parse_state_body body =
  match String.split_on_char '\000' body with
  | "clamp-publish-state-v1" :: races :: conflict_count :: rest ->
      Option.map
        (fun (version, races, _, conflicts, baseline) ->
          let preservation =
            if conflicts = [] then Preservation_not_started
            else Preservation_legacy_unresolved
          in
          version, races, preservation, conflicts, baseline)
        (parse_state_payload V1 races Preservation_not_started conflict_count rest)
  | "clamp-publish-state-v2" :: races :: branch :: conflict_count :: rest ->
      Option.map
        (fun (version, races, preservation, conflicts, baseline) ->
          let preservation =
            if branch <> "" then preservation
            else if conflicts = [] then Preservation_not_started
            else Preservation_legacy_unresolved
          in
          version, races, preservation, conflicts, baseline)
        (parse_state_payload V2 races
           (if branch = "" then Preservation_not_started
            else Preservation_push_pending branch)
           conflict_count rest)
  | magic :: races :: status :: branch :: conflict_count :: rest
    when magic = state_magic ->
      let preservation =
        match status, branch with
        | "none", "" -> Some Preservation_not_started
        | "legacy_unresolved", "" -> Some Preservation_legacy_unresolved
        | "push_pending", branch when branch <> "" ->
            Some (Preservation_push_pending branch)
        | "proven", branch when branch <> "" ->
            Some (Preservation_proven branch)
        | _ -> None
      in
      Option.bind preservation (fun preservation ->
          parse_state_payload V3 races preservation conflict_count rest)
  | _ -> None

let publication_refs repo =
  let* output =
    git repo
      [ "for-each-ref"; "--format=%(refname)"; "refs/clamp/publish/" ]
      (1024 * 1024)
  in
  Ok (lines output)

let state_error () =
  failure Internal "publish_state_invalid"
    "The local publication state is incomplete or ambiguous."

let valid_preserved_branch thread_id branch =
  let prefix = "conflicts/" ^ thread_id ^ "/" in
  let timestamp_length = 16 in
  String.starts_with ~prefix branch
  && String.length branch = String.length prefix + timestamp_length
  &&
  let timestamp =
    String.sub branch (String.length prefix) timestamp_length
  in
  let rec valid_timestamp index =
    if index = timestamp_length then true
    else
      let character = timestamp.[index] in
      let valid =
        if index = 8 then character = 'T'
        else if index = 15 then character = 'Z'
        else character >= '0' && character <= '9'
      in
      valid && valid_timestamp (index + 1)
  in
  valid_timestamp 0

let preservation_branch = function
  | Preservation_not_started | Preservation_legacy_unresolved -> None
  | Preservation_push_pending branch | Preservation_proven branch -> Some branch

let hash_state repo races preservation conflicts baseline =
  let body = state_body races preservation conflicts baseline in
  if String.length body > maximum_git_output then state_error ()
  else
    let* output =
      git_input repo [ "hash-object"; "-w"; "--stdin" ] body 128
    in
    let object_id = String.trim output in
    if Sync.Git.valid_sha object_id then Ok object_id else state_error ()

let update_refs repo protocol =
  match git_input repo [ "update-ref"; "--stdin" ] protocol 4096 with
  | Ok _ -> Ok ()
  | Error error ->
      failure ~cause:error.code Internal "publish_state_update_failed"
        "The local publication state could not be updated atomically."

let migrate_state repo state =
  let* state_object =
    hash_state repo state.races state.preservation state.conflicts
      state.conflict_baseline
  in
  let protocol =
    String.concat "\n"
      [ "start";
        "verify " ^ original_ref state.thread_id ^ " " ^ state.original;
        "update " ^ current_ref state.thread_id ^ " " ^ state_object ^ " "
        ^ state.state_object;
        "prepare"; "commit"; "" ]
  in
  let* () = update_refs repo protocol in
  Ok { state with state_object }

let load_state repo thread_id =
  let* refs = publication_refs repo in
  if refs = [] then Ok None
  else
    let prefix = state_prefix thread_id in
    if List.exists (fun reference -> not (String.starts_with ~prefix reference)) refs
    then
      failure Validation "publish_thread_mismatch"
        "A publication is already active for another Amp thread."
    else
      let original_reference = original_ref thread_id
      and state_reference = current_ref thread_id in
      if List.sort String.compare refs
         <> List.sort String.compare [ original_reference; state_reference ]
      then state_error ()
      else
        let* original = resolve_commit repo original_reference in
        let* state_object = resolve_object repo state_reference in
        let* kind = git repo [ "cat-file"; "-t"; state_object ] 32 in
        if String.trim kind <> "blob" then state_error ()
        else
          let* body =
            git repo [ "cat-file"; "blob"; state_object ] maximum_git_output
          in
          match parse_state_body body with
          | None -> state_error ()
          | Some (version, races, preservation, conflicts, conflict_baseline)
            when Option.for_all
                   (valid_preserved_branch thread_id)
                   (preservation_branch preservation) ->
              let state =
                { thread_id; original; races; conflicts; conflict_baseline;
                  preservation; state_object }
              in
              Result.map (fun state -> Some state)
                (match version with V3 -> Ok state | V1 | V2 -> migrate_state repo state)
          | Some _ -> state_error ()

let create_state repo thread_id original =
  let* state_object = hash_state repo 0 Preservation_not_started [] [] in
  let protocol =
    String.concat "\n"
      [ "start";
        "create " ^ original_ref thread_id ^ " " ^ original;
        "create " ^ current_ref thread_id ^ " " ^ state_object;
        "prepare"; "commit"; "" ]
  in
  let* () = update_refs repo protocol in
  Ok
    { thread_id; original; races = 0; conflicts = [];
      conflict_baseline = []; preservation = Preservation_not_started;
      state_object }

let update_state repo state ~races ~conflicts ~baseline =
  let conflicts = List.sort_uniq String.compare conflicts in
  let baseline =
    List.sort_uniq
      (fun (left, _) (right, _) -> String.compare left right) baseline
  in
  let* state_object =
    hash_state repo races state.preservation conflicts baseline
  in
  let protocol =
    String.concat "\n"
      [ "start";
        "verify " ^ original_ref state.thread_id ^ " " ^ state.original;
        "update " ^ current_ref state.thread_id ^ " " ^ state_object ^ " "
        ^ state.state_object;
        "prepare"; "commit"; "" ]
  in
  let* () = update_refs repo protocol in
  Ok { state with races; conflicts; conflict_baseline = baseline; state_object }

let update_preservation repo state preservation =
  let valid_transition =
    match state.preservation, preservation with
    | (Preservation_not_started | Preservation_legacy_unresolved),
      Preservation_push_pending _ ->
        true
    | Preservation_push_pending pending, Preservation_proven proven ->
        pending = proven
    | _ -> false
  in
  let valid_branch =
    Option.exists (valid_preserved_branch state.thread_id)
      (preservation_branch preservation)
  in
  if not valid_transition
     || not valid_branch
  then state_error ()
  else
    let* state_object =
      hash_state repo state.races preservation state.conflicts
        state.conflict_baseline
    in
    let protocol =
      String.concat "\n"
        [ "start";
          "verify " ^ original_ref state.thread_id ^ " " ^ state.original;
          "update " ^ current_ref state.thread_id ^ " " ^ state_object ^ " "
          ^ state.state_object;
          "prepare"; "commit"; "" ]
    in
    let* () = update_refs repo protocol in
    Ok { state with preservation; state_object }

let record_preservation_pending repo state branch =
  update_preservation repo state (Preservation_push_pending branch)

let record_preservation_proven repo state branch =
  update_preservation repo state (Preservation_proven branch)

let cleanup_state repo state =
  let protocol =
    String.concat "\n"
      [ "start";
        "delete " ^ original_ref state.thread_id ^ " " ^ state.original;
        "delete " ^ current_ref state.thread_id ^ " " ^ state.state_object;
        "prepare"; "commit"; "" ]
  in
  update_refs repo protocol

let load_source repo =
  let path = Filename.concat repo "clamp.yaml" in
  match Config.load_source_repository path with
  | Error "source_repository_missing" ->
      failure Validation "source_repository_missing"
        "clamp.yaml must configure source_repository."
  | Error _ ->
      failure Validation "source_repository_invalid"
        "clamp.yaml source_repository is invalid."
  | Ok source ->
      (match Config.load path with
      | Ok () -> Ok source
      | Error _ ->
          failure Validation "config_invalid"
            "clamp.yaml is invalid or incompatible.")

let local_config repo key =
  let* result =
    git_status repo [ "config"; "--local"; "--get-all"; key ] 8192
  in
  if not result.succeeded then Ok None
  else
    match lines result.output with
    | [ value ] -> Ok (Some value)
    | _ ->
        failure Validation "git_config_invalid"
          "Repository Git configuration is invalid."

let local_config_records repo =
  let* output =
    git repo [ "config"; "--local"; "--null"; "--list" ] (1024 * 1024)
  in
  let parse record =
    match String.index_opt record '\n' with
    | None -> None
    | Some separator ->
        let key = String.sub record 0 separator |> String.lowercase_ascii in
        let value =
          String.sub record (separator + 1)
            (String.length record - separator - 1)
        in
        Some (key, String.lowercase_ascii value)
  in
  let records = String.split_on_char '\000' output in
  if List.exists (fun record -> record <> "" && Option.is_none (parse record)) records
  then
    failure Validation "git_config_invalid"
      "Repository Git configuration is invalid."
  else Ok (List.filter_map parse records)

let reject_transform_config repo =
  let* records = local_config_records repo in
  let unsafe (key, value) =
    String.starts_with ~prefix:"filter." key
    || String.starts_with ~prefix:"merge." key
    || key = "core.attributesfile"
    || key = "core.eol"
    || key = "core.checkroundtripencoding"
    || key = "core.fsmonitor"
    || (key = "core.autocrlf" && value <> "false")
    || (key = "core.safecrlf" && value <> "false")
  in
  if List.exists unsafe records then
    failure Validation "publish_transform_config_unsafe"
      "Repository-local Git staging or merge transformation configuration is unsafe for publication."
  else Ok ()

let safe_identity_value value =
  value <> "" && not (String.contains value '\n')
  && not (String.contains value '\r') && not (String.contains value '\000')

let safe_author_name value =
  safe_identity_value value && not (String.contains value '<')
  && not (String.contains value '>')

let safe_author_email value =
  safe_identity_value value && String.contains value '@'
  && not (String.contains value '<') && not (String.contains value '>')
  && not (String.exists (fun character -> Char.code character <= 0x20) value)

let local_fixture_remote remote =
  (not (Filename.is_relative remote))
  || String.starts_with ~prefix:"file:///" remote

let repository_preflight ?(allow_detached_rebase = false) repo source =
  let* () = reject_transform_config repo in
  let* branch =
    git_status repo [ "symbolic-ref"; "-q"; "HEAD" ] 1024
  in
  if (not branch.succeeded && not allow_detached_rebase)
     || (branch.succeeded
         && String.trim branch.output <> "refs/heads/main")
  then
    failure Validation "publish_ref_invalid"
      "Publication requires the attached refs/heads/main branch."
  else
    let* branch_remote = local_config repo "branch.main.remote" in
    let* branch_merge = local_config repo "branch.main.merge" in
    if branch_remote <> Some "origin" || branch_merge <> Some "refs/heads/main"
    then
      failure Validation "publish_ref_invalid"
        "Local main must track origin/main."
    else
      let* name = local_config repo "user.name" in
      let* email = local_config repo "user.email" in
      if not (Option.exists safe_author_name name)
         || not (Option.exists safe_author_email email)
      then
        failure Validation "publish_author_missing"
          "Repository-local Git user.name and user.email are required."
      else
        let* fetch_urls, push_urls =
          Result.map_error of_sync (Sync.Git.origin_urls repo)
        in
        match fetch_urls, push_urls with
        | [ remote ], [ push_remote ] when remote = push_remote ->
            if Sync.Git.amp_remote source remote
               || (String.starts_with ~prefix:"local.test/" source
                   && local_fixture_remote remote)
            then Ok ()
            else
              failure Validation "publish_remote_invalid"
                "The origin URL does not match the configured repository identity."
        | _ ->
            failure Validation "publish_remote_invalid"
              "The origin fetch and push remote must be one identical URL."

let working_paths repo =
  let* staged = git_paths repo [ "diff"; "--cached"; "--name-only" ] in
  let* unstaged = git_paths repo [ "diff"; "--name-only" ] in
  let* untracked =
    git_paths repo [ "ls-files"; "--others"; "--exclude-standard" ]
  in
  Ok (List.sort_uniq String.compare (staged @ unstaged @ untracked))

let ensure_managed_worktree repo =
  let* paths = working_paths repo in
  let unrelated = List.filter (fun path -> not (managed_path path)) paths in
  if unrelated = [] then Ok paths
  else
    failure ~paths:unrelated Validation "publish_unrelated_changes"
      "Publication refuses unrelated staged, worktree, or untracked changes."

let prepare_todo root changed =
  let tasks_changed = List.exists task_path changed in
  match Local.todo_drift_at root with
  | Error issue -> Error (of_local issue)
  | Ok drift when drift || tasks_changed ->
      Result.map_error of_local (Local.todo_at root) |> Result.map (fun _ -> ())
  | Ok _ -> Ok ()

let unpublished_preflight repo =
  let* head = current_head repo in
  let* tracked = resolve_commit repo "refs/remotes/origin/main" in
  let* ancestor =
    git_status repo [ "merge-base"; "--is-ancestor"; head; tracked ] 1024
  in
  if ancestor.succeeded then Ok ()
  else
    failure Validation "publish_unpublished_commits"
      "Publication refuses pre-existing unpublished commits."

type index_entry = {
  index_mode : string;
  index_object : string;
  index_stage : int;
  index_path : string;
}

let parse_index_entries output =
  let parse record =
    match String.index_opt record '\t' with
    | None -> None
    | Some separator ->
        let header =
          String.sub record 0 separator |> String.split_on_char ' '
        in
        let path =
          String.sub record (separator + 1)
            (String.length record - separator - 1)
        in
        (match header with
        | [ mode; object_id; stage ]
          when Sync.Git.valid_sha object_id ->
            Option.map
              (fun stage ->
                { index_mode = mode; index_object = object_id;
                  index_stage = stage; index_path = path })
              (int_of_string_opt stage)
        | _ -> None)
  in
  let records = String.split_on_char '\000' output in
  if List.exists (fun record -> record <> "" && Option.is_none (parse record)) records
  then
    failure Internal "git_index_invalid" "Git returned an invalid index entry."
  else Ok (List.filter_map parse records)

let index_entries repo =
  let* output =
    git repo
      [ "ls-files"; "--stage"; "-z"; "--";
        "clamp.yaml"; "TODO.md"; "knowledge" ]
      maximum_git_output
  in
  parse_index_entries output

let all_index_entries repo =
  let* output =
    git repo [ "ls-files"; "--stage"; "-z" ] maximum_git_output
  in
  parse_index_entries output

let existing_mode entries path =
  entries
  |> List.find_opt (fun entry -> entry.index_path = path)
  |> Option.map (fun entry -> entry.index_mode)

let safe_managed_mode mode = mode = "100644" || mode = "100755"

let hash_worktree_file repo path mode =
  if not (safe_managed_mode mode) then
    failure Validation "publish_managed_not_regular"
      "Managed publication files must be regular files."
  else
    let absolute = Filename.concat repo path in
    try
      let metadata = Unix.lstat absolute in
      if metadata.st_kind <> Unix.S_REG then
        failure ~paths:[ path ] Validation "publish_managed_not_regular"
          "Managed publication files must be regular files."
      else
        let* output =
          git repo
            [ "hash-object"; "-w"; "--no-filters"; "--"; absolute ] 128
        in
        let object_id = String.trim output in
        if Sync.Git.valid_sha object_id then Ok (Some (mode, object_id))
        else
          failure Internal "git_object_invalid"
            "Git did not create a valid managed snapshot."
    with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None

let stage_exact_managed repo =
  let* ignored =
    git_paths repo
      [ "ls-files"; "--others"; "--ignored"; "--exclude-standard";
        "--"; "clamp.yaml"; "TODO.md"; "knowledge" ]
  in
  if ignored <> [] then
    failure ~paths:ignored Validation "publish_managed_ignored"
      "Ignored managed files cannot be published safely."
  else
    let* entries = index_entries repo in
    let* listed =
      git_paths repo
        [ "ls-files"; "--cached"; "--others"; "--exclude-standard";
          "--"; "clamp.yaml"; "TODO.md"; "knowledge" ]
    in
    let paths =
      List.sort_uniq String.compare
        (listed @ List.map (fun entry -> entry.index_path) entries)
    in
    let snapshots = Hashtbl.create (List.length paths) in
    let rec snapshot = function
      | [] -> Ok ()
      | path :: rest ->
          let mode =
            match existing_mode entries path with
            | Some mode -> mode
            | None ->
                (try
                   let metadata = Unix.lstat (Filename.concat repo path) in
                   if metadata.st_perm land 0o111 = 0 then "100644" else "100755"
                 with Unix.Unix_error _ -> "100644")
          in
          let* value = hash_worktree_file repo path mode in
          Option.iter (fun value -> Hashtbl.replace snapshots path value) value;
          snapshot rest
    in
    let* () = snapshot paths in
    let zero = String.make 40 '0' in
    let input = Buffer.create (List.length paths * 96) in
    List.iter
      (fun path ->
        match Hashtbl.find_opt snapshots path with
        | Some (mode, object_id) ->
            Buffer.add_string input mode;
            Buffer.add_char input ' ';
            Buffer.add_string input object_id;
            Buffer.add_char input '\t';
            Buffer.add_string input path;
            Buffer.add_char input '\000'
        | None ->
            Buffer.add_string input "0 ";
            Buffer.add_string input zero;
            Buffer.add_char input '\t';
            Buffer.add_string input path;
            Buffer.add_char input '\000')
      paths;
    let* _ =
      git_input repo [ "update-index"; "-z"; "--index-info" ]
        (Buffer.contents input) maximum_git_output
    in
    let* actual = index_entries repo in
    let actual_managed =
      List.filter (fun entry -> managed_path entry.index_path) actual
    in
    if List.exists (fun entry -> entry.index_stage <> 0) actual_managed
       || List.length actual_managed <> Hashtbl.length snapshots
       || List.exists
            (fun entry ->
              match Hashtbl.find_opt snapshots entry.index_path with
              | Some (mode, object_id) ->
                  mode <> entry.index_mode || object_id <> entry.index_object
              | None -> true)
            actual_managed
    then
      failure Internal "publish_snapshot_mismatch"
        "The staged managed tree does not exactly match the validated snapshots."
    else Ok ()

let path_fingerprint repo entries path =
  let indexed =
    entries
    |> List.filter (fun entry -> entry.index_path = path)
    |> List.sort (fun left right ->
           let by_stage = Int.compare left.index_stage right.index_stage in
           if by_stage <> 0 then by_stage
           else String.compare left.index_object right.index_object)
  in
  let index_text =
    indexed
    |> List.map (fun entry ->
           Printf.sprintf "%s %s %d" entry.index_mode entry.index_object
             entry.index_stage)
    |> String.concat "\n"
  in
  let absolute = Filename.concat repo path in
  let* worktree =
    try
      let metadata = Unix.lstat absolute in
      if metadata.st_kind <> Unix.S_REG then
        failure ~paths:[ path ] Validation "publish_unrelated_changes"
          "Publication conflict handling refuses non-regular owner changes."
      else
        let* output =
          git repo
            [ "hash-object"; "-w"; "--no-filters"; "--"; absolute ] 128
        in
        let object_id = String.trim output in
        if Sync.Git.valid_sha object_id then Ok object_id
        else
          failure Internal "git_object_invalid"
            "Git did not create a valid conflict-state snapshot."
    with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok "absent"
  in
  Ok
    Digestif.SHA256.(to_hex (digest_string (index_text ^ "\000" ^ worktree)))

let capture_conflict_baseline repo =
  let* paths = working_paths repo in
  let* entries = all_index_entries repo in
  let rec capture accumulated = function
    | [] -> Ok (List.rev accumulated)
    | path :: rest ->
        let* digest = path_fingerprint repo entries path in
        capture ((path, digest) :: accumulated) rest
  in
  capture [] paths

let ensure_conflict_worktree repo state =
  let allowed path = path = "TODO.md" || List.mem path state.conflicts in
  let* current_paths = working_paths repo in
  let* entries = all_index_entries repo in
  let baseline_paths = List.map fst state.conflict_baseline in
  let candidates =
    List.sort_uniq String.compare (current_paths @ baseline_paths)
    |> List.filter (fun path -> not (allowed path))
  in
  let rec changed accumulated = function
    | [] -> Ok (List.rev accumulated)
    | path :: rest ->
        (match List.assoc_opt path state.conflict_baseline with
        | None -> changed (path :: accumulated) rest
        | Some _ when not (List.mem path current_paths) ->
            changed (path :: accumulated) rest
        | Some expected ->
            let* actual = path_fingerprint repo entries path in
            changed
              (if actual = expected then accumulated else path :: accumulated)
              rest)
  in
  let* changed = changed [] candidates in
  if changed = [] then Ok current_paths
  else
    failure ~paths:changed Validation "publish_unrelated_changes"
      "Publication refuses owner changes outside the recorded conflict-resolution paths."

type tree_entry = {
  tree_mode : string;
  tree_object : string;
  tree_path : string;
}

let parse_tree_entries output =
  let parse record =
    match String.index_opt record '\t' with
    | None -> None
    | Some separator ->
        let header =
          String.sub record 0 separator |> String.split_on_char ' '
        in
        let path =
          String.sub record (separator + 1)
            (String.length record - separator - 1)
        in
        (match header with
        | [ mode; "blob"; object_id ] when Sync.Git.valid_sha object_id ->
            Some { tree_mode = mode; tree_object = object_id; tree_path = path }
        | _ -> None)
  in
  let records = String.split_on_char '\000' output in
  if List.exists (fun record -> record <> "" && Option.is_none (parse record)) records
  then
    failure Validation "publish_validation_failed"
      "The exact managed Git tree contains an unsupported entry."
  else Ok (List.filter_map parse records)

let safe_relative_path path =
  Filename.is_relative path
  && path <> ""
  && List.for_all
       (fun component -> component <> "" && component <> "." && component <> "..")
       (String.split_on_char '/' path)

let rec remove_tree path =
  try
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | _ -> Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let rec make_private_directories path root =
  if path <> root && path <> Filename.dirname path then begin
    make_private_directories (Filename.dirname path) root;
    if not (Sys.file_exists path) then Unix.mkdir path 0o700
  end

let write_private path contents =
  let descriptor =
    Unix.openfile path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600
  in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let bytes = Bytes.unsafe_of_string contents in
      let rec write offset =
        if offset < Bytes.length bytes then
          match Unix.write descriptor bytes offset (Bytes.length bytes - offset) with
          | 0 -> raise End_of_file
          | count -> write (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> write offset
      in
      write 0)

let validate_exact_tree repo treeish =
  let* output =
    git repo
      [ "ls-tree"; "-r"; "-z"; "--full-tree"; treeish; "--";
        "clamp.yaml"; "TODO.md"; "knowledge" ]
      maximum_git_output
  in
  let* entries = parse_tree_entries output in
  if List.exists
       (fun entry ->
         not (managed_path entry.tree_path)
         || not (safe_relative_path entry.tree_path)
         || not (safe_managed_mode entry.tree_mode))
       entries
  then
    failure Validation "publish_validation_failed"
      "The exact managed Git tree contains an unsupported path or entry."
  else
    let temporary = Filename.temp_file "clamp-publish-tree-" "" in
    Sys.remove temporary;
    Unix.mkdir temporary 0o700;
    Fun.protect
      ~finally:(fun () -> remove_tree temporary)
      (fun () ->
        let rec materialize = function
          | [] -> Ok ()
          | entry :: rest ->
              let path = Filename.concat temporary entry.tree_path in
              (try make_private_directories (Filename.dirname path) temporary
               with Unix.Unix_error _ -> ());
              let* contents =
                git repo [ "cat-file"; "blob"; entry.tree_object ]
                  maximum_git_output
              in
              let* () =
                try write_private path contents; Ok ()
                with Unix.Unix_error _ | Sys_error _ ->
                  failure Internal "publish_validation_materialization_failed"
                    "The exact managed Git tree could not be validated safely."
              in
              materialize rest
        in
        let* () = materialize entries in
        match Bundle.validate_checked temporary with
        | Error issue -> Error (of_local issue)
        | Ok checked ->
            let errors = List.filter Diagnostic.is_error checked.diagnostics in
            if errors = [] then Ok checked.diagnostics
            else
              failure ~diagnostics:checked.diagnostics Validation
                "publish_validation_failed"
                "Managed publication validation failed.")

let staged_paths repo =
  git_paths repo [ "diff"; "--cached"; "--name-only" ]

let prepare_candidate_index repo root =
  let* changed = ensure_managed_worktree repo in
  let* () = prepare_todo root changed in
  let* _ = ensure_managed_worktree repo in
  let* () = stage_exact_managed repo in
  let* staged = staged_paths repo in
  if List.exists (fun path -> not (managed_path path)) staged then
    failure ~paths:(List.filter (fun path -> not (managed_path path)) staged)
      Validation "publish_unrelated_changes"
      "Publication refuses unrelated staged changes."
  else
    let* tree = git repo [ "write-tree" ] 128 in
    let tree = String.trim tree in
    if not (Sync.Git.valid_sha tree) then
      failure Internal "git_tree_invalid" "Git did not write a valid tree."
    else
      let* _ = validate_exact_tree repo tree in
      Ok staged

let commit_arguments action =
  [ "-c"; "core.hooksPath=/dev/null"; "commit"; "--quiet";
    "--no-verify"; "--no-gpg-sign" ] @ action

let commit_managed repo root =
  let* staged = prepare_candidate_index repo root in
  if staged = [] then
    failure Validation "publish_no_changes"
      "There are no managed changes to publish."
  else
    let* () =
      git repo
        (commit_arguments [ "-m"; "Clamp knowledge update" ])
        maximum_git_output
      |> Result.map (fun _ -> ())
    in
    let* commit = current_head repo in
    let* _ = validate_exact_tree repo commit in
    Ok commit

let finalize_rebased_commit repo root =
  let* staged = prepare_candidate_index repo root in
  let* () =
    if staged = [] then Ok ()
    else
      git repo (commit_arguments [ "--amend"; "--no-edit" ]) maximum_git_output
      |> Result.map (fun _ -> ())
  in
  let* commit = current_head repo in
  let* _ = validate_exact_tree repo commit in
  Ok ()

let unmerged_paths repo =
  git_paths repo [ "diff"; "--name-only"; "--diff-filter=U" ]

let conflict_error state =
  failure ~commit:state.original ~paths:state.conflicts Conflict
    "publish_conflict"
    "Managed content has a semantic rebase conflict; resolve it and retry, or preserve it explicitly."

let record_conflicts repo state paths =
  let genuine =
    paths |> List.filter (fun path -> path <> "TODO.md")
    |> List.sort_uniq String.compare
  in
  if genuine = [] then Ok state
  else if state.conflicts <> [] then Ok state
  else
    let* baseline = capture_conflict_baseline repo in
    update_state repo state ~races:state.races ~conflicts:genuine ~baseline

let continue_rebase repo state root ~count_clean_race =
  let* initial = unmerged_paths repo in
  let genuine = List.filter (( <> ) "TODO.md") initial in
  let* state = record_conflicts repo state genuine in
  let* _ =
    if state.conflicts = [] then ensure_managed_worktree repo
    else ensure_conflict_worktree repo state
  in
  if genuine <> [] then
    conflict_error state
  else
    let* () =
      if List.mem "TODO.md" initial then
        Result.map_error of_local (Local.todo_at root) |> Result.map (fun _ -> ())
      else Ok ()
    in
    let* _ = prepare_candidate_index repo root in
    let* remaining = unmerged_paths repo in
    let genuine = List.filter (( <> ) "TODO.md") remaining in
    if genuine <> [] then
      let* state = record_conflicts repo state genuine in
      conflict_error state
    else if remaining <> [] then
      failure Internal "publish_todo_conflict_unresolved"
        "The generated TODO conflict could not be resolved safely."
    else
      let* result =
        git_status repo
          [ "-c"; "core.hooksPath=/dev/null";
            "-c"; "core.editor=true"; "rebase"; "--continue" ]
          maximum_git_output
      in
      if result.succeeded then
        let* () = finalize_rebased_commit repo root in
        let* state =
          if state.conflicts = [] then Ok state
          else
            update_state repo state ~races:state.races ~conflicts:[]
              ~baseline:[]
        in
        if count_clean_race then
          update_state repo state ~races:(state.races + 1) ~conflicts:[]
            ~baseline:[]
        else Ok state
      else
        let* paths = unmerged_paths repo in
        let genuine = List.filter (( <> ) "TODO.md") paths in
        if genuine = [] then
          failure Transient "publish_rebase_failed" "Git rebase failed."
        else
          let* state = record_conflicts repo state genuine in
          conflict_error state

let rebase_onto_origin repo state root ~count_clean_race =
  let* result =
    git_status repo
      [ "-c"; "core.hooksPath=/dev/null";
        "-c"; "core.editor=true"; "rebase";
        "refs/remotes/origin/main" ]
      maximum_git_output
  in
  if result.succeeded then
    let* () = finalize_rebased_commit repo root in
    if count_clean_race then
      update_state repo state ~races:(state.races + 1) ~conflicts:[]
        ~baseline:[]
    else Ok state
  else continue_rebase repo state root ~count_clean_race

let fetch repo source =
  Result.map_error of_sync
    (Sync.Git.fetch_origin_main ~force:false repo source maximum_git_output)

let timestamp now =
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min
    tm.tm_sec

let push_ref repo source refspec =
  Result.map_error of_sync
    (Sync.Git.push_origin repo source refspec maximum_git_output)

let remote_branch_status repo source branch =
  Result.map_error of_sync
    (Sync.Git.remote_branch_status repo source branch maximum_git_output)

let detach_publication repo commit =
  git repo [ "switch"; "--quiet"; "--detach"; commit ] maximum_git_output
  |> Result.map (fun _ -> ())

let attach_published_main repo state commit =
  let* main = resolve_commit repo "refs/heads/main" in
  let* () =
    if main = commit then Ok ()
    else if main = state.original then
      git repo
        [ "update-ref"; "refs/heads/main"; commit; state.original ] 1024
      |> Result.map (fun _ -> ())
    else
      failure Internal "publish_local_main_changed"
        "Git publication succeeded, but local main changed unexpectedly."
  in
  let* () =
    git repo [ "switch"; "--quiet"; "main" ] maximum_git_output
    |> Result.map (fun _ -> ())
  in
  let* head = current_head repo in
  if head = commit then Ok ()
  else
    failure Internal "publish_local_main_changed"
      "Git publication succeeded, but local main could not be restored safely."

let verify_abort repo state =
  let* head = current_head repo in
  let* index_tree = git repo [ "write-tree" ] 128 in
  let* original_tree = tree_of repo state.original in
  let* branch = git_status repo [ "symbolic-ref"; "-q"; "HEAD" ] 1024 in
  let* paths = working_paths repo in
  if head = state.original && String.trim index_tree = original_tree
     && branch.succeeded && String.trim branch.output = "refs/heads/main"
     && paths = []
  then Ok ()
  else
    failure Internal "publish_rebase_abort_failed"
      "The conflicted rebase did not restore the original publication state."

let post_abort_failure ?cause state code message =
  failure ~commit:state.original ~paths:state.conflicts ?cause Validation code
    message

let verify_post_abort_state repo state =
  let baseline_paths = List.map fst state.conflict_baseline in
  let baseline_matches =
    state.conflicts <> []
    && List.for_all (fun path -> List.mem path baseline_paths) state.conflicts
    && List.for_all
         (fun path -> path = "TODO.md" || List.mem path state.conflicts)
         baseline_paths
  in
  if not baseline_matches then
    post_abort_failure ~cause:"conflict_baseline_mismatch" state
      "publish_conflict_post_abort_unverified"
      "The retained conflict state cannot be proven safe for post-abort preservation."
  else
    let observations =
      let* rebasing = rebase_in_progress repo in
      let* original = resolve_commit repo state.original in
      let* head = current_head repo in
      let* main = resolve_commit repo "refs/heads/main" in
      let* index_tree = git repo [ "write-tree" ] 128 in
      let* original_tree = tree_of repo state.original in
      let* branch = git_status repo [ "symbolic-ref"; "-q"; "HEAD" ] 1024 in
      let* paths = working_paths repo in
      Ok
        (rebasing, original, head, main, String.trim index_tree, original_tree,
         branch, paths)
    in
    match observations with
    | Error observed ->
        post_abort_failure ~cause:observed.code state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (true, _, _, _, _, _, _, _) ->
        post_abort_failure ~cause:"rebase_in_progress" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, original, _, _, _, _, _, _) when original <> state.original ->
        post_abort_failure ~cause:"original_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, _, head, _, _, _, _, _) when head <> state.original ->
        post_abort_failure ~cause:"head_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, _, _, main, _, _, _, _) when main <> state.original ->
        post_abort_failure ~cause:"main_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, _, _, _, index_tree, original_tree, _, _)
      when index_tree <> original_tree ->
        post_abort_failure ~cause:"index_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, _, _, _, _, _, branch, _)
      when not branch.succeeded
           || String.trim branch.output <> "refs/heads/main" ->
        post_abort_failure ~cause:"branch_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok (_, _, _, _, _, _, _, _ :: _) ->
        post_abort_failure ~cause:"worktree_changed" state
          "publish_conflict_post_abort_unverified"
          "The retained conflict state cannot be proven safe for post-abort preservation."
    | Ok _ -> Ok ()

let pending_preservation_failure ?cause state branch kind code message =
  failure ~commit:state.original ~branch ~paths:state.conflicts
    ~preservation_pending:true ?cause kind code message

let proven_preservation_failure ?cause state branch kind code message =
  failure ~commit:state.original ~branch ~paths:state.conflicts
    ~preserved:true ~cleanup_pending:true ?cause kind code message

let preserved_outcome repo state branch =
  match state.preservation with
  | Preservation_proven proven when proven = branch ->
      (match cleanup_state repo state with
      | Ok () ->
          failure ~commit:state.original ~branch ~paths:state.conflicts
            ~preserved:true Conflict "publish_conflict_preserved"
            "The original knowledge commit was preserved for semantic conflict resolution."
      | Error cleanup ->
          failure ~commit:state.original ~branch ~paths:state.conflicts
            ~preserved:true ~cleanup_pending:true ~cleanup_cause:cleanup.code
            Conflict "publish_conflict_preserved_cleanup_pending"
            "The original knowledge commit was preserved, but local publication-state cleanup remains pending.")
  | _ -> state_error ()

let mark_preservation_proven repo hooks state branch =
  match record_preservation_proven repo state branch with
  | Ok state ->
      hooks.after_preservation_proven ~branch ~commit:state.original;
      preserved_outcome repo state branch
  | Error update ->
      pending_preservation_failure ~cause:update.code state branch Internal
        "publish_conflict_preservation_proof_pending"
        "The conflict branch was pushed, but local proof-state recording must be retried."

let push_pending_preservation repo source hooks state branch =
  let refspec = state.original ^ ":refs/heads/" ^ branch in
  hooks.before_push ~attempt:0 ~refspec;
  match push_ref repo source refspec with
  | Error push ->
      pending_preservation_failure ~cause:push.code state branch push.kind
        "publish_conflict_preservation_failed"
        "The conflict commit could not be preserved on the remote; the exact pending branch must be verified before retry."
  | Ok pushed when not pushed.succeeded ->
      pending_preservation_failure state branch Transient
        "publish_conflict_preservation_failed"
        "The conflict commit could not be preserved on the remote; the exact pending branch must be verified before retry."
  | Ok _ -> mark_preservation_proven repo hooks state branch

let allocate_pending_preservation repo source hooks state =
  let branch =
    "conflicts/" ^ state.thread_id ^ "/" ^ timestamp (hooks.now ())
  in
  match record_preservation_pending repo state branch with
  | Error allocation ->
      failure ~commit:state.original ~paths:state.conflicts
        ~cause:allocation.code Internal
        "publish_conflict_preservation_allocation_failed"
        "The conflict branch identity could not be recorded atomically; local publication state was retained."
  | Ok state -> push_pending_preservation repo source hooks state branch

let recover_post_abort_conflict repo source hooks state =
  let* () = verify_post_abort_state repo state in
  allocate_pending_preservation repo source hooks state

let retry_pending_preservation repo source hooks state branch =
  match remote_branch_status repo source branch with
  | Error remote ->
      pending_preservation_failure ~cause:remote.code state branch remote.kind
        "publish_conflict_preservation_verification_failed"
        "The pending conflict branch could not be verified; local publication state was retained."
  | Ok None -> push_pending_preservation repo source hooks state branch
  | Ok (Some commit) when commit = state.original ->
      mark_preservation_proven repo hooks state branch
  | Ok (Some _) ->
      pending_preservation_failure state branch Internal
        "publish_conflict_preservation_changed"
        "The pending conflict branch identifies another commit; local publication state was retained."

let retry_proven_cleanup repo source state branch =
  match remote_branch_status repo source branch with
  | Error remote ->
      proven_preservation_failure ~cause:remote.code state branch remote.kind
        "publish_conflict_preservation_verification_failed"
        "The proven conflict branch could not be reverified; local publication state was retained."
  | Ok (Some commit) when commit = state.original ->
      preserved_outcome repo state branch
  | Ok None | Ok (Some _) ->
      proven_preservation_failure state branch Internal
        "publish_conflict_preservation_changed"
        "The proven conflict branch no longer identifies the original commit; local publication state was retained."

let preserve_conflict repo source hooks state =
  if state.conflicts = [] then
    failure Validation "publish_conflict_not_genuine"
      "Only a genuine managed-content conflict may be preserved."
  else
    let* _ = ensure_conflict_worktree repo state in
    let* aborted =
      git_status repo
        [ "-c"; "core.hooksPath=/dev/null"; "rebase"; "--abort" ]
        maximum_git_output
    in
    if not aborted.succeeded then
      failure Internal "publish_rebase_abort_failed"
        "The conflicted rebase could not be aborted safely."
    else
      let* () =
        git repo [ "switch"; "--quiet"; "main" ] maximum_git_output
        |> Result.map (fun _ -> ())
      in
      let* () = verify_abort repo state in
      allocate_pending_preservation repo source hooks state

type git_success = {
  pushed_commit : string;
  cleanup_error : error option;
}

let published_success repo state commit =
  match attach_published_main repo state commit with
  | Error cleanup ->
      Ok { pushed_commit = commit; cleanup_error = Some cleanup }
  | Ok () ->
      (match cleanup_state repo state with
      | Ok () -> Ok { pushed_commit = commit; cleanup_error = None }
      | Error cleanup ->
          Ok { pushed_commit = commit; cleanup_error = Some cleanup })

let rec publish_attempts repo source hooks root state =
  let* head = current_head repo in
  let* _ = validate_exact_tree repo head in
  let* remote_before = resolve_commit repo "refs/remotes/origin/main" in
  let* already_remote =
    git_status repo
      [ "merge-base"; "--is-ancestor"; head;
        "refs/remotes/origin/main" ] 1024
  in
  if already_remote.succeeded then published_success repo state head
  else if state.races >= 3 then
    let branch =
      "recovery/" ^ state.thread_id ^ "/" ^ timestamp (hooks.now ())
    in
    let refspec = head ^ ":refs/heads/" ^ branch in
    hooks.before_push ~attempt:4 ~refspec;
    let* pushed = push_ref repo source refspec in
    if not pushed.succeeded then
      failure Transient "publish_recovery_failed"
        "The race-exhausted commit could not be preserved on the remote."
    else
      (match cleanup_state repo state with
      | Ok () ->
          failure ~commit:head ~branch Transient "publish_race_exhausted"
            "Three clean publication races were exhausted; the latest rebased commit was preserved on a recovery branch."
      | Error cleanup ->
          failure ~commit:head ~branch ~cause:cleanup.code Transient
            "publish_race_exhausted"
            "Three clean publication races were exhausted and the latest rebased commit was preserved, but local publication-state cleanup must be retried.")
  else
    let attempt = state.races + 1 in
    let refspec = head ^ ":refs/heads/main" in
    hooks.before_push ~attempt ~refspec;
    let* pushed = push_ref repo source refspec in
    if pushed.succeeded then begin
      hooks.after_main_push ~commit:head;
      published_success repo state head
    end
    else
      let* () = fetch repo source in
      let* remote_after = resolve_commit repo "refs/remotes/origin/main" in
      if remote_after = remote_before then
        if String.starts_with ~prefix:"ampcode.com/" source then
          failure Authentication "git_auth_failed"
            "Authenticated Git publication failed."
        else failure Transient "publish_push_failed" "Git publication failed."
      else
        let* state =
          rebase_onto_origin repo state root ~count_clean_race:true
        in
        publish_attempts repo source hooks root state

let resume repo source hooks root state preserve =
  let* rebasing = rebase_in_progress repo in
  if preserve then
    match state.preservation, rebasing with
    | Preservation_push_pending branch, false ->
        retry_pending_preservation repo source hooks state branch
    | Preservation_proven branch, false ->
        retry_proven_cleanup repo source state branch
    | (Preservation_push_pending _ | Preservation_proven _), true ->
        state_error ()
    | (Preservation_not_started | Preservation_legacy_unresolved), false
      when state.conflicts <> [] ->
        recover_post_abort_conflict repo source hooks state
    | (Preservation_not_started | Preservation_legacy_unresolved), false ->
        failure Validation "publish_no_active_conflict"
          "There is no active publication conflict to preserve."
    | (Preservation_not_started | Preservation_legacy_unresolved), true ->
        preserve_conflict repo source hooks state
  else
    match state.preservation with
    | Preservation_push_pending branch | Preservation_proven branch ->
        failure ~commit:state.original ~branch ~paths:state.conflicts Validation
          "publish_conflict_preservation_retry_required"
          "Conflict preservation is pending; rerun with --preserve-conflict."
    | (Preservation_not_started | Preservation_legacy_unresolved)
      when not rebasing && state.conflicts <> [] ->
        post_abort_failure state
          "publish_conflict_post_abort_preservation_required"
          "A retained post-abort conflict must be recovered with --preserve-conflict."
    | Preservation_not_started | Preservation_legacy_unresolved ->
        let* state =
          if rebasing then continue_rebase repo state root ~count_clean_race:false
          else
            let* paths = working_paths repo in
            if paths = [] then Ok state
            else
              failure Validation "publish_resume_dirty"
                "An active publication can resume only from a clean worktree."
        in
        let* () = fetch repo source in
        let* state =
          rebase_onto_origin repo state root ~count_clean_race:false
        in
        publish_attempts repo source hooks root state

let start repo source hooks root thread_id =
  let* _ = ensure_managed_worktree repo in
  let* () = unpublished_preflight repo in
  let* original = commit_managed repo root in
  let* state = create_state repo thread_id original in
  let* () = detach_publication repo original in
  let* () = fetch repo source in
  let* state = rebase_onto_origin repo state root ~count_clean_race:false in
  publish_attempts repo source hooks root state

let git_flow ~repo ~thread_id ~preserve_conflict ~hooks root =
  let* source = load_source repo in
  let* rebasing = rebase_in_progress repo in
  let* state = load_state repo thread_id in
  let* () =
    repository_preflight
      ~allow_detached_rebase:(Option.is_some state)
      repo source
  in
  match state, rebasing with
  | None, true ->
      failure Validation "publish_rebase_in_progress"
        "An unrelated Git rebase is already in progress."
  | None, false when preserve_conflict ->
      failure Validation "publish_no_active_conflict"
        "There is no active publication conflict to preserve."
  | None, false -> start repo source hooks root thread_id
  | Some state, _ -> resume repo source hooks root state preserve_conflict

let run_with ~repo ~thread_id ~preserve_conflict
    ~(sync : string -> (Sync.report, Sync.error) result) ~hooks =
  if not (valid_thread_id thread_id) then
    failure Validation "publish_thread_id_invalid"
      "--thread-id must be an exact Amp thread ID."
  else
    let locked =
      Local.with_exclusive_repo repo (fun root ->
          Ok (git_flow ~repo ~thread_id ~preserve_conflict ~hooks root))
    in
    match locked with
    | Error local -> Error (of_local local)
    | Ok (Error _ as error) -> error
    | Ok (Ok git_success) ->
        hooks.before_sync ~commit:git_success.pushed_commit;
        let synchronized = sync git_success.pushed_commit in
        (match synchronized, git_success.cleanup_error with
        | Ok sync, None -> Ok { commit = git_success.pushed_commit; sync }
        | Ok _, Some cleanup ->
            failure ~published:true ~commit:git_success.pushed_commit
              ~cause:cleanup.code Internal "publish_complete_cleanup_failed"
              "Git publication succeeded, but local publication-state cleanup must be retried."
        | Error sync_error, None ->
            let cause = sync_error.code in
            failure ~published:true ~commit:git_success.pushed_commit ~cause
              ~diagnostics:sync_error.diagnostics Stale
              "publish_complete_index_stale"
              "Git publication succeeded, but the derived index is stale and must be synchronized later."
        | Error sync_error, Some cleanup ->
            failure ~published:true ~commit:git_success.pushed_commit
              ~cause:sync_error.code ~cleanup_cause:cleanup.code
              ~diagnostics:sync_error.diagnostics Stale
              "publish_complete_index_stale_cleanup_pending"
              "Git publication succeeded, but the derived index is stale and local publication-state cleanup is incomplete; synchronize the index later and retry or repair local cleanup before another publication.")

let production_sync repo commit =
  match Sys.getenv_opt "KB_DATABASE_DIRECT_URL" with
  | Some url when url <> "" ->
      Sync.run ~repo ~url ~reembed:false ~allow_mass_deletion:false
        ~target_commit:(Some commit)
  | _ ->
      Error
        (Sync.fallback_error ~code:"database_direct_url_missing"
           ~message:
             "KB_DATABASE_DIRECT_URL is required for post-push synchronization.")

let run ~repo ~thread_id ~preserve_conflict =
  run_with ~repo ~thread_id ~preserve_conflict
    ~sync:(production_sync repo) ~hooks:default_hooks

module For_test = struct
  type nonrec hooks = hooks = {
    before_push : attempt:int -> refspec:string -> unit;
    after_preservation_proven : branch:string -> commit:string -> unit;
    after_main_push : commit:string -> unit;
    before_sync : commit:string -> unit;
    now : unit -> float;
  }

  let default_hooks = default_hooks
  let run = run_with
end
