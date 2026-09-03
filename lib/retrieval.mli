type history = {
  include_deprecated : bool;
  include_stale : bool;
  include_closed_tasks : bool;
}

val normal_history : history

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

val search :
  repo:string -> url:string -> query:string -> history:history ->
  (result list, error) Stdlib.result

val get :
  repo:string -> url:string -> id:string -> history:history ->
  (concept, error) Stdlib.result

val exit_class : error -> Exit_class.t
val result_json : result -> Yojson.Safe.t
val human_results : verbose:bool -> result list -> string
val concept_json : concept -> string
val cli_result : error -> Cli_result.t

module For_test : sig
  val semantic : float -> float
  val recency : now:float -> float option -> float
  val frequency : int64 -> float
  val score : semantic:float -> recency:float -> frequency:float -> float
  val timestamp :
    last_accessed:float option -> generated:float option -> indexed:float -> float
  val snippet : string -> string
  val compare_results : result -> result -> int
  val visible :
    history:history -> today:string -> status:string -> stale_after:string option ->
    task_state:string option -> bool

  type embedding = string -> (float array, error) Stdlib.result

  val search_with_connection :
    connection:Postgresql.connection -> embed:embedding ->
    source:string -> local_commit:string -> query:string -> history:history ->
    (result list, error) Stdlib.result

  val search_with_settings :
    settings:Config.retrieval ->
    check_local_ref:(timeout:float -> (unit, error) Stdlib.result) ->
    connection:Postgresql.connection -> embed:embedding ->
    source:string -> local_commit:string -> query:string -> history:history ->
    (result list, error) Stdlib.result

  val search_with_clock :
    now:(unit -> float) -> settings:Config.retrieval ->
    check_local_ref:(timeout:float -> (unit, error) Stdlib.result) ->
    connection:Postgresql.connection -> embed:embedding ->
    source:string -> local_commit:string -> query:string -> history:history ->
    (result list, error) Stdlib.result

  val get_with_connection :
    connection:Postgresql.connection -> source:string -> local_commit:string ->
    id:string -> history:history -> (concept, error) Stdlib.result

  val get_with_ref_check :
    check_local_ref:(timeout:float -> (unit, error) Stdlib.result) ->
    connection:Postgresql.connection -> source:string -> local_commit:string ->
    id:string -> history:history -> (concept, error) Stdlib.result

  val get_with_clock :
    now:(unit -> float) ->
    check_local_ref:(timeout:float -> (unit, error) Stdlib.result) ->
    connection:Postgresql.connection -> source:string -> local_commit:string ->
    id:string -> history:history -> (concept, error) Stdlib.result

  val get_with_deadline :
    deadline_seconds:float -> now:(unit -> float) ->
    check_local_ref:(timeout:float -> (unit, error) Stdlib.result) ->
    connection:Postgresql.connection -> source:string -> local_commit:string ->
    id:string -> history:history -> (concept, error) Stdlib.result

  val check_local_commit :
    ?timeout:float -> string -> string -> (unit, error) Stdlib.result
  val check_final_ref :
    now:(unit -> float) -> deadline:float ->
    (timeout:float -> (unit, error) Stdlib.result) ->
    (unit, error) Stdlib.result
  val candidate_sql : string
  val configure_ann :
    Postgresql.connection -> (Postgresql.result, Database.error) Stdlib.result
  val validation_total_bytes : int
  val search_database_error : Database.error -> error
  val get_database_error : Database.error -> error
end
