let get_ok = function Ok value -> value | Error error -> Alcotest.fail error.Clamp.Upgrade.code

let metadata_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail error.Clamp.Runtime_metadata.code

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

let fixture_revision = "0123456789abcdef0123456789abcdef01234567"

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
  write (Filename.concat root "THIRD_PARTY_NOTICES") "notices\n";
  write (Filename.concat root "VERSION") (version ^ "\n");
  write (Filename.concat root "REVISION") (fixture_revision ^ "\n")

let rec mkdirs path =
  if path <> Filename.dirname path && not (Sys.file_exists path) then begin
    mkdirs (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let manifest_release_layout root version =
  release_layout root version;
  Clamp.Runtime_metadata.mandatory_files
  |> List.iter (fun relative ->
         let path = Filename.concat root relative in
         if not (Sys.file_exists path) then begin
           mkdirs (Filename.dirname path);
           write path (relative ^ "\n")
         end)

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

let resolved_release_archive () =
  with_directory (fun parent ->
      let source = Filename.concat parent "source" in
      Unix.mkdir source 0o700;
      let archive_root = "clamp-1.2.3-linux-x86_64" in
      release_layout (Filename.concat source archive_root) "1.2.3";
      let archive_path = Filename.concat parent (archive_root ^ ".tar.gz") in
      let command =
        Printf.sprintf "/usr/bin/tar -C %s -czf %s %s"
          (Filename.quote source) (Filename.quote archive_path)
          (Filename.quote archive_root)
      in
      Alcotest.(check int) "fixture archive" 0 (Sys.command command);
      let archive = read archive_path in
      let digest = Digestif.SHA256.(to_hex (digest_string archive)) in
      let checksum = digest ^ "  " ^ archive_root ^ ".tar.gz\n" in
      let extracted = ref "" in
      let resolved =
        get_ok
          (Clamp.Upgrade.For_test.with_release_archive ~version:"1.2.3"
             ~archive ~checksum (fun (release : Clamp.Upgrade.release) ->
               extracted := release.runtime_root;
               Alcotest.(check bool) "runtime available to callback" true
                 (Sys.file_exists
                    (Filename.concat release.runtime_root "bin/kb"));
               release))
      in
      Alcotest.(check string) "release version" "1.2.3" resolved.version;
      Alcotest.(check string) "release revision" fixture_revision
        resolved.revision;
      Alcotest.(check string) "release SHA-256" digest resolved.sha256;
      Alcotest.(check string) "release URL"
        "https://github.com/gvrooyen/clamp/releases/download/v1.2.3/clamp-1.2.3-linux-x86_64.tar.gz"
        resolved.url;
      Alcotest.(check bool) "temporary runtime cleaned" false
        (Sys.file_exists !extracted);
      write (Filename.concat source (archive_root ^ "/REVISION"))
        "not-a-revision\n";
      Alcotest.(check int) "invalid marker archive" 0 (Sys.command command);
      let invalid_archive = read archive_path in
      let invalid_digest =
        Digestif.SHA256.(to_hex (digest_string invalid_archive))
      in
      let invalid_checksum =
        invalid_digest ^ "  " ^ archive_root ^ ".tar.gz\n"
      in
      let invalid =
        Clamp.Upgrade.For_test.with_release_archive ~version:"1.2.3"
          ~archive:invalid_archive ~checksum:invalid_checksum Fun.id
      in
      Alcotest.(check string) "invalid marker code" "upgrade_archive_invalid"
        (match invalid with
        | Error error -> error.code
        | Ok _ -> Alcotest.fail "invalid revision marker accepted"))

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

let portable_metadata_contract () =
  let module Metadata = Clamp.Runtime_metadata in
  let version = "0.2.0" in
  let revision = fixture_revision in
  let make_target target digest size : Metadata.target =
    { target;
      archive_url =
        "https://github.com/gvrooyen/clamp/releases/download/v0.2.0/"
        ^ Metadata.archive_name ~version ~target;
      archive_sha256 = digest;
      archive_root = "clamp-0.2.0-" ^ target;
      archive_size = size;
      required_files = Metadata.mandatory_files }
  in
  let digest = String.make 64 'a' in
  let manifest : Metadata.manifest =
    { version; revision;
      targets =
        [ make_target "linux-x86_64" digest 1024;
          make_target "macos-arm64" digest 2048 ] }
  in
  let serialized = metadata_ok (Metadata.serialize_manifest manifest) in
  Alcotest.(check string) "deterministic manifest" serialized
    (metadata_ok (Metadata.serialize_manifest manifest));
  let parsed =
    metadata_ok (Metadata.parse_manifest ~expected_version:version serialized)
  in
  Alcotest.(check string) "exact Mac selection" "macos-arm64"
    (metadata_ok (Metadata.select_target parsed "macos-arm64")).target;
  Alcotest.(check string) "no target fallback" "runtime_manifest_target_missing"
    (match Metadata.select_target parsed "linux-arm64" with
    | Error error -> error.code
    | Ok _ -> Alcotest.fail "unknown target selected");
  let manifest_url, _ = Metadata.manifest_urls ~version in
  let lock : Metadata.v2_lock =
    { version; revision; manifest_url; manifest_sha256 = digest }
  in
  let lock = Metadata.serialize_lock lock in
  List.iter
    (fun target ->
      Alcotest.(check bool) ("v2 lock on " ^ target) true
        (Result.is_ok (Metadata.parse_lock ~target lock)))
    Metadata.accepted_targets;
  let v1 =
    "version=0.1.4\nrevision=" ^ revision
    ^ "\nurl=https://github.com/gvrooyen/clamp/releases/download/v0.1.4/clamp-0.1.4-linux-x86_64.tar.gz\nsha256="
    ^ digest ^ "\n"
  in
  Alcotest.(check bool) "v1 Linux lock retained" true
    (Result.is_ok (Metadata.parse_lock ~target:"linux-x86_64" v1));
  Alcotest.(check string) "v1 Mac migration required" "runtime_lock_v2_invalid"
    (match Metadata.parse_lock ~target:"macos-arm64" v1 with
    | Error error -> error.code
    | Ok _ -> Alcotest.fail "v1 lock accepted on Mac");
  let duplicate =
    Str.replace_first (Str.regexp_string {|"schema_version":1|})
      {|"schema_version":1,"schema_version":1|} serialized
  in
  Alcotest.(check bool) "duplicate key rejected" true
    (Result.is_error (Metadata.parse_manifest ~expected_version:version duplicate));
  let unknown_target =
    Str.replace_first (Str.regexp_string "macos-arm64") "linux-arm64" serialized
  in
  Alcotest.(check bool) "unknown manifest target rejected" true
    (Result.is_error
       (Metadata.parse_manifest ~expected_version:version unknown_target));
  Alcotest.(check string) "oversized manifest code" "runtime_manifest_too_large"
    (match
       Metadata.parse_manifest ~expected_version:version
         (String.make (Metadata.maximum_manifest_bytes + 1) ' ')
     with
    | Error error -> error.code
    | Ok _ -> Alcotest.fail "oversized manifest accepted")

let portable_tar_listing () =
  let safe = Clamp.Upgrade.For_test.archive_sizes_safe ~maximum:4L in
  Alcotest.(check bool) "GNU tar regular and directory" true
    (safe
       "drwxr-xr-x 0/0 0 2026-09-12 09:14 root/\n-rw-r--r-- 0/0 4 2026-09-12 09:14 root/file\n");
  Alcotest.(check bool) "macOS bsdtar regular and directory" true
    (safe
       "drwxr-xr-x 0 502 0 0 Sep 12 11:13 root/\n-rw-r--r-- 0 502 0 4 Sep 12 11:13 root/file\n");
  Alcotest.(check bool) "macOS size is fifth token" false
    (Clamp.Upgrade.For_test.archive_sizes_safe ~maximum:3L
       "-rw-r--r-- 0 0 0 4 Sep 12 11:13 root/file\n");
  List.iter
    (fun mode ->
      Alcotest.(check bool) ("reject archive type " ^ mode) false
        (safe (mode ^ " 0 0 0 0 Sep 12 11:13 root/link\n")))
    [ "lrwxr-xr-x"; "hrw-r--r--" ]

let verified_manifest_archive () =
  with_directory (fun parent ->
      let module Metadata = Clamp.Runtime_metadata in
      let version = "0.2.0" and target = "linux-x86_64" in
      let archive_root = "clamp-0.2.0-linux-x86_64" in
      let source = Filename.concat parent "source" in
      Unix.mkdir source 0o700;
      manifest_release_layout (Filename.concat source archive_root) version;
      let archive_path = Filename.concat parent (archive_root ^ ".tar.gz") in
      let command =
        Printf.sprintf "/usr/bin/tar -C %s -czf %s %s"
          (Filename.quote source) (Filename.quote archive_path)
          (Filename.quote archive_root)
      in
      Alcotest.(check int) "manifest fixture archive" 0 (Sys.command command);
      let archive = read archive_path in
      let digest = Digestif.SHA256.(to_hex (digest_string archive)) in
      let record : Metadata.target =
        { target;
          archive_url =
            "https://github.com/gvrooyen/clamp/releases/download/v0.2.0/"
            ^ Metadata.archive_name ~version ~target;
          archive_sha256 = digest; archive_root;
          archive_size = String.length archive;
          required_files = Metadata.mandatory_files }
      in
      let manifest =
        metadata_ok
          (Metadata.serialize_manifest
             { version; revision = fixture_revision; targets = [ record ] })
      in
      let manifest_sha256 = Digestif.SHA256.(to_hex (digest_string manifest)) in
      let resolved =
        get_ok
          (Clamp.Upgrade.For_test.with_manifest_release ~target ~version ~manifest
             ~manifest_sha256 ~archive Fun.id)
      in
      Alcotest.(check string) "manifest release target" target resolved.target;
      Alcotest.(check string) "manifest release revision" fixture_revision
        resolved.revision;
      Alcotest.(check (option string)) "manifest lock URL"
        (Some
           "https://github.com/gvrooyen/clamp/releases/download/v0.2.0/clamp-0.2.0-runtime-manifest.json")
        resolved.manifest_url;
      Alcotest.(check string) "manifest checksum mismatch"
        "runtime_manifest_checksum_mismatch"
        (match
           Clamp.Upgrade.For_test.with_manifest_release ~target ~version ~manifest
             ~manifest_sha256:(String.make 64 '0') ~archive Fun.id
         with
        | Error error -> error.code
        | Ok _ -> Alcotest.fail "bad manifest checksum accepted");
      Alcotest.(check string) "archive checksum mismatch"
        "runtime_archive_checksum_mismatch"
        (let changed_archive = Bytes.of_string archive in
         Bytes.set changed_archive 0
           (if Bytes.get changed_archive 0 = '\000' then '\001' else '\000');
         match
           Clamp.Upgrade.For_test.with_manifest_release ~target ~version ~manifest
             ~manifest_sha256 ~archive:(Bytes.unsafe_to_string changed_archive) Fun.id
         with
        | Error error -> error.code
        | Ok _ -> Alcotest.fail "bad archive accepted"))

let () =
  Alcotest.run "Clamp release upgrade"
    [ ( "upgrade",
        [ Alcotest.test_case "version and latest contract" `Quick version_contract;
          Alcotest.test_case "checksum contract" `Quick checksum_contract;
          Alcotest.test_case "verified release metadata" `Quick
            resolved_release_archive;
          Alcotest.test_case "verified atomic installation" `Quick atomic_install;
          Alcotest.test_case "portable metadata contract" `Quick
            portable_metadata_contract;
          Alcotest.test_case "portable tar listing" `Quick portable_tar_listing;
          Alcotest.test_case "verified manifest archive" `Quick
            verified_manifest_archive ] ) ]
