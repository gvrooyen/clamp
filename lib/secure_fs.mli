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
(** Opens one entry without following it, including symlinks. Linux uses
    O_PATH; Darwin uses O_EVTONLY/O_SYMLINK and fails closed if entry access
    is denied. *)
val create_file_at : Unix.file_descr -> string -> Unix.file_descr
val flock : Unix.file_descr -> bool -> unit
(** Advisory [flock] on the already-open descriptor. [true] requests an
    exclusive lock and [false] a shared lock. *)
val funlock : Unix.file_descr -> unit
val mkdir_at : Unix.file_descr -> string -> unit
val mkdir_private_at : Unix.file_descr -> string -> Unix.file_descr
(** Creates a directory and returns a descriptor for the created inode, even
    under a restrictive umask. Darwin creates with the final owner-only mode. *)
val chmod_descriptor : Unix.file_descr -> int -> unit
(** Descriptor-bound mode repair. This also supports [O_PATH] descriptors
    returned by [mkdir_private_at]. *)
(** Linux [renameat2] / Darwin [renameatx_np]. They fail closed when the syscall or the
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
val fsync : Unix.file_descr -> unit
(** Durable data/metadata synchronization, including the device cache on
    Darwin. Darwin accepts only local APFS; unsupported operations fail closed. *)
val descriptor_count : unit -> int
(** Number of open descriptors, including the temporary enumeration descriptor.
    Intended for relative leak assertions, with identical counting on both OSes. *)
type directory_removal
val watch_directory_removal : Unix.file_descr -> directory_removal
val directory_removal_observed : directory_removal -> bool
val close_directory_removal : directory_removal -> unit
(** Register immediately before final validated removal, after quarantine and
    fault hooks. The caller keeps the source descriptor open until the witness
    is closed. Linux checks its real zero link count; Darwin also retains a
    duplicate and latches NOTE_DELETE. Never reuse a witness across
    rename-exchange: Darwin can report DELETE for an exchange destination. A
    missing event is not removal proof. *)

(** [open_beneath root relative] opens a regular-file candidate without
    following symlinks in any component. Empty, [.], [..], slash-containing,
    and NUL-containing components are rejected. The caller owns the returned
    descriptor. *)
val open_beneath : Unix.file_descr -> string -> Unix.file_descr

(** Synchronize every regular file and directory in a no-follow tree, with
    directories synchronized bottom-up. Rejects links, special entries, and
    concurrent identity replacement. *)
type tree_snapshot
val sync_tree : string -> tree_snapshot
(** Validate the complete names, kinds, and identities of a synchronized tree
    through its retained root descriptor. *)
val tree_matches : Unix.file_descr -> tree_snapshot -> bool

(** Remove exactly the retained tree through [parent], first moving it to an
    operation-private random quarantine name. [validate] is checked before and
    after every destructive/durability boundary. Foreign replacements are
    preserved and reported through an exception. *)
val remove_tree_at :
  validate:(unit -> bool) -> Unix.file_descr -> string -> Unix.file_descr ->
  identity -> unit

module For_test : sig
  val with_rename_error_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  val with_flock_error_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  val with_fsync_error_hook :
    (Unix.file_descr -> unit) -> (unit -> 'a) -> 'a
  val with_sync_tree_error_hook : (unit -> unit) -> (unit -> 'a) -> 'a
end
