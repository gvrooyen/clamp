type result = {
  concepts : int;
  reserved : int;
  diagnostics : Diagnostic.t list;
}

val ulid : string -> bool

type reserved_validation = {
  body : string;
  retain_links : bool;
  issues : (string * string) list;
}

val validate_reserved_document :
  relative:string -> string -> reserved_validation

type warning_source = {
  source_id : string;
  relative : string;
  type_name : string option;
  links : string list;
}

val warning_diagnostics :
  concept_ids:string list -> warning_source list -> Diagnostic.t list

val validate_checked : string -> (result, Local.error) Stdlib.result
val validate_at : string -> Unix.file_descr -> (result, Local.error) Stdlib.result
val validate : string -> result

module For_test : sig
  val validate_with_hook :
    after_preflight:(unit -> unit) -> string -> result
  val validate_with_open_hook :
    string -> after_open:(unit -> unit) -> result
  val validate_with_entry_hooks :
    string -> before_preflight_entry:(string -> unit) ->
    after_preflight:(unit -> unit) ->
    before_validation_entry:(string -> unit) -> result
end
