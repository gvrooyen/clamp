module Fs = Clamp.Secure_fs

let rec remove path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
      Unix.chmod path 0o700;
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let with_root action =
  let path = Filename.temp_file "clamp-secure-fs-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  let directory = Fs.open_directory path in
  Fun.protect ~finally:(fun () -> Unix.close directory; remove path)
    (fun () -> action path directory)

let with_fd fd action = Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> action fd)
let same a b = a.Fs.device = b.Fs.device && a.inode = b.inode
let check label value = Alcotest.(check bool) label true value
let unix_error label action =
  check label (try action (); false with Unix.Unix_error _ -> true)

let entries () = with_root (fun path root ->
    let original = with_fd (Fs.create_file_at root "file") (fun fd ->
        ignore (Unix.write_substring fd "asymmetric" 0 10);
        Fs.fsync fd;
        Fs.descriptor_identity fd) in
    Unix.link (Filename.concat path "file") (Filename.concat path "hard");
    with_fd (Fs.open_path_at root "hard") (fun fd ->
        Alcotest.(check int) "hard link count" 2 (Fs.descriptor_link_count fd);
        check "hard link identity" (same original (Fs.descriptor_identity fd)));
    Unix.utimes (Filename.concat path "file") 1000.125 2000.375;
    with_fd (Fs.open_file_at root "file") (fun fd ->
        List.iter (fun identity ->
            Alcotest.(check (pair int64 int)) "exact subsecond modification time"
              (2000L, 375_000_000)
              (identity.Fs.modified_seconds, identity.modified_nanoseconds))
          [Fs.descriptor_identity fd; snd (Fs.inspect root "file")]);
    Unix.symlink "missing" (Filename.concat path "link");
    let kind, link = Fs.inspect root "link" in
    check "lstat symlink" (kind = Fs.Symlink);
    with_fd (Fs.open_path_at root "link") (fun fd ->
        check "descriptor witnesses link, not target" (same link (Fs.descriptor_identity fd));
        Fs.unlink_at root "link";
        Unix.symlink "file" (Filename.concat path "link");
        check "retained witness detects replacement"
          (not (same (Fs.descriptor_identity fd) (snd (Fs.inspect root "link")))));
    unix_error "file open never follows link" (fun () ->
        with_fd (Fs.open_file_at root "link") ignore);
    Unix.symlink "." (Filename.concat path "directory-link");
    unix_error "directory traversal never follows link" (fun () ->
        with_fd (Fs.open_directory_at root "directory-link") ignore);
    unix_error "beneath never follows intermediate link" (fun () ->
        with_fd (Fs.open_beneath root "directory-link/file") ignore);
    Unix.mkfifo (Filename.concat path "fifo") 0o600;
    with_fd (Fs.open_path_at root "fifo") (fun fd ->
        check "FIFO metadata open witnesses the entry"
          (same (snd (Fs.inspect root "fifo")) (Fs.descriptor_identity fd)));
    let seen = ref [] in Fs.iter_entries root (fun name -> seen := name :: !seen);
    Alcotest.(check (list string)) "entries exclude dot entries"
      ["directory-link"; "fifo"; "file"; "hard"; "link"]
      (List.sort String.compare !seen);
    check "nanoseconds are in range"
      (original.modified_nanoseconds >= 0 && original.modified_nanoseconds < 1_000_000_000
       && original.changed_nanoseconds >= 0 && original.changed_nanoseconds < 1_000_000_000);
    Alcotest.(check int64) "exact file size" 10L original.size;
    Fs.fsync root)

let private_modes () = with_root (fun path root ->
    let previous = Unix.umask 0o777 in
    let fd = Fun.protect ~finally:(fun () -> ignore (Unix.umask previous))
        (fun () -> Fs.mkdir_private_at root "private") in
    with_fd fd (fun fd ->
        let original = Fs.descriptor_identity fd in
        Fs.rename_noreplace root "private" root "retained";
        Unix.mkdir (Filename.concat path "private") 0o755;
        let foreign_mode = (Unix.stat (Filename.concat path "private")).st_perm in
        Fs.chmod_descriptor fd 0o700;
        check "chmod remains descriptor bound"
          (same original (snd (Fs.inspect root "retained")));
        Alcotest.(check int) "foreign replacement mode unchanged" foreign_mode
          (Unix.stat (Filename.concat path "private")).st_perm;
        Alcotest.(check (pair int int)) "private ownership and mode"
          (Fs.effective_uid (), 0o700) (Fs.descriptor_owner_mode fd));
    with_fd (Fs.open_directory_at root "retained") (fun fd ->
        Fs.fsync fd;
        let watch = Fs.watch_directory_removal fd in
        Fun.protect ~finally:(fun () -> Fs.close_directory_removal watch) (fun () ->
            Fs.rmdir_at root "retained";
            check "removed directory witness" (Fs.directory_removal_observed watch);
            Fs.fsync root;
            check "removal proof survives repeated checks" (Fs.directory_removal_observed watch)));
    Fs.mkdir_at root "ordinary";
    Fs.rmdir_at root "ordinary";
    Fs.fsync root)

let atomic () = with_root (fun path root ->
    let a = with_fd (Fs.create_file_at root "a") Fs.descriptor_identity in
    let b = with_fd (Fs.create_file_at root "b") Fs.descriptor_identity in
    unix_error "exclusive rename does not overwrite" (fun () -> Fs.rename_noreplace root "a" root "b");
    check "destination preserved" (same b (snd (Fs.inspect root "b")));
    Fs.rename_exchange root "a" root "b";
    check "swap source" (same b (snd (Fs.inspect root "a")));
    check "swap destination" (same a (snd (Fs.inspect root "b")));
    List.iter (fun error ->
        Alcotest.check_raises "unsupported is stable" Fs.Atomic_rename_unavailable
          (fun () -> Fs.For_test.with_rename_error_hook
              (fun () -> raise (Unix.Unix_error (error, "fixture", "")))
              (fun () -> Fs.rename_exchange root "a" root "b")))
      [Unix.ENOSYS; Unix.EINVAL; Unix.EOPNOTSUPP];
    with_fd (Fs.create_file_at root "replacement") (fun _ ->
    Alcotest.check_raises "replacement at validation boundary" Fs.Rename_validation_failed
      (fun () -> Fs.For_test.with_rename_error_hook
          (fun () -> Unix.rename
              (Filename.concat path "replacement") (Filename.concat path "a"))
          (fun () -> Fs.rename_exchange_checked root "a" root "b"
              ~validate:(fun () -> same b (snd (Fs.inspect root "a")))));
    check "failed checked rename preserves destination" (same a (snd (Fs.inspect root "b"))));
    unix_error "missing exchange destination fails" (fun () -> Fs.rename_exchange root "a" root "missing");
    Fs.rename_noreplace root "a" root "moved";
    Fs.unlink_at root "moved";
    Fs.fsync root)

let locking () = with_root (fun path root ->
    Fs.flock root true;
    let read, write = Unix.pipe ~cloexec:true () in
    match Unix.fork () with
    | 0 ->
        Unix.close read; Unix.close root;
        (try with_fd (Fs.open_directory path) (fun fd ->
             Fs.flock fd false;
             ignore (Unix.write_substring write "L" 0 1);
             Fs.funlock fd);
           Unix._exit 0 with _ -> Unix._exit 2)
    | pid ->
        Unix.close write;
        let readable, _, _ = Unix.select [read] [] [] 0.1 in
        check "exclusive lock blocks independently opened shared lock" (readable = []);
        Fs.funlock root;
        let readable, _, _ = Unix.select [read] [] [] 3. in
        check "unlock releases waiter" (readable = [read]);
        Unix.close read;
        check "waiter succeeded" (snd (Unix.waitpid [] pid) = Unix.WEXITED 0))

let removal_races () = with_root (fun path root ->
    let before = Fs.descriptor_count () in
    for index = 1 to 40 do
      let name = "witness-" ^ string_of_int index in
      with_fd (Fs.mkdir_private_at root name) (fun path_fd ->
          with_fd (Fs.open_directory_at root name) (fun data_fd ->
              let fd = if index mod 2 = 0 then path_fd else data_fd in
              let watch = Fs.watch_directory_removal fd in
              Fun.protect ~finally:(fun () -> Fs.close_directory_removal watch) (fun () ->
                  Fs.rename_noreplace root name root "renamed";
                  check "rename is not deletion" (not (Fs.directory_removal_observed watch));
                  Unix.mkdir (Filename.concat path name) 0o700;
                  Fs.rmdir_at root name;
                  check "replacement deletion is not original deletion"
                    (not (Fs.directory_removal_observed watch));
                  Fs.rmdir_at root "renamed";
                  check "retained original deletion is observed" (Fs.directory_removal_observed watch))))
    done;
    Alcotest.(check int) "watch queues and duplicates all closed" before (Fs.descriptor_count ());
    Fs.mkdir_at root "closed-source";
    let watch = with_fd (Fs.open_directory_at root "closed-source")
        Fs.watch_directory_removal in
    Fun.protect ~finally:(fun () -> Fs.close_directory_removal watch) (fun () ->
        with_fd (Fs.create_file_at root "reused-fd") (fun _ ->
            Fs.rmdir_at root "closed-source";
            let observed =
              try Fs.directory_removal_observed watch with Unix.Unix_error _ -> false
            in
            if Clamp.Upgrade.For_test.detected_target () = Ok "macos-arm64" then
              check "Darwin watch owns its descriptor independently of source reuse"
                observed
            else
              check "Linux borrowed descriptor reuse fails closed" (not observed)));
    Fs.close_directory_removal watch;
    check "closed watch cannot certify removal" (try
      ignore (Fs.directory_removal_observed watch); false
      with Invalid_argument _ -> true);
    with_fd (Fs.create_file_at root "regular") (fun fd ->
        check "non-directory registration fails" (try
          let watch = Fs.watch_directory_removal fd in Fs.close_directory_removal watch; false
          with Invalid_argument _ -> true));
    Fs.mkdir_at root "nonempty";
    with_fd (Fs.open_directory_at root "nonempty") (fun fd ->
        with_fd (Fs.create_file_at fd "child") ignore;
        let watch = Fs.watch_directory_removal fd in
        Fun.protect ~finally:(fun () -> Fs.close_directory_removal watch) (fun () ->
            unix_error "failed rmdir" (fun () -> Fs.rmdir_at root "nonempty");
            check "failed syscall is not deletion" (not (Fs.directory_removal_observed watch)))))

let descriptors () =
  let before = Fs.descriptor_count () in
  with_root (fun _ root ->
      let baseline = Fs.descriptor_count () in
      with_fd (Fs.create_file_at root "callback") (fun _ ->
          Alcotest.(check int) "count detects an additional live descriptor"
            (baseline + 1) (Fs.descriptor_count ()));
      Alcotest.(check int) "count detects descriptor close" baseline (Fs.descriptor_count ());
      for _ = 1 to 100 do
        unix_error "missing entry" (fun () -> with_fd (Fs.open_path_at root "missing") ignore);
        (try Fs.iter_entries root (fun _ -> raise Exit) with Exit -> ())
      done);
  Alcotest.(check int) "exact descriptor cleanup" before (Fs.descriptor_count ())

let unsupported_durability () =
  if Clamp.Upgrade.For_test.detected_target () = Ok "macos-arm64" then begin
    let before = Fs.descriptor_count () in
    for _ = 1 to 20 do
      Alcotest.check_raises "devfs traversal fails closed"
        (Unix.Unix_error (Unix.EOPNOTSUPP, "open", "/dev"))
        (fun () -> with_fd (Fs.open_directory "/dev") ignore);
      with_fd (Unix.openfile "/dev" [Unix.O_RDONLY; Unix.O_CLOEXEC] 0) (fun fd ->
          Alcotest.check_raises "devfs durability never falls back"
            (Unix.Unix_error (Unix.EOPNOTSUPP, "fsync", ""))
            (fun () -> Fs.fsync fd))
    done;
    Alcotest.(check int) "unsupported filesystem failures close descriptors"
      before (Fs.descriptor_count ())
  end

let tree_durability () = with_root (fun path root ->
    Fs.mkdir_at root "tree";
    with_fd (Fs.open_directory_at root "tree") (fun tree ->
        with_fd (Fs.create_file_at tree "file") (fun file ->
            ignore (Unix.write_substring file "durable" 0 7));
        Fs.mkdir_at tree "nested";
        with_fd (Fs.open_directory_at tree "nested") (fun nested ->
            with_fd (Fs.create_file_at nested "leaf") (fun leaf ->
                ignore (Unix.write_substring leaf "state" 0 5))));
    ignore (Fs.sync_tree (Filename.concat path "tree"));
    let injected = ref false in
    Alcotest.check_raises "tree synchronization propagates failure"
      (Unix.Unix_error (Unix.EIO, "sync_tree", ""))
      (fun () ->
        Fs.For_test.with_sync_tree_error_hook
          (fun () ->
            injected := true;
            raise (Unix.Unix_error (Unix.EIO, "sync_tree", "")))
          (fun () -> ignore (Fs.sync_tree (Filename.concat path "tree"))));
    check "tree fault seam invoked" !injected;
    Unix.symlink "file" (Filename.concat path "tree/link");
    Alcotest.check_raises "tree synchronization rejects symlinks"
      Fs.Rename_validation_failed
      (fun () -> ignore (Fs.sync_tree (Filename.concat path "tree")));
    Unix.unlink (Filename.concat path "tree/link"))

let final_tree_and_cleanup_races () = with_root (fun path root ->
    Fs.mkdir_at root "tree-race";
    with_fd (Fs.open_directory_at root "tree-race") (fun tree ->
        with_fd (Fs.create_file_at tree "file") (fun file ->
            ignore (Unix.write_substring file "old" 0 3));
        let tree_identity = Unix.fstat tree and replaced = ref false in
        Alcotest.check_raises "final directory flush replacement is rejected"
          Fs.Rename_validation_failed
          (fun () ->
            ignore
              (Fs.For_test.with_fsync_error_hook
                 (fun descriptor ->
                   let identity = Unix.fstat descriptor in
                   if
                     (not !replaced) && identity.st_dev = tree_identity.st_dev
                     && identity.st_ino = tree_identity.st_ino
                   then begin
                     replaced := true;
                     Unix.unlink (Filename.concat path "tree-race/file");
                     Unix.symlink "foreign" (Filename.concat path "tree-race/file")
                   end)
                 (fun () -> Fs.sync_tree (Filename.concat path "tree-race"))));
        check "final flush replacement injected" !replaced;
        Unix.unlink (Filename.concat path "tree-race/file"));
    Fs.rmdir_at root "tree-race";
    Fs.mkdir_at root "cleanup-race";
    let retained = Fs.open_path_at root "cleanup-race" in
    Fun.protect ~finally:(fun () -> Unix.close retained) (fun () ->
        let identity = Fs.descriptor_identity retained in
        let root_identity = Unix.fstat root and quarantine = ref None in
        let recreate_after_removal descriptor =
          let stat = Unix.fstat descriptor in
          let entries = Sys.readdir path |> Array.to_list in
          (match
             List.find_opt (String.starts_with ~prefix:".clamp-remove-") entries
           with Some name -> quarantine := Some name | None -> ());
          if stat.st_dev = root_identity.st_dev && stat.st_ino = root_identity.st_ino
          then
            Option.iter
              (fun name ->
                if not (Sys.file_exists (Filename.concat path name)) then
                  Unix.mkdir (Filename.concat path name) 0o700)
              !quarantine
        in
        Alcotest.check_raises "quarantine recreation fails cleanup proof"
          Fs.Rename_validation_failed
          (fun () ->
            Fs.For_test.with_fsync_error_hook recreate_after_removal (fun () ->
                Fs.remove_tree_at ~validate:(fun () -> true) root "cleanup-race"
                  retained identity));
        check "foreign quarantine recreation preserved"
          (Option.exists
             (fun name -> Sys.file_exists (Filename.concat path name)) !quarantine));
    Option.iter
      (fun name -> Unix.rmdir (Filename.concat path name))
      (Sys.readdir path |> Array.to_list
       |> List.find_opt (String.starts_with ~prefix:".clamp-remove-"));
    Fs.mkdir_at root "ancestor-race";
    with_fd (Fs.open_directory_at root "ancestor-race") (fun ancestor ->
        Fs.mkdir_at ancestor "a";
        Fs.mkdir_at ancestor "b");
    let retained = Fs.open_path_at root "ancestor-race" in
    Fun.protect ~finally:(fun () -> Unix.close retained) (fun () ->
        let identity = Fs.descriptor_identity retained
        and rename_calls = ref 0 and outer_quarantine = ref "" in
        Alcotest.check_raises "ancestor substitution stops child cleanup"
          Fs.Rename_validation_failed
          (fun () ->
            Fs.For_test.with_rename_error_hook
              (fun () ->
                incr rename_calls;
                if !rename_calls = 2 then begin
                  let quarantine =
                    Sys.readdir path |> Array.to_list
                    |> List.find
                         (String.starts_with ~prefix:".clamp-remove-")
                  in
                  outer_quarantine := quarantine;
                  Unix.rename (Filename.concat path quarantine)
                    (Filename.concat path "detached-cleanup");
                  Unix.mkdir (Filename.concat path quarantine) 0o700
                end)
              (fun () ->
                Fs.remove_tree_at ~validate:(fun () -> true) root "ancestor-race"
                  retained identity));
        check "foreign ancestor replacement preserved"
          (Sys.file_exists (Filename.concat path !outer_quarantine));
        check "detached first child preserved"
          (Sys.file_exists (Filename.concat path "detached-cleanup/a"));
        check "detached second child preserved"
          (Sys.file_exists (Filename.concat path "detached-cleanup/b"))))

let () = Alcotest.run "native secure filesystem"
    ["contract", List.map (fun (name, test) -> Alcotest.test_case name `Quick test)
       ["entries and durability", entries; "private modes", private_modes;
        "atomic races and failures", atomic; "locking", locking;
        "removal witnesses", removal_races;
        "descriptor cleanup", descriptors;
        "unsupported durability", unsupported_durability;
        "tree durability", tree_durability;
        "final tree and cleanup races", final_tree_and_cleanup_races]]
