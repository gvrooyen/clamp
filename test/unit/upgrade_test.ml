let get_ok = function Ok value -> value | Error error -> Alcotest.fail error.Clamp.Upgrade.code

let write ?(mode = 0o644) path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents);
  Unix.chmod path mode

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let reported_version executable =
  let channel =
    Unix.open_process_args_in executable [| executable; "--version" |]
  in
  let output = input_line channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> output
  | _ -> Alcotest.fail "fixture kb --version failed"

let rec remove path =
  if Sys.file_exists path then
    match (Unix.lstat path).st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | _ -> Unix.unlink path

let with_directory action =
  let root = Filename.temp_file "clamp-upgrade-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> action root)

let release_layout root version =
  Unix.mkdir root 0o755;
  Unix.mkdir (Filename.concat root "bin") 0o755;
  Unix.mkdir (Filename.concat root "lib") 0o755;
  write ~mode:0o755 (Filename.concat root "bin/kb")
    (Printf.sprintf
       "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '%s\\n'; exit 0; fi\nexit 2\n"
       version);
  write (Filename.concat root "README.txt") "release\n";
  write (Filename.concat root "LICENSE") "license\n";
  write (Filename.concat root "THIRD_PARTY_NOTICES") "notices\n"

let version_contract () =
  let valid = Clamp.Upgrade.For_test.valid_version in
  List.iter
    (fun value -> Alcotest.(check bool) value true (valid value))
    [ "0.1.0"; "10.20.30" ];
  List.iter
    (fun value -> Alcotest.(check bool) value false (valid value))
    [ ""; "v1.2.3"; "1.2"; "1.2.3.4"; "01.2.3"; "1.02.3";
      "1.2.03"; "1.2.3-rc1" ];
  Alcotest.(check (result string string)) "latest tag" (Ok "1.2.3")
    (Clamp.Upgrade.For_test.latest_version {|{"tag_name":"v1.2.3"}|}
    |> Result.map_error (fun error -> error.Clamp.Upgrade.code));
  Alcotest.(check string) "invalid latest code" "upgrade_latest_invalid"
    (match Clamp.Upgrade.For_test.latest_version {|{"tag_name":"v1.2.3-rc1"}|} with
    | Error error -> error.code
    | Ok _ -> Alcotest.fail "invalid latest version accepted");
  let archive, checksum = Clamp.Upgrade.For_test.release_urls ~version:"1.2.3" in
  Alcotest.(check string) "archive URL"
    "https://github.com/gvrooyen/clamp/releases/download/v1.2.3/clamp-1.2.3-linux-x86_64.tar.gz"
    archive;
  Alcotest.(check string) "checksum URL" (archive ^ ".sha256") checksum

let checksum_contract () =
  let digest = String.make 64 'a' in
  let contents = digest ^ "  clamp-1.2.3-linux-x86_64.tar.gz\n" in
  Alcotest.(check (result string string)) "published checksum" (Ok digest)
    (Clamp.Upgrade.For_test.checksum ~version:"1.2.3" contents
    |> Result.map_error (fun error -> error.Clamp.Upgrade.code));
  List.iter
    (fun contents ->
      Alcotest.(check bool) "invalid checksum" true
        (Result.is_error
           (Clamp.Upgrade.For_test.checksum ~version:"1.2.3" contents)))
    [ digest ^ "  other.tar.gz\n"; String.make 64 'A' ^ "  clamp-1.2.3-linux-x86_64.tar.gz\n";
      digest ^ " *clamp-1.2.3-linux-x86_64.tar.gz\n"; contents ^ "extra\n" ]

let atomic_install () =
  with_directory (fun parent ->
      let installation = Filename.concat parent "installed" in
      release_layout installation "0.1.3";
      let source = Filename.concat parent "source" in
      Unix.mkdir source 0o700;
      let archive_root = "clamp-0.2.0-linux-x86_64" in
      release_layout (Filename.concat source archive_root) "0.2.0";
      let archive_path = Filename.concat parent (archive_root ^ ".tar.gz") in
      let command =
        Printf.sprintf "/usr/bin/tar -C %s -czf %s %s"
          (Filename.quote source) (Filename.quote archive_path)
          (Filename.quote archive_root)
      in
      Alcotest.(check int) "fixture archive" 0 (Sys.command command);
      let archive = read archive_path in
      let mismatch =
        Clamp.Upgrade.For_test.install_archive ~current_version:"0.1.3"
          ~installation_root:installation ~version:"0.2.0" ~archive
          ~checksum:(String.make 64 '0' ^ "  " ^ archive_root ^ ".tar.gz\n")
      in
      Alcotest.(check string) "checksum mismatch" "upgrade_checksum_mismatch"
        (match mismatch with
        | Error error -> error.code
        | Ok _ -> Alcotest.fail "checksum mismatch installed");
      Alcotest.(check string) "old installation preserved" "0.1.3"
        (reported_version (Filename.concat installation "bin/kb"));
      write ~mode:0o755 (Filename.concat source (archive_root ^ "/bin/kb"))
        "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '9.9.9\\n'; exit 0; fi\nexit 2\n";
      Alcotest.(check int) "wrong-version fixture archive" 0
        (Sys.command command);
      let wrong_archive = read archive_path in
      let wrong_digest = Digestif.SHA256.(to_hex (digest_string wrong_archive)) in
      let wrong_checksum = wrong_digest ^ "  " ^ archive_root ^ ".tar.gz\n" in
      let wrong_candidate =
        Clamp.Upgrade.For_test.install_archive ~current_version:"0.1.3"
          ~installation_root:installation ~version:"0.2.0"
          ~archive:wrong_archive ~checksum:wrong_checksum
      in
      Alcotest.(check string) "candidate version mismatch"
        "upgrade_candidate_invalid"
        (match wrong_candidate with
        | Error error -> error.code
        | Ok _ -> Alcotest.fail "wrong candidate version installed");
      Alcotest.(check string) "candidate failure preserves old installation"
        "0.1.3" (reported_version (Filename.concat installation "bin/kb"));
      write ~mode:0o755 (Filename.concat source (archive_root ^ "/bin/kb"))
        "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '0.2.0\\n'; exit 0; fi\nexit 2\n";
      Alcotest.(check int) "valid fixture archive" 0 (Sys.command command);
      let archive = read archive_path in
      let digest = Digestif.SHA256.(to_hex (digest_string archive)) in
      let checksum = digest ^ "  " ^ archive_root ^ ".tar.gz\n" in
      let result =
        get_ok
          (Clamp.Upgrade.For_test.install_archive ~current_version:"0.1.3"
             ~installation_root:installation ~version:"0.2.0" ~archive
             ~checksum)
      in
      Alcotest.(check bool) "installation changed" true result.changed;
      Alcotest.(check string) "installed version" "0.2.0" result.version;
      Alcotest.(check string) "new installation runs" "0.2.0"
        (reported_version (Filename.concat installation "bin/kb"));
      Sys.readdir parent
      |> Array.iter (fun name ->
             Alcotest.(check bool) ("no updater residue: " ^ name) false
               (String.starts_with ~prefix:".clamp-upgrade-" name)))

let () =
  Alcotest.run "Clamp release upgrade"
    [ ( "upgrade",
        [ Alcotest.test_case "version and latest contract" `Quick version_contract;
          Alcotest.test_case "checksum contract" `Quick checksum_contract;
          Alcotest.test_case "verified atomic installation" `Quick atomic_install ] ) ]
