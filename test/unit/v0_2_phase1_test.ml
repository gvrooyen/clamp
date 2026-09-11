let source_root = if Sys.file_exists "PRD.md" then "." else "../.."

let path value = Filename.concat source_root value

let read file =
  let channel = open_in_bin file in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let fixture name =
  Yojson.Safe.from_file
    (path (Filename.concat "test/fixtures/v0_2_phase1" name))

let member name value = Yojson.Safe.Util.member name value
let strings value = Yojson.Safe.Util.convert_each Yojson.Safe.Util.to_string value
let records value = Yojson.Safe.Util.to_list value
let assoc value = Yojson.Safe.Util.to_assoc value
let string name value = member name value |> Yojson.Safe.Util.to_string
let int name value = member name value |> Yojson.Safe.Util.to_int
let bool name value = member name value |> Yojson.Safe.Util.to_bool

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false

let unique label values =
  let sorted = List.sort_uniq String.compare values in
  Alcotest.(check int) label (List.length values) (List.length sorted)

let exact_keys label expected value =
  let actual = assoc value |> List.map fst in
  unique (label ^ " unique keys") actual;
  Alcotest.(check (list string)) label (List.sort String.compare expected)
    (List.sort String.compare actual)

let section ~heading ~next_heading text =
  let first = Str.search_forward (Str.regexp_string heading) text 0 in
  let last =
    Str.search_forward (Str.regexp_string next_heading) text
      (first + String.length heading)
  in
  String.sub text first (last - first)

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let valid_sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let exit_classes =
  let open Clamp.Exit_class in
  [ ("success", Success); ("user_error", User_error); ("conflict", Conflict);
    ("authentication", Authentication);
    ("transient_external", Transient_external); ("stale_index", Stale_index);
    ("internal", Internal) ]

let exit_class name =
  match List.assoc_opt name exit_classes with
  | Some value -> value
  | None -> Alcotest.failf "unknown fixture exit class %s" name

let payload_value field =
  match string "type" field with
  | "boolean" -> member "value" field
  | "integer" -> `Int (int "minimum" field)
  | "enum" -> `String (member "values" field |> strings |> List.hd)
  | "enum_list" -> `List [ `String (member "values" field |> strings |> List.hd) ]
  | "path_list" -> `List [ `String "safe/path" ]
  | "sha1" -> `String (String.make 40 'a')
  | "sha256" -> `String (String.make 64 'a')
  | "identifier" | "version" -> `String "safe-value"
  | value -> Alcotest.failf "unknown fixture field type %s" value

let field_keys field =
  match string "type" field with
  | "sha1" | "sha256" -> [ "name"; "type" ]
  | "identifier" | "version" -> [ "name"; "type"; "max_bytes" ]
  | "enum" -> [ "name"; "type"; "values" ]
  | "enum_list" -> [ "name"; "type"; "values"; "max_items" ]
  | "path_list" -> [ "name"; "type"; "max_items"; "item_max_bytes" ]
  | "integer" -> [ "name"; "type"; "minimum"; "maximum" ]
  | "boolean" -> [ "name"; "type"; "value" ]
  | value -> Alcotest.failf "unknown fixture field type %s" value

let prd_contract_codes prd =
  let contract =
    section ~heading:"### New stable machine contract"
      ~next_heading:"### 0.2.0 local-clone acceptance criteria" prd
  in
  let pattern = Str.regexp "`\\([a-z][a-z0-9_]*_[a-z0-9_]+\\)`" in
  let rec collect position values =
    try
      let found = Str.search_forward pattern contract position in
      collect (found + 1) (Str.matched_group 1 contract :: values)
    with Not_found -> List.sort_uniq String.compare values
  in
  collect 0 []

let contract_codes contracts = List.map (string "code") contracts

let validate_contract_fixture value =
  let invalid message = raise (Invalid_argument message) in
  let object_value label = function
    | `Assoc fields -> fields
    | _ -> invalid (label ^ " must be an object")
  in
  let array_value label = function
    | `List values -> values
    | _ -> invalid (label ^ " must be an array")
  in
  let exact label expected value =
    let fields = object_value label value in
    let actual = List.map fst fields in
    if List.length actual <> List.length (List.sort_uniq String.compare actual)
    then invalid (label ^ " has duplicate keys");
    if List.sort String.compare actual <> List.sort String.compare expected then
      invalid (label ^ " has missing or unknown keys")
  in
  try
    exact "contract fixture"
      [ "schema_version"; "envelopes"; "exit_classes"; "payload_shapes";
        "context_extensions"; "contracts" ]
      value;
    if int "schema_version" value <> 1 then invalid "unsupported schema";
    let shapes = member "payload_shapes" value |> object_value "payload shapes" in
    let shape_names = List.map fst shapes in
    if List.length shape_names
       <> List.length (List.sort_uniq String.compare shape_names)
    then invalid "duplicate payload shape";
    List.iter
      (fun (shape, fields_json) ->
        let fields = array_value shape fields_json in
        let names = List.map (string "name") fields in
        if List.length names <> List.length (List.sort_uniq String.compare names)
        then invalid (shape ^ " has duplicate fields");
        List.iter
          (fun field ->
            exact (shape ^ " field") (field_keys field) field;
            match string "type" field with
            | "identifier" | "version" ->
                if int "max_bytes" field < 1 then invalid "invalid byte bound"
            | "enum" ->
                if member "values" field |> strings = [] then
                  invalid "empty enum"
            | "enum_list" ->
                if int "max_items" field < 1 then invalid "invalid item bound"
            | "path_list" ->
                if int "max_items" field < 1 || int "item_max_bytes" field < 1
                then invalid "invalid path bound"
            | "integer" ->
                if int "minimum" field > int "maximum" field then
                  invalid "invalid integer range"
            | "boolean" ->
                if bool "value" field then invalid "boolean literal must be false"
            | "sha1" | "sha256" -> ()
            | _ -> invalid "unknown field type")
          fields)
      shapes;
    let contracts = member "contracts" value |> array_value "contracts" in
    let codes = List.map (string "code") contracts
    and selections = List.map (string "selection") contracts in
    if List.length codes <> List.length (List.sort_uniq String.compare codes)
    then invalid "duplicate contract code";
    if List.length selections
       <> List.length (List.sort_uniq String.compare selections)
    then invalid "duplicate contract selection";
    List.iter
      (fun contract ->
        exact "contract"
          [ "category"; "code"; "ok"; "exit_class"; "scopes"; "selection";
            "payload_shape" ]
          contract;
        ignore (bool "ok" contract);
        ignore (member "scopes" contract |> strings);
        if not (List.mem (string "payload_shape" contract) shape_names) then
          invalid "unknown payload shape")
      contracts;
    Ok ()
  with
  | Invalid_argument message -> Error message
  | Yojson.Safe.Util.Type_error (message, _) -> Error message

let replace_object_field name replacement = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if key = name then (key, replacement value) else (key, value))
           fields)
  | value -> value

let contract_fixture_rejects_malformed_schema () =
  let fixture = fixture "contracts.json" in
  let contracts = member "contracts" fixture |> records in
  let first = List.hd contracts in
  let malformed =
    [ ("missing top-level field",
       match fixture with
       | `Assoc fields -> `Assoc (List.remove_assoc "envelopes" fields)
       | value -> value);
      ("unknown top-level field",
       match fixture with
       | `Assoc fields -> `Assoc (("future", `Null) :: fields)
       | value -> value);
      ("duplicate contract code",
       replace_object_field "contracts"
         (fun _ -> `List (first :: contracts)) fixture);
      ("missing contract field",
       replace_object_field "contracts"
         (fun _ ->
           `List
             ((match first with
              | `Assoc fields -> `Assoc (List.remove_assoc "payload_shape" fields)
              | value -> value)
             :: List.tl contracts))
         fixture);
      ("wrong field type",
       replace_object_field "contracts"
         (fun _ ->
           `List
             (replace_object_field "scopes" (fun _ -> `String "sync") first
             :: List.tl contracts))
         fixture);
      ("invalid bound",
       replace_object_field "payload_shapes"
         (function
           | `Assoc shapes ->
               `Assoc
                 (List.map
                    (fun (name, fields) ->
                      if name <> "target" then (name, fields)
                      else
                        ( name,
                          match fields with
                          | `List (field :: rest) ->
                              `List
                                (replace_object_field "max_bytes"
                                   (fun _ -> `Int 0) field
                                :: rest)
                          | value -> value ))
                    shapes)
           | value -> value)
         fixture);
      ("invalid Boolean literal",
       replace_object_field "payload_shapes"
         (function
           | `Assoc shapes ->
               `Assoc
                 (List.map
                    (fun (name, fields) ->
                      if name <> "fallback" then (name, fields)
                      else
                        ( name,
                          match fields with
                          | `List (fallback :: boolean :: rest) ->
                              `List
                                (fallback
                                :: replace_object_field "value"
                                     (fun _ -> `String "false") boolean
                                :: rest)
                          | value -> value ))
                    shapes)
           | value -> value)
         fixture) ]
  in
  List.iter
    (fun (label, value) ->
      match validate_contract_fixture value with
      | Error _ -> ()
      | Ok () -> Alcotest.fail (label ^ " was accepted"))
    malformed

let stable_envelopes_and_codes () =
  let fixture = fixture "contracts.json" in
  (match validate_contract_fixture fixture with
  | Ok () -> ()
  | Error message -> Alcotest.failf "valid contract fixture rejected: %s" message);
  exact_keys "contract fixture keys"
    [ "schema_version"; "envelopes"; "exit_classes"; "payload_shapes";
      "context_extensions"; "contracts" ]
    fixture;
  Alcotest.(check int) "schema" 1 (int "schema_version" fixture);
  let envelopes = member "envelopes" fixture in
  exact_keys "envelope definitions" [ "success"; "failure" ] envelopes;
  Alcotest.(check (list string)) "success envelope"
    [ "ok"; "code"; "data" ] (member "success" envelopes |> strings);
  Alcotest.(check (list string)) "failure envelope"
    [ "ok"; "code"; "message"; "details" ]
    (member "failure" envelopes |> strings);
  let fixture_exits = member "exit_classes" fixture |> records in
  Alcotest.(check int) "all existing exits" (List.length exit_classes)
    (List.length fixture_exits);
  List.iter
    (fun value ->
      exact_keys "exit class fields" [ "name"; "code" ] value;
      let name = string "name" value in
      let expected = Clamp.Exit_class.code (exit_class name) in
      Alcotest.(check int) (name ^ " exit") expected (int "code" value))
    fixture_exits;
  let shapes = member "payload_shapes" fixture |> assoc in
  unique "unique payload shapes" (List.map fst shapes);
  List.iter
    (fun (shape, fields_json) ->
      let fields = records fields_json in
      let names = List.map (string "name") fields in
      unique (shape ^ " field names") names;
      List.iter
        (fun field ->
          exact_keys (shape ^ "." ^ string "name" field ^ " schema")
            (field_keys field) field;
          Alcotest.(check bool) (shape ^ " body-free field") false
            (List.mem (string "name" field)
               [ "body"; "content"; "document"; "message"; "origin_url";
                 "password"; "secret"; "stderr"; "stdout"; "token";
                 "helper_output" ]);
          ignore (payload_value field))
        fields)
    shapes;
  let extensions = member "context_extensions" fixture in
  exact_keys "context extensions"
    [ "sync_fallback"; "publication_sync_cause" ] extensions;
  let sync_extension = member "sync_fallback" extensions in
  exact_keys "sync fallback extension"
    [ "codes"; "required_shape"; "optional_field" ] sync_extension;
  Alcotest.(check string) "sync fallback shape" "fallback"
    (string "required_shape" sync_extension);
  let optional = member "optional_field" sync_extension in
  exact_keys "sync optional diagnostic"
    [ "name"; "type"; "max_items" ] optional;
  Alcotest.(check string) "diagnostic field" "diagnostics"
    (string "name" optional);
  Alcotest.(check int) "diagnostic bound" 1000 (int "max_items" optional);
  let publication_extension = member "publication_sync_cause" extensions in
  exact_keys "publication sync cause extension"
    [ "codes"; "top_level_codes"; "published"; "top_level_exit_class" ]
    publication_extension;
  Alcotest.(check (list string)) "publication top-level codes"
    [ "publish_complete_index_stale";
      "publish_complete_index_stale_cleanup_pending" ]
    (member "top_level_codes" publication_extension |> strings);
  Alcotest.(check bool) "publication remains durable" true
    (bool "published" publication_extension);
  Alcotest.(check string) "publication top-level exit" "stale_index"
    (string "top_level_exit_class" publication_extension);
  let contracts = member "contracts" fixture |> records in
  let codes = contract_codes contracts in
  unique "unique stable codes" codes;
  let selections = List.map (string "selection") contracts in
  unique "unique selection identifiers" selections;
  let categories =
    contracts |> List.map (string "category") |> List.sort_uniq String.compare
  in
  Alcotest.(check (list string)) "required categories"
    [ "amp_helper"; "preflight"; "runtime_metadata"; "scaffold";
      "service_credentials"; "setup"; "target" ]
    categories;
  let prd = read (path "PRD.md") in
  let code_pattern = Str.regexp "^[a-z][a-z0-9_]*$" in
  let documented_codes =
    (prd_contract_codes prd
    |> List.filter (fun code ->
           not
             (List.mem code
                [ "publish_complete_index_stale";
                  "publish_complete_index_stale_cleanup_pending" ])))
    @ [ "database_direct_url_missing"; "database_url_missing";
        "openrouter_api_key_missing" ]
    |> List.sort_uniq String.compare
  in
  Alcotest.(check (list string)) "PRD and fixture code sets"
    (List.sort String.compare codes) documented_codes;
  let allowed_scopes =
    [ "get"; "init"; "launcher"; "publish"; "scaffold_upgrade"; "search";
      "setup_local"; "sync"; "upgrade" ]
  in
  List.iter
    (fun value ->
      exact_keys "contract fields"
        [ "category"; "code"; "ok"; "exit_class"; "scopes"; "selection";
          "payload_shape" ]
        value;
      let code = string "code" value in
      Alcotest.(check bool) (code ^ " spelling") true
        (Str.string_match code_pattern code 0);
      Alcotest.(check bool) (code ^ " in PRD") true (contains prd code);
      let ok = bool "ok" value in
      let class_name = string "exit_class" value in
      let class_value = exit_class class_name in
      Alcotest.(check bool) (code ^ " success class") ok
        (class_value = Clamp.Exit_class.Success);
      let scopes = member "scopes" value |> strings in
      unique (code ^ " scopes") scopes;
      List.iter
        (fun scope ->
          Alcotest.(check bool) (code ^ " known scope " ^ scope) true
            (List.mem scope allowed_scopes))
        scopes;
      let shape_name = string "payload_shape" value in
      let fields =
        match List.assoc_opt shape_name shapes with
        | Some shape -> records shape
        | None -> Alcotest.failf "%s references unknown shape %s" code shape_name
      in
      let payload =
        `Assoc
          (List.map
             (fun field -> string "name" field, payload_value field)
             fields)
      in
      let result =
        if ok then Clamp.Cli_result.success ~code ~data:payload
        else
          Clamp.Cli_result.failure ~exit_class:class_value ~code
            ~message:"The operation did not complete." ~details:payload
      in
      let envelope = Clamp.Cli_result.to_yojson result in
      let keys = Yojson.Safe.Util.to_assoc envelope |> List.map fst in
      let expected_keys =
        if ok then [ "ok"; "code"; "data" ]
        else [ "ok"; "code"; "message"; "details" ]
      in
      Alcotest.(check (list string)) (code ^ " exact envelope") expected_keys keys;
      Alcotest.(check int) (code ^ " process exit")
        (Clamp.Exit_class.code class_value) (Clamp.Cli_result.exit_code result))
    contracts;
  let extension_codes = member "codes" sync_extension |> strings in
  unique "sync extension codes" extension_codes;
  let expected_sync_extension_codes =
    contracts
    |> List.filter (fun contract ->
           string "category" contract = "amp_helper"
           && List.mem "sync" (member "scopes" contract |> strings))
    |> List.map (string "code") |> List.sort String.compare
  in
  Alcotest.(check (list string)) "complete Sync fallback extension"
    expected_sync_extension_codes (List.sort String.compare extension_codes);
  List.iter
    (fun code ->
      let contract = List.find (fun value -> string "code" value = code) contracts in
      Alcotest.(check bool) (code ^ " has sync scope") true
        (List.mem "sync" (member "scopes" contract |> strings)))
    extension_codes;
  let publication_causes = member "codes" publication_extension |> strings in
  Alcotest.(check (list string)) "publication nested credential causes"
    [ "database_direct_url_missing"; "openrouter_api_key_missing" ]
    publication_causes;
  List.iter
    (fun code ->
      let contract = List.find (fun value -> string "code" value = code) contracts in
      Alcotest.(check bool) (code ^ " is not a publication top-level code") false
        (List.mem "publish" (member "scopes" contract |> strings)))
    publication_causes

let production_missing_credential_contracts () =
  let fixture = fixture "contracts.json" in
  let contracts = member "contracts" fixture |> records in
  let shapes = member "payload_shapes" fixture |> assoc in
  let check code result =
    let contract = List.find (fun value -> string "code" value = code) contracts in
    let expected_exit =
      string "exit_class" contract |> exit_class |> Clamp.Exit_class.code
    in
    let json = Clamp.Cli_result.to_yojson result in
    Alcotest.(check string) (code ^ " production code") code
      (string "code" json);
    Alcotest.(check int) (code ^ " production exit") expected_exit
      (Clamp.Cli_result.exit_code result);
    let details = member "details" json in
    let shape = string "payload_shape" contract in
    let expected_keys =
      List.assoc shape shapes |> records |> List.map (string "name")
      |> List.sort String.compare
    in
    Alcotest.(check (list string)) (code ^ " fixture payload") expected_keys
      (assoc details |> List.map fst |> List.sort String.compare);
    Alcotest.(check string) (code ^ " exact fallback")
      "local_markdown_or_rg" (string "fallback" details);
    Alcotest.(check bool) (code ^ " semantic non-equivalence") false
      (bool "semantic_equivalent" details)
  in
  check "database_url_missing"
    (Clamp.Retrieval.cli_result
       { kind = Clamp.Retrieval.Validation; code = "database_url_missing";
         message = "A pooled database URL is required." });
  check "database_direct_url_missing"
    (Clamp.Sync.fallback_error ~code:"database_direct_url_missing"
       ~message:"A direct database URL is required."
    |> Clamp.Sync.cli_result);
  check "openrouter_api_key_missing"
    (Clamp.Sync.fallback_error ~code:"openrouter_api_key_missing"
       ~message:"An OpenRouter key is required."
    |> Clamp.Sync.cli_result)

let scaffold_fixtures () =
  let fixture = fixture "scaffolds.json" in
  exact_keys "scaffold fixture keys"
    [ "schema_version"; "sanitized_initial_0_1_4_example";
      "migration_identity_0_1_4"; "owner_modified_0_1_x";
      "fresh_0_2_expected" ]
    fixture;
  Alcotest.(check int) "schema" 1 (int "schema_version" fixture);
  let exact = member "sanitized_initial_0_1_4_example" fixture in
  exact_keys "sanitized initial keys"
    [ "tag"; "tag_commit"; "source_repository"; "runtime_archive";
      "runtime_archive_sha256"; "runtime_lock_sha256"; "config_sha256";
      "empty_todo_sha256"; "empty_directories" ]
    exact;
  Alcotest.(check string) "exact tag" "v0.1.4" (string "tag" exact);
  Alcotest.(check string) "exact tag commit"
    "75b5c6a9ec63374b5953b8035768388055448738"
    (string "tag_commit" exact);
  Alcotest.(check string) "sanitized source" "local.test/clamp-fixture"
    (string "source_repository" exact);
  Alcotest.(check string) "published archive digest"
    "f4b9cfbb6736def71eb5c54acae955cfe19b1e03cf519aa4616cad5dd6a53841"
    (string "runtime_archive_sha256" exact);
  List.iter
    (fun key ->
      Alcotest.(check bool) (key ^ " digest") true
        (valid_sha256 (string key exact)))
    [ "runtime_archive_sha256"; "runtime_lock_sha256"; "config_sha256";
      "empty_todo_sha256" ];
  Alcotest.(check (list string)) "empty knowledge directories"
    [ "knowledge/decisions"; "knowledge/facts"; "knowledge/journal";
      "knowledge/people"; "knowledge/preferences"; "knowledge/projects";
      "knowledge/tasks" ]
    (member "empty_directories" exact |> strings);
  let migration = member "migration_identity_0_1_4" fixture in
  exact_keys "migration identity keys"
    [ "replaceable_scaffold"; "validated_runtime_pin";
      "preserved_owner_data"; "accepted_checkout_permissions" ]
    migration;
  let files = member "replaceable_scaffold" migration |> records in
  let file_paths = List.map (string "path") files in
  unique "exact scaffold paths" file_paths;
  let expected_files =
    [ (".agents/resume", "100755", "0700",
       "c2ffc1cf437ec9269c01c5e8e077667dd2e0a800",
       "4dbcaa05812ebd0ff016e3efbdf329c5466c9ee24edf62dc1c14b7a62a0bc5cb");
      (".agents/setup", "100755", "0700",
       "bd45c5a2f69e7e8039052a2f05f6dfb7958e69c3",
       "1155bfedbf08b8a76e185e5a324ac6b07270bf650a01da21dab014dfef1f345c");
      (".agents/skills/managing-clamp-knowledge/SKILL.md", "100644", "0600",
       "dbd957844d6b0f2ea36b7ced90e2971e6d3e32ac",
       "c18b36a55792ca8b8504aac6e083cc474df79f7f37140b55d3dde1e0c33af4a4");
      (".gitignore", "100644", "0600",
       "4eaf0a30c8317611d0077870daff24013d34b006",
       "3f542922e7680145916cfcf9e48a8eb149880630a90ec71bb59df19ae5d1c15d");
      ("AGENTS.md", "100644", "0600",
       "e1865c22f53de4744667f8992bd410d8cc8c49f8",
       "f0f09d96f49ae5a0479544abcb482aeefb8b35b32c36b8700b3b82c124fb421c");
      ("README.md", "100644", "0600",
       "ae2cf7581d9c073d8392470aa4bb80f74783c4a7",
       "fd5180900792a9592b0749102a5ce8c19063174d3192281323ae16c15c3468da") ]
  in
  Alcotest.(check (list string)) "exact static generated files"
    [ ".agents/resume"; ".agents/setup";
      ".agents/skills/managing-clamp-knowledge/SKILL.md"; ".gitignore";
      "AGENTS.md"; "README.md" ]
    file_paths;
  List.iter2
    (fun (path, git_mode, initializer_mode, blob, digest) value ->
      exact_keys (path ^ " fields")
        [ "path"; "git_mode"; "initializer_mode"; "git_blob_sha1"; "sha256" ]
        value;
      Alcotest.(check (list string)) (path ^ " exact identity")
        [ path; git_mode; initializer_mode; blob; digest ]
        [ string "path" value; string "git_mode" value;
          string "initializer_mode" value; string "git_blob_sha1" value;
          string "sha256" value ])
    expected_files files;
  let runtime_pin = member "validated_runtime_pin" migration in
  exact_keys "runtime pin keys"
    [ "path"; "accepted_format"; "replacement";
      "static_content_identity_required" ]
    runtime_pin;
  Alcotest.(check (list string)) "runtime pin semantics"
    [ ".agents/clamp-runtime.lock"; "v1-four-field"; "v2-lock" ]
    [ string "path" runtime_pin; string "accepted_format" runtime_pin;
      string "replacement" runtime_pin ];
  Alcotest.(check bool) "runtime lock is validated, not static" false
    (bool "static_content_identity_required" runtime_pin);
  Alcotest.(check (list string)) "owner data preserved"
    [ "clamp.yaml"; "TODO.md"; "knowledge/**" ]
    (member "preserved_owner_data" migration |> strings);
  let modified = member "owner_modified_0_1_x" fixture in
  exact_keys "owner-modified fixture keys"
    [ "base"; "changed_paths"; "mutation"; "replacement_sha256" ]
    modified;
  let modified_path =
    path "test/fixtures/v0_2_phase1/owner-modified-AGENTS.md"
  in
  Alcotest.(check string) "owner-modified digest"
    (string "replacement_sha256" modified) (sha256 (read modified_path));
  let original_agents =
    files |> List.find (fun value -> string "path" value = "AGENTS.md")
    |> string "sha256"
  in
  Alcotest.(check string) "owner-modified base" "migration_identity_0_1_4"
    (string "base" modified);
  Alcotest.(check (list string)) "only AGENTS modified" [ "AGENTS.md" ]
    (member "changed_paths" modified |> strings);
  Alcotest.(check string) "exact owner mutation"
    "append LF, '# Owner customization', LF" (string "mutation" modified);
  Alcotest.(check bool) "owner modification differs" false
    (original_agents = string "replacement_sha256" modified);
  let fresh = member "fresh_0_2_expected" fixture in
  exact_keys "fresh scaffold keys"
    [ "source_repository"; "required_files"; "forbidden_top_level";
      "runtime_lock_version"; "initial_commits"; "initial_branch";
      "remote_present" ]
    fresh;
  let required = member "required_files" fresh |> strings in
  unique "fresh scaffold paths" required;
  Alcotest.(check (list string)) "exact future scaffold"
    [ ".agents/clamp-runtime.lock"; ".agents/clamp-scaffold.json"; ".agents/kb";
      ".agents/resume"; ".agents/setup"; ".agents/setup-local";
      ".agents/skills/managing-clamp-knowledge/SKILL.md"; ".gitignore";
      "AGENTS.md"; "README.md"; "TODO.md"; "clamp.yaml" ]
    required;
  let forbidden = member "forbidden_top_level" fresh |> strings in
  Alcotest.(check (list string)) "exact source exclusions"
    [ "_build"; "_opam"; "bin"; "db"; "dune"; "dune-project"; "lib";
      "test" ]
    forbidden;
  List.iter
    (fun forbidden_path ->
      Alcotest.(check bool) ("future inventory excludes " ^ forbidden_path) false
        (List.mem forbidden_path required))
    forbidden;
  Alcotest.(check int) "v2 lock" 2 (int "runtime_lock_version" fresh);
  Alcotest.(check int) "one initial commit" 1 (int "initial_commits" fresh);
  Alcotest.(check string) "initial branch" "main" (string "initial_branch" fresh);
  Alcotest.(check bool) "no initial remote" false (bool "remote_present" fresh)

let target_and_environment_fixtures () =
  let environment_fixture = fixture "environments.json" in
  exact_keys "environment fixture keys"
    [ "schema_version"; "auth_contexts"; "release_targets";
      "local_configuration_cases"; "runtime_metadata_cases";
      "capability_gates"; "macos_native_observations";
      "compatibility_gates" ]
    environment_fixture;
  Alcotest.(check int) "schema" 1
    (int "schema_version" environment_fixture);
  let serialized = Yojson.Safe.to_string environment_fixture in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool) ("sanitized: " ^ forbidden) false
        (contains serialized forbidden))
    [ "postgresql://"; "sk-or-"; "password="; "PRIVATE KEY" ];
  let auth = member "auth_contexts" environment_fixture |> records in
  Alcotest.(check (list string)) "auth fixtures"
    [ "orb_v1"; "local_linux_direct_install"; "local_macos_arm64" ]
    (List.map (string "name") auth);
  List.iter
    (fun value ->
      Alcotest.(check bool) (string "name" value ^ " stores no secret") false
        (bool "persisted_secret" value))
    auth;
  let mac_auth =
    List.find (fun value -> string "name" value = "local_macos_arm64") auth
  in
  Alcotest.(check string) "Mac aggregate state"
    "candidate_pending_ordinary_update" (string "state" mac_auth);
  Alcotest.(check string) "Mac read-only clone qualification"
    "passed_user_skills_read_only"
    (string "amp_clone_existing_project" mac_auth);
  Alcotest.(check string) "Mac helper is reconstructed explicitly"
    "!amp git-credential-helper" (string "clone_effective_helper_shape" mac_auth);
  Alcotest.(check string) "Mac qualified absolute helper"
    "!$HOME/.amp/bin/amp git-credential-helper"
    (string "qualified_explicit_helper_shape" mac_auth);
  Alcotest.(check bool) "Mac helper does not use HTTP path" false
    (bool "clone_use_http_path" mac_auth);
  Alcotest.(check bool) "Mac clone writes no author" false
    (bool "clone_writes_repository_author" mac_auth);
  Alcotest.(check (list string)) "Mac helper environment allowlist"
    [ "HOME"; "PATH"; "GIT_CONFIG_NOSYSTEM"; "GIT_CONFIG_GLOBAL";
      "GIT_TERMINAL_PROMPT" ]
    (member "credential_environment_allowlist" mac_auth |> strings);
  Alcotest.(check string) "Mac ordinary update remains pending"
    "pending_no_authoritative_prior_executable_identity"
    (string "ordinary_update_state" mac_auth);
  let targets = member "release_targets" environment_fixture |> records in
  Alcotest.(check (list string)) "exact target set"
    [ "linux-x86_64"; "macos-arm64" ] (List.map (string "target") targets);
  let linux =
    List.find (fun value -> string "target" value = "linux-x86_64") targets
  and mac =
    List.find (fun value -> string "target" value = "macos-arm64") targets
  in
  Alcotest.(check string) "Linux candidate" "candidate" (string "state" linux);
  Alcotest.(check string) "Linux minimum" "Linux with glibc 2.36"
    (string "minimum_os" linux);
  Alcotest.(check (list string)) "Linux ext4 only" [ "ext4" ]
    (member "filesystems" linux |> strings);
  Alcotest.(check (list string)) "Linux prerequisite closure"
    [ "bash>=5.2"; "git>=2.39"; "curl>=7.88.1"; "python3>=3.11";
      "gnu-tar>=1.34"; "sha256sum>=9.1"; "rg>=14.1" ]
    (member "bootstrap" linux |> strings);
  Alcotest.(check string) "macOS candidate" "candidate"
    (string "state" mac);
  Alcotest.(check string) "macOS conservative minimum" "macOS 26.5.2"
    (string "minimum_os" mac);
  Alcotest.(check (list string)) "macOS APFS qualification"
    [ "local writable case-insensitive APFS" ]
    (member "filesystems" mac |> strings);
  Alcotest.(check (list string)) "macOS consumer bootstrap closure"
    [ "bash>=3.2.57-without-mapfile-or-associative-arrays";
      "git>=2.50.1-Apple-Git-155"; "curl>=8.7.1";
      "python3>=3.9.6-strict-json-wrapper";
      "bsdtar>=3.5.3-libarchive>=3.7.4"; "shasum>=6.02";
      "rg>=14.1.1" ]
    (member "bootstrap" mac |> strings);
  let contracts = fixture "contracts.json" |> member "contracts" |> records in
  let codes = contract_codes contracts in
  let cases =
    (member "local_configuration_cases" environment_fixture |> records)
    @ (member "runtime_metadata_cases" environment_fixture |> records)
  in
  List.iter
    (fun value ->
      let expected = string "expected_code" value in
      Alcotest.(check bool) (string "name" value ^ " code exists") true
        (List.mem expected codes))
    cases;
  let capabilities = member "capability_gates" environment_fixture |> records in
  let capability name target =
    capabilities
    |> List.find (fun value -> string "capability" value = name)
    |> string target
  in
  Alcotest.(check int) "exact capability gate count" 3
    (List.length capabilities);
  Alcotest.(check (list string)) "exact capability names"
    [ "authenticated_current_thread_identity"; "current_thread_owner_email";
      "disposable_postgresql_pgvector" ]
    (List.map (string "capability") capabilities);
  List.iter
    (fun name ->
      Alcotest.(check string) (name ^ " Linux pending")
        "pending_non_orb_runner" (capability name "linux"))
    [ "authenticated_current_thread_identity"; "current_thread_owner_email";
      "disposable_postgresql_pgvector" ];
  Alcotest.(check string) "Mac identity interface passed"
    "passed_authenticated_local_runner_context"
    (capability "authenticated_current_thread_identity" "macos");
  Alcotest.(check string) "Mac owner email interface passed"
    "passed_owner_bound_interface_no_delivery_attempt"
    (capability "current_thread_owner_email" "macos");
  Alcotest.(check string) "Mac database feasibility passed"
    "passed_postgresql_15_19_pgvector_0_8_1"
    (capability "disposable_postgresql_pgvector" "macos");
  let native = member "macos_native_observations" environment_fixture in
  exact_keys "macOS native observation keys"
    [ "os"; "architecture"; "translated"; "apfs_primitives";
      "database_harness"; "migrations_applied"; "tool_observations";
      "ripgrep_archive_sha256"; "ripgrep_runtime_dependency";
      "runtime_build_state"; "ripgrep_state" ]
    native;
  Alcotest.(check string) "exact observed macOS" "macOS 26.5.2 build 25F84"
    (string "os" native);
  Alcotest.(check string) "native architecture" "arm64"
    (string "architecture" native);
  Alcotest.(check bool) "native execution" false (bool "translated" native);
  Alcotest.(check (list string)) "required APFS primitives"
    [ "directory_fsync"; "file_fullfsync"; "flock"; "hard_link_identity";
      "nofollow"; "retained_descriptor"; "descriptor_relative_unlink";
      "rename_exclusive"; "rename_exchange"; "exchange_rollback" ]
    (member "apfs_primitives" native |> strings);
  Alcotest.(check string) "disposable database harness"
    "private_unix_socket_postgresql_15_19_pgvector_0_8_1"
    (string "database_harness" native);
  Alcotest.(check (list string)) "migrations exercised"
    [ "0001_enable_vector.sql"; "0002_application_schema.sql" ]
    (member "migrations_applied" native |> strings);
  Alcotest.(check (list string)) "native tool observations"
    [ "bash=3.2.57-no-mapfile-or-associative-arrays";
      "git=2.50.1-Apple-Git-155"; "curl=8.7.1";
      "python3=3.9.6-strict-wrapper-passed";
      "bsdtar=3.5.3-libarchive=3.7.4"; "shasum=6.02";
      "rg=14.1.1-arm64" ]
    (member "tool_observations" native |> strings);
  Alcotest.(check string) "ripgrep archive identity"
    "24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be"
    (string "ripgrep_archive_sha256" native);
  Alcotest.(check string) "ripgrep is qualified"
    "qualified_disposable_official_archive"
    (string "ripgrep_state" native);
  let compatibility = member "compatibility_gates" environment_fixture |> records in
  Alcotest.(check int) "one compatibility protocol" 1
    (List.length compatibility);
  let proxy_gate = List.hd compatibility in
  exact_keys "legacy compatibility protocol"
    [ "name"; "state"; "proxy_private_ca_result"; "proxy_connections";
      "proxy_requests"; "alternative"; "qualified_with_version";
      "qualified_archive_sha256"; "qualified_result_code" ]
    proxy_gate;
  Alcotest.(check string) "immutable compatibility protocol"
    "immutable_0_1_4_prepublication" (string "name" proxy_gate);
  Alcotest.(check string) "proxy/CA result"
    "failed_ca_override_after_proxy_connect"
    (string "proxy_private_ca_result" proxy_gate);
  Alcotest.(check (list string)) "proxy was used"
    [ "github.com:443" ] (member "proxy_connections" proxy_gate |> strings);
  Alcotest.(check (list string)) "private CA failed before HTTP" []
    (member "proxy_requests" proxy_gate |> strings);
  Alcotest.(check string) "offline mechanism qualified"
    "offline_initializer_qualified" (string "state" proxy_gate);
  Alcotest.(check string) "immutable initializer result"
    "repository_initialized" (string "qualified_result_code" proxy_gate);
  Alcotest.(check string) "qualified archive identity"
    "f4b9cfbb6736def71eb5c54acae955cfe19b1e03cf519aa4616cad5dd6a53841"
    (string "qualified_archive_sha256" proxy_gate)

let () =
  Alcotest.run "Clamp 0.2 Phase 1"
    [ ( "contract freeze",
        [ Alcotest.test_case "stable envelopes and codes" `Quick
            stable_envelopes_and_codes;
          Alcotest.test_case "malformed fixture schema is rejected" `Quick
            contract_fixture_rejects_malformed_schema;
          Alcotest.test_case "production missing-credential adapters" `Quick
            production_missing_credential_contracts;
          Alcotest.test_case "scaffold fixtures" `Quick scaffold_fixtures;
          Alcotest.test_case "target and environment fixtures" `Quick
            target_and_environment_fixtures ] ) ]
