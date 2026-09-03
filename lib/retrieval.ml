type history = {
  include_deprecated : bool;
  include_stale : bool;
  include_closed_tasks : bool;
}

let normal_history =
  { include_deprecated = false; include_stale = false;
    include_closed_tasks = false }

type error_kind = Validation | Authentication | Transient | Stale | Internal
type error = { kind : error_kind; code : string; message : string }

type result = {
  id : string;
  concept_type : string;
  title : string option;
  description : string option;
  status : string;
  verified_tier : string;
  asserted_by : string option;
  task_state : string option;
  semantic : float;
  recency : float;
  frequency : float;
  score : float;
  snippet : string;
}

type concept = {
  id : string;
  concept_type : string;
  title : string option;
  description : string option;
  status : string;
  verified_tier : string;
  asserted_by : string option;
  task_state : string option;
  frontmatter : string;
  body : string;
  document : string;
  json_output : string;
}

let error kind code message = Error { kind; code; message }
let ( let* ) = Result.bind

let exit_class error =
  match error.kind with
  | Validation -> Exit_class.User_error
  | Authentication -> Exit_class.Authentication
  | Transient -> Exit_class.Transient_external
  | Stale -> Exit_class.Stale_index
  | Internal -> Exit_class.Internal

type operation = Search | Get

let database_error ?operation (failure : Database.error) =
  if failure.code = "database_commit_deadline_expired" then
    { kind = Transient; code = "retrieval_validation_timeout";
      message =
        "Retrieval validation expired before commit dispatch; use local Markdown or rg." }
  else if failure.code = "database_connection_lost"
          && failure.finalization = Database.After_commit_dispatch then
    { kind = Transient; code = failure.code;
      message =
        (match operation with
        | Some Get ->
            "Database connection was lost after access telemetry commit was dispatched; access telemetry may or may not have committed. Do not retry blindly because access could be counted twice."
        | Some Search ->
            "Database connection was lost after the search transaction commit was dispatched; transaction acknowledgement is uncertain. Search did not update access telemetry."
        | None -> failure.message) }
  else
    let kind =
      if List.mem failure.code [ "index_missing"; "index_stale";
                                 "index_incompatible" ] then Stale
      else
        match failure.kind with
        | Database.Authentication -> Authentication
        | Transient | Timeout -> Transient
        | Validation | Sql -> Validation
        | Internal -> Internal
    in
    { kind; code = failure.code; message = failure.message }

let db result = Result.map_error database_error result

let semantic similarity = Float.max 0. (Float.min 1. ((similarity +. 1.) /. 2.))

let recency ~now timestamp =
  match timestamp with
  | None -> 0.
  | Some timestamp ->
      let age_days = Float.max 0. ((now -. timestamp) /. 86400.) in
      2. ** (-.age_days /. 30.)

let frequency accesses =
  let accesses = Int64.max 0L accesses in
  Float.min 1. (log (1. +. Int64.to_float accesses) /. log 101.)

let score ~semantic ~recency ~frequency =
  (0.70 *. semantic) +. (0.20 *. recency) +. (0.10 *. frequency)

let timestamp ~last_accessed ~generated ~indexed =
  match last_accessed, generated with
  | Some value, _ -> value
  | None, Some value -> value
  | None, None -> indexed

let snippet_length = 240
let truncation_marker = "…"

let snippet body =
  let normalized = Buffer.create (String.length body) in
  let space = ref true in
  String.iter
    (fun character ->
      if Char.code character <= 0x20 then begin
        if not !space then Buffer.add_char normalized ' ';
        space := true
      end else begin
        Buffer.add_char normalized character;
        space := false
      end)
    body;
  let value = String.trim (Buffer.contents normalized) in
  if String.length value <= snippet_length then value
  else
    let limit = snippet_length - String.length truncation_marker in
    let cut = ref limit in
    while !cut > 0 && Char.code value.[!cut] land 0xC0 = 0x80 do decr cut done;
    String.sub value 0 !cut ^ truncation_marker

let visible ~history ~today ~status ~stale_after ~task_state =
  (history.include_deprecated || status <> "deprecated")
  && (history.include_stale
      || Option.for_all (fun stale_after -> today < stale_after) stale_after)
  && (history.include_closed_tasks
      || not (List.mem task_state [ Some "done"; Some "cancelled" ]))

let nullable row column = if row#getisnull 0 column then None else Some (row#getvalue 0 column)
let nullable_at rows index column =
  if rows#getisnull index column then None else Some (rows#getvalue index column)

let execute connection ?params sql =
  db
    (Database.For_retrieval.transaction connection ~statement_timeout_ms:5000
       (fun connection ->
         Database.For_retrieval.execute connection
           ~expect:[ Postgresql.Tuples_ok ] ?params sql))

let state_sql =
  "SELECT source_repository,source_ref,last_indexed_commit,embedding_model,embedding_dimensions FROM public.index_state WHERE id=1"

let validate_state state ~source ~local_commit =
  if state#ntuples = 0 then
    error Stale "index_missing"
      "The derived retrieval index has no checkpoint; use local Markdown or rg until synchronization succeeds."
  else if state#ntuples <> 1 then
    error Internal "index_state_invalid" "The retrieval checkpoint is invalid."
  else
    let indexed_commit = nullable state 2 in
    if state#getvalue 0 0 <> source
       || state#getvalue 0 1 <> "refs/heads/main"
       || state#getvalue 0 3 <> Openrouter.canonical_identity
       || state#getvalue 0 4 <> string_of_int Openrouter.dimensions then
      error Stale "index_incompatible"
        "The derived retrieval index is incompatible; use local Markdown or rg until synchronization succeeds."
    else if indexed_commit <> Some local_commit then
      error Stale "index_stale"
        "The derived retrieval index is stale; use local Markdown or rg until synchronization succeeds."
    else Ok ()

let index_preflight connection ~source ~local_commit =
  let* relations =
    execute connection
      "SELECT pg_catalog.to_regclass('public.concepts') IS NOT NULL, pg_catalog.to_regclass('public.index_state') IS NOT NULL"
  in
  if relations#ntuples <> 1 || relations#getvalue 0 0 <> "t"
     || relations#getvalue 0 1 <> "t" then
    error Stale "index_missing"
      "The derived retrieval index is missing; use local Markdown or rg until synchronization succeeds."
  else
    let* state = execute connection state_sql in
    validate_state state ~source ~local_commit

let vector_literal values =
  let buffer = Buffer.create (Array.length values * 4) in
  Buffer.add_char buffer '[';
  Array.iteri
    (fun index value ->
      if index > 0 then Buffer.add_char buffer ',';
      Buffer.add_string buffer (Printf.sprintf "%.17g" value))
    values;
  Buffer.add_char buffer ']';
  Buffer.contents buffer

let bool value = if value then "true" else "false"

let rec yaml_of_raw = function
  | `Null -> Ok (Exact_yaml.Scalar (Null, "null"))
  | `Bool value -> Ok (Exact_yaml.Scalar (Bool, string_of_bool value))
  | `Intlit value -> Ok (Exact_yaml.Scalar (Integer, value))
  | `Floatlit value -> Ok (Exact_yaml.Scalar (Float, value))
  | `Stringlit literal ->
      (match Yojson.Safe.from_string literal with
      | `String value -> Ok (Exact_yaml.Scalar (String, value))
      | _ -> Error ())
  | `List values ->
      List.fold_left
        (fun result value ->
          Result.bind result (fun values ->
              Result.map (fun value -> value :: values) (yaml_of_raw value)))
        (Ok []) values
      |> Result.map (fun values -> Exact_yaml.Seq (List.rev values))
  | `Assoc fields ->
      List.fold_left
        (fun result (key, value) ->
          Result.bind result (fun fields ->
              Result.map (fun value -> (key, value) :: fields) (yaml_of_raw value)))
        (Ok []) fields
      |> Result.map (fun fields -> Exact_yaml.Map (List.rev fields))

let days_from_civil year month day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let year_of_era = year - (era * 400) in
  let shifted_month = month + if month > 2 then -3 else 9 in
  let day_of_year = ((153 * shifted_month) + 2) / 5 + day - 1 in
  let day_of_era =
    (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100)
    + day_of_year
  in
  (era * 146097) + day_of_era - 719468

let rfc3339_microseconds value =
  if not (Concept.rfc3339 value) then None
  else
    try
      let number offset count = int_of_string (String.sub value offset count) in
      let zone =
        let rec find index =
          match value.[index] with
          | 'Z' | 'z' | '+' | '-' -> index
          | _ -> find (index + 1)
        in
        find 19
      in
      let fraction =
        if zone = 19 then 0
        else
          let digits = String.sub value 20 (zone - 20) in
          let padded = digits ^ String.make 6 '0' in
          let micros = int_of_string (String.sub padded 0 6) in
          if String.length digits <= 6 then micros
          else
            let first_discarded = digits.[6] in
            let later_nonzero =
              String.length digits > 7
              && String.exists (fun digit -> digit <> '0')
                   (String.sub digits 7 (String.length digits - 7))
            in
            if first_discarded > '5'
               || (first_discarded = '5' && (later_nonzero || micros mod 2 = 1))
            then micros + 1
            else micros
      in
      let offset =
        match value.[zone] with
        | 'Z' | 'z' -> 0
        | sign ->
            let seconds = (number (zone + 1) 2 * 3600) + (number (zone + 4) 2 * 60) in
            if sign = '+' then seconds else -seconds
      in
      let days = days_from_civil (number 0 4) (number 5 2) (number 8 2) in
      let seconds =
        (days * 86400) + (number 11 2 * 3600) + (number 14 2 * 60)
        + number 17 2 - offset
      in
      Some
        (Int64.add (Int64.mul (Int64.of_int seconds) 1_000_000L)
           (Int64.of_int fraction))
    with _ -> None

let epoch_microseconds value =
  try
    let negative = String.starts_with ~prefix:"-" value in
    let unsigned = if negative then String.sub value 1 (String.length value - 1) else value in
    let whole, fraction =
      match String.index_opt unsigned '.' with
      | None -> (unsigned, "")
      | Some point ->
          (String.sub unsigned 0 point,
           String.sub unsigned (point + 1) (String.length unsigned - point - 1))
    in
    if whole = "" || String.length fraction > 6
       || not (String.for_all (function '0' .. '9' -> true | _ -> false) whole)
       || not (String.for_all (function '0' .. '9' -> true | _ -> false) fraction)
    then None
    else
      let fraction = fraction ^ String.make (6 - String.length fraction) '0' in
      let result =
        Int64.(add (mul (of_string whole) 1_000_000L) (of_string fraction))
      in
      Some (if negative then Int64.neg result else result)
  with _ -> None

let same_timestamp expected actual =
  match expected, actual with
  | None, None -> true
  | Some expected, Some actual ->
      rfc3339_microseconds expected = epoch_microseconds actual
  | _ -> false

let projection_matches
    ({ Concept.concept_type = expected_type; title = expected_title;
       description = expected_description; tags = expected_tags;
       status = expected_status; stale_after = expected_stale_after;
       generated_by = expected_generated_by; generated_at = expected_generated_at;
       asserted_by = expected_asserted_by; verified_tier = expected_verified_tier;
       task_state = expected_task_state; task_priority = expected_task_priority;
       task_due_on = expected_task_due_on; task_due_at = expected_task_due_at;
       task_completed_at = expected_task_completed_at } : Concept.index_projection)
    ({ Concept.concept_type = actual_type; title = actual_title;
       description = actual_description; tags = actual_tags;
       status = actual_status; stale_after = actual_stale_after;
       generated_by = actual_generated_by; generated_at = actual_generated_at;
       asserted_by = actual_asserted_by; verified_tier = actual_verified_tier;
       task_state = actual_task_state; task_priority = actual_task_priority;
       task_due_on = actual_task_due_on; task_due_at = actual_task_due_at;
       task_completed_at = actual_task_completed_at } : Concept.index_projection) =
  expected_type = actual_type
  && expected_title = actual_title
  && expected_description = actual_description
  && expected_tags = actual_tags
  && expected_status = actual_status
  && expected_stale_after = actual_stale_after
  && expected_generated_by = actual_generated_by
  && same_timestamp expected_generated_at actual_generated_at
  && expected_asserted_by = actual_asserted_by
  && expected_verified_tier = actual_verified_tier
  && expected_task_state = actual_task_state
  && expected_task_priority = actual_task_priority
  && expected_task_due_on = actual_task_due_on
  && same_timestamp expected_task_due_at actual_task_due_at
  && same_timestamp expected_task_completed_at actual_task_completed_at

let valid_indexed_row ~id ~actual ~metadata ~body =
  if String.length body > Limits.max_file_bytes
     || not (Concept.concept_id id) || Concept.validate metadata <> [] then false
  else
    match Embedding_input.make { Frontmatter.metadata; body } with
    | Error _ -> false
    | Ok _ ->
        projection_matches (Concept.index_projection metadata) actual

let indexed_metadata value =
  if String.length value > Limits.max_file_bytes then None
  else
    let raw = Yojson.Raw.from_string value in
    match raw, yaml_of_raw raw with
    | `Assoc _, Ok (Exact_yaml.Map _ as metadata) -> Some (raw, metadata)
    | _ -> None

let validation_total_bytes = 16 * 1024 * 1024
let validation_row_bytes = 9 * 1024 * 1024
let validation_batch_rows = 16
let retrieval_deadline_seconds = 5.

external monotonic_now : unit -> float = "clamp_monotonic_now"

let validation_limit () =
  error Transient "retrieval_validation_limit"
    "The candidate set exceeds the fixed retrieval validation budget; use local Markdown or rg."

let validation_timeout () =
  error Transient "retrieval_validation_timeout"
    "Retrieval validation exceeded its fixed deadline; use local Markdown or rg."

let within_deadline ~now deadline =
  if now () >= deadline then validation_timeout () else Ok ()

let commit_before_deadline ~now deadline () = deadline -. now () >= 0.001

let bounded_database_result = function
  | Error (failure : Database.error) when failure.code = "database_query_timeout" ->
      validation_timeout ()
  | result -> db result

let bounded_execute connection ~now ~deadline ?(expect = [ Postgresql.Tuples_ok ])
    ?params sql =
  let remaining = deadline -. now () in
  if remaining <= 0. then validation_timeout ()
  else
    let milliseconds = max 1 (int_of_float (ceil (remaining *. 1000.))) in
    let setup =
      Database.For_retrieval.execute connection
        ~expect:[ Postgresql.Command_ok ]
        (Printf.sprintf "SET LOCAL statement_timeout = %d" milliseconds)
    in
    let* _ =
      if now () >= deadline then validation_timeout ()
      else bounded_database_result setup
    in
    let result = Database.For_retrieval.execute connection ~expect ?params sql in
    if now () >= deadline then validation_timeout ()
    else bounded_database_result result

let paths_json paths =
  `List (List.map (fun path -> `String path) paths) |> Yojson.Safe.to_string

let paths_parameter ~now ~deadline paths =
  let* () = within_deadline ~now deadline in
  let value = paths_json paths in
  let* () = within_deadline ~now deadline in
  Ok [| value |]

let candidate_sql =
  "WITH candidate_base AS MATERIALIZED (SELECT path,generated_at,indexed_at,1-(embedding <=> $1::public.vector) AS similarity FROM public.concepts WHERE ($2::bool OR status<>'deprecated') AND ($3::bool OR stale_after IS NULL OR (pg_catalog.now() AT TIME ZONE 'Africa/Johannesburg')::pg_catalog.date<stale_after) AND ($4::bool OR task_state IS NULL OR task_state NOT IN ('done','cancelled')) AND embedding_model=$5 ORDER BY embedding <=> $1::public.vector LIMIT $6::int4), candidates AS (SELECT candidate_base.*,COALESCE(pg_catalog.sum(pg_catalog.octet_length(path)::pg_catalog.int8) OVER (),0) AS path_bytes FROM candidate_base) SELECT CASE WHEN c.path_bytes<=$7::int8 THEN c.path END,c.similarity,EXTRACT(epoch FROM a.last_accessed_at),EXTRACT(epoch FROM c.generated_at),EXTRACT(epoch FROM c.indexed_at),COALESCE(a.access_count,0),EXTRACT(epoch FROM pg_catalog.now()),c.path_bytes FROM candidates c LEFT JOIN public.access_stats a ON a.concept_path=c.path"

let content_size_sql =
  "WITH requested(path) AS (SELECT pg_catalog.jsonb_array_elements_text($1::jsonb)), selected AS (SELECT c.*,pg_catalog.octet_length(c.frontmatter::pg_catalog.text)::pg_catalog.int8 AS frontmatter_bytes,pg_catalog.octet_length(c.body)::pg_catalog.int8 AS body_bytes,(pg_catalog.octet_length(c.frontmatter::pg_catalog.text)::pg_catalog.int8+pg_catalog.octet_length(c.body)::pg_catalog.int8+pg_catalog.octet_length(c.path)::pg_catalog.int8+pg_catalog.octet_length(c.type)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.title),0)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.description),0)::pg_catalog.int8+pg_catalog.octet_length(pg_catalog.to_json(c.tags)::pg_catalog.text)::pg_catalog.int8+pg_catalog.octet_length(c.status)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.generated_by),0)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.asserted_by),0)::pg_catalog.int8+pg_catalog.octet_length(c.verified_tier)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.task_state),0)::pg_catalog.int8+COALESCE(pg_catalog.octet_length(c.task_priority),0)::pg_catalog.int8+512)::pg_catalog.int8 AS transfer_upper_bytes FROM public.concepts c JOIN requested r USING(path)) SELECT pg_catalog.count(*)::pg_catalog.text,COALESCE(pg_catalog.sum(transfer_upper_bytes),0)::pg_catalog.text,COALESCE(pg_catalog.max(frontmatter_bytes),0)::pg_catalog.text,COALESCE(pg_catalog.max(body_bytes),0)::pg_catalog.text,COALESCE(pg_catalog.max(transfer_upper_bytes),0)::pg_catalog.text FROM selected"

let content_rows_sql =
  "WITH requested(path) AS (SELECT pg_catalog.jsonb_array_elements_text($1::jsonb)) SELECT c.path,c.type,c.title,c.description,pg_catalog.to_json(c.tags)::pg_catalog.text,c.status,c.stale_after::pg_catalog.text,c.generated_by,EXTRACT(epoch FROM c.generated_at),c.asserted_by,c.verified_tier,c.task_state,c.task_priority,c.task_due_on::pg_catalog.text,EXTRACT(epoch FROM c.task_due_at),EXTRACT(epoch FROM c.task_completed_at),c.frontmatter::pg_catalog.text,c.body FROM public.concepts c JOIN requested r USING(path)"

let configure_ann connection =
  Result.bind
    (Database.For_retrieval.execute connection
       ~expect:[ Postgresql.Command_ok ]
       "SET LOCAL hnsw.iterative_scan = 'strict_order'")
    (fun _ ->
      Database.For_retrieval.execute connection
        ~expect:[ Postgresql.Command_ok ] "SET LOCAL enable_seqscan = off")

let parse_float value =
  match float_of_string_opt value with
  | Some value when Float.is_finite value -> value
  | _ -> raise (Invalid_argument "invalid database float")

type candidate = {
  path : string;
  similarity : float;
  last_accessed : float option;
  generated : float option;
  indexed : float;
  accesses : int64;
  now : float;
}

type indexed_content = {
  path : string;
  projection : Concept.index_projection;
  raw : Yojson.Raw.t;
  metadata : Exact_yaml.t;
  body : string;
}

let tags_of_json value =
  match Yojson.Safe.from_string value with
  | `List values -> List.map Yojson.Safe.Util.to_string values
  | _ -> raise (Invalid_argument "invalid indexed tags")

let content_row rows index =
  let path = rows#getvalue index 0 in
  let projection : Concept.index_projection =
    { concept_type = rows#getvalue index 1;
      title = nullable_at rows index 2;
      description = nullable_at rows index 3;
      tags = tags_of_json (rows#getvalue index 4);
      status = rows#getvalue index 5;
      stale_after = nullable_at rows index 6;
      generated_by = nullable_at rows index 7;
      generated_at = nullable_at rows index 8;
      asserted_by = nullable_at rows index 9;
      verified_tier = rows#getvalue index 10;
      task_state = nullable_at rows index 11;
      task_priority = nullable_at rows index 12;
      task_due_on = nullable_at rows index 13;
      task_due_at = nullable_at rows index 14;
      task_completed_at = nullable_at rows index 15 }
  in
  let raw, metadata =
    match indexed_metadata (rows#getvalue index 16) with
    | Some value -> value
    | None -> raise (Invalid_argument "invalid indexed metadata")
  in
  let body = rows#getvalue index 17 in
  if not (valid_indexed_row ~id:path ~actual:projection ~metadata ~body) then
    raise (Invalid_argument "inconsistent indexed projection");
  { path; projection; raw; metadata; body }

let candidates_of_rows ~now ~deadline rows =
  let parse index =
    try
      if rows#getisnull index 0 then raise (Invalid_argument "candidate path limit");
      Ok
        { path = rows#getvalue index 0;
          similarity = parse_float (rows#getvalue index 1);
          last_accessed = Option.map parse_float (nullable_at rows index 2);
          generated = Option.map parse_float (nullable_at rows index 3);
          indexed = parse_float (rows#getvalue index 4);
          accesses = Int64.max 0L (Int64.of_string (rows#getvalue index 5));
          now = parse_float (rows#getvalue index 6) }
    with _ ->
      error Internal "database_row_invalid" "Database returned an invalid retrieval row."
  in
  try
    if
      rows#ntuples > 0
      && (rows#getisnull 0 0
          || Int64.of_string (rows#getvalue 0 7)
             > Int64.of_int validation_total_bytes)
    then validation_limit ()
    else
      let rec loop index values =
        if index = rows#ntuples then Ok (List.rev values)
        else
          let* () = within_deadline ~now deadline in
          let* value = parse index in
          let* () = within_deadline ~now deadline in
          loop (index + 1) (value :: values)
      in
      loop 0 []
  with _ ->
    error Internal "database_row_invalid" "Database returned an invalid retrieval row."

let content_preflight connection ~now ~deadline paths =
  let* params = paths_parameter ~now ~deadline paths in
  let* rows =
    bounded_execute connection ~now ~deadline ~params content_size_sql
  in
  try
    if rows#ntuples <> 1 then
      error Internal "database_row_invalid" "Database returned an invalid retrieval row."
    else
      let count = int_of_string (rows#getvalue 0 0)
      and total = Int64.of_string (rows#getvalue 0 1)
      and frontmatter = Int64.of_string (rows#getvalue 0 2)
      and body = Int64.of_string (rows#getvalue 0 3)
      and row = Int64.of_string (rows#getvalue 0 4) in
      if count <> List.length paths then
        error Internal "database_row_invalid" "Database returned an invalid retrieval row."
      else if total > Int64.of_int validation_total_bytes
              || frontmatter > Int64.of_int Limits.max_file_bytes
              || body > Int64.of_int Limits.max_file_bytes
              || row > Int64.of_int validation_row_bytes then
        validation_limit ()
      else Ok ()
  with _ ->
    error Internal "database_row_invalid" "Database returned an invalid retrieval row."

let validate_content connection ~now ~deadline paths =
  let table = Hashtbl.create (List.length paths) in
  let rec split count taken remaining =
    if count = 0 then (List.rev taken, remaining)
    else
      match remaining with
      | [] -> (List.rev taken, [])
      | item :: rest -> split (count - 1) (item :: taken) rest
  in
  let rec batches = function
    | [] -> Ok table
    | remaining ->
        let batch, rest = split validation_batch_rows [] remaining in
        let* params = paths_parameter ~now ~deadline batch in
        let* rows =
          bounded_execute connection ~now ~deadline ~params content_rows_sql
        in
        if rows#ntuples <> List.length batch then
          error Internal "database_row_invalid"
            "Database returned an invalid retrieval row."
        else
          let rec add index =
            if index = rows#ntuples then Ok ()
            else
              let* () = within_deadline ~now deadline in
              let parsed =
                try Ok (content_row rows index) with _ ->
                  error Internal "database_row_invalid"
                    "Database returned an invalid retrieval row."
              in
              let* row = parsed in
              if not (List.mem row.path batch) || Hashtbl.mem table row.path then
                error Internal "database_row_invalid"
                  "Database returned an invalid retrieval row."
              else begin
                Hashtbl.add table row.path row;
                let* () = within_deadline ~now deadline in
                add (index + 1)
              end
          in
          let* () = add 0 in
          batches rest
  in
  let* () = content_preflight connection ~now ~deadline paths in
  batches paths

let search_rows (settings : Config.retrieval) ~now ~deadline candidates contents =
  let make (candidate : candidate) =
    try
          let content = Hashtbl.find contents candidate.path in
          let semantic = semantic candidate.similarity in
          let age_days =
            Float.max 0.
              ((candidate.now
                -. timestamp ~last_accessed:candidate.last_accessed
                     ~generated:candidate.generated ~indexed:candidate.indexed)
               /. 86400.)
          in
          let recency =
            2. ** (-.age_days /. float_of_int settings.recency_half_life_days)
          in
          let frequency =
            Float.min 1.
              (log (1. +. Int64.to_float candidate.accesses)
               /. log (1. +. float_of_int settings.frequency_saturation_count))
          in
          let score =
            (settings.semantic_weight *. semantic)
            +. (settings.recency_weight *. recency)
            +. (settings.frequency_weight *. frequency)
          in
          Ok { id = candidate.path; concept_type = content.projection.concept_type;
            title = content.projection.title;
            description = content.projection.description;
            status = content.projection.status;
            verified_tier = content.projection.verified_tier;
            asserted_by = content.projection.asserted_by;
            task_state = content.projection.task_state;
            semantic; recency; frequency; score;
            snippet = snippet content.body }
    with _ ->
      error Internal "database_row_invalid" "Database returned an invalid retrieval row."
  in
  let rec collect values = function
    | [] -> Ok (List.rev values)
    | candidate :: remaining ->
        let* () = within_deadline ~now deadline in
        let* value = make candidate in
        let* () = within_deadline ~now deadline in
        collect (value :: values) remaining
  in
  let* values = collect [] candidates in
  try
    let compare_results left right =
      let ranked = Float.compare right.score left.score in
      if ranked <> 0 then ranked else String.compare left.id right.id
    in
    let values = List.sort compare_results values in
    let* () = within_deadline ~now deadline in
    Ok values
  with _ ->
    error Internal "database_row_invalid" "Database returned an invalid retrieval row."

type embedding = string -> (float array, error) Result.t

let default_settings : Config.retrieval =
  { candidate_limit = 100; result_limit = 10; semantic_weight = 0.70;
    recency_weight = 0.20; frequency_weight = 0.10;
    recency_half_life_days = 30; frequency_saturation_count = 100 }

let check_final_ref ~now ~deadline check_local_ref =
  let remaining = deadline -. now () in
  if remaining <= 0. then validation_timeout ()
  else
    let result = check_local_ref ~timeout:remaining in
    if now () >= deadline then validation_timeout () else result

let search_with_clock ~now ~(settings : Config.retrieval)
    ~check_local_ref ~connection
    ~embed ~source ~local_commit ~query ~history =
  let* () = index_preflight connection ~source ~local_commit in
  let* embedding = embed query in
  if Array.length embedding <> Openrouter.dimensions
     || not (Array.for_all Float.is_finite embedding) then
    error Internal "embedding_invalid" "Query embedding is invalid."
  else
    let deadline = now () +. retrieval_deadline_seconds in
    match
      Database.For_retrieval.transaction_result ~repeatable_read:true connection
        ~statement_timeout_ms:5000
        ~commit_before_deadline:(commit_before_deadline ~now deadline)
        (fun connection ->
          Ok
            (let* _ =
               bounded_execute connection ~now ~deadline
                 ~expect:[ Postgresql.Command_ok ]
                 "SET LOCAL hnsw.iterative_scan = 'strict_order'"
             in
             let* _ =
               bounded_execute connection ~now ~deadline
                 ~expect:[ Postgresql.Command_ok ] "SET LOCAL enable_seqscan = off"
             in
             let* () = within_deadline ~now deadline in
             let vector = vector_literal embedding in
             let* () = within_deadline ~now deadline in
             let* rows =
               bounded_execute connection ~now ~deadline
                 ~params:[| vector; bool history.include_deprecated;
                            bool history.include_stale;
                            bool history.include_closed_tasks;
                            Openrouter.canonical_identity;
                            string_of_int settings.candidate_limit;
                            string_of_int validation_total_bytes |]
                 candidate_sql
             in
             let* candidates = candidates_of_rows ~now ~deadline rows in
             let paths =
               List.map (fun (candidate : candidate) -> candidate.path) candidates
             in
             let* () = within_deadline ~now deadline in
             let* contents = validate_content connection ~now ~deadline paths in
             let* ranked = search_rows settings ~now ~deadline candidates contents in
             let results =
               List.filteri (fun index _ -> index < settings.result_limit) ranked
             in
             let* () = within_deadline ~now deadline in
             let* state = bounded_execute connection ~now ~deadline state_sql in
             let* () = validate_state state ~source ~local_commit in
             let* () = check_final_ref ~now ~deadline check_local_ref in
             let* _ = bounded_execute connection ~now ~deadline "SELECT 1" in
             Ok results))
    with
    | Error failure -> Error (database_error ~operation:Search failure)
    | Ok result -> result

let search_with_settings = search_with_clock ~now:monotonic_now

let get_visible_sql =
  "SELECT path FROM public.concepts WHERE path=$1 AND ($2::bool OR status<>'deprecated') AND ($3::bool OR stale_after IS NULL OR (pg_catalog.now() AT TIME ZONE 'Africa/Johannesburg')::pg_catalog.date<stale_after) AND ($4::bool OR task_state IS NULL OR task_state NOT IN ('done','cancelled')) FOR SHARE"

let json_string value = Yojson.Safe.to_string (`String value)
let json_optional = function None -> "null" | Some value -> json_string value

let concept_data_json concept =
  String.concat ""
    [ "{\"id\":"; json_string concept.id;
      ",\"type\":"; json_string concept.concept_type;
      ",\"title\":"; json_optional concept.title;
      ",\"description\":"; json_optional concept.description;
      ",\"status\":"; json_string concept.status;
      ",\"verified_tier\":"; json_string concept.verified_tier;
      ",\"asserted_by\":"; json_optional concept.asserted_by;
      ",\"task_state\":"; json_optional concept.task_state;
      ",\"frontmatter\":"; concept.frontmatter;
      ",\"body\":"; json_string concept.body; "}" ]

let prepare_concept ~now ~deadline content =
  let* () = within_deadline ~now deadline in
  try
    let frontmatter = Yojson.Raw.to_string content.raw in
    let body = content.body in
    let projection = content.projection in
    let partial =
      { id = content.path; concept_type = projection.concept_type;
        title = projection.title; description = projection.description;
        status = projection.status; verified_tier = projection.verified_tier;
        asserted_by = projection.asserted_by; task_state = projection.task_state;
        frontmatter; body;
        document = "---\n" ^ Exact_yaml.to_string content.metadata ^ "---\n" ^ body;
        json_output = "" }
    in
    let json_output =
      "{\"ok\":true,\"code\":\"concept_retrieved\",\"data\":"
      ^ concept_data_json partial ^ "}"
    in
    ignore (Yojson.Raw.from_string json_output);
    let* () = within_deadline ~now deadline in
    Ok { partial with json_output }
  with _ ->
    error Internal "database_row_invalid" "Database returned an invalid concept row."

let get_with_deadline ~deadline_seconds ~now ~check_local_ref ~connection ~source
    ~local_commit ~id ~history =
  let* () = index_preflight connection ~source ~local_commit in
  let deadline = now () +. deadline_seconds in
  match
    Database.For_retrieval.transaction_result connection ~statement_timeout_ms:5000
      ~commit_before_deadline:(commit_before_deadline ~now deadline)
      (fun connection ->
        Ok
          (let* visible =
             bounded_execute connection ~now ~deadline
               ~params:[| id; bool history.include_deprecated;
                          bool history.include_stale;
                          bool history.include_closed_tasks |]
               get_visible_sql
           in
           if visible#ntuples = 0 then
             error Validation "concept_not_found"
               "The indexed concept was not found or is hidden."
           else if visible#ntuples <> 1 || visible#getvalue 0 0 <> id then
             error Internal "database_row_invalid"
               "Database returned an invalid concept row."
           else
             let* contents = validate_content connection ~now ~deadline [ id ] in
             let* concept =
               match Hashtbl.find_opt contents id with
               | Some content -> prepare_concept ~now ~deadline content
               | None ->
                   error Internal "database_row_invalid"
                     "Database returned an invalid concept row."
             in
             let* state = bounded_execute connection ~now ~deadline state_sql in
             let* () = validate_state state ~source ~local_commit in
             let* () = check_final_ref ~now ~deadline check_local_ref in
             let* () = within_deadline ~now deadline in
             let* _ =
               bounded_execute connection ~now ~deadline
                 ~expect:[ Postgresql.Command_ok ] ~params:[| id |]
                 "INSERT INTO public.access_stats(concept_path,last_accessed_at,access_count) VALUES ($1,pg_catalog.now(),1) ON CONFLICT(concept_path) DO UPDATE SET last_accessed_at=excluded.last_accessed_at,access_count=public.access_stats.access_count+1"
             in
             let* _ = bounded_execute connection ~now ~deadline "SELECT 1" in
             Ok concept))
  with
  | Error failure -> Error (database_error ~operation:Get failure)
  | Ok result -> result

let get_with_clock = get_with_deadline ~deadline_seconds:retrieval_deadline_seconds
let get_with_connection = get_with_clock ~now:monotonic_now

let check_local_commit ?(timeout = 30.) repo expected =
  match Sync.local_origin_main ~timeout repo with
  | Ok actual when actual = expected -> Ok ()
  | Ok _ ->
      error Stale "local_ref_changed"
        "The local origin/main ref changed during retrieval; retry after synchronization."
  | Error _ ->
      error Stale "local_ref_missing"
        "The local origin/main ref is unavailable; use local Markdown or rg."

let source_and_commit repo =
  let* commit =
    Result.map_error
      (fun (_ : Sync.error) ->
        { kind = Stale; code = "local_ref_missing";
          message = "The local origin/main ref is unavailable; use local Markdown or rg." })
      (Sync.local_origin_main repo)
  in
  let* contents =
    Result.map_error
      (fun (failure : Sync.error) ->
        { kind = Validation; code = failure.code; message = failure.message })
      (Sync.local_config_at_commit repo commit)
  in
  match Config.source_repository contents, Config.retrieval contents with
  | Ok source, Ok settings -> Ok (source, commit, settings)
  | _ -> error Validation "config_invalid" "clamp.yaml is invalid or incompatible."

let production_embed query =
  if query = "" || String.trim query = "" || not (Frontmatter.valid_utf8 query) then
    error Validation "search_query_invalid" "Search query must be non-empty UTF-8."
  else if String.length query > 8000 then
    error Validation "embedding_input_too_large" "Search query exceeds the 8,000-byte embedding limit."
  else
    match Sys.getenv_opt "OPENROUTER_API_KEY" with
    | None | Some "" ->
        error Authentication "openrouter_api_key_missing"
          "OPENROUTER_API_KEY is required for semantic search."
    | Some api_key ->
        (match Openrouter.embed ~api_key query with
        | Ok embedding -> Ok embedding.values
        | Error failure ->
            let kind =
              match failure.kind with
              | Openrouter.Authentication -> Authentication
              | Validation | Invalid_response | Response_too_large -> Validation
              | Rate_limited | Payment_required | Transient -> Transient
            in
            error kind failure.code failure.message)

let with_remote ~repo ~url operation =
  let* source, local_commit, settings = source_and_commit repo in
  match
    Database.For_retrieval.with_remote ~url (fun connection ->
        Ok (operation connection source local_commit settings
              (fun ~timeout -> check_local_commit ~timeout repo local_commit)))
  with
  | Ok result -> result
  | Error failure -> Error (database_error failure)

let search ~repo ~url ~query ~history =
  with_remote ~repo ~url
    (fun connection source local_commit settings check_local_ref ->
      search_with_settings ~settings ~check_local_ref ~connection
        ~embed:production_embed ~source ~local_commit ~query ~history)

let get ~repo ~url ~id ~history =
  if not (Concept.concept_id id) then
    error Validation "concept_id_invalid" "Concept identifier is invalid."
  else
    with_remote ~repo ~url
      (fun connection source local_commit _settings check_local_ref ->
        get_with_connection ~check_local_ref ~connection ~source ~local_commit ~id
          ~history)

let optional name = function None -> (name, `Null) | Some value -> (name, `String value)

let result_json (result : result) =
  `Assoc
    [ ("id", `String result.id); ("type", `String result.concept_type);
      optional "title" result.title; optional "description" result.description;
      ("status", `String result.status); ("verified_tier", `String result.verified_tier);
      optional "asserted_by" result.asserted_by; optional "task_state" result.task_state;
      ("semantic", `Float result.semantic); ("recency", `Float result.recency);
      ("frequency", `Float result.frequency); ("score", `Float result.score);
      ("snippet", `String result.snippet) ]

let result_source (result : result) =
  match result.title with
  | None | Some "" -> result.id
  | Some title -> Printf.sprintf "%s (%s)" title result.id

let human_results ~verbose = function
  | [] -> "No indexed results."
  | (top : result) :: _ when not verbose ->
      Printf.sprintf "%s\n\nSource: %s\nStatus: %s · verification: %s"
        top.snippet (result_source top) top.status top.verified_tier
  | results ->
      results
      |> List.mapi (fun index (result : result) ->
          Printf.sprintf
            "%d. %s\n   %s\n   Source: %s · %s\n   Status: %s · verification: %s\n   Ranking score: %.4f (semantic %.4f · recency %.4f · frequency %.4f)"
            (index + 1)
            (Option.value result.title ~default:result.id)
            result.snippet result.id result.concept_type result.status
            result.verified_tier result.score result.semantic result.recency
            result.frequency)
      |> String.concat "\n\n"

let concept_json concept = concept.json_output

let cli_result error =
  let degraded =
    match error.kind with
    | Authentication | Transient | Stale ->
        [ ("fallback", `String "local_markdown_or_rg");
          ("semantic_equivalent", `Bool false) ]
    | Validation when error.code = "database_url_missing" ->
        [ ("fallback", `String "local_markdown_or_rg");
          ("semantic_equivalent", `Bool false) ]
    | Validation | Internal -> []
  in
  Cli_result.failure ~exit_class:(exit_class error) ~code:error.code
    ~message:error.message ~details:(`Assoc degraded)

module For_test = struct
  let semantic = semantic
  let recency = recency
  let frequency = frequency
  let score = score
  let timestamp = timestamp
  let snippet = snippet
  let compare_results (left : result) (right : result) =
    let ranked = Float.compare right.score left.score in
    if ranked <> 0 then ranked else String.compare left.id right.id
  let visible = visible
  type embedding = string -> (float array, error) Result.t
  let search_with_connection =
    search_with_settings ~settings:default_settings
      ~check_local_ref:(fun ~timeout:_ -> Ok ())
  let search_with_settings = search_with_settings
  let search_with_clock = search_with_clock
  let get_with_ref_check = get_with_connection
  let get_with_clock = get_with_clock
  let get_with_deadline = get_with_deadline
  let get_with_connection =
    get_with_ref_check ~check_local_ref:(fun ~timeout:_ -> Ok ())
  let check_local_commit = check_local_commit
  let check_final_ref = check_final_ref
  let candidate_sql = candidate_sql
  let configure_ann = configure_ann
  let validation_total_bytes = validation_total_bytes
  let search_database_error = database_error ~operation:Search
  let get_database_error = database_error ~operation:Get
end
