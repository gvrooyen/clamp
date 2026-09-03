type t =
  | Success
  | User_error
  | Conflict
  | Authentication
  | Transient_external
  | Stale_index
  | Internal

let code = function
  | Success -> 0
  | User_error -> 2
  | Conflict -> 3
  | Authentication -> 4
  | Transient_external -> 5
  | Stale_index -> 6
  | Internal -> 70

let name = function
  | Success -> "success"
  | User_error -> "user_error"
  | Conflict -> "conflict"
  | Authentication -> "authentication"
  | Transient_external -> "transient_external"
  | Stale_index -> "stale_index"
  | Internal -> "internal"
