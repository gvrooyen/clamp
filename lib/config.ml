open Exact_yaml

let fields = function Map values -> Some values | _ -> None
let find_field key values = List.assoc_opt key values
let keys_equal expected values =
  List.sort String.compare expected
  = List.sort String.compare (List.map fst values)

let string = function Scalar (String, value) -> Some value | _ -> None
let integer = function Scalar (Integer, value) -> int_of_string_opt value | _ -> None
let number = function
  | Scalar ((Integer | Float), value) -> float_of_string_opt value
  | _ -> None

let default_human_authority = "human:owner"

let valid_human_authority value =
  let prefix_length = String.length "human:" in
  String.length value > prefix_length && String.length value <= 255
  && String.starts_with ~prefix:"human:" value
  && String.sub value prefix_length (String.length value - prefix_length)
     |> String.for_all (function
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '@' -> true
          | _ -> false)

type retrieval = {
  candidate_limit : int;
  result_limit : int;
  semantic_weight : float;
  recency_weight : float;
  frequency_weight : float;
  recency_half_life_days : int;
  frequency_saturation_count : int;
}

let maximum_candidate_limit = 1000
let maximum_result_limit = 100
let maximum_recency_half_life_days = 3650
let maximum_frequency_saturation_count = 1_000_000

let valid_source_repository value =
  let value_length = String.length value in
  let valid_host host =
    let valid_label label =
      label <> "" && String.length label <= 63
      && not (String.starts_with ~prefix:"-" label)
      && not (String.ends_with ~suffix:"-" label)
      && String.for_all
           (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
           label
    in
    host <> "" && String.length host <= 253 && String.contains host '.'
    && List.for_all valid_label (String.split_on_char '.' host)
  in
  match String.index_opt value '/' with
  | None -> false
  | Some slash ->
      let host = String.sub value 0 slash in
      let path = String.sub value (slash + 1) (value_length - slash - 1) in
      valid_host host && path <> "" && not (String.ends_with ~suffix:"/" path)
      && not (String.ends_with ~suffix:".git" path)
      && not (String.contains value '?') && not (String.contains value '#')
      && not (String.contains value ':')
      && String.trim value = value
      && List.for_all
           (fun component ->
             component <> "" && component <> "." && component <> ".."
             && String.for_all
                  (function
                    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '@' -> true
                    | _ -> false)
                  component)
           (String.split_on_char '/' path)

let parse contents =
  match Exact_yaml.parse contents with
  | Ok (Map values) -> Ok values
  | Ok _ -> Error "configuration must be a mapping"
  | Error _ -> Error "configuration contains malformed or unsupported YAML"

let validate contents =
      match parse contents with
      | Error _ as error -> error
      | Ok top ->
              let required_top_keys =
                [ "schema_version"; "source_repository"; "timezone";
                  "inferred_writes"; "embedding"; "retrieval" ]
              in
              let allowed_top_keys = "human_authority" :: required_top_keys in
              if
                not
                  (List.for_all
                     (fun key -> Option.is_some (find_field key top))
                     required_top_keys
                  && List.for_all
                       (fun (key, _) -> List.mem key allowed_top_keys)
                       top)
              then
                Error "configuration has missing or unknown keys"
              else if find_field "schema_version" top <> Some (Scalar (Integer, "1")) then
                Error "schema_version must be integer 1"
              else if Option.bind (find_field "timezone" top) string
                      <> Some "Africa/Johannesburg" then
                Error "timezone must be Africa/Johannesburg"
              else if
                not
                  (Option.exists valid_source_repository
                     (Option.bind (find_field "source_repository" top) string))
              then Error "source_repository is missing or invalid"
              else if
                not
                  (List.mem
                     (Option.bind (find_field "inferred_writes" top) string)
                     [ Some "confirm"; Some "auto_draft" ])
              then Error "inferred_writes must be confirm or auto_draft"
              else if
                not
                  (match find_field "human_authority" top with
                  | None -> true
                  | Some value ->
                      Option.exists valid_human_authority (string value))
              then Error "human_authority must be a nonempty human: identifier"
              else
                match
                  ( Option.bind (find_field "embedding" top) fields,
                    Option.bind (find_field "retrieval" top) fields )
                with
                | Some embedding, Some retrieval ->
                    let embedding_keys =
                      [ "provider"; "base_url"; "model"; "dimensions";
                        "max_input_bytes"; "provider_order"; "allow_fallbacks";
                        "data_collection" ]
                    in
                    let retrieval_keys =
                      [ "candidate_limit"; "result_limit"; "semantic_weight";
                        "recency_weight"; "frequency_weight";
                        "recency_half_life_days"; "frequency_saturation_count" ]
                    in
                    if
                      not
                        (keys_equal embedding_keys embedding
                        && keys_equal retrieval_keys retrieval)
                    then Error "embedding or retrieval has missing or unknown keys"
                    else
                      let exact =
                        [ ("provider", Scalar (String, "openrouter"));
                          ("base_url", Scalar (String, "https://openrouter.ai/api/v1"));
                          ("model", Scalar (String, "openai/text-embedding-3-small"));
                          ("dimensions", Scalar (Integer, "1536"));
                          ("max_input_bytes", Scalar (Integer, "8000"));
                          ("provider_order", Seq [ Scalar (String, "openai") ]);
                          ("allow_fallbacks", Scalar (Bool, "false"));
                          ("data_collection", Scalar (String, "deny")) ]
                      in
                      if
                        List.exists
                          (fun (key, value) -> find_field key embedding <> Some value)
                          exact
                      then Error "embedding configuration is incompatible with v1"
                      else
                        let positive key =
                          match Option.bind (find_field key retrieval) integer with
                          | Some value -> value > 0
                          | None -> false
                        in
                        let integer_keys =
                          [ "candidate_limit"; "result_limit";
                            "recency_half_life_days";
                            "frequency_saturation_count" ]
                        in
                        if not (List.for_all positive integer_keys) then
                          Error "retrieval counts and half-life must be positive integers"
                        else
                          let candidate =
                            Option.get
                              (Option.bind (find_field "candidate_limit" retrieval) integer)
                          and result =
                            Option.get
                              (Option.bind (find_field "result_limit" retrieval) integer)
                          in
                          let half_life =
                            Option.get
                              (Option.bind
                                 (find_field "recency_half_life_days" retrieval)
                                 integer)
                          and saturation =
                            Option.get
                              (Option.bind
                                 (find_field "frequency_saturation_count" retrieval)
                                 integer)
                          in
                          if candidate > maximum_candidate_limit then
                            Error "candidate_limit exceeds the v1 maximum"
                          else if result > maximum_result_limit then
                            Error "result_limit exceeds the v1 maximum"
                          else if half_life > maximum_recency_half_life_days then
                            Error "recency_half_life_days exceeds the v1 maximum"
                          else if saturation > maximum_frequency_saturation_count then
                            Error "frequency_saturation_count exceeds the v1 maximum"
                          else if result > candidate then
                            Error "result_limit must not exceed candidate_limit"
                          else
                            let weights =
                              [ "semantic_weight"; "recency_weight";
                                "frequency_weight" ]
                              |> List.map (fun key ->
                                     Option.bind (find_field key retrieval) number)
                            in
                            (match weights with
                            | [ Some semantic; Some recency; Some frequency ]
                              when List.for_all
                                     (fun value -> Float.is_finite value && value >= 0.)
                                     [ semantic; recency; frequency ]
                                   && Float.abs
                                        (semantic +. recency +. frequency -. 1.)
                                      < 1e-9 ->
                                Ok ()
                            | _ ->
                                Error
                                  "retrieval weights must be finite, nonnegative, and sum to 1")
                | _ -> Error "embedding and retrieval must be mappings"

let source_repository contents =
  Result.bind (parse contents) (fun top ->
      match Option.bind (find_field "source_repository" top) string with
      | None -> Error "source_repository_missing"
      | Some value when valid_source_repository value -> Ok value
      | Some _ -> Error "source_repository_invalid")

let human_authority contents =
  Result.bind (validate contents) (fun () ->
      Result.bind (parse contents) (fun top ->
          match Option.bind (find_field "human_authority" top) string with
          | None -> Ok default_human_authority
          | Some value -> Ok value))

let retrieval contents =
  Result.bind (validate contents) (fun () ->
      Result.bind (parse contents) (fun top ->
          match Option.bind (find_field "retrieval" top) fields with
          | None -> Error "retrieval_invalid"
          | Some values ->
              try
                let integer_value key =
                  Option.get (Option.bind (find_field key values) integer)
                and number_value key =
                  Option.get (Option.bind (find_field key values) number)
                in
                Ok
                  { candidate_limit = integer_value "candidate_limit";
                    result_limit = integer_value "result_limit";
                    semantic_weight = number_value "semantic_weight";
                    recency_weight = number_value "recency_weight";
                    frequency_weight = number_value "frequency_weight";
                    recency_half_life_days = integer_value "recency_half_life_days";
                    frequency_saturation_count =
                      integer_value "frequency_saturation_count" }
              with _ -> Error "retrieval_invalid"))

let load_at directory name =
  try
    let kind, expected = Secure_fs.inspect directory name in
    if kind <> Secure_fs.Regular then Error (Safe_file.message Safe_file.Not_regular)
    else
      Result.bind
        (Secure_fs.open_file_at directory name
        |> Safe_file.read_descriptor ~expected
        |> Result.map_error Safe_file.message)
        validate
  with Unix.Unix_error _ | Sys_error _ ->
    Error (Safe_file.message Safe_file.Missing_or_unreadable)

let load path =
  try
    let directory = Secure_fs.open_directory (Filename.dirname path) in
    Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
        load_at directory (Filename.basename path))
  with Unix.Unix_error _ | Sys_error _ ->
    Error (Safe_file.message Safe_file.Missing_or_unreadable)

let load_source_repository path =
  try
    let directory = Secure_fs.open_directory (Filename.dirname path) in
    Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
        let name = Filename.basename path in
        let kind, expected = Secure_fs.inspect directory name in
        if kind <> Secure_fs.Regular then Error "source_repository_missing"
        else
          Secure_fs.open_file_at directory name
          |> Safe_file.read_descriptor ~expected
          |> Result.map_error (fun _ -> "source_repository_missing")
          |> fun result -> Result.bind result source_repository)
  with Unix.Unix_error _ | Sys_error _ -> Error "source_repository_missing"
