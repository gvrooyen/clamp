type error = { code : string; message : string }

type target = {
  target : string;
  archive_url : string;
  archive_sha256 : string;
  archive_root : string;
  archive_size : int;
  required_files : string list;
}

type manifest = {
  version : string;
  revision : string;
  targets : target list;
}

type v1_lock = {
  version : string;
  revision : string;
  url : string;
  sha256 : string;
}

type v2_lock = {
  version : string;
  revision : string;
  manifest_url : string;
  manifest_sha256 : string;
}

type lock = V1 of v1_lock | V2 of v2_lock

let maximum_lock_bytes = 8_192
let maximum_manifest_bytes = 1_048_576
let maximum_archive_bytes = 67_108_864
let maximum_extracted_bytes = 67_108_864L
let maximum_targets = 16
let maximum_depth = 8
let maximum_nodes = 1_024
let maximum_required_files = 256
let accepted_targets = [ "linux-x86_64"; "macos-arm64" ]

let mandatory_files =
  [ "LICENSE"; "README.txt"; "REVISION"; "THIRD_PARTY_NOTICES"; "VERSION";
    "bin/kb"; "share/clamp/migrations/0001_enable_vector.sql";
    "share/clamp/migrations/0002_application_schema.sql";
    "share/clamp/templates/AGENTS.md"; "share/clamp/templates/README.md";
    "share/clamp/templates/gitignore"; "share/clamp/templates/resume";
    "share/clamp/templates/runtime_metadata.py"; "share/clamp/templates/setup";
    "share/clamp/templates/skill.md" ]

let error code message = Error { code; message }

let valid_component component =
  component <> "" && component <> "." && component <> ".."
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '-' -> true
         | _ -> false)
       component

let valid_relative_path value =
  value <> "" && String.length value <= 4_096
  && not (String.starts_with ~prefix:"/" value)
  && not (String.ends_with ~suffix:"/" value)
  && List.for_all valid_component (String.split_on_char '/' value)

let valid_version value =
  let component value =
    value <> ""
    && String.for_all (function '0' .. '9' -> true | _ -> false) value
    && (value = "0" || value.[0] <> '0')
  in
  String.length value <= 63
  && match String.split_on_char '.' value with
     | [ major; minor; patch ] -> List.for_all component [ major; minor; patch ]
     | _ -> false

let valid_revision value =
  String.length value = 40
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let valid_sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let valid_https_url value =
  String.length value > 8 && String.length value <= 2_048
  && String.starts_with ~prefix:"https://" value
  && not (String.contains value '@')
  && String.for_all
       (function ' ' | '\t' | '\n' | '\r' -> false | _ -> true)
       value

let release_base version =
  "https://github.com/gvrooyen/clamp/releases/download/v" ^ version ^ "/"

let manifest_name version = "clamp-" ^ version ^ "-runtime-manifest.json"

let manifest_urls ~version =
  let url = release_base version ^ manifest_name version in
  (url, url ^ ".sha256")

let archive_name ~version ~target =
  "clamp-" ^ version ^ "-" ^ target ^ ".tar.gz"

let valid_release_url ~version ~name value =
  valid_https_url value && value = release_base version ^ name

let keys expected fields =
  let actual = List.map fst fields in
  List.length actual = List.length (List.sort_uniq String.compare actual)
  && List.sort String.compare actual = List.sort String.compare expected

let bounded_json value =
  let nodes = ref 0 in
  let rec walk depth value =
    incr nodes;
    !nodes <= maximum_nodes && depth <= maximum_depth
    && match value with
       | `Assoc fields ->
           let names = List.map fst fields in
           List.length names = List.length (List.sort_uniq String.compare names)
           && List.for_all (fun (_, child) -> walk (depth + 1) child) fields
       | `List values -> List.for_all (walk (depth + 1)) values
       | `String _ | `Int _ -> true
       | `Bool _ | `Null | `Float _ | `Intlit _ | `Tuple _ | `Variant _ -> false
  in
  walk 1 value

let parse_json ~code ~maximum contents =
  if String.length contents > maximum then
    error
      (if code = "runtime_manifest_invalid" then "runtime_manifest_too_large" else code)
      (if code = "runtime_manifest_invalid" then
         "The runtime manifest exceeds the 1 MiB safety limit."
       else "The runtime lock exceeds its safety limit.")
  else if not (Frontmatter.valid_utf8 contents) then
    error code "Runtime metadata must be valid UTF-8 JSON."
  else
    try
      let value = Yojson.Safe.from_string contents in
      if bounded_json value then Ok value
      else error code "Runtime metadata exceeds its structural limits."
    with Yojson.Json_error _ -> error code "Runtime metadata is malformed JSON."

let string_field name fields =
  match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None

let int_field name fields =
  match List.assoc_opt name fields with Some (`Int value) -> Some value | _ -> None

let parse_v1_lock ~target contents =
  let lines = String.split_on_char '\n' contents in
  match lines with
  | [ version_line; revision_line; url_line; sha_line; "" ] ->
      let value prefix line =
        if String.starts_with ~prefix line then
          Some
            (String.sub line (String.length prefix)
               (String.length line - String.length prefix))
        else None
      in
      (match
         ( value "version=" version_line,
           value "revision=" revision_line,
           value "url=" url_line,
           value "sha256=" sha_line )
       with
      | Some version, Some revision, Some url, Some sha256
        when target = "linux-x86_64" && valid_version version
             && valid_revision revision && valid_sha256 sha256
             && valid_release_url ~version
                  ~name:(archive_name ~version ~target:"linux-x86_64") url ->
          Ok (V1 { version; revision; url; sha256 })
      | _ -> error "runtime_lock_v2_invalid" "The runtime lock is invalid for this target.")
  | _ -> error "runtime_lock_v2_invalid" "The runtime lock is invalid for this target."

let parse_lock ~target contents =
  if String.length contents > maximum_lock_bytes then
    error "runtime_lock_v2_invalid" "The runtime lock exceeds its safety limit."
  else if String.starts_with ~prefix:"version=" contents then
    parse_v1_lock ~target contents
  else
    Result.bind
      (parse_json ~code:"runtime_lock_v2_invalid" ~maximum:maximum_lock_bytes contents)
      (function
        | `Assoc fields
          when keys
                 [ "schema_version"; "version"; "revision"; "manifest_url";
                   "manifest_sha256" ]
                 fields ->
            (match
               ( int_field "schema_version" fields,
                 string_field "version" fields,
                 string_field "revision" fields,
                 string_field "manifest_url" fields,
                 string_field "manifest_sha256" fields )
             with
            | Some 2, Some version, Some revision, Some manifest_url,
              Some manifest_sha256
              when valid_version version && valid_revision revision
                   && valid_sha256 manifest_sha256
                   && valid_release_url ~version ~name:(manifest_name version)
                        manifest_url ->
                Ok (V2 { version; revision; manifest_url; manifest_sha256 })
            | _ -> error "runtime_lock_v2_invalid" "The v2 runtime lock is invalid.")
        | _ -> error "runtime_lock_v2_invalid" "The v2 runtime lock is invalid.")

let serialize_lock (lock : v2_lock) =
  `Assoc
    [ ("schema_version", `Int 2); ("version", `String lock.version);
      ("revision", `String lock.revision);
      ("manifest_url", `String lock.manifest_url);
      ("manifest_sha256", `String lock.manifest_sha256) ]
  |> Yojson.Safe.to_string |> fun value -> value ^ "\n"

let parse_target ~version = function
  | `Assoc fields
    when keys
           [ "target"; "archive_url"; "archive_sha256"; "archive_root";
             "archive_size"; "required_files" ]
           fields ->
      (match
         ( string_field "target" fields,
           string_field "archive_url" fields,
           string_field "archive_sha256" fields,
           string_field "archive_root" fields,
           int_field "archive_size" fields,
           List.assoc_opt "required_files" fields )
       with
      | Some target, Some archive_url, Some archive_sha256, Some archive_root,
        Some archive_size, Some (`List files) ->
          let required_files =
            List.fold_right
              (fun value result ->
                match (value, result) with
                | `String value, Some values -> Some (value :: values)
                | _ -> None)
              files (Some [])
          in
          (match required_files with
          | Some required_files
            when List.mem target accepted_targets
                 && valid_release_url ~version
                      ~name:(archive_name ~version ~target) archive_url
                 && valid_sha256 archive_sha256
                 && archive_root = "clamp-" ^ version ^ "-" ^ target
                 && archive_size > 0 && archive_size <= maximum_archive_bytes
                 && required_files <> []
                 && List.length required_files <= maximum_required_files
                 && required_files = List.sort_uniq String.compare required_files
                 && List.for_all valid_relative_path required_files
                 && List.for_all
                      (fun file -> List.mem file required_files)
                      mandatory_files ->
              Ok
                { target; archive_url; archive_sha256; archive_root; archive_size;
                  required_files }
          | _ -> error "runtime_manifest_invalid" "A runtime target record is invalid.")
      | _ -> error "runtime_manifest_invalid" "A runtime target record is invalid.")
  | _ -> error "runtime_manifest_invalid" "A runtime target record is invalid."

let parse_manifest ~expected_version contents =
  Result.bind
    (parse_json ~code:"runtime_manifest_invalid" ~maximum:maximum_manifest_bytes
       contents)
    (function
      | `Assoc fields
        when keys [ "schema_version"; "version"; "revision"; "targets" ] fields ->
          (match
             ( int_field "schema_version" fields,
               string_field "version" fields,
               string_field "revision" fields,
               List.assoc_opt "targets" fields )
           with
          | Some 1, Some version, Some revision, Some (`List values)
            when version = expected_version && valid_version version
                 && valid_revision revision && values <> []
                 && List.length values <= maximum_targets ->
              let parsed = List.map (parse_target ~version) values in
              if List.exists Result.is_error parsed then
                List.find Result.is_error parsed |> Result.map (fun _ -> assert false)
              else
                let targets = List.map Result.get_ok parsed in
                let names = List.map (fun target -> target.target) targets in
                if names <> List.sort_uniq String.compare names then
                  error "runtime_manifest_invalid"
                    "Runtime manifest targets must be unique and sorted."
                else Ok { version; revision; targets }
          | _ -> error "runtime_manifest_invalid" "The runtime manifest is invalid.")
      | _ -> error "runtime_manifest_invalid" "The runtime manifest is invalid.")

let serialize_manifest (manifest : manifest) =
  let target value =
    `Assoc
      [ ("target", `String value.target);
        ("archive_url", `String value.archive_url);
        ("archive_sha256", `String value.archive_sha256);
        ("archive_root", `String value.archive_root);
        ("archive_size", `Int value.archive_size);
        ( "required_files",
          `List (List.map (fun file -> `String file) value.required_files) ) ]
  in
  let value =
    `Assoc
      [ ("schema_version", `Int 1); ("version", `String manifest.version);
        ("revision", `String manifest.revision);
        ("targets", `List (List.map target manifest.targets)) ]
    |> Yojson.Safe.to_string |> fun value -> value ^ "\n"
  in
  Result.map (fun _ -> value) (parse_manifest ~expected_version:manifest.version value)

let select_target manifest target =
  match List.find_opt (fun value -> value.target = target) manifest.targets with
  | Some value -> Ok value
  | None -> error "runtime_manifest_target_missing" "The runtime manifest has no exact target match."
