type t =
  | Success
  | User_error
  | Conflict
  | Authentication
  | Transient_external
  | Stale_index
  | Internal

val code : t -> int
val name : t -> string
