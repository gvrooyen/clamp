type failure_kind =
  | Validation
  | Authentication
  | Transient
  | Timeout
  | Sql
  | Internal

type finalization = Before_commit_dispatch | After_commit_dispatch

type error = {
  code : string;
  message : string;
  kind : failure_kind;
  finalization : finalization;
}

type retry_effects = {
  now : unit -> float;
  sleep : float -> unit;
  jitter : unit -> float;
}

type migration_report = {
  applied : string list;
  already_applied : string list;
  ledger_count : int;
}

type local_target = {
  socket_dir : string;
  port : int;
  data_directory : string;
}

type concept_row = {
  path : string;
  blob_hash : string;
  embedding_input_hash : string;
  concept_type : string;
  status : string;
  embedding_model : string;
  indexed_at : string;
}

type access_stats_row = {
  concept_path : string;
  last_accessed_at : string option;
  access_count : int64;
}

type index_state_row = {
  source_repository : string;
  source_ref : string;
  last_indexed_commit : string option;
  embedding_model : string;
  embedding_dimensions : int;
  last_indexed_at : string option;
}

val validate_remote_url : string -> (unit, error) result
val classify_connection_message : string -> failure_kind
val classify_query_message : string -> failure_kind
val retry :
  ?effects:retry_effects ->
  ?max_attempts:int ->
  ?max_elapsed_s:float ->
  (unit -> ('a, error) result) ->
  ('a, error) result
val retry_delay : retry_effects -> int -> float
val child_deadline :
  effects:retry_effects -> parent:float -> cap:float -> float option
val sleep_before_deadline :
  effects:retry_effects -> deadline:float -> float -> bool
val polling_ok_before_deadline :
  effects:retry_effects -> deadline:float -> (unit -> unit) -> bool
val make_process_jitter :
  pid:(unit -> int) ->
  initialize:(unit -> Random.State.t) ->
  unit ->
  unit -> float
val production_jitter : unit -> float
val prepare_remote_url :
  ?resolver:(deadline:float -> string ->
    (string list, [ `Timeout | `Resolve | `Invalid ]) result) ->
  effects:retry_effects ->
  deadline:float ->
  string ->
  (string, error) result
val poll_waitpid :
  effects:retry_effects ->
  deadline:float ->
  (unit -> [ `Running | `Collected ]) ->
  bool
type resolver_system = {
  pipe : unit -> Unix.file_descr * Unix.file_descr;
  fork : unit -> int;
  close : Unix.file_descr -> unit;
  set_nonblock : Unix.file_descr -> unit;
  select_read : Unix.file_descr -> float -> bool;
  read : Unix.file_descr -> bytes -> int -> int -> int;
  kill : int -> int -> unit;
  waitpid_nohang : int -> [ `Running | `Collected ];
  resolve : string -> string list option;
}
val default_resolver_system : resolver_system
val resolve_host_with :
  system:resolver_system ->
  effects:retry_effects ->
  deadline:float ->
  string ->
  (string list, [ `Timeout | `Resolve | `Invalid ]) result

val migrate_remote : repo:string -> url:string -> (migration_report, error) result
val migrate_remote_from :
  migrations_dir:string -> url:string -> (migration_report, error) result
val migrate_local : repo:string -> database:string -> (migration_report, error) result
val migrate_local_from :
  migrations_dir:string -> database:string -> (migration_report, error) result
val discover_local_target : unit -> (local_target, error) result
val exit_class : error -> Exit_class.t

val concept_rows : Postgresql.result -> (concept_row list, error) result
val access_stats_rows : Postgresql.result -> (access_stats_row list, error) result
val index_state_row : Postgresql.result -> (index_state_row option, error) result

module For_tests : sig
  val with_local_target : local_target -> (unit -> 'a) -> 'a
  (** Scoped integration-only private Unix socket target. No environment or
      CLI override exists; runtime local discovery remains Debian-only. *)
  type ledger_constraint_row
  val ledger_constraint_row :
    constraint_type:string -> name:string -> definition:string -> key:string ->
    ?key_dimensions:int -> ?key_length:int -> ?key_lower_bound:int ->
    ?public_namespace:bool ->
    ?validated:bool -> ?deferrable:bool -> ?deferred:bool -> ?local:bool ->
    ?inherited_count:int -> ?no_inherit:bool ->
    ?enforced:bool option -> ?period:bool option ->
    ?ancillary_canonical:bool ->
    unit -> ledger_constraint_row
  val valid_ledger_constraints :
    server_version_num:int ->
    [ `Current | `Legacy ] -> ledger_constraint_row list -> bool
  val ledger_constraint_query : int -> string
end

module For_sync : sig
  val with_remote :
    url:string ->
    (Postgresql.connection -> ('a, error) result) ->
    ('a, error) result
  val execute :
    Postgresql.connection ->
    ?expect:Postgresql.result_status list ->
    ?params:string array ->
    string ->
    (Postgresql.result, error) result
  val transaction :
    Postgresql.connection ->
    statement_timeout_ms:int ->
    (Postgresql.connection -> ('a, error) result) ->
    ('a, error) result
end

module For_retrieval : sig
  val with_remote :
    url:string ->
    (Postgresql.connection -> ('a, error) result) ->
    ('a, error) result
  val execute :
    Postgresql.connection ->
    ?expect:Postgresql.result_status list ->
    ?params:string array ->
    string ->
    (Postgresql.result, error) result
  val transaction :
    Postgresql.connection ->
    statement_timeout_ms:int ->
    (Postgresql.connection -> ('a, error) result) ->
    ('a, error) result
  val transaction_result :
    ?repeatable_read:bool ->
    Postgresql.connection ->
    statement_timeout_ms:int ->
    commit_before_deadline:(unit -> bool) ->
    (Postgresql.connection -> (('a, 'failure) result, error) result) ->
    (('a, 'failure) result, error) result
end
