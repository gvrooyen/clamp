type error = { code : string; message : string }

type created = {
  path : string;
  source_repository : string;
  runtime_revision : string;
}

val create :
  target:string ->
  source_repository:string ->
  runtime_version:string ->
  runtime_revision:string ->
  runtime_url:string ->
  runtime_sha256:string ->
  ?runtime_root:string ->
  unit ->
  (created, error) Stdlib.result

val preflight :
  target:string ->
  source_repository:string ->
  (unit, error) Stdlib.result

val exit_class : error -> Exit_class.t
