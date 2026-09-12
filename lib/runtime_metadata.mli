type error = { code : string; message : string }

type target = {
  target : string;
  archive_url : string;
  archive_sha256 : string;
  archive_root : string;
  archive_size : int;
  required_files : string list;
}

type manifest = {
  version : string;
  revision : string;
  targets : target list;
}

type v1_lock = {
  version : string;
  revision : string;
  url : string;
  sha256 : string;
}

type v2_lock = {
  version : string;
  revision : string;
  manifest_url : string;
  manifest_sha256 : string;
}

type lock = V1 of v1_lock | V2 of v2_lock

val maximum_lock_bytes : int
val maximum_manifest_bytes : int
val maximum_archive_bytes : int
val maximum_extracted_bytes : int64
val maximum_targets : int
val accepted_targets : string list
val mandatory_files : string list
val valid_version : string -> bool
val valid_revision : string -> bool
val valid_sha256 : string -> bool
val manifest_name : string -> string
val manifest_urls : version:string -> string * string
val archive_name : version:string -> target:string -> string
val parse_lock : target:string -> string -> (lock, error) result
val serialize_lock : v2_lock -> string
val parse_manifest : expected_version:string -> string -> (manifest, error) result
val serialize_manifest : manifest -> (string, error) result
val select_target : manifest -> string -> (target, error) result
