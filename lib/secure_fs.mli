type kind = Regular | Directory | Symlink | Other

exception Atomic_rename_unavailable
exception Private_creation_unwitnessed
exception Rename_validation_failed

type identity = {
  device : int64;
  inode : int64;
  size : int64;
  modified_seconds : int64;
  modified_nanoseconds : int;
  changed_seconds : int64;
  changed_nanoseconds : int;
}

val valid_component : string -> bool
val open_directory : string -> Unix.file_descr
(** [open_directory] rejects embedded NUL bytes. The [_at] operations reject
    empty, [.], [..], slash-containing, and NUL-containing names before
    invoking the no-follow native primitives. *)
val open_directory_at : Unix.file_descr -> string -> Unix.file_descr
val open_file_at : Unix.file_descr -> string -> Unix.file_descr
val open_path_at : Unix.file_descr -> string -> Unix.file_descr
(** Opens one entry without following it. The returned [O_PATH] descriptor can
    witness any entry kind, including symlinks. *)
val create_file_at : Unix.file_descr -> string -> Unix.file_descr
val flock : Unix.file_descr -> bool -> unit
(** Advisory Linux [flock] on the already-open descriptor. [true] requests an
    exclusive lock and [false] a shared lock. *)
val funlock : Unix.file_descr -> unit
val mkdir_at : Unix.file_descr -> string -> unit
val mkdir_private_at : Unix.file_descr -> string -> Unix.file_descr
(** Creates a directory and returns an [O_PATH] descriptor for the created
    inode, even when the caller's umask initially removes all permissions. *)
val chmod_descriptor : Unix.file_descr -> int -> unit
(** Descriptor-bound mode repair. This also supports [O_PATH] descriptors
    returned by [mkdir_private_at]. *)
(** Linux [renameat2] operations. They fail closed when the syscall or the
    requested flag is unavailable; neither operation falls back to rename. *)
val rename_noreplace : Unix.file_descr -> string -> Unix.file_descr -> string -> unit
val rename_exchange : Unix.file_descr -> string -> Unix.file_descr -> string -> unit
(** Checked variants invoke the rename fault seam, evaluate [validate]
    exception-safely, and then issue the raw syscall without another callback. *)
val rename_noreplace_checked :
  validate:(unit -> bool) -> Unix.file_descr -> string -> Unix.file_descr -> string -> unit
val rename_exchange_checked :
  validate:(unit -> bool) -> Unix.file_descr -> string -> Unix.file_descr -> string -> unit
val unlink_at : Unix.file_descr -> string -> unit
val rmdir_at : Unix.file_descr -> string -> unit
val inspect : Unix.file_descr -> string -> kind * identity
val descriptor_identity : Unix.file_descr -> identity
val descriptor_link_count : Unix.file_descr -> int
val descriptor_owner_mode : Unix.file_descr -> int * int
(** Effective uid of this process, from [geteuid(2)]. *)
val effective_uid : unit -> int
val iter_entries : Unix.file_descr -> (string -> unit) -> unit

(** [open_beneath root relative] opens a regular-file candidate without
    following symlinks in any component. Empty, [.], [..], slash-containing,
    and NUL-containing components are rejected. The caller owns the returned
    descriptor. *)
val open_beneath : Unix.file_descr -> string -> Unix.file_descr

module For_test : sig
  val with_rename_error_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  val with_flock_error_hook : (unit -> unit) -> (unit -> 'a) -> 'a
end
