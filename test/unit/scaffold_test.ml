let source_root =
  Option.value (Sys.getenv_opt "DUNE_SOURCEROOT")
    ~default:(if Sys.file_exists "runtime/templates" then "." else "../..")

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let write ?(mode = 0o600) path contents =
  let descriptor =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] mode
  in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      let bytes = Bytes.unsafe_of_string contents in
      let rec loop offset =
        if offset < Bytes.length bytes then
          let count = Unix.write descriptor bytes offset (Bytes.length bytes - offset) in
          if count = 0 then raise End_of_file else loop (offset + count)
      in
      loop 0;
      Unix.fchmod descriptor mode)

let rec mkdirs path =
  if path <> Filename.dirname path && not (Sys.file_exists path) then begin
    mkdirs (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let command value =
  let status = Sys.command value in
  if status <> 0 then Alcotest.failf "command failed (%d): %s" status value

let find_prefixed directory prefix =
  Sys.readdir directory |> Array.to_list
  |> List.find (String.starts_with ~prefix)

let assert_no_preparation_state root =
  let names = Sys.readdir (Filename.concat root ".clamp") |> Array.to_list in
  List.iter
    (fun prefix ->
      Alcotest.(check bool) ("no retained " ^ prefix) false
        (List.exists (String.starts_with ~prefix) names))
    [ "scaffold-upgrade-preparing"; ".clamp-remove-" ]

let git root arguments =
  command
    (String.concat " "
       ("env -i HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null"
        :: "/usr/bin/git" :: "-C" :: Filename.quote root
        :: List.map Filename.quote arguments))

let git_show path =
  let command =
    Printf.sprintf "/usr/bin/git -C %s show %s"
      (Filename.quote source_root) (Filename.quote ("v0.1.4:runtime/templates/" ^ path))
  in
  let channel = Unix.open_process_in command in
  let buffer = Buffer.create 4096 in
  (try while true do Buffer.add_channel buffer channel 4096 done with End_of_file -> ());
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> Buffer.contents buffer
  | _ -> Alcotest.failf "could not read v0.1.4 template %s" path

let runtime_root parent =
  let root = Filename.concat parent "runtime" in
  let destination = Filename.concat root "share/clamp/templates" in
  mkdirs destination;
  [ "setup"; "resume"; "setup-local"; "kb"; "runtime_metadata.py";
    "skill.md"; "AGENTS.md"; "README.md"; "gitignore" ]
  |> List.iter (fun name ->
         let mode =
           if List.mem name [ "setup"; "resume"; "setup-local"; "kb" ]
           then 0o700 else 0o600
         in
         write ~mode (Filename.concat destination name)
           (read (Filename.concat source_root ("runtime/templates/" ^ name))));
  root

let with_directory action =
  let root = Filename.temp_file "clamp-scaffold-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command ("rm -rf -- " ^ Filename.quote root)))
    (fun () -> action root)

let revision = "0123456789abcdef0123456789abcdef01234567"
let manifest_sha256 = String.make 64 'b'
let manifest_url =
  "https://github.com/gvrooyen/clamp/releases/download/v0.2.0/clamp-0.2.0-runtime-manifest.json"

let create_legacy parent =
  let root = Filename.concat parent "private" in
  Unix.mkdir root 0o700;
  mkdirs (Filename.concat root ".agents/skills/managing-clamp-knowledge");
  mkdirs (Filename.concat root "knowledge/facts");
  [ ("resume", ".agents/resume", 0o700);
    ("setup", ".agents/setup", 0o700);
    ("skill.md", ".agents/skills/managing-clamp-knowledge/SKILL.md", 0o600);
    ("gitignore", ".gitignore", 0o600);
    ("AGENTS.md", "AGENTS.md", 0o600);
    ("README.md", "README.md", 0o600) ]
  |> List.iter (fun (template, path, mode) ->
         write ~mode (Filename.concat root path) (git_show template));
  write (Filename.concat root ".agents/clamp-runtime.lock")
    ("version=0.1.4\nrevision=" ^ revision
     ^ "\nurl=https://github.com/gvrooyen/clamp/releases/download/v0.1.4/clamp-0.1.4-linux-x86_64.tar.gz\nsha256="
     ^ String.make 64 'a' ^ "\n");
  write (Filename.concat root "clamp.yaml") "owner config\n";
  write (Filename.concat root "TODO.md") "owner todo\n";
  write (Filename.concat root "knowledge/facts/preserved.md") "private knowledge\n";
  git root [ "init"; "--quiet"; "--initial-branch=main" ];
  git root [ "config"; "user.name"; "Fixture" ];
  git root [ "config"; "user.email"; "fixture@example.invalid" ];
  git root [ "add"; "--all" ];
  git root [ "commit"; "--quiet"; "--message=legacy" ];
  root

let run root runtime =
  Clamp.Scaffold.upgrade ~repo:root ~runtime_root:runtime
    ~runtime_version:"0.2.0" ~runtime_revision:revision ~manifest_url
    ~manifest_sha256

let expect code
    (result : (Clamp.Scaffold.success, Clamp.Scaffold.error) result) =
  match result with
  | Ok success ->
      Alcotest.(check string) "success code" code success.Clamp.Scaffold.code;
      `Success success
  | Error failure ->
      if failure.Clamp.Scaffold.code <> code then
        Alcotest.failf "expected %s, got %s (%s): %s" code
          failure.code failure.message (Yojson.Safe.to_string failure.details);
      Alcotest.(check string) "error code" code failure.Clamp.Scaffold.code;
      `Failure failure

let exact_upgrade_and_rerun () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let head_before =
        let output = Filename.concat parent "head" in
        command (Printf.sprintf "/usr/bin/git -C %s rev-parse HEAD >%s"
                   (Filename.quote root) (Filename.quote output));
        read output
      in
      let result = run root runtime in
      ignore (expect "scaffold_upgrade_complete" result);
      Alcotest.(check string) "knowledge preserved" "private knowledge\n"
        (read (Filename.concat root "knowledge/facts/preserved.md"));
      Alcotest.(check string) "config preserved" "owner config\n"
        (read (Filename.concat root "clamp.yaml"));
      Alcotest.(check string) "TODO preserved" "owner todo\n"
        (read (Filename.concat root "TODO.md"));
      let head_after = Filename.concat parent "head-after" in
      command (Printf.sprintf "/usr/bin/git -C %s rev-parse HEAD >%s"
                 (Filename.quote root) (Filename.quote head_after));
      Alcotest.(check string) "history unchanged" head_before (read head_after);
      List.iter
        (fun path ->
          Alcotest.(check bool) (path ^ " generated") true
            (Sys.file_exists (Filename.concat root path)))
        [ ".agents/kb"; ".agents/setup-local"; ".agents/runtime_metadata.py";
          ".agents/clamp-scaffold.json" ];
      git root [ "add"; "--all" ];
      git root [ "commit"; "--quiet"; "--message=portable" ];
      ignore (expect "scaffold_already_current" (run root runtime)))

let owner_modified_is_conflict () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      write (Filename.concat root "AGENTS.md")
        (git_show "AGENTS.md" ^ "\n# Owner customization\n");
      git root [ "add"; "AGENTS.md" ];
      git root [ "commit"; "--quiet"; "--message=custom" ];
      match expect "scaffold_owner_modified" (run root runtime) with
      | `Failure failure ->
          let paths =
            Yojson.Safe.Util.(failure.Clamp.Scaffold.details |> member "paths" |> to_list
                              |> List.map to_string)
          in
          Alcotest.(check (list string)) "reviewable path" [ "AGENTS.md" ] paths
      | `Success _ -> Alcotest.fail "owner modification accepted")

let current_v2_owner_modification_is_conflict () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      ignore (expect "scaffold_upgrade_complete" (run root runtime));
      git root [ "add"; "--all" ];
      git root [ "commit"; "--quiet"; "--message=portable" ];
      write (Filename.concat root "README.md") "reviewed owner replacement\n";
      git root [ "add"; "README.md" ];
      git root [ "commit"; "--quiet"; "--message=customize" ];
      match expect "scaffold_owner_modified" (run root runtime) with
      | `Failure failure ->
          Alcotest.(check (list string)) "v2 conflict path" [ "README.md" ]
            Yojson.Safe.Util.(failure.Clamp.Scaffold.details |> member "paths"
                              |> to_list |> List.map to_string)
      | `Success _ -> Alcotest.fail "modified v2 scaffold accepted")

let failure_rolls_back () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let calls = ref 0 in
      let result =
        Clamp.Scaffold.For_test.with_install_hook
          (fun _ -> incr calls; if !calls = 4 then raise Exit)
          (fun () -> run root runtime)
      in
      ignore (expect "scaffold_upgrade_failed" result);
      Alcotest.(check int) "injection reached" 4 !calls;
      Alcotest.(check int) "exact rollback is clean" 0
        (Sys.command
           (Printf.sprintf "test -z \"$(/usr/bin/git -C %s status --porcelain)\""
              (Filename.quote root)));
      Alcotest.(check bool) "transaction cleaned" false
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade")))

let interrupted_transaction_recovers_before_rerun () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let interrupted =
        try
          ignore
            (Clamp.Scaffold.For_test.with_interruption_after 3 (fun () ->
                 run root runtime));
          false
        with _ -> true
      in
      Alcotest.(check bool) "interruption injected" true interrupted;
      Alcotest.(check bool) "transaction retained" true
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade"));
      ignore (expect "scaffold_recovery_required" (run root runtime));
      Alcotest.(check int) "recovery restored exact Git state" 0
        (Sys.command
           (Printf.sprintf "test -z \"$(/usr/bin/git -C %s status --porcelain)\""
              (Filename.quote root)));
      Alcotest.(check bool) "recovered transaction removed" false
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade"));
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let interrupted_transaction_preserves_foreign_replacement () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_interruption_after 1 (fun () ->
                run root runtime))
       with _ -> ());
      let path = Filename.concat root ".agents/clamp-runtime.lock" in
      write path "foreign replacement\n";
      (match expect "scaffold_recovery_required" (run root runtime) with
      | `Failure failure ->
          Alcotest.(check string) "foreign state" "foreign_replacement"
            Yojson.Safe.Util.(failure.Clamp.Scaffold.details |> member "state"
                              |> to_string)
      | `Success _ -> Alcotest.fail "foreign replacement accepted");
      Alcotest.(check string) "foreign replacement preserved"
        "foreign replacement\n" (read path);
      Alcotest.(check bool) "transaction retained for review" true
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade")))

let committed_interruption_recovers_completion () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let interrupt wrapper expected_path =
        (try ignore (wrapper (fun () -> run root runtime)) with _ -> ());
        Alcotest.(check bool) "durable recovery state retained" true
          (Sys.file_exists (Filename.concat root expected_path));
        ignore (expect "scaffold_upgrade_complete" (run root runtime));
        Alcotest.(check bool) "recovery state cleaned" false
          (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade"));
        Alcotest.(check bool) "cleanup quarantine cleaned" false
          (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade-cleanup"))
      in
      interrupt Clamp.Scaffold.For_test.with_commit_interruption
        ".clamp/scaffold-upgrade")

let cleanup_rename_interruption_recovers_completion () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_cleanup_interruption (fun () ->
                run root runtime))
       with _ -> ());
      Alcotest.(check bool) "discoverable cleanup quarantine" true
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade-cleanup"));
      ignore (expect "scaffold_upgrade_complete" (run root runtime));
      Alcotest.(check bool) "cleanup quarantine removed" false
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade-cleanup")))

let cleanup_entry_interruption_recovers_completion () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_cleanup_entry_interruption "slot-000"
              (fun () -> run root runtime))
       with _ -> ());
      Alcotest.(check bool) "cleanup record retained" true
        (Sys.file_exists
           (Filename.concat root ".clamp/scaffold-upgrade-cleanup-record.json"));
      ignore (expect "scaffold_upgrade_complete" (run root runtime));
      Alcotest.(check bool) "cleanup record removed" false
        (Sys.file_exists
           (Filename.concat root ".clamp/scaffold-upgrade-cleanup-record.json")))

let preparation_interruption_recovers () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_preparation_interruption (fun () ->
                run root runtime))
       with _ -> ());
      (match expect "scaffold_recovery_required" (run root runtime) with
      | `Failure failure ->
          Alcotest.(check string) "recovered state" "transaction_recovery"
            Yojson.Safe.Util.(failure.Clamp.Scaffold.details |> member "state"
                              |> to_string)
      | `Success _ -> Alcotest.fail "preparation recovery reported success");
      assert_no_preparation_state root;
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let initial_record_interruption_recovers () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_initial_record_interruption (fun () ->
                run root runtime))
       with _ -> ());
      ignore (expect "scaffold_recovery_required" (run root runtime));
      assert_no_preparation_state root;
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let record_exchange_interruption_recovers () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_record_exchange_interruption (fun () ->
                run root runtime))
       with _ -> ());
      ignore (expect "scaffold_recovery_required" (run root runtime));
      assert_no_preparation_state root;
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let slot_creation_interruption_recovers () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_slot_creation_interruption (fun () ->
                run root runtime))
       with _ -> ());
      ignore (expect "scaffold_recovery_required" (run root runtime));
      assert_no_preparation_state root;
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let rollback_cleanup_interruption_recovers () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let calls = ref 0 in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_cleanup_entry_interruption "slot-000"
              (fun () ->
                Clamp.Scaffold.For_test.with_install_hook
                  (fun _ -> incr calls; if !calls = 4 then raise Exit)
                  (fun () -> run root runtime)))
       with _ -> ());
      ignore (expect "scaffold_recovery_required" (run root runtime));
      Alcotest.(check bool) "rollback cleanup removed" false
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade-cleanup"));
      ignore (expect "scaffold_upgrade_complete" (run root runtime)))

let committed_foreign_slot_is_preserved () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      (try
         ignore
           (Clamp.Scaffold.For_test.with_commit_interruption (fun () ->
                run root runtime))
       with _ -> ());
      let transaction = Filename.concat root ".clamp/scaffold-upgrade" in
      let slot_name = find_prefixed transaction "slot-000-" in
      let slot = Filename.concat transaction slot_name in
      let contents = read slot in
      let foreign = slot ^ ".foreign" in
      write foreign contents;
      Sys.remove slot;
      Unix.rename foreign slot;
      ignore (expect "scaffold_recovery_required" (run root runtime));
      let quarantined =
        Filename.concat root (".clamp/scaffold-upgrade-cleanup/" ^ slot_name)
      in
      Alcotest.(check string) "foreign slot preserved" contents (read quarantined))

let clamp_substitution_prevents_install () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let replaced = ref false in
      let result =
        Clamp.Scaffold.For_test.with_install_hook
          (fun _ ->
            if not !replaced then begin
              replaced := true;
              Unix.rename (Filename.concat root ".clamp")
                (Filename.concat root ".clamp-original");
              Unix.mkdir (Filename.concat root ".clamp") 0o700;
              write (Filename.concat root ".clamp/foreign") "preserve\n"
            end)
          (fun () -> run root runtime)
      in
      ignore (expect "scaffold_recovery_required" result);
      Alcotest.(check string) "foreign private root preserved" "preserve\n"
        (read (Filename.concat root ".clamp/foreign"));
      Alcotest.(check int) "no scaffold target changed" 0
        (Sys.command
           (Printf.sprintf "test -z \"$(/usr/bin/git -C %s status --porcelain --untracked-files=no)\""
              (Filename.quote root))))

let parent_substitution_preserves_foreign_tree () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let original = Filename.concat root ".agents-original" in
      let replacement = Filename.concat root ".agents" in
      let replaced = ref false in
      let result =
        Clamp.Scaffold.For_test.with_install_hook
          (fun _ ->
            if not !replaced then begin
              replaced := true;
              Unix.rename replacement original;
              Unix.mkdir replacement 0o700;
              write (Filename.concat replacement "clamp-runtime.lock")
                "foreign parent\n"
            end)
          (fun () -> run root runtime)
      in
      ignore (expect "scaffold_upgrade_failed" result);
      Alcotest.(check string) "foreign parent untouched" "foreign parent\n"
        (read (Filename.concat replacement "clamp-runtime.lock"));
      Alcotest.(check string) "detached original remains legacy"
        ("version=0.1.4\nrevision=" ^ revision
         ^ "\nurl=https://github.com/gvrooyen/clamp/releases/download/v0.1.4/clamp-0.1.4-linux-x86_64.tar.gz\nsha256="
         ^ String.make 64 'a' ^ "\n")
        (read (Filename.concat original "clamp-runtime.lock"));
      Alcotest.(check bool) "uncertain transaction retained" true
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade")))

let same_content_foreign_inode_is_preserved () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      let path = Filename.concat root ".agents/clamp-runtime.lock" in
      let contents = read path in
      let replacement = path ^ ".replacement" in
      let replacement_inode = ref 0 in
      let replaced = ref false in
      let result =
        Clamp.Scaffold.For_test.with_install_hook
          (fun _ ->
            if not !replaced then begin
              replaced := true;
              write replacement contents;
              Unix.rename replacement path;
              replacement_inode := (Unix.lstat path).st_ino
            end)
          (fun () -> run root runtime)
      in
      ignore (expect "scaffold_recovery_required" result);
      Alcotest.(check string) "foreign bytes preserved" contents (read path);
      Alcotest.(check int) "foreign inode preserved" !replacement_inode
        (Unix.lstat path).st_ino;
      Alcotest.(check bool) "transaction retained" true
        (Sys.file_exists (Filename.concat root ".clamp/scaffold-upgrade")))

let busy_repository_is_unchanged () =
  with_directory (fun parent ->
      let runtime = runtime_root parent and root = create_legacy parent in
      write (Filename.concat root "owner.tmp") "unrelated\n";
      ignore (expect "scaffold_busy" (run root runtime));
      Alcotest.(check string) "unrelated state preserved" "unrelated\n"
        (read (Filename.concat root "owner.tmp")))

let launcher_selects_repository_runtime () =
  with_directory (fun parent ->
      let runtime = runtime_root parent in
      let machine =
        let channel = Unix.open_process_args_in "/usr/bin/uname"
            [| "/usr/bin/uname"; "-m" |] in
        let value = input_line channel in
        ignore (Unix.close_process_in channel);
        value
      in
      let target_name = if machine = "arm64" then "macos-arm64" else "linux-x86_64" in
      let version = "0.2.0" in
      let archive_sha256 = String.make 64 'c' in
      let target : Clamp.Runtime_metadata.target =
        { target = target_name;
          archive_url =
            ("https://github.com/gvrooyen/clamp/releases/download/v0.2.0/clamp-0.2.0-"
             ^ target_name ^ ".tar.gz");
          archive_sha256; archive_root = "clamp-0.2.0-" ^ target_name;
          archive_size = 1024;
          required_files = Clamp.Runtime_metadata.mandatory_files }
      in
      let manifest =
        match
          Clamp.Runtime_metadata.serialize_manifest
            { version; revision; targets = [ target ] }
        with
        | Ok value -> value
        | Error error -> Alcotest.fail error.message
      in
      let manifest_sha256 = Digestif.SHA256.(to_hex (digest_string manifest)) in
      let manifest_url =
        "https://github.com/gvrooyen/clamp/releases/download/v0.2.0/clamp-0.2.0-runtime-manifest.json"
      in
      let root = Filename.concat parent "private repo;quoted" in
      (match
         Clamp.Initializer.create_v2 ~target:root
           ~source_repository:"example.invalid/owner/private"
           ~runtime_version:version ~runtime_revision:revision ~manifest_url
           ~manifest_sha256 ~runtime_root:runtime ()
       with
      | Ok _ -> ()
      | Error error -> Alcotest.failf "%s: %s" error.code error.message);
      let home = Filename.concat parent "empty home" in
      let manifest_cache =
        Filename.concat home
          (".local/share/clamp/kb/manifests/" ^ manifest_sha256 ^ ".json")
      in
      mkdirs (Filename.dirname manifest_cache);
      write manifest_cache manifest;
      let installation =
        Filename.concat home
          (".local/share/clamp/kb/runtimes/" ^ target_name ^ "/" ^ archive_sha256)
      in
      mkdirs (Filename.concat installation "bin");
      write (Filename.concat installation "VERSION") (version ^ "\n");
      write (Filename.concat installation "REVISION") (revision ^ "\n");
      write (Filename.concat installation ".archive-sha256")
        (archive_sha256 ^ "\n");
      write ~mode:0o700 (Filename.concat installation "bin/kb")
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 0.2.0; exit 0; fi\nprintf '%s\\n' \"$@\" >\"$CAPTURE\"\n";
      let capture = Filename.concat parent "captured arguments" in
      let launcher = Filename.concat root ".agents/kb" in
      command
        (Printf.sprintf
           "cd / && env -i HOME=%s CAPTURE=%s PATH=/hostile %s validate --json"
           (Filename.quote home) (Filename.quote capture) (Filename.quote launcher));
      Alcotest.(check (list string)) "explicit retained root and arguments"
        [ "--repo"; root; "validate"; "--json" ]
        (read capture |> String.split_on_char '\n'
         |> List.filter (fun value -> value <> "")))

let setup_local_preflight_is_bounded_and_redacted () =
  with_directory (fun parent ->
      let runtime = runtime_root parent in
      let root = Filename.concat parent "private setup repo" in
      let manifest_sha256 = String.make 64 'd' in
      (match
         Clamp.Initializer.create_v2 ~target:root
           ~source_repository:"example.invalid/owner/private"
           ~runtime_version:"0.2.0" ~runtime_revision:revision ~manifest_url
           ~manifest_sha256 ~runtime_root:runtime ()
       with
      | Ok _ -> ()
      | Error error -> Alcotest.failf "%s: %s" error.code error.message);
      write (Filename.concat root "unrelated.tmp") "preserve me\n";
      let home = Filename.concat parent "hostile home" in
      Unix.mkdir home 0o700;
      let output = Filename.concat parent "setup-output" in
      let sentinel = "setup-secret-sentinel" in
      let status =
        Sys.command
          (Printf.sprintf
             "cd / && env -i HOME=%s PATH=/hostile OPENROUTER_API_KEY=%s KB_DATABASE_URL=%s KB_DATABASE_DIRECT_URL=%s %s >%s 2>&1"
             (Filename.quote home) (Filename.quote sentinel)
             (Filename.quote sentinel) (Filename.quote sentinel)
             (Filename.quote (Filename.concat root ".agents/setup-local"))
             (Filename.quote output))
      in
      Alcotest.(check bool) "preflight fails before network" true (status <> 0);
      Alcotest.(check int) "frozen user-error exit" 2 status;
      let text = read output in
      let json = Yojson.Safe.from_string (String.trim text) in
      Alcotest.(check string) "machine code" "local_setup_dirty_worktree"
        Yojson.Safe.Util.(json |> member "code" |> to_string);
      Alcotest.(check (list string)) "exact body-free payload" [ "worktree" ]
        Yojson.Safe.Util.(json |> member "details" |> member "paths" |> to_list
                          |> List.map to_string);
      Alcotest.(check bool) "stable dirty-worktree code" true
        (let needle = "local_setup_dirty_worktree" in
         let length = String.length needle in
         let rec contains offset =
           offset + length <= String.length text
           && (String.sub text offset length = needle || contains (offset + 1))
         in
         contains 0);
      Alcotest.(check bool) "secret values are absent" false
        (let length = String.length sentinel in
         let rec contains offset =
           offset + length <= String.length text
           && (String.sub text offset length = sentinel || contains (offset + 1))
         in
         contains 0);
      Alcotest.(check string) "tracked and owner state unchanged" "preserve me\n"
        (read (Filename.concat root "unrelated.tmp")))

let setup_local_rejects_dangerous_git_config () =
  with_directory (fun parent ->
      let runtime = runtime_root parent in
      let root = Filename.concat parent "private setup repo" in
      (match
         Clamp.Initializer.create_v2 ~target:root
           ~source_repository:"example.invalid/owner/private"
           ~runtime_version:"0.2.0" ~runtime_revision:revision ~manifest_url
           ~manifest_sha256:(String.make 64 'd') ~runtime_root:runtime ()
       with
      | Ok _ -> ()
      | Error error -> Alcotest.failf "%s: %s" error.code error.message);
      git root [ "config"; "--local"; "http.sslVerify"; "false" ];
      let home = Filename.concat parent "home" in
      Unix.mkdir home 0o700;
      let output = Filename.concat parent "output" in
      let status =
        Sys.command
          (Printf.sprintf "env -i HOME=%s %s >%s 2>&1"
             (Filename.quote home)
             (Filename.quote (Filename.concat root ".agents/setup-local"))
             (Filename.quote output))
      in
      Alcotest.(check int) "user-error exit" 2 status;
      let json = Yojson.Safe.from_string (String.trim (read output)) in
      Alcotest.(check string) "unsafe Git code" "local_setup_repository_invalid"
        Yojson.Safe.Util.(json |> member "code" |> to_string))

let consumer_templates_exclude_source_workflows () =
  let contents =
    [ "AGENTS.md"; "README.md"; "skill.md" ]
    |> List.map (fun name -> read (Filename.concat source_root ("runtime/templates/" ^ name)))
    |> String.concat "\n"
  in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool) ("consumer template excludes " ^ forbidden) false
        (let length = String.length forbidden in
         let rec contains offset =
           offset + length <= String.length contents
           && (String.sub contents offset length = forbidden
               || contains (offset + 1))
         in
         contains 0))
    [ ".agents/phase9-acceptance"; "dune "; "opam ";
      "CLAMP_REVIEWED_PHASE7_KB"; "/home/user/workspace/repo" ]

let () =
  Alcotest.run "portable Clamp scaffold"
    [ ("upgrade",
       [ Alcotest.test_case "exact 0.1.4 and rerun" `Quick exact_upgrade_and_rerun;
         Alcotest.test_case "owner modification" `Quick owner_modified_is_conflict;
         Alcotest.test_case "current v2 owner modification" `Quick
           current_v2_owner_modification_is_conflict;
         Alcotest.test_case "reported failure rollback" `Quick failure_rolls_back;
         Alcotest.test_case "interrupted recovery" `Quick
           interrupted_transaction_recovers_before_rerun;
         Alcotest.test_case "foreign replacement" `Quick
           interrupted_transaction_preserves_foreign_replacement;
         Alcotest.test_case "committed interruption" `Quick
           committed_interruption_recovers_completion;
         Alcotest.test_case "cleanup rename interruption" `Quick
           cleanup_rename_interruption_recovers_completion;
         Alcotest.test_case "cleanup entry interruption" `Quick
           cleanup_entry_interruption_recovers_completion;
         Alcotest.test_case "preparation interruption" `Quick
           preparation_interruption_recovers;
         Alcotest.test_case "initial record interruption" `Quick
           initial_record_interruption_recovers;
         Alcotest.test_case "record exchange interruption" `Quick
           record_exchange_interruption_recovers;
         Alcotest.test_case "slot creation interruption" `Quick
           slot_creation_interruption_recovers;
         Alcotest.test_case "rollback cleanup interruption" `Quick
           rollback_cleanup_interruption_recovers;
         Alcotest.test_case "committed foreign slot" `Quick
           committed_foreign_slot_is_preserved;
         Alcotest.test_case "private root substitution" `Quick
           clamp_substitution_prevents_install;
         Alcotest.test_case "parent substitution" `Quick
           parent_substitution_preserves_foreign_tree;
         Alcotest.test_case "same-content foreign inode" `Quick
           same_content_foreign_inode_is_preserved;
         Alcotest.test_case "busy repository" `Quick busy_repository_is_unchanged;
         Alcotest.test_case "portable launcher" `Quick
           launcher_selects_repository_runtime;
         Alcotest.test_case "setup-local preflight" `Quick
           setup_local_preflight_is_bounded_and_redacted;
         Alcotest.test_case "setup-local Git config" `Quick
           setup_local_rejects_dangerous_git_config;
         Alcotest.test_case "source-free instructions" `Quick
           consumer_templates_exclude_source_workflows ]) ]
