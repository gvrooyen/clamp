type request = Version of string | Latest

type error_kind = Validation | Transient | Internal

type error = {
  kind : error_kind;
  code : string;
  message : string;
}

type success = {
  previous_version : string;
  version : string;
  installation_root : string;
  changed : bool;
}

type release = {
  version : string;
  revision : string;
  target : string;
  url : string;
  sha256 : string;
  manifest_url : string option;
  manifest_sha256 : string option;
  runtime_root : string;
}

val run : current_version:string -> request -> (success, error) result
val with_release : ?target:string -> request -> (release -> 'a) -> ('a, error) result
val with_offline_release :
  target:string ->
  version:string ->
  manifest_path:string ->
  manifest_sha256:string ->
  archive_path:string ->
  (release -> 'a) ->
  ('a, error) result
val exit_class : error -> Exit_class.t

module For_test : sig
  val valid_version : string -> bool
  val latest_version : string -> (string, error) result
  val checksum : version:string -> string -> (string, error) result
  val release_urls : version:string -> string * string
  val archive_sizes_safe : ?maximum:int64 -> string -> bool
  val detected_target : unit -> (string, error) result

  val with_manifest_release :
    target:string ->
    version:string ->
    manifest:string ->
    manifest_sha256:string ->
    archive:string ->
    (release -> 'a) ->
    ('a, error) result

  val install_archive :
    current_version:string ->
    installation_root:string ->
    version:string ->
    archive:string ->
    checksum:string ->
    (success, error) result

  val install_prepared :
    current_version:string ->
    installation_root:string ->
    release ->
    (success, error) result

  val with_release_archive :
    version:string ->
    archive:string ->
    checksum:string ->
    (release -> 'a) ->
    ('a, error) result
end
