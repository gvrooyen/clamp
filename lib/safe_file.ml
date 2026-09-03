type error =
  | Missing_or_unreadable
  | Not_regular
  | Changed_during_read
  | Too_large

let unchanged left right =
  left.Secure_fs.device = right.Secure_fs.device && left.inode = right.inode
  && left.size = right.size
  && left.modified_seconds = right.modified_seconds
  && left.modified_nanoseconds = right.modified_nanoseconds
  && left.changed_seconds = right.changed_seconds
  && left.changed_nanoseconds = right.changed_nanoseconds

let same_file left right =
  left.Secure_fs.device = right.Secure_fs.device && left.inode = right.inode

let read_descriptor_with_hook ~expected ~after_open descriptor =
  Fun.protect
    ~finally:(fun () -> try Unix.close descriptor with _ -> ())
    (fun () ->
      let opened_status = Unix.fstat descriptor in
      let opened = Secure_fs.descriptor_identity descriptor in
      if opened_status.st_kind <> Unix.S_REG then Error Not_regular
      else if not (unchanged opened expected) then Error Changed_during_read
      else if opened.size > Int64.of_int Limits.max_file_bytes then Error Too_large
      else begin
        after_open ();
        let buffer = Bytes.create 65_536 in
        let output = Buffer.create (min (Int64.to_int opened.size) 65_536) in
        let rec loop total =
          if total = Limits.max_file_bytes then
            let probe = Bytes.create 1 in
            (match Unix.read descriptor probe 0 1 with
            | 0 ->
                let final = Secure_fs.descriptor_identity descriptor in
                if unchanged final opened then Ok (Buffer.contents output)
                else Error Changed_during_read
            | _ -> Error Too_large
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop total)
          else
            let available = Limits.max_file_bytes - total in
            match Unix.read descriptor buffer 0 (min available (Bytes.length buffer)) with
            | 0 ->
                let final = Secure_fs.descriptor_identity descriptor in
                if not (unchanged final opened) || Int64.of_int total <> final.size then
                  Error Changed_during_read
                else Ok (Buffer.contents output)
            | count ->
                Buffer.add_subbytes output buffer 0 count;
                loop (total + count)
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop total
        in
        loop 0
      end)

let read_descriptor ~expected descriptor =
  read_descriptor_with_hook ~expected ~after_open:(fun () -> ()) descriptor

module For_test = struct
  let read_descriptor_with_hook = read_descriptor_with_hook
end

let message = function
  | Missing_or_unreadable -> "file is missing or unreadable"
  | Not_regular -> "file must be a regular file and not a symlink"
  | Changed_during_read -> "file changed while it was being validated"
  | Too_large -> "file exceeds the 8 MiB safety limit"

let code = function
  | Missing_or_unreadable -> "file_unreadable"
  | Not_regular -> "file_not_regular"
  | Changed_during_read -> "file_changed"
  | Too_large -> "file_size_limit"
