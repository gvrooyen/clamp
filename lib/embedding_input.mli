type t = { text : string; sha256 : string }

type error = Invalid_utf8 | Too_large of { actual : int; maximum : int }

val maximum_bytes : int
val make : Frontmatter.t -> (t, error) result
val changed : Frontmatter.t -> Frontmatter.t -> (bool, error) result
val error_code : error -> string
val error_message : error -> string
