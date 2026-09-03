type t

val success : code:string -> data:Yojson.Safe.t -> t

val failure :
  exit_class:Exit_class.t ->
  code:string ->
  message:string ->
  details:Yojson.Safe.t ->
  t

val not_implemented : command:string -> t
val exit_code : t -> int
val to_yojson : t -> Yojson.Safe.t
val to_json_string : t -> string
val message : t -> string option
