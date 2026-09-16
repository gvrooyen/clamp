type error = {
  code : string;
  message : string;
  details : Yojson.Safe.t;
  exit_class : Exit_class.t;
}

type success = {
  code : string;
  from_version : string;
  to_version : string;
  changed_paths : string list;
}

type generated_file = { path : string; mode : int; contents : string }

val generated_files :
  runtime_root:string -> lock:string -> version:string ->
  (generated_file list, error) result

val upgrade :
  repo:string ->
  runtime_root:string ->
  runtime_version:string ->
  runtime_revision:string ->
  manifest_url:string ->
  manifest_sha256:string ->
  (success, error) result

module For_test : sig
  val with_install_hook : (string -> unit) -> (unit -> 'a) -> 'a
  val with_interruption_after : int -> (unit -> 'a) -> 'a
  val with_commit_interruption : (unit -> 'a) -> 'a
  val with_cleanup_interruption : (unit -> 'a) -> 'a
  val with_cleanup_entry_interruption : string -> (unit -> 'a) -> 'a
  val with_preparation_interruption : (unit -> 'a) -> 'a
  val with_record_exchange_interruption : (unit -> 'a) -> 'a
  val with_slot_creation_interruption : (unit -> 'a) -> 'a
  val with_initial_record_interruption : (unit -> 'a) -> 'a
end
