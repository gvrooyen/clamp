type error =
  | Missing_or_unreadable
  | Not_regular
  | Changed_during_read
  | Too_large

val unchanged : Secure_fs.identity -> Secure_fs.identity -> bool
val same_file : Secure_fs.identity -> Secure_fs.identity -> bool

(** [read_descriptor ~expected descriptor] consumes [descriptor]. Ownership is
    transferred to this function, which closes it before returning or raising;
    callers must not close or reuse it afterward. *)
val read_descriptor :
  expected:Secure_fs.identity -> Unix.file_descr -> (string, error) result

module For_test : sig
  (** Test hook variant with the same descriptor ownership transfer as
      [read_descriptor]. *)
  val read_descriptor_with_hook :
    expected:Secure_fs.identity ->
    after_open:(unit -> unit) ->
    Unix.file_descr ->
    (string, error) result
end

val message : error -> string
val code : error -> string
