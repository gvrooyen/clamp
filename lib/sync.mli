type counts = {
  added : int;
  metadata_updated : int;
  reembedded : int;
  unchanged : int;
  deleted : int;
}

type report = {
  commit : string;
  counts : counts;
  rebuilt : bool;
  diagnostics : Diagnostic.t list;
}

type error_kind = Validation | Authentication | Transient | Internal
type error = {
  kind : error_kind;
  code : string;
  message : string;
  diagnostics : Diagnostic.t list;
}

val run :
  repo:string ->
  url:string ->
  reembed:bool ->
  allow_mass_deletion:bool ->
  target_commit:string option ->
  (report, error) result

val exit_class : error -> Exit_class.t
val cli_result : error -> Cli_result.t
val fallback_producers : unit -> (string * error_kind) list
val fallback_error : code:string -> message:string -> error
val preflight_repository : string -> (unit, error) result
val completion_code : report -> string
val local_origin_main : ?timeout:float -> string -> (string, error) result
val local_config_at_commit : string -> string -> (string, error) result

module Git : sig
  type command_result = { output : string; succeeded : bool }

  val run : string -> string list -> int -> (string, error) result
  val run_input :
    string -> string list -> string -> int -> (string, error) result
  val run_status :
    ?timeout:float -> string -> string list -> int ->
    (command_result, error) result
  val origin_urls : string -> (string list * string list, error) result
  val fetch_origin_main :
    ?force:bool -> string -> string -> int -> (unit, error) result
  val push_origin :
    string -> string -> string -> int -> (command_result, error) result
  val remote_branch_status :
    string -> string -> string -> int -> (string option, error) result
  val valid_sha : string -> bool
  val amp_remote : string -> string -> bool
end

module For_test : sig
  type embedding = string -> (float array, error) result

  val database_error : Database.error -> error
  val openrouter_error : Openrouter.error -> error

  val run_with_connection :
    repo:string ->
    connection:Postgresql.connection ->
    embed:embedding ->
    reembed:bool ->
    allow_mass_deletion:bool ->
    target_commit:string option ->
    (report, error) result

  val run_process :
    program:string ->
    arguments:string array ->
    maximum:int ->
    timeout:float ->
    after_spawn:(int -> unit) ->
    (string, error) result

  val run_process_with_hooks :
    program:string ->
    arguments:string array ->
    maximum:int ->
    timeout:float ->
    before_pipe:(int -> unit) ->
    child_setup_delay:float ->
    after_fork:(int -> unit) ->
    after_readiness_selectable:(unit -> unit) ->
    before_ack_write:(unit -> unit) ->
    before_ack_close:(unit -> unit) ->
    after_spawn:(int -> unit) ->
    before_waitpid:(unit -> unit) ->
    (string * Unix.process_status, error) result

  val parse_knowledge_root : string -> (unit, error) result
  val trusted_amp_runtime : unit -> (string * string array, error) result
  val amp_remote : string -> string -> bool
  val amp_git :
    repo:string -> remote:string -> arguments:(string -> string list) ->
    maximum:int -> timeout:float -> (string, error) result
  val local_origin_main_with_hooks :
    repo:string -> timeout:float -> child_setup_delay:float ->
    after_fork:(int -> unit) -> (string, error) result
end
