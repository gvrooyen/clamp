open Diagnostic

type result = {
  concepts : int;
  reserved : int;
  diagnostics : Diagnostic.t list;
}

type source_file = {
  relative : string;
  identity : Secure_fs.identity;
}

type parsed_concept = {
  id : string;
  relative : string;
  type_name : string option;
  superseded_by : string option;
  dependencies : string list;
  links : string list;
}

type warning_source = {
  source_id : string;
  relative : string;
  type_name : string option;
  links : string list;
}

let reserved name = name = "index.md" || name = "log.md"

let ulid value =
  String.length value = 26 && value.[0] <= '7'
  && String.for_all
       (fun character ->
         String.contains "0123456789ABCDEFGHJKMNPQRSTVWXYZ" character)
       value

let slug value =
  value <> ""
  && Str.string_match (Str.regexp {|^[a-z0-9]+\(-[a-z0-9]+\)*$|}) value 0

let task_path id =
  match String.split_on_char '/' id with
  | [ "tasks"; name ] ->
      (match String.index_opt name '-' with
      | Some 26 ->
          ulid (String.sub name 0 26) && String.length name > 27
          && slug (String.sub name 27 (String.length name - 27))
      | _ -> false)
  | _ -> false

let journal_path id type_name =
  match String.split_on_char '/' id with
  | [ "journal"; year; day ] ->
      String.length year = 4 && String.starts_with ~prefix:(year ^ "-") day
      && Concept.date day && type_name = Some "journal"
  | _ -> false

let has_prefix_component prefix id =
  id = prefix || String.starts_with ~prefix:(prefix ^ "/") id

let normalize base target =
  let raw =
    if String.starts_with ~prefix:"/" target then
      String.sub target 1 (String.length target - 1)
    else if base = "" then target
    else base ^ "/" ^ target
  in
  let rec loop accumulated = function
    | [] -> Some (String.concat "/" (List.rev accumulated))
    | "." :: rest -> loop accumulated rest
    | ".." :: rest ->
        (match accumulated with [] -> None | _ :: tail -> loop tail rest)
    | component :: rest -> loop (component :: accumulated) rest
  in
  loop [] (String.split_on_char '/' raw)

let hex_value character =
  match character with
  | '0' .. '9' -> Some (Char.code character - Char.code '0')
  | 'a' .. 'f' -> Some (10 + Char.code character - Char.code 'a')
  | 'A' .. 'F' -> Some (10 + Char.code character - Char.code 'A')
  | _ -> None

let percent_decode value =
  let buffer = Buffer.create (String.length value) in
  let rec loop index =
    if index = String.length value then Ok (Buffer.contents buffer)
    else if value.[index] <> '%' then begin
      Buffer.add_char buffer value.[index];
      loop (index + 1)
    end else if index + 2 >= String.length value then Error ()
    else
      match (hex_value value.[index + 1], hex_value value.[index + 2]) with
      | Some high, Some low ->
          Buffer.add_char buffer (Char.chr ((high lsl 4) lor low));
          loop (index + 3)
      | _ -> Error ()
  in
  loop 0

let decode_uri_path value =
  let rec loop decoded = function
    | [] -> Ok (String.concat "/" (List.rev decoded))
    | component :: rest ->
        Result.bind (percent_decode component) (fun component ->
            if
              String.contains component '/' || String.contains component '\\'
              || not (Frontmatter.valid_utf8 component)
            then Error ()
            else loop (component :: decoded) rest)
  in
  loop [] (String.split_on_char '/' value)

let path_part destination =
  let stop =
    [ String.index_opt destination '?'; String.index_opt destination '#' ]
    |> List.filter_map Fun.id
    |> function [] -> String.length destination | values -> List.fold_left min max_int values
  in
  String.sub destination 0 stop

let external_link destination =
  Str.string_match
    (Str.regexp "^[A-Za-z][A-Za-z0-9+.-]*:") destination 0
  || String.starts_with ~prefix:"//" destination

let warning_diagnostics ~concept_ids sources =
  let ids = Hashtbl.create (List.length concept_ids) in
  List.iter (fun id -> Hashtbl.replace ids id ()) concept_ids;
  let diagnostics = ref [] in
  let add ?(field = "") path code message =
    diagnostics :=
      Diagnostic.make ~severity:Warning ~field path code message :: !diagnostics
  in
  List.iter
    (fun source ->
      let path = "knowledge/" ^ source.relative in
      Option.iter
        (fun value ->
          if String.trim value <> "" && not (List.mem value Concept.known_types)
          then add ~field:"type" path "unknown_type" "unknown non-empty OKF type")
        source.type_name;
      List.iter
        (fun destination ->
          if destination <> "" && not (external_link destination)
             && not (String.starts_with ~prefix:"#" destination)
          then
            let encoded = path_part destination in
            match decode_uri_path encoded with
            | Error () ->
                add path "link_invalid_uri"
                  "Markdown link contains invalid percent encoding or an encoded path separator"
            | Ok decoded ->
                let bundle_absolute = String.starts_with ~prefix:"/" decoded in
                let decoded, directory =
                  if String.starts_with ~prefix:"/knowledge/" decoded then
                    (String.sub decoded 11 (String.length decoded - 11), "")
                  else if bundle_absolute then
                    (String.sub decoded 1 (String.length decoded - 1), "")
                  else
                    let directory =
                      match String.rindex_opt source.source_id '/' with
                      | None -> ""
                      | Some index -> String.sub source.source_id 0 index
                    in
                    (decoded, directory)
                in
                (match normalize directory decoded with
                | None when not bundle_absolute -> ()
                | None ->
                    add path "link_unresolved"
                      "bundle-absolute link escapes the knowledge bundle"
                | Some normalized
                  when String.ends_with ~suffix:".md" normalized
                       && not (reserved (Filename.basename normalized)) ->
                    let target =
                      String.sub normalized 0 (String.length normalized - 3)
                    in
                    if not (Hashtbl.mem ids target) then
                      add path "link_unresolved" "concept link does not resolve"
                | Some _ -> ()))
        source.links)
    sources;
  List.sort Diagnostic.compare !diagnostics

type reserved_validation = {
  body : string;
  retain_links : bool;
  issues : (string * string) list;
}

let valid_reserved_index_entry ~relative destination =
  if destination = "" || external_link destination
     || String.starts_with ~prefix:"#" destination
  then false
  else
    match decode_uri_path (path_part destination) with
    | Error () -> false
    | Ok decoded ->
        let decoded, directory =
          if String.starts_with ~prefix:"/knowledge/" decoded then
            (String.sub decoded 11 (String.length decoded - 11), "")
          else if String.starts_with ~prefix:"/" decoded then
            (String.sub decoded 1 (String.length decoded - 1), "")
          else
            let source_id =
              String.sub relative 0 (String.length relative - 3)
            in
            let directory =
              match String.rindex_opt source_id '/' with
              | None -> ""
              | Some index -> String.sub source_id 0 index
            in
            (decoded, directory)
        in
        Option.exists
          (fun normalized ->
            normalized <> ""
            &&
            (String.ends_with ~suffix:"/" normalized
             || (String.ends_with ~suffix:".md" normalized
                 && not (reserved (Filename.basename normalized)))))
          (normalize directory decoded)

let validate_reserved_document ~relative contents =
  let name = Filename.basename relative in
  let root_index = relative = "index.md" in
  let malformed_body () =
    Option.value (Frontmatter.body_after_delimiters contents) ~default:contents
  in
  let numeric_issues metadata =
    Exact_yaml.numeric_issues metadata
    |> List.map (fun (_, failure) ->
           (Exact_yaml.numeric_error_code failure,
            Exact_yaml.numeric_error_message failure))
  in
  let body, retain_links, diagnostics =
    if name = "index.md" then
      if Frontmatter.has_opening_delimiter contents then
        if not root_index then
          (malformed_body (), false,
           [ ("reserved_index_frontmatter",
              "only the bundle-root index.md may contain frontmatter") ])
        else
          (match Frontmatter.parse contents with
          | Error _ ->
              (malformed_body (), false,
               [ ("reserved_index_invalid", "root index frontmatter is malformed") ])
          | Ok parsed ->
              let diagnostics =
                if
                  parsed.metadata
                  = Exact_yaml.Map
                      [ ("okf_version",
                         Exact_yaml.Scalar (Exact_yaml.String, "0.2")) ]
                then []
                else
                  [ ("reserved_index_version",
                     "root index frontmatter must contain only okf_version: \"0.2\"") ]
              in
              (parsed.body, true, diagnostics @ numeric_issues parsed.metadata))
      else (contents, true, [])
    else if Frontmatter.has_opening_delimiter contents then
      (match Frontmatter.parse contents with
      | Ok parsed -> (parsed.body, true, numeric_issues parsed.metadata)
      | Error _ ->
          (malformed_body (), false,
           [ ("reserved_log_invalid", "log.md frontmatter is malformed") ]))
    else (contents, true, [])
  in
  let valid_utf8 = Frontmatter.valid_utf8 body in
  let diagnostics =
    if not valid_utf8 then
      ("invalid_utf8", "reserved document must be valid UTF-8") :: diagnostics
    else if name = "index.md" then
      if
        List.exists (valid_reserved_index_entry ~relative)
          (Markdown_links.index_entries body)
      then diagnostics
      else
        ("reserved_index_sections",
         "index.md requires a linked entry under a section heading")
        :: diagnostics
    else
      let flat_structure, dates = Markdown_links.log_structure body in
      let diagnostics =
        if flat_structure then diagnostics
        else
          ("reserved_log_sections",
           "log.md requires one leading H1 followed only by H2 date groups")
          :: diagnostics
      in
      if dates = [] || not (List.for_all Concept.date dates) then
        ("reserved_log_dates", "log.md requires ISO YYYY-MM-DD H2 date headings")
        :: diagnostics
      else if dates <> List.sort_uniq (Fun.flip String.compare) dates then
        ("reserved_log_order", "log.md date headings must be newest first")
        :: diagnostics
      else diagnostics
  in
  { body; retain_links = retain_links && valid_utf8; issues = List.rev diagnostics }

exception Markdown_file_limit
type preflight_result = Within_limit | File_limit_exceeded | Traversal_incomplete

module Diagnostic_collector = Diagnostic.Collector

let within_markdown_file_limit ?(before_entry = fun _ -> ()) root =
  let count = ref 0 in
  let incomplete = ref false in
  let rec walk directory =
    try
      Secure_fs.iter_entries directory (fun name ->
          try
            before_entry name;
            let kind, identity = Secure_fs.inspect directory name in
            match kind with
            | Secure_fs.Regular when String.ends_with ~suffix:".md" name ->
                incr count;
                if !count > Limits.max_markdown_files then
                  raise Markdown_file_limit
            | Secure_fs.Directory ->
                let child = Secure_fs.open_directory_at directory name in
                Fun.protect ~finally:(fun () -> Unix.close child) (fun () ->
                    let opened = Secure_fs.descriptor_identity child in
                    if identity.device = opened.device && identity.inode = opened.inode
                    then walk child
                    else incomplete := true)
            | Secure_fs.Regular | Secure_fs.Symlink | Secure_fs.Other -> ()
          with Unix.Unix_error _ | Sys_error _ -> incomplete := true)
    with Unix.Unix_error _ | Sys_error _ -> incomplete := true
  in
  try
    let repository = Secure_fs.open_directory root in
    Fun.protect ~finally:(fun () -> Unix.close repository) (fun () ->
        let knowledge = Secure_fs.open_directory_at repository "knowledge" in
        Fun.protect ~finally:(fun () -> Unix.close knowledge) (fun () ->
            walk knowledge));
    if !incomplete then Traversal_incomplete else Within_limit
  with
  | Markdown_file_limit -> File_limit_exceeded
  | Unix.Unix_error _ | Sys_error _ -> Traversal_incomplete

let validate_within_file_limit ?(after_open = fun () -> ())
    ?(before_entry = fun _ -> ()) root =
  let diagnostics = Diagnostic_collector.create () in
  let add ?(severity = Error) ?field path code message =
    Diagnostic_collector.add diagnostics (make ~severity ?field path code message)
  in
  let retained_descriptors = ref [] in
  let retain descriptor =
    retained_descriptors := descriptor :: !retained_descriptors;
    descriptor
  in
  let close_noerr descriptor =
    try Unix.close descriptor with _ -> ()
  in
  Fun.protect
    ~finally:(fun () -> List.iter close_noerr !retained_descriptors)
    (fun () ->
  let repository_directory =
    try Some (Secure_fs.open_directory root |> retain)
    with Unix.Unix_error _ | Sys_error _ -> None
  in
  let config_result =
    match repository_directory with
    | Some directory -> Config.load_at directory "clamp.yaml"
    | None -> Result.Error (Safe_file.message Safe_file.Missing_or_unreadable)
  in
  (match config_result with
  | Ok () -> ()
  | Error message ->
      let code =
        if message = Safe_file.message Safe_file.Too_large then
          "config_file_size_limit"
        else "config_invalid"
      in
      add "clamp.yaml" code message);
  let concepts = ref [] and reserved_files = ref [] and markdown_count = ref 0 in
  let same_identity left right =
    left.Secure_fs.device = right.Secure_fs.device && left.inode = right.inode
  in
  let rec walk relative path_is_portable directory =
      try
        let concepts_before = !concepts in
        let reserved_before = !reserved_files in
        let directory_before = Secure_fs.descriptor_identity directory in
        let sibling_names = Hashtbl.create 32 in
        let sibling_collisions = Hashtbl.create 4 in
        Secure_fs.iter_entries directory (fun name ->
            if Concept.portable_component name then
              let folded = String.lowercase_ascii name in
              match Hashtbl.find_opt sibling_names folded with
              | None -> Hashtbl.add sibling_names folded name
              | Some existing ->
                  Hashtbl.replace sibling_names folded (max existing name);
                  Hashtbl.replace sibling_collisions folded ());
        if path_is_portable then
          Hashtbl.iter
            (fun folded () ->
              let name = Hashtbl.find sibling_names folded in
              let collision_path =
                if relative = "" then name else relative ^ "/" ^ name
              in
              add ("knowledge/" ^ collision_path) "path_duplicate"
                "Markdown path collides case-insensitively")
            sibling_collisions;
        Secure_fs.iter_entries directory (fun name ->
          try
                   before_entry name;
                   let child_relative =
                     if relative = "" then name else relative ^ "/" ^ name
                   in
                   let kind, identity = Secure_fs.inspect directory name in
                   if
                     kind = Secure_fs.Regular
                     && String.ends_with ~suffix:".md" name
                   then begin
                     incr markdown_count;
                     if !markdown_count > Limits.max_markdown_files then
                       raise Markdown_file_limit
                   end;
                   let component_is_portable = Concept.portable_component name in
                   let component_collides =
                     component_is_portable
                     && Hashtbl.mem sibling_collisions
                          (String.lowercase_ascii name)
                   in
                   let child_path_is_portable =
                     path_is_portable && component_is_portable
                     && not component_collides
                   in
                   if not component_is_portable then
                     add "knowledge" "path_component_invalid"
                       "knowledge path contains a non-UTF-8, non-portable, or URI-unsafe component";
                   let relative = child_relative in
                   match kind with
                     | Secure_fs.Symlink when child_path_is_portable ->
                         add ("knowledge/" ^ relative) "symlink_forbidden"
                           "symlinks are forbidden under knowledge"
                     | Secure_fs.Directory ->
                         let child = Secure_fs.open_directory_at directory name in
                         Fun.protect ~finally:(fun () -> Unix.close child) (fun () ->
                             if
                               same_identity identity
                                 (Secure_fs.descriptor_identity child)
                             then walk relative child_path_is_portable child
                             else if child_path_is_portable then
                               add ("knowledge/" ^ relative) "directory_changed"
                                 "knowledge directory changed during validation")
                     | Secure_fs.Regular
                       when child_path_is_portable
                            && String.ends_with ~suffix:".md" relative ->
              let file = { relative; identity } in
              let basename = Filename.basename relative in
              let folded_basename = String.lowercase_ascii basename in
              if reserved folded_basename && basename <> folded_basename then
                add ("knowledge/" ^ relative) "reserved_case_invalid"
                  "reserved index.md and log.md names must use canonical lowercase"
              else if reserved basename then
                reserved_files := file :: !reserved_files
              else concepts := file :: !concepts
                     | Secure_fs.Other
                       when child_path_is_portable
                            && String.ends_with ~suffix:".md" relative ->
                         add ("knowledge/" ^ relative) "file_not_regular"
                           "Markdown paths must be regular files"
                     | Secure_fs.Regular | Secure_fs.Symlink | Secure_fs.Other -> ()
          with Unix.Unix_error _ | Sys_error _ ->
            let diagnostic_path =
              if Concept.portable_component name then
                let child_relative =
                  if relative = "" then name else relative ^ "/" ^ name
                in
                "knowledge/" ^ child_relative
              else "knowledge"
            in
            add diagnostic_path "path_unreadable"
              "knowledge entry changed or became unreadable during validation");
        let directory_after = Secure_fs.descriptor_identity directory in
        if not (Safe_file.unchanged directory_before directory_after) then begin
          concepts := concepts_before;
          reserved_files := reserved_before;
          let path =
            if relative = "" then "knowledge" else "knowledge/" ^ relative
          in
          add path "directory_changed"
            "knowledge directory membership changed during validation"
        end
      with Unix.Unix_error _ | Sys_error _ ->
        add ("knowledge/" ^ relative) "directory_unreadable"
          "knowledge path is unreadable"
  in
  let knowledge_directory =
    try match repository_directory with
    | None -> raise Not_found
    | Some repository ->
      let directory = Secure_fs.open_directory_at repository "knowledge" |> retain in
      after_open ();
      walk "" true directory;
      Some directory
   with Unix.Unix_error _ | Sys_error _ | Not_found ->
     add "knowledge" "knowledge_not_directory"
       "knowledge must be a readable directory, not a symlink";
     None
  in
  let folded_paths = Hashtbl.create 128 in
  List.sort
    (fun (left : source_file) (right : source_file) ->
      String.compare left.relative right.relative)
    (!reserved_files @ !concepts)
  |> List.iter (fun (file : source_file) ->
         let folded = String.lowercase_ascii file.relative in
         if Hashtbl.mem folded_paths folded then
           add ("knowledge/" ^ file.relative) "path_duplicate"
             "Markdown path collides case-insensitively"
         else Hashtbl.add folded_paths folded file.relative);
  let read (file : source_file) =
    let result =
      match knowledge_directory with
      | None -> Result.Error Safe_file.Missing_or_unreadable
      | Some root ->
          (try
             Secure_fs.open_beneath root file.relative
             |> Safe_file.read_descriptor ~expected:file.identity
           with Unix.Unix_error _ | Sys_error _ ->
             Result.Error Safe_file.Changed_during_read)
    in
    match result with
    | Ok contents -> Some contents
    | Error error ->
        add ("knowledge/" ^ file.relative) (Safe_file.code error)
          (Safe_file.message error);
        None
  in
  let link_count = ref 0 and link_limit_reported = ref false in
  let reserved_link_sources = ref [] in
  let count_links ~retain body =
    let remaining = Limits.max_markdown_links - !link_count in
    let links, count, truncated =
      if remaining < 0 then ([], 0, true)
      else if retain then
        let links, truncated =
          Markdown_links.extract_bounded ~limit:(remaining + 1) body
        in
        (links, List.length links, truncated)
      else
        let count, truncated =
          Markdown_links.count_bounded ~limit:(remaining + 1) body
        in
        ([], count, truncated)
    in
    let overflow = truncated || count > remaining in
    if overflow && not !link_limit_reported then begin
      link_limit_reported := true;
      add "knowledge" "markdown_link_limit"
        "bundle exceeds the 100,000 Markdown-link safety limit"
    end;
    if overflow then link_count := Limits.max_markdown_links + 1
    else link_count := !link_count + count;
    if overflow then [] else links
  in
  let body_after_malformed_frontmatter contents =
    Option.value (Frontmatter.body_after_delimiters contents) ~default:contents
  in
  let retain_reserved_links (file : source_file) body =
    let links = count_links ~retain:true body in
    reserved_link_sources :=
      { source_id = String.sub file.relative 0 (String.length file.relative - 3);
        relative = file.relative; type_name = None; links }
      :: !reserved_link_sources
  in
  let validate_reserved (file : source_file) contents =
    let validation = validate_reserved_document ~relative:file.relative contents in
    if validation.retain_links then retain_reserved_links file validation.body
    else ignore (count_links ~retain:false validation.body);
    List.iter
      (fun (code, message) ->
        let structural =
          List.mem code
            [ "reserved_index_sections"; "reserved_log_sections";
              "reserved_log_dates"; "reserved_log_order" ]
        in
        if not (structural && !link_limit_reported) then
          add ("knowledge/" ^ file.relative) code message)
      validation.issues
  in
  List.sort
    (fun (left : source_file) (right : source_file) ->
      String.compare left.relative right.relative)
    !reserved_files
  |> List.iter (fun (file : source_file) ->
         read file
         |> Option.iter (validate_reserved file));
  let ids = Hashtbl.create 128 and folded_ids = Hashtbl.create 128 in
  let parsed = ref [] and concept_count = ref 0 in
  List.sort
    (fun (left : source_file) (right : source_file) ->
      String.compare left.relative right.relative)
    !concepts
  |> List.iter (fun (file : source_file) ->
         incr concept_count;
         let path = "knowledge/" ^ file.relative in
         let id = String.sub file.relative 0 (String.length file.relative - 3) in
         if not (Concept.concept_id id) then
           add path "concept_id_invalid" "concept path is not portable and URI-safe";
         let folded = String.lowercase_ascii id in
         if not (Hashtbl.mem folded_ids folded) then begin
           Hashtbl.add folded_ids folded id;
           Hashtbl.add ids id ()
         end;
         read file
         |> Option.iter (fun contents ->
                match Frontmatter.parse contents with
                | Error message ->
                    ignore
                      (count_links ~retain:false
                         (body_after_malformed_frontmatter contents));
                    let code =
                      match message with
                      | "YAML depth limit exceeded" -> "yaml_depth_limit"
                      | "YAML node limit exceeded" -> "yaml_node_limit"
                      | "concept must be valid UTF-8" -> "invalid_utf8"
                      | _ -> "frontmatter_invalid"
                    in
                    add path code "frontmatter is malformed or unsupported"
                | Ok concept ->
                    Concept.validate concept.metadata
                    |> List.iter (fun (field, message) ->
                           add ~field path "metadata_invalid" message);
                    Exact_yaml.numeric_issues concept.metadata
                    |> List.iter (fun (field, failure) ->
                           add ~field path
                             (Exact_yaml.numeric_error_code failure)
                             (Exact_yaml.numeric_error_message failure));
                    let type_name =
                      Option.bind (Exact_yaml.find "type" concept.metadata)
                        Exact_yaml.string
                    in
                    if has_prefix_component "tasks" id then begin
                      if not (task_path id && type_name = Some "task") then
                        add path "task_path_invalid"
                          "every tasks/ path must be a task named <ULID>-<slug>.md"
                    end else if type_name = Some "task" then
                      add path "task_path_invalid" "task concepts must be under tasks/";
                    if has_prefix_component "journal" id then begin
                      if not (journal_path id type_name) then
                        add path "journal_path_invalid"
                          "every journal/ path must match journal/<year>/<date>.md and type journal"
                    end else if type_name = Some "journal" then
                      add path "journal_path_invalid"
                        "journal concepts must use the canonical journal path";
                    let clamp = Exact_yaml.find "clamp" concept.metadata in
                    let superseded_by =
                      Option.bind clamp (fun value ->
                          Option.bind (Exact_yaml.find "superseded_by" value)
                            Exact_yaml.string)
                    in
                    let dependencies =
                      let task =
                        Option.bind clamp (Exact_yaml.find "task")
                      in
                      let depends_on =
                        Option.bind task (Exact_yaml.find "depends_on")
                      in
                      match depends_on with
                      | Some (Exact_yaml.Seq values) ->
                          List.filter_map Exact_yaml.string values
                      | _ -> []
                    in
                    let links = count_links ~retain:true concept.body in
                    parsed :=
                      { id; relative = file.relative; type_name; superseded_by;
                        dependencies; links }
                      :: !parsed));
  let exists id = Hashtbl.mem ids id in
  List.iter
    (fun (concept : parsed_concept) ->
      let path = "knowledge/" ^ concept.relative in
      Option.iter
        (fun target ->
          if target = concept.id then
            add path "supersession_self" "concept cannot supersede itself"
          else if not (exists target) then
            add path "reference_unresolved" "superseded concept does not resolve")
        concept.superseded_by;
      List.iter
        (fun target ->
          if target = concept.id then
            add path "dependency_self" "task cannot depend on itself"
          else if not (exists target) then
            add path "dependency_unresolved" "task dependency does not resolve")
        concept.dependencies)
    !parsed;
  let warnings =
    warning_diagnostics
      ~concept_ids:(Hashtbl.to_seq_keys ids |> List.of_seq)
      (!reserved_link_sources
       @ List.map
           (fun (concept : parsed_concept) ->
             { source_id = concept.id; relative = concept.relative;
               type_name = concept.type_name; links = concept.links })
           !parsed)
  in
  (if !link_count <= Limits.max_markdown_links then warnings
   else List.filter (fun diagnostic -> diagnostic.code = "unknown_type") warnings)
  |> List.iter (Diagnostic_collector.add diagnostics);
  { concepts = !concept_count;
    reserved = List.length !reserved_files;
    diagnostics = Diagnostic_collector.diagnostics diagnostics })

let file_limit_result () =
  { concepts = 0;
    reserved = 0;
    diagnostics =
      [ make "knowledge" "markdown_file_limit"
          "bundle exceeds the 10,000 Markdown-file safety limit" ] }

let validate_with_hook ~after_preflight root =
  match within_markdown_file_limit root with
  | File_limit_exceeded -> file_limit_result ()
  | Within_limit | Traversal_incomplete -> begin
    after_preflight ();
    try validate_within_file_limit root
    with Markdown_file_limit -> file_limit_result ()
  end

let validate_unlocked root root_descriptor =
  let preflight = within_markdown_file_limit root in
  let result =
    match preflight with
    | File_limit_exceeded -> file_limit_result ()
    | Within_limit | Traversal_incomplete ->
        (try validate_within_file_limit root
         with Markdown_file_limit -> file_limit_result ())
  in
  let additional =
    match preflight with
    | File_limit_exceeded -> Ok None
    | Within_limit | Traversal_incomplete -> match Local.todo_drift_at root_descriptor with
    | Ok true ->
        Ok (Some
          (make "TODO.md" "todo_drift"
             "generated TODO does not match task concepts"))
    | Error issue when Local.exit_class issue = Exit_class.Internal ->
        Error issue
    | Error _ ->
        Ok (Some
          (make "TODO.md" "todo_unreadable"
             "generated TODO cannot be read or compared safely"))
    | Ok false -> Ok None
  in
  Result.map (function
  | None -> result
  | Some diagnostic ->
      let all = List.sort Diagnostic.compare (diagnostic :: result.diagnostics) in
      let diagnostics =
        if List.length all <= Limits.max_diagnostics then all
        else
          let without_marker =
            List.filter (fun item -> item.code <> "diagnostic_limit") all
          in
          let rec take count values =
            match (count, values) with
            | 0, _ | _, [] -> []
            | count, value :: rest -> value :: take (count - 1) rest
          in
          make "knowledge" "diagnostic_limit"
            "bundle exceeds the 1,000-diagnostic safety limit"
          :: take (Limits.max_diagnostics - 1) without_marker
          |> List.sort Diagnostic.compare
      in
      { result with diagnostics }) additional

let validate_checked root =
  Local.with_shared_repo root (fun root_descriptor ->
      validate_unlocked root root_descriptor)

let validate_at root root_descriptor = validate_unlocked root root_descriptor

let validate root =
  match validate_checked root with
  | Ok result -> result
  | Error _ ->
      { concepts = 0; reserved = 0;
        diagnostics =
          [ make "knowledge" "bundle_unreadable"
              "bundle cannot be locked or read safely" ] }

module For_test = struct
  let validate_with_hook = validate_with_hook

  let validate_with_open_hook root ~after_open =
    match within_markdown_file_limit root with
    | File_limit_exceeded -> file_limit_result ()
    | Within_limit | Traversal_incomplete ->
        validate_within_file_limit ~after_open root

  let validate_with_entry_hooks root ~before_preflight_entry ~after_preflight
      ~before_validation_entry =
    match within_markdown_file_limit ~before_entry:before_preflight_entry root with
    | File_limit_exceeded -> file_limit_result ()
    | Within_limit | Traversal_incomplete ->
        after_preflight ();
        (try
           validate_within_file_limit ~before_entry:before_validation_entry root
         with Markdown_file_limit -> file_limit_result ())
end
