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

val valid_thread_id : string -> bool
val exit_class : error -> Exit_class.t
val error_details : error -> Yojson.Safe.t

val run :
  repo:string -> thread_id:string -> preserve_conflict:bool ->
  (report, error) result

module For_test : sig
  type hooks = {
    before_push : attempt:int -> refspec:string -> unit;
    after_preservation_proven : branch:string -> commit:string -> unit;
    after_main_push : commit:string -> unit;
    before_sync : commit:string -> unit;
    now : unit -> float;
  }

  val default_hooks : hooks

  val run :
    repo:string -> thread_id:string -> preserve_conflict:bool ->
    sync:(string -> (Sync.report, Sync.error) result) -> hooks:hooks ->
    (report, error) result
end
