type error = { code : string; message : string }

type task_due =
  | Due_on of string
  | Due_at of string * Timedesc.Timestamp.t

type task = {
  id : string;
  doc : Frontmatter.t;
  state : string;
  priority : string;
  title : string;
  due : task_due option;
}

type operation =
  | Temp_create | Write | File_fsync | Rename | Dir_fsync | Unlink
  | Rollback | Mkdir | Directory_open | Mode_repair | Private_revalidate | Rmdir

type ownership_phase =
  | Before_target_install
  | After_target_exchange
  | Before_target_restore
  | Before_target_restore_capture
  | After_target_restore_capture
  | Before_temp_cleanup
  | After_temp_capture
  | After_directory_create
  | Before_directory_cleanup
  | After_directory_capture
  | Before_private_destruct

type transaction_phase =
  | After_task_prepared
  | After_task_input_render
  | After_todo_prepared
  | After_task_renamed
  | After_todo_renamed

type task_input_capture_phase =
  | After_task_directory_retained
  | After_task_directory_enumerated
  | After_task_member_opened
  | Before_task_member_revalidate

type task_read_phase =
  | After_task_root_inspect
  | After_task_knowledge_inspect
  | After_task_directory_inspect
  | After_task_member_inspect
  | After_task_member_read
  | After_task_directory_reenumerated

type optional_todo_read_phase =
  | After_todo_inspect
  | After_todo_opened

type private_directory_cleanup_proof =
  | Parent_chain
  | Parent_mode
  | Removed_directory_nlink
  | Quarantine_absence

val error : string -> string -> ('a, error) result
val exit_class : error -> Exit_class.t
val read : string -> (string, error) result
val with_shared_repo :
  string -> (Unix.file_descr -> ('a, error) result) -> ('a, error) result
val with_exclusive_repo :
  string -> (Unix.file_descr -> ('a, error) result) -> ('a, error) result
val with_read_lock_if_present :
  Unix.file_descr -> (unit -> ('a, error) result) -> ('a, error) result
val todo_drift_at : Unix.file_descr -> (bool, error) result
val todo_at : Unix.file_descr -> (string, error) result

type mutation_disposition = Created | Updated
type mutation_result = { id : string; disposition : mutation_disposition }

val mutate_with_outcome :
  repo:string -> id:string -> contents:string -> claim:string -> confirmed:bool ->
  allow_unknown:bool -> create:bool -> (mutation_result, error) result
val mutate :
  repo:string -> id:string -> contents:string -> claim:string -> confirmed:bool ->
  allow_unknown:bool -> create:bool -> (string, error) result
val verify :
  authority:string option -> string -> string -> (string, error) result
val deprecate_checked :
  claim:string -> confirmed:bool -> string -> string -> string option ->
  (string, error) result
val set_policy : string -> string -> (unit, error) result

val task_of : string -> Frontmatter.t -> task option
val compare_task : task -> task -> int
val list_tasks : string -> (task list, error) result
val tasks : string -> (task list, error) result
val render_todo : now:float -> task list -> string
val todo : string -> (string, error) result
val todo_drift : string -> (bool, error) result
val markdown_label : string -> string

val valid_ulid : string -> bool
val ulid_with : now_ms:(unit -> int64) -> entropy:(int -> bytes) -> string
val ulid : unit -> string
val valid_slug : string -> bool
val slug : string -> string
val task_path : string -> bool
val add_task :
  repo:string -> contents:string -> claim:string -> confirmed:bool ->
  (string, error) result
val transition :
  ?closure_authority:string -> string -> string -> string -> (string, error) result

val verification_events : Exact_yaml.t -> Exact_yaml.t list
val canonical_document_bytes : Frontmatter.t -> (string, error) result

module For_test : sig
  val with_clock : (unit -> float) -> (unit -> 'a) -> 'a
  val with_transaction_hook : (transaction_phase -> unit) -> (unit -> 'a) -> 'a
  val with_operation_hook : (operation -> unit) -> (unit -> 'a) -> 'a
  val with_final_gate_failure_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  val with_ownership_hook : (ownership_phase -> unit) -> (unit -> 'a) -> 'a
  val with_after_existing_read_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  val with_private_directory_cleanup_proof_hook :
    (private_directory_cleanup_proof -> bool -> unit) -> (unit -> 'a) -> 'a
  val with_task_input_capture_hook :
    (task_input_capture_phase -> unit) -> (unit -> 'a) -> 'a
  val with_task_read_hook : (task_read_phase -> unit) -> (unit -> 'a) -> 'a
  val with_optional_todo_read_hook :
    (optional_todo_read_phase -> unit) -> (unit -> 'a) -> 'a
end
