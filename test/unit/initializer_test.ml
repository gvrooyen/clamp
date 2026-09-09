let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let write path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents)

let rec mkdirs path =
  if path <> Filename.dirname path && not (Sys.file_exists path) then begin
    mkdirs (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let runtime_root root =
  let templates = Filename.concat root "share/clamp/templates" in
  let source =
    if Sys.file_exists "runtime/templates" then "runtime/templates"
    else "../../runtime/templates"
  in
  mkdirs templates;
  [ "setup"; "resume"; "skill.md"; "AGENTS.md"; "README.md"; "gitignore" ]
  |> List.iter (fun name ->
         write (Filename.concat templates name)
           (read (Filename.concat source name)));
  root

let check_ok = function
  | Ok value -> value
  | Error (failure : Clamp.Initializer.error) ->
      Alcotest.failf "%s: %s" failure.code failure.message

let create root target =
  Clamp.Initializer.create ~target
    ~source_repository:"example.invalid/owner/private-clamp"
    ~runtime_version:"0.1.2"
    ~runtime_revision:"0123456789abcdef0123456789abcdef01234567"
    ~runtime_url:
      "https://github.com/gvrooyen/clamp/releases/download/v0.1.2/clamp-0.1.2-linux-x86_64.tar.gz"
    ~runtime_sha256:(String.make 64 'a') ~runtime_root:root ()

let complete_private_repository () =
  let parent = Filename.temp_file "clamp-init-" "" in
  Sys.remove parent;
  Unix.mkdir parent 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf -- " ^ Filename.quote parent)))
    (fun () ->
      let templates = runtime_root (Filename.concat parent "runtime") in
      let target = Filename.concat parent "private-clamp" in
      let created = check_ok (create templates target) in
      Alcotest.(check string) "reported path" target created.path;
      Alcotest.(check bool) "Git repository" true
        (Sys.file_exists (Filename.concat target ".git/HEAD"));
      Alcotest.(check string) "main branch" "ref: refs/heads/main\n"
        (read (Filename.concat target ".git/HEAD"));
      Alcotest.(check bool) "no inherited Git hooks" false
        (Sys.file_exists (Filename.concat target ".git/hooks"));
      Alcotest.(check int) "one initial commit" 0
        (Sys.command
           (Printf.sprintf
              "test \"$(git -C %s rev-list --count HEAD)\" = 1"
              (Filename.quote target)));
      Alcotest.(check int) "clean initialized repository" 0
        (Sys.command
           (Printf.sprintf "test -z \"$(git -C %s status --porcelain)\""
              (Filename.quote target)));
      Alcotest.(check string) "generic commit author"
        "Clamp Initializer <clamp@local.invalid>\n"
        (let output = Filename.concat parent "author" in
         let command =
           Printf.sprintf "git -C %s show -s --format='%%an <%%ae>' > %s"
             (Filename.quote target) (Filename.quote output)
         in
         if Sys.command command <> 0 then Alcotest.fail "could not read initial author";
         read output);
      Alcotest.(check string) "empty TODO"
        (Clamp.Local.render_todo ~now:0. []) (read (Filename.concat target "TODO.md"));
      let validation = Clamp.Bundle.validate target in
      Alcotest.(check int) "empty concepts" 0 validation.concepts;
      Alcotest.(check bool) "valid bundle" false
        (List.exists Clamp.Diagnostic.is_error validation.diagnostics);
      [ "bin"; "lib"; "test"; "db"; "dune"; "dune-project";
        "clamp.opam"; "clamp.opam.locked" ]
      |> List.iter (fun path ->
             Alcotest.(check bool) ("implementation absent: " ^ path) false
               (Sys.file_exists (Filename.concat target path)));
      Alcotest.(check bool) "setup executable" true
        (((Unix.stat (Filename.concat target ".agents/setup")).st_perm land 0o100) <> 0);
      Alcotest.(check string) "runtime lock"
        ("version=0.1.2\n"
         ^ "revision=0123456789abcdef0123456789abcdef01234567\n"
         ^ "url=https://github.com/gvrooyen/clamp/releases/download/v0.1.2/clamp-0.1.2-linux-x86_64.tar.gz\n"
         ^ "sha256=" ^ String.make 64 'a' ^ "\n")
        (read (Filename.concat target ".agents/clamp-runtime.lock")))

let rejects_without_side_effects () =
  let parent = Filename.temp_file "clamp-init-invalid-" "" in
  Sys.remove parent;
  Unix.mkdir parent 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf -- " ^ Filename.quote parent)))
    (fun () ->
      let templates = runtime_root (Filename.concat parent "runtime") in
      let target = Filename.concat parent "private-clamp" in
      let result =
        Clamp.Initializer.create ~target ~source_repository:"invalid"
          ~runtime_version:"0.1.0"
          ~runtime_revision:"0123456789abcdef0123456789abcdef01234567"
          ~runtime_url:"https://example.invalid/runtime.tar.gz"
          ~runtime_sha256:(String.make 64 'a') ~runtime_root:templates ()
      in
      (match result with
      | Error failure ->
          Alcotest.(check string) "stable error" "source_repository_invalid"
            failure.code
      | Ok _ -> Alcotest.fail "invalid source repository accepted");
      Alcotest.(check bool) "target absent" false (Sys.file_exists target);
      (match
         Clamp.Initializer.create ~target ~source_repository:"example.invalid/private"
           ~runtime_version:"0.1.0"
           ~runtime_revision:"0123456789abcdef0123456789abcdef01234567"
           ~runtime_url:"https://example.invalid/runtime archive.tar.gz"
           ~runtime_sha256:(String.make 64 'a') ~runtime_root:templates ()
       with
      | Error failure ->
          Alcotest.(check string) "URL error" "runtime_url_invalid" failure.code
      | Ok _ -> Alcotest.fail "runtime URL containing whitespace accepted");
      ignore (check_ok (create templates target));
      let marker = Filename.concat target "marker" in
      write marker "owner data\n";
      (match create templates target with
      | Error failure ->
          Alcotest.(check string) "existing error" "init_target_exists" failure.code
      | Ok _ -> Alcotest.fail "existing target replaced");
      Alcotest.(check string) "existing target preserved" "owner data\n" (read marker))

let () =
  Alcotest.run "Clamp private repository initialization"
    [ ("init",
       [ Alcotest.test_case "complete source-free repository" `Quick
           complete_private_repository;
         Alcotest.test_case "invalid and existing targets" `Quick
           rejects_without_side_effects ]) ]
