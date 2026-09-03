open Exact_yaml

let known_types =
  [ "fact"; "preference"; "person"; "project"; "decision"; "journal"; "task" ]

let nonempty_string = function
  | Scalar (String, value) -> String.trim value <> ""
  | _ -> false

let string = function Scalar (String, value) -> Some value | _ -> None
let mapping = function Map fields -> Some fields | _ -> None
let sequence = function Seq values -> Some values | _ -> None
let field key value = Exact_yaml.find key value

let date value =
  if
    not
      (Str.string_match
         (Str.regexp "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$")
         value 0)
  then false
  else
    let year = int_of_string (String.sub value 0 4)
    and month = int_of_string (String.sub value 5 2)
    and day = int_of_string (String.sub value 8 2) in
    let leap = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0) in
    let days =
      match month with
      | 2 -> if leap then 29 else 28
      | 4 | 6 | 9 | 11 -> 30
      | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
      | _ -> 0
    in
    day >= 1 && day <= days

let rfc3339 value =
  let length = String.length value in
  let digits offset count =
    offset + count <= length
    && String.for_all
         (fun character -> character >= '0' && character <= '9')
         (String.sub value offset count)
  in
  let number offset count = int_of_string (String.sub value offset count) in
  if
    length < 20 || not (digits 0 4 && digits 5 2 && digits 8 2 && digits 11 2
                        && digits 14 2 && digits 17 2)
    || value.[4] <> '-' || value.[7] <> '-'
    || (value.[10] <> 'T' && value.[10] <> 't')
    || value.[13] <> ':' || value.[16] <> ':'
  then false
  else
    let zone_start =
      match String.index_from_opt value 19 'Z' with
      | Some index -> Some index
      | None ->
          (match String.index_from_opt value 19 'z' with
          | Some index -> Some index
          | None -> match String.index_from_opt value 19 '+' with
          | Some index -> Some index
          | None -> String.index_from_opt value 19 '-')
    in
    match zone_start with
    | None -> false
    | Some index ->
        let fraction_valid =
          index = 19
          || (value.[19] = '.' && index > 20 && digits 20 (index - 20))
        in
        let zone_valid =
          if value.[index] = 'Z' || value.[index] = 'z' then index = length - 1
          else
            index + 6 = length && value.[index + 3] = ':'
            && digits (index + 1) 2 && digits (index + 4) 2
            && number (index + 1) 2 <= 23 && number (index + 4) 2 < 60
        in
        date (String.sub value 0 10) && number 11 2 < 24
        && number 14 2 < 60 && number 17 2 < 60 && fraction_valid && zone_valid

let portable_component component =
  let basename =
    match String.index_opt component '.' with
    | None -> component
    | Some index -> String.sub component 0 index
  in
  let reserved =
    let name = String.uppercase_ascii basename in
    List.mem name [ "CON"; "PRN"; "AUX"; "NUL" ]
    ||
    let numbered prefix =
      String.length name = 4 && String.starts_with ~prefix name
      && name.[3] >= '1' && name.[3] <= '9'
    in
    numbered "COM" || numbered "LPT"
  in
  component <> "" && component <> "." && component <> ".."
  && not (String.ends_with ~suffix:"." component)
  && Frontmatter.valid_utf8 component && not reserved
  && String.for_all
       (fun character ->
         (character >= 'a' && character <= 'z')
         || (character >= 'A' && character <= 'Z')
         || (character >= '0' && character <= '9')
         || character = '-' || character = '_' || character = '.')
       component

let concept_id value =
  value <> "" && value.[0] <> '/' && not (String.ends_with ~suffix:".md" value)
  && List.for_all portable_component (String.split_on_char '/' value)

let validate metadata =
  let errors = ref [] in
  let error field message = errors := (field, message) :: !errors in
  let check_string key =
    field key metadata
    |> Option.iter (fun value ->
           if Option.is_none (string value) then error key "must be a string")
  in
  let type_name = Option.bind (field "type" metadata) string in
  (match metadata with Map _ -> () | _ -> error "" "metadata must be a mapping");
  (match type_name with
  | None -> error "type" "type is required and nonempty"
  | Some value when String.trim value = "" ->
      error "type" "type is required and nonempty"
  | Some _ -> ());
  List.iter check_string [ "title"; "description"; "resource"; "computation" ];
  field "tags" metadata
  |> Option.iter (function
       | Seq values when List.for_all (fun value -> Option.is_some (string value)) values -> ()
       | _ -> error "tags" "must be a list of strings");
  field "status" metadata
  |> Option.iter (fun value ->
         if not (List.mem (string value) [ Some "draft"; Some "stable"; Some "deprecated" ])
         then error "status" "invalid status");
  field "stale_after" metadata
  |> Option.iter (fun value ->
         if not (Option.exists date (string value)) then
           error "stale_after" "must be a valid date");
  field "generated" metadata
  |> Option.iter (function
       | Map _ as generated ->
           if not (Option.exists nonempty_string (field "by" generated)) then
             error "generated.by" "required nonempty string";
           if not (Option.exists rfc3339 (Option.bind (field "at" generated) string)) then
             error "generated.at" "required RFC3339 timestamp"
       | _ -> error "generated" "must be a mapping");
  field "verified" metadata
  |> Option.iter (fun verified ->
         let events = match verified with Map _ -> [ verified ] | Seq values -> values | _ -> [] in
         if
           events = []
           || not
                (List.for_all
                   (function
                     | Map _ as event ->
                         Option.exists nonempty_string (field "by" event)
                         && Option.exists rfc3339
                              (Option.bind (field "at" event) string)
                     | _ -> false)
                   events)
         then error "verified" "must contain valid verification events");
  let validate_window path = function
    | Map fields as window
      when List.sort String.compare (List.map fst fields) = [ "from"; "to" ] ->
        let from = Option.bind (field "from" window) string
        and until = Option.bind (field "to" window) string in
        if
          not
            (Option.exists date from && Option.exists date until
            && Option.get from <= Option.get until)
        then error path "must contain an ordered from/to date range"
    | _ -> error path "must contain exactly from/to dates"
  in
  field "usage_window" metadata |> Option.iter (validate_window "usage_window");
  field "sources" metadata
  |> Option.iter (function
       | Seq sources ->
           let ids = ref [] in
           List.iteri
             (fun index -> function
               | Map _ as source ->
                   let prefix = Printf.sprintf "sources[%d]" index in
                   if not (Option.exists nonempty_string (field "resource" source)) then
                     error (prefix ^ ".resource") "required nonempty string";
                   List.iter
                     (fun key ->
                       field key source
                       |> Option.iter (fun value ->
                              if Option.is_none (string value) then
                                error (prefix ^ "." ^ key) "must be a string"))
                     [ "id"; "title"; "author" ];
                   Option.bind (field "id" source) string
                   |> Option.iter (fun id ->
                          if List.mem id !ids then error (prefix ^ ".id") "duplicate source id"
                          else ids := id :: !ids);
                   field "usage_count" source
                   |> Option.iter (function
                        | Scalar (Integer, value) ->
                            if
                              value = ""
                              || value.[0] = '-'
                              || not
                                   (String.for_all
                                      (fun c -> c >= '0' && c <= '9') value)
                            then
                              error (prefix ^ ".usage_count")
                                "must be a nonnegative integer"
                        | _ -> error (prefix ^ ".usage_count") "must be a nonnegative integer");
                   field "last_modified" source
                   |> Option.iter (fun value ->
                          if not (Option.exists date (string value)) then
                            error (prefix ^ ".last_modified") "must be a valid date");
                   field "usage_window" source
                   |> Option.iter (validate_window (prefix ^ ".usage_window"))
               | _ -> error (Printf.sprintf "sources[%d]" index) "must be a mapping")
             sources
       | _ -> error "sources" "must be a list of source mappings");
  let attested = type_name = Some "Attested Computation" in
  if attested && not (Option.exists nonempty_string (field "runtime" metadata)) then
    error "runtime" "required for Attested Computation";
  field "runtime" metadata
  |> Option.iter (fun value -> if not (nonempty_string value) then error "runtime" "must be nonempty");
  field "parameters" metadata
  |> Option.iter (function
       | Seq parameters ->
           List.iteri
             (fun index -> function
               | Map _ as parameter ->
                   let prefix = Printf.sprintf "parameters[%d]" index in
                   if not (Option.exists nonempty_string (field "name" parameter)) then error (prefix ^ ".name") "required";
                   if not (Option.exists nonempty_string (field "type" parameter)) then error (prefix ^ ".type") "required";
                   (match field "required" parameter with Some (Scalar (Bool, _)) -> () | _ -> error (prefix ^ ".required") "must be a boolean")
               | _ -> error (Printf.sprintf "parameters[%d]" index) "must be a mapping")
             parameters
       | _ -> error "parameters" "must be a list");
  let validate_resource_mapping key =
    field key metadata
    |> Option.iter (function
         | Map _ as value ->
             if not (Option.exists nonempty_string (field "resource" value)) then
               error (key ^ ".resource") "required nonempty string"
         | _ -> error key "must be a mapping")
  in
  validate_resource_mapping "executor";
  validate_resource_mapping "attester";
  field "executor" metadata
  |> Option.iter (function
       | Map _ as executor ->
           (match field "receipt" executor with
           | Some (Seq values) when values <> [] && List.for_all nonempty_string values -> ()
           | _ -> error "executor.receipt" "must be a nonempty list of strings")
       | _ -> ());
  ignore attested;
  (match field "clamp" metadata with
  | Some (Map _ as clamp) ->
      if not (Option.exists nonempty_string (field "asserted_by" clamp)) then error "clamp.asserted_by" "required nonempty string";
      field "superseded_by" clamp |> Option.iter (fun value -> if not (Option.exists concept_id (string value)) then error "clamp.superseded_by" "invalid concept ID");
      if Option.is_some (field "superseded_by" clamp)
         && Option.bind (field "status" metadata) string <> Some "deprecated"
      then error "clamp.superseded_by" "requires status deprecated";
      let task = field "task" clamp in
      if type_name = Some "task" && Option.is_none task then error "clamp.task" "task metadata required";
      if type_name <> Some "task" && Option.is_some task then error "clamp.task" "only valid for task concepts";
      task |> Option.iter (function
        | Map fields as task ->
            let state = Option.bind (field "state" task) string in
            if not (List.mem state [ Some "todo"; Some "doing"; Some "blocked"; Some "done"; Some "cancelled" ]) then error "clamp.task.state" "invalid state";
            field "priority" task |> Option.iter (fun value -> if not (List.mem (string value) [ Some "low"; Some "normal"; Some "high"; Some "urgent" ]) then error "clamp.task.priority" "invalid priority");
            let due_on = field "due_on" task and due_at = field "due_at" task in
            if Option.is_some due_on && Option.is_some due_at then error "clamp.task" "due_on and due_at are exclusive";
            due_on |> Option.iter (fun value -> if not (Option.exists date (string value)) then error "clamp.task.due_on" "invalid date");
            due_at |> Option.iter (fun value -> if not (Option.exists rfc3339 (string value)) then error "clamp.task.due_at" "invalid datetime");
            let completed = field "completed_at" task in
            if (state = Some "done") <> Option.is_some completed then error "clamp.task.completed_at" "required iff state is done";
            completed |> Option.iter (fun value -> if not (Option.exists rfc3339 (string value)) then error "clamp.task.completed_at" "invalid datetime");
            field "depends_on" task |> Option.iter (function
              | Seq values when List.for_all (fun value -> Option.exists concept_id (string value)) values && List.length values = List.length (List.sort_uniq compare values) -> ()
              | _ -> error "clamp.task.depends_on" "invalid or duplicate concept IDs")
        | _ -> error "clamp.task" "must be a mapping")
  | _ -> error "clamp" "mapping with asserted_by is required");
  List.rev !errors

type index_projection = {
  concept_type : string;
  title : string option;
  description : string option;
  tags : string list;
  status : string;
  stale_after : string option;
  generated_by : string option;
  generated_at : string option;
  asserted_by : string option;
  verified_tier : string;
  task_state : string option;
  task_priority : string option;
  task_due_on : string option;
  task_due_at : string option;
  task_completed_at : string option;
}

let index_projection metadata =
  let optional name value = Option.bind (field name value) string in
  let generated = field "generated" metadata
  and clamp = field "clamp" metadata in
  let task = Option.bind clamp (field "task") in
  let tags =
    match field "tags" metadata with
    | Some (Seq values) -> List.filter_map string values
    | _ -> []
  in
  let events =
    match field "verified" metadata with
    | Some (Map _ as event) -> [ event ]
    | Some (Seq values) -> values
    | _ -> []
  in
  let verifiers =
    List.filter_map
      (function Map _ as event -> optional "by" event | _ -> None)
      events
  in
  let verified_tier =
    if List.exists (String.starts_with ~prefix:"human:") verifiers then
      "human-reviewed"
    else if verifiers <> [] then "machine-confirmed"
    else "unverified"
  in
  { concept_type = Option.value (optional "type" metadata) ~default:"";
    title = optional "title" metadata;
    description = optional "description" metadata;
    tags;
    status = Option.value (optional "status" metadata) ~default:"stable";
    stale_after = optional "stale_after" metadata;
    generated_by = Option.bind generated (optional "by");
    generated_at = Option.bind generated (optional "at");
    asserted_by = Option.bind clamp (optional "asserted_by");
    verified_tier;
    task_state = Option.bind task (optional "state");
    task_priority = Option.bind task (optional "priority");
    task_due_on = Option.bind task (optional "due_on");
    task_due_at = Option.bind task (optional "due_at");
    task_completed_at = Option.bind task (optional "completed_at") }

type verification_change = Preserve_verification | Clear_verification

let classify_verification old_concept new_concept =
  let rec canonical = function
    | Map fields ->
        fields
        |> List.map (fun (key, value) -> (key, canonical value))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right)
        |> fun fields -> Map fields
    | Seq values -> Seq (List.map canonical values)
    | value -> value
  in
  let semantic_source = function
    | Map fields ->
        Map
          (List.filter
             (fun (key, _) ->
               not (List.mem key [ "usage_count"; "last_modified"; "usage_window" ]))
             fields)
    | value -> value
  in
  let semantic_task = function
    | Map fields ->
        Map
          (List.filter
             (fun (key, _) ->
               not (List.mem key [ "state"; "priority"; "completed_at" ]))
             fields)
    | value -> value
  in
  let semantic_metadata = function
    | Map fields ->
        fields
        |> List.filter_map (fun (key, value) ->
               if
                 List.mem key
                   [ "generated"; "verified"; "status"; "stale_after";
                     "usage_window" ]
               then None
               else if key = "sources" then
                 Some
                   ( key,
                     match value with
                     | Seq sources -> Seq (List.map semantic_source sources)
                     | value -> value )
               else if key = "clamp" then
                 Some
                   ( key,
                     match value with
                     | Map clamp ->
                         Map
                           (List.map
                              (fun (name, value) ->
                                if name = "task" then (name, semantic_task value)
                                else (name, value))
                              clamp)
                     | value -> value )
               else Some (key, value))
        |> fun fields -> canonical (Map fields)
    | value -> canonical value
  in
  if
    Markdown_links.visible_text old_concept.Frontmatter.body
    <> Markdown_links.visible_text new_concept.Frontmatter.body
    || semantic_metadata old_concept.metadata
       <> semantic_metadata new_concept.metadata
  then Clear_verification
  else Preserve_verification
