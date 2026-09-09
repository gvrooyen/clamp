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
  url : string;
  sha256 : string;
  runtime_root : string;
}

val run : current_version:string -> request -> (success, error) result
val with_release : request -> (release -> 'a) -> ('a, error) result
val exit_class : error -> Exit_class.t

module For_test : sig
  val valid_version : string -> bool
  val latest_version : string -> (string, error) result
  val checksum : version:string -> string -> (string, error) result
  val release_urls : version:string -> string * string

  val install_archive :
    current_version:string ->
    installation_root:string ->
    version:string ->
    archive:string ->
    checksum:string ->
    (success, error) result

  val with_release_archive :
    version:string ->
    archive:string ->
    checksum:string ->
    (release -> 'a) ->
    ('a, error) result
end
