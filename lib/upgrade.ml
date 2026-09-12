type request = Version of string | Latest

type error_kind = Validation | Transient | Internal

type error = {
  kind : error_kind;
  code : string;
  message : string;
}

type success = {
  previous_version : string;
  version : string;
  installation_root : string;
  changed : bool;
}

type release = {
  version : string;
  revision : string;
  target : string;
  url : string;
  sha256 : string;
  manifest_url : string option;
  manifest_sha256 : string option;
  runtime_root : string;
}

let error kind code message = Error { kind; code; message }

let exit_class error =
  match error.kind with
  | Validation -> Exit_class.User_error
  | Transient -> Exit_class.Transient_external
  | Internal -> Exit_class.Internal

let valid_version = Runtime_metadata.valid_version

let archive_name version = "clamp-" ^ version ^ "-linux-x86_64.tar.gz"

let release_urls ~version =
  let base =
    "https://github.com/gvrooyen/clamp/releases/download/v" ^ version ^ "/"
  in
  let archive = archive_name version in
  (base ^ archive, base ^ archive ^ ".sha256")

let latest_version body =
  try
    let open Yojson.Safe.Util in
    match Yojson.Safe.from_string body |> member "tag_name" with
    | `String tag when String.starts_with ~prefix:"v" tag ->
        let version = String.sub tag 1 (String.length tag - 1) in
        if valid_version version then Ok version
        else
          error Transient "upgrade_latest_invalid"
            "GitHub returned an invalid latest Clamp release."
    | _ ->
        error Transient "upgrade_latest_invalid"
          "GitHub returned an invalid latest Clamp release."
  with Yojson.Json_error _ ->
    error Transient "upgrade_latest_invalid"
      "GitHub returned malformed latest-release metadata."

let checksum_named ~expected_name ~code contents =
  match String.split_on_char '\n' contents with
  | first :: rest when List.for_all (fun line -> line = "") rest ->
      let length = String.length first in
      if length = 66 + String.length expected_name
         && String.sub first 64 2 = "  "
         && String.sub first 66 (String.length expected_name) = expected_name
      then
        let digest = String.sub first 0 64 in
        if
          String.for_all
            (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
            digest
        then Ok digest
        else
          error Transient code
            "The release checksum file is invalid."
      else
        error Transient code
          "The release checksum file is invalid."
  | [] ->
      error Transient code
        "The release checksum file is invalid."
  | _ ->
      error Transient code
        "The release checksum file is invalid."

let checksum ~version contents =
  checksum_named ~expected_name:(archive_name version)
    ~code:"upgrade_checksum_invalid" contents

let maximum_metadata_bytes = 1_048_576
let maximum_archive_bytes = 134_217_728
let maximum_extracted_bytes = 536_870_912L

type response = { status : int; body : string }

let fetch ~maximum_bytes url =
  let response = Buffer.create 4096 in
  let oversized = ref false in
  let write chunk =
    if Buffer.length response + String.length chunk > maximum_bytes then begin
      oversized := true;
      0
    end
    else begin
      Buffer.add_string response chunk;
      String.length chunk
    end
  in
  try
    let handle = Curl.init () in
    Fun.protect
      ~finally:(fun () -> Curl.cleanup handle)
      (fun () ->
        Curl.set_url handle url;
        Curl.set_protocols handle [ Curl.CURLPROTO_HTTPS ];
        Curl.set_redirprotocols handle [ Curl.CURLPROTO_HTTPS ];
        Curl.set_followlocation handle true;
        Curl.set_maxredirs handle 5;
        Curl.set_nosignal handle true;
        Curl.set_connecttimeoutms handle 3000;
        Curl.set_timeoutms handle 30000;
        Curl.set_sslverifypeer handle true;
        Curl.set_sslverifyhost handle Curl.SSLVERIFYHOST_HOSTNAME;
        Curl.set_useragent handle "clamp/0.1.4";
        Curl.set_httpheader handle
          [ "Accept: application/vnd.github+json";
            "X-GitHub-Api-Version: 2022-11-28" ];
        Curl.set_writefunction handle write;
        Curl.perform handle;
        Ok { status = Curl.get_responsecode handle; body = Buffer.contents response })
  with
  | Curl.CurlException (_, _, _) when !oversized ->
      error Transient "upgrade_download_too_large"
        "The Clamp release download exceeded its safety limit."
  | Curl.CurlException _ ->
      error Transient "upgrade_network_error"
        "The Clamp release could not be downloaded securely."
  | _ ->
      error Internal "upgrade_internal_error"
        "The Clamp upgrade failed unexpectedly."

let successful_download ~not_found = function
  | Error _ as failure -> failure
  | Ok { status = 200; body } -> Ok body
  | Ok { status = 404; _ } ->
      error Validation "upgrade_release_not_found" not_found
  | Ok _ ->
      error Transient "upgrade_download_failed"
        "GitHub did not return the requested Clamp release."

let random_hex () =
  let bytes = Bytes.create 16 in
  let descriptor =
    Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
  in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      let rec read offset =
        if offset < Bytes.length bytes then
          let count = Unix.read descriptor bytes offset (Bytes.length bytes - offset) in
          if count = 0 then raise End_of_file else read (offset + count)
      in
      read 0);
  let result = Buffer.create 32 in
  Bytes.iter (fun byte -> Buffer.add_string result (Printf.sprintf "%02x" (Char.code byte))) bytes;
  Buffer.contents result

let write_file path contents =
  let descriptor =
    Unix.openfile path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
      0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      let bytes = Bytes.unsafe_of_string contents in
      let rec write offset =
        if offset < Bytes.length bytes then
          let count = Unix.write descriptor bytes offset (Bytes.length bytes - offset) in
          if count = 0 then raise End_of_file else write (offset + count)
      in
      write 0;
      Secure_fs.fsync descriptor)

let read_file_limited path maximum =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let length = in_channel_length channel in
      if length > maximum then None else Some (really_input_string channel length))

let run_process ~stdout program arguments =
  let output =
    Unix.openfile stdout
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
      0o600
  in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close output; Unix.close null)
    (fun () ->
      let argv = Array.of_list (program :: arguments) in
      let environment =
        [| "HOME=/tmp"; "LANG=C.UTF-8"; "LC_ALL=C.UTF-8";
           "PATH=/usr/bin:/bin" |]
      in
      let pid = Unix.create_process_env program argv environment null output null in
      match snd (Unix.waitpid [] pid) with Unix.WEXITED 0 -> true | _ -> false)

let rec remove_tree path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
  | _ -> Unix.unlink path

let cleanup path = try if Sys.file_exists path then remove_tree path with _ -> ()

let path_exists path =
  try ignore (Unix.lstat path); true
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let cleanup_strict path =
  try
    if path_exists path then remove_tree path;
    not (path_exists path)
  with _ -> false

let valid_archive_path ~root path =
  let path = if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path in
  match String.split_on_char '/' path with
  | first :: rest ->
      first = root && List.for_all (fun part -> part <> "" && part <> "." && part <> "..") rest
  | [] -> false

let unique_archive_paths entries =
  let normalized =
    List.map
      (fun path ->
        if String.ends_with ~suffix:"/" path then
          String.sub path 0 (String.length path - 1)
        else path)
      entries
  in
  List.length normalized = List.length (List.sort_uniq String.compare normalized)

let archive_sizes_safe ?(maximum = maximum_extracted_bytes) contents =
  let rec total size = function
    | [] -> Some size
    | line :: rest when line = "" -> total size rest
    | line :: rest ->
        (match
           String.split_on_char ' ' line
           |> List.filter (fun part -> part <> "")
        with
        | mode :: fields
          when String.length mode > 0 && (mode.[0] = '-' || mode.[0] = 'd') ->
            let bytes =
              match fields with
              | owner :: bytes :: _ when String.contains owner '/' -> Some bytes
              | links :: uid :: gid :: bytes :: _
                when Option.is_some (Int64.of_string_opt links)
                     && Option.is_some (Int64.of_string_opt uid)
                     && Option.is_some (Int64.of_string_opt gid) ->
                  Some bytes
              | _ -> None
            in
            (match Option.bind bytes Int64.of_string_opt with
            | Some bytes when bytes >= 0L ->
                let next = Int64.add size bytes in
                if next < size || next > maximum then None
                else total next rest
            | _ -> None)
        | _ -> None)
  in
  Option.is_some (total 0L (String.split_on_char '\n' contents))

let rec regular_tree path =
  match (Unix.lstat path).st_kind with
  | Unix.S_REG -> true
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.for_all (fun name -> regular_tree (Filename.concat path name))
  | _ -> false

let required_release_layout root =
  let regular relative =
    try (Unix.lstat (Filename.concat root relative)).st_kind = Unix.S_REG
    with Unix.Unix_error _ -> false
  and directory relative =
    try (Unix.lstat (Filename.concat root relative)).st_kind = Unix.S_DIR
    with Unix.Unix_error _ -> false
  in
  regular "bin/kb" && regular "README.txt" && regular "LICENSE"
  && regular "THIRD_PARTY_NOTICES" && directory "lib"

let valid_revision value =
  String.length value = 40
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let with_release_archive ~version ~archive ~checksum:checksum_contents action =
  if not (valid_version version) then
    error Validation "upgrade_version_invalid"
      "--version must be a stable X.Y.Z release version."
  else
    Result.bind (checksum ~version checksum_contents) (fun expected ->
        let actual = Digestif.SHA256.(to_hex (digest_string archive)) in
        if actual <> expected then
          error Transient "upgrade_checksum_mismatch"
            "The downloaded Clamp release failed SHA-256 verification."
        else
          let temporary =
            Filename.concat (Filename.get_temp_dir_name ())
              (".clamp-release-" ^ random_hex ())
          in
          let archive_root = "clamp-" ^ version ^ "-linux-x86_64" in
          let archive_path = Filename.concat temporary (archive_name version) in
          let listing_path = Filename.concat temporary "archive.list" in
          let sizes_path = Filename.concat temporary "archive.sizes" in
          let version_path = Filename.concat temporary "candidate.version" in
          let extraction = Filename.concat temporary "extract" in
          let finish result =
            cleanup temporary;
            result
          in
          try
            Unix.mkdir temporary 0o700;
            Unix.mkdir extraction 0o700;
            write_file archive_path archive;
            let listed =
              run_process ~stdout:listing_path "/usr/bin/tar"
                [ "-tzf"; archive_path ]
            in
            let listing = read_file_limited listing_path maximum_metadata_bytes in
            if not listed || Option.is_none listing then
              finish
                (error Transient "upgrade_archive_invalid"
                   "The downloaded Clamp release archive is invalid.")
            else
              let entries =
                Option.get listing |> String.split_on_char '\n'
                |> List.filter (fun value -> value <> "")
              in
              if
                entries = [] || not (unique_archive_paths entries)
                || not
                     (List.for_all (valid_archive_path ~root:archive_root) entries)
              then
                finish
                  (error Transient "upgrade_archive_invalid"
                     "The downloaded Clamp release archive has an unsafe layout.")
              else if
                not
                  (run_process ~stdout:sizes_path "/usr/bin/tar"
                     [ "-tvzf"; archive_path; "--numeric-owner" ])
                || not
                     (Option.exists archive_sizes_safe
                        (read_file_limited sizes_path maximum_metadata_bytes))
              then
                finish
                  (error Transient "upgrade_archive_too_large"
                     "The downloaded Clamp release expands beyond its safety limit.")
              else if
                not
                  (run_process ~stdout:(Filename.concat temporary "extract.out")
                     "/usr/bin/tar"
                     [ "-xzf"; archive_path; "-C"; extraction;
                       "--no-same-owner"; "--no-same-permissions" ])
              then
                finish
                  (error Transient "upgrade_archive_invalid"
                     "The downloaded Clamp release archive could not be extracted.")
              else
                let candidate = Filename.concat extraction archive_root in
                if not (required_release_layout candidate && regular_tree candidate)
                then
                  finish
                    (error Transient "upgrade_archive_invalid"
                       "The downloaded Clamp release package is incomplete.")
                else
                  let version_marker =
                    read_file_limited (Filename.concat candidate "VERSION") 128
                  and revision_marker =
                    read_file_limited (Filename.concat candidate "REVISION") 128
                  in
                  (match (version_marker, revision_marker) with
                  | Some version_marker, Some revision_marker
                    when version_marker = version ^ "\n"
                         && String.ends_with ~suffix:"\n" revision_marker ->
                      let revision =
                        String.sub revision_marker 0
                          (String.length revision_marker - 1)
                      in
                      if not (valid_revision revision) then
                        finish
                          (error Transient "upgrade_archive_invalid"
                             "The downloaded Clamp release markers are invalid.")
                      else begin
                        Unix.chmod (Filename.concat candidate "bin/kb") 0o755;
                        let candidate_runs =
                          run_process ~stdout:version_path
                            (Filename.concat candidate "bin/kb") [ "--version" ]
                        in
                        let reported = read_file_limited version_path 128 in
                        if not candidate_runs || reported <> Some (version ^ "\n")
                        then
                          finish
                            (error Transient "upgrade_candidate_invalid"
                               "The downloaded Clamp binary did not report the requested version.")
                        else
                          let url, _ = release_urls ~version in
                          let result =
                            action
                              { version; revision; target = "linux-x86_64"; url;
                                sha256 = expected; manifest_url = None;
                                manifest_sha256 = None;
                                runtime_root = candidate }
                          in
                          finish (Ok result)
                      end
                  | _ ->
                      finish
                        (error Transient "upgrade_archive_invalid"
                           "The downloaded Clamp release markers are invalid."))
          with _ ->
            finish
              (error Internal "upgrade_internal_error"
                 "The Clamp upgrade failed unexpectedly."))

let metadata_error (failure : Runtime_metadata.error) =
  error Validation failure.code failure.message

let with_manifest_release ~target ~version ~manifest ~manifest_sha256 ~archive
    action =
  let actual_manifest_sha256 =
    Digestif.SHA256.(to_hex (digest_string manifest))
  in
  if actual_manifest_sha256 <> manifest_sha256 then
    error Validation "runtime_manifest_checksum_mismatch"
      "The runtime manifest failed SHA-256 verification."
  else
    match Runtime_metadata.parse_manifest ~expected_version:version manifest with
    | Error failure -> metadata_error failure
    | Ok parsed ->
        (match Runtime_metadata.select_target parsed target with
        | Error failure -> metadata_error failure
        | Ok selected ->
            let actual_archive_sha256 =
              Digestif.SHA256.(to_hex (digest_string archive))
            in
            if String.length archive > selected.archive_size then
              error Validation "runtime_archive_too_large"
                "The runtime archive exceeds its authenticated size bound."
            else if actual_archive_sha256 <> selected.archive_sha256 then
              error Validation "runtime_archive_checksum_mismatch"
                "The runtime archive failed SHA-256 verification."
            else
              let temporary =
                Filename.concat (Filename.get_temp_dir_name ())
                  (".clamp-manifest-release-" ^ random_hex ())
              in
              let archive_path = Filename.concat temporary "runtime.tar.gz" in
              let listing_path = Filename.concat temporary "archive.list" in
              let sizes_path = Filename.concat temporary "archive.sizes" in
              let version_path = Filename.concat temporary "candidate.version" in
              let extraction = Filename.concat temporary "extract" in
              let finish result =
                cleanup temporary;
                result
              in
              try
                Unix.mkdir temporary 0o700;
                Unix.mkdir extraction 0o700;
                write_file archive_path archive;
                let listed =
                  run_process ~stdout:listing_path "/usr/bin/tar"
                    [ "-tzf"; archive_path ]
                in
                let listing = read_file_limited listing_path maximum_metadata_bytes in
                if not listed || Option.is_none listing then
                  finish
                    (error Validation "runtime_archive_invalid"
                       "The runtime archive is invalid.")
                else
                  let entries =
                    Option.get listing |> String.split_on_char '\n'
                    |> List.filter (fun value -> value <> "")
                  in
                  if
                    entries = [] || not (unique_archive_paths entries)
                    || not
                         (List.for_all
                            (valid_archive_path ~root:selected.archive_root)
                            entries)
                  then
                    finish
                      (error Validation "runtime_archive_invalid"
                         "The runtime archive has an unsafe layout.")
                  else if
                    not
                      (run_process ~stdout:sizes_path "/usr/bin/tar"
                         [ "-tvzf"; archive_path; "--numeric-owner" ])
                    || not
                         (Option.exists
                            (archive_sizes_safe
                               ~maximum:Runtime_metadata.maximum_extracted_bytes)
                            (read_file_limited sizes_path maximum_metadata_bytes))
                  then
                    finish
                      (error Validation "runtime_archive_too_large"
                         "The runtime archive expands beyond its safety limit.")
                  else if
                    not
                      (run_process
                         ~stdout:(Filename.concat temporary "extract.out")
                         "/usr/bin/tar"
                         [ "-xzf"; archive_path; "-C"; extraction;
                           "--no-same-owner"; "--no-same-permissions" ])
                  then
                    finish
                      (error Validation "runtime_archive_invalid"
                         "The runtime archive could not be extracted.")
                  else
                    let candidate =
                      Filename.concat extraction selected.archive_root
                    in
                    let required =
                      List.for_all
                        (fun relative ->
                          try
                            (Unix.lstat (Filename.concat candidate relative)).st_kind
                            = Unix.S_REG
                          with Unix.Unix_error _ -> false)
                        selected.required_files
                    in
                    if not (required && regular_tree candidate) then
                      finish
                        (error Validation "runtime_archive_invalid"
                           "The runtime package is incomplete or unsafe.")
                    else
                      let version_marker =
                        read_file_limited (Filename.concat candidate "VERSION") 128
                      and revision_marker =
                        read_file_limited (Filename.concat candidate "REVISION") 128
                      in
                      if
                        version_marker <> Some (version ^ "\n")
                        || revision_marker <> Some (parsed.revision ^ "\n")
                      then
                        finish
                          (error Validation "runtime_archive_invalid"
                             "The runtime package markers do not match its manifest.")
                      else begin
                        Unix.chmod (Filename.concat candidate "bin/kb") 0o755;
                        let candidate_runs =
                          run_process ~stdout:version_path
                            (Filename.concat candidate "bin/kb") [ "--version" ]
                        in
                        if
                          not candidate_runs
                          || read_file_limited version_path 128
                             <> Some (version ^ "\n")
                        then
                          finish
                            (error Validation "runtime_archive_invalid"
                               "The runtime executable failed validation.")
                        else
                          let manifest_url, _ =
                            Runtime_metadata.manifest_urls ~version
                          in
                          let result =
                            action
                              { version; revision = parsed.revision; target;
                                url = selected.archive_url;
                                sha256 = selected.archive_sha256;
                                manifest_url = Some manifest_url;
                                manifest_sha256 = Some manifest_sha256;
                                runtime_root = candidate }
                          in
                          finish (Ok result)
                      end
              with _ ->
                finish
                  (error Internal "upgrade_internal_error"
                     "The Clamp release could not be prepared."))

let command_output program arguments =
  let temporary = Filename.temp_file "clamp-command-" ".out" in
  Fun.protect ~finally:(fun () -> cleanup temporary) (fun () ->
      if run_process ~stdout:temporary program arguments then
        read_file_limited temporary 128
      else None)

let detected_target () =
  match
    ( command_output "/usr/bin/uname" [ "-s" ],
      command_output "/usr/bin/uname" [ "-m" ] )
  with
  | Some "Linux\n", Some "x86_64\n" -> Ok "linux-x86_64"
  | Some "Darwin\n", Some "arm64\n" -> Ok "macos-arm64"
  | _ ->
      error Validation "local_target_unsupported"
        "This operating system and architecture is not a Clamp release target."

let same_identity left right = left.Secure_fs.device = right.Secure_fs.device && left.inode = right.inode

let entry_absent parent name =
  try ignore (Secure_fs.inspect parent name); false
  with Unix.Unix_error (Unix.ENOENT, _, _) -> true

let cleanup_expected ~guard ?retained parent_fd name expected =
  try
    let _, observed = Secure_fs.inspect parent_fd name in
    if not (same_identity expected observed) then false
    else begin
      let descriptor, close_descriptor =
        match retained with
        | Some descriptor -> (descriptor, false)
        | None -> (Secure_fs.open_path_at parent_fd name, true)
      in
      Fun.protect
        ~finally:(fun () -> if close_descriptor then Unix.close descriptor)
        (fun () ->
          Secure_fs.remove_tree_at ~validate:guard parent_fd name descriptor
            expected);
      guard () && entry_absent parent_fd name
    end
  with _ -> false

let directory_path_matches path descriptor expected =
  try
    let observed = Secure_fs.open_directory path in
    Fun.protect ~finally:(fun () -> Unix.close observed) (fun () ->
        same_identity expected (Secure_fs.descriptor_identity observed)
        && same_identity expected (Secure_fs.descriptor_identity descriptor))
  with _ -> false

let exchange_state_matches ~parent_path ~parent_fd ~parent_identity ~target_name
    ~target_identity ~stage_name ~stage_identity =
  directory_path_matches parent_path parent_fd parent_identity
  && (try
        let _, target = Secure_fs.inspect parent_fd target_name
        and _, stage = Secure_fs.inspect parent_fd stage_name in
        same_identity target_identity target && same_identity stage_identity stage
      with _ -> false)

let uncertain message =
  error Internal "upgrade_state_uncertain" message

let finalize_exchange ~parent_path ~parent_fd ~parent_identity ~target_name
    ~stage_component ~original ~original_descriptor ~candidate
    ~candidate_descriptor ~candidate_snapshot success =
  let forward_guard () =
    exchange_state_matches ~parent_path ~parent_fd ~parent_identity
      ~target_name ~target_identity:candidate ~stage_name:stage_component
      ~stage_identity:original
    && same_identity candidate
         (Secure_fs.descriptor_identity candidate_descriptor)
    && same_identity original
         (Secure_fs.descriptor_identity original_descriptor)
    && Secure_fs.tree_matches candidate_descriptor candidate_snapshot
  in
  let restored_guard () =
    exchange_state_matches ~parent_path ~parent_fd ~parent_identity
      ~target_name ~target_identity:original ~stage_name:stage_component
      ~stage_identity:candidate
    && same_identity candidate
         (Secure_fs.descriptor_identity candidate_descriptor)
    && same_identity original
         (Secure_fs.descriptor_identity original_descriptor)
  in
  match (try Secure_fs.fsync parent_fd; true with _ -> false) with
  | true ->
      if not (forward_guard ())
      then uncertain "The Clamp installation changed during durability finalization."
      else if not
                (cleanup_expected ~guard:(fun () ->
                     directory_path_matches parent_path parent_fd parent_identity
                     && (try
                           let _, active = Secure_fs.inspect parent_fd target_name in
                           same_identity candidate active
                           && Secure_fs.tree_matches candidate_descriptor
                                candidate_snapshot
                         with _ -> false))
                   ~retained:original_descriptor parent_fd stage_component original)
      then uncertain "The new Clamp installation is active, but cleanup durability is uncertain."
      else
        if
          directory_path_matches parent_path parent_fd parent_identity
          && entry_absent parent_fd stage_component
          && (try
                let _, active = Secure_fs.inspect parent_fd target_name in
                same_identity candidate active
                && Secure_fs.tree_matches candidate_descriptor candidate_snapshot
              with _ -> false)
        then Ok success
        else uncertain "The Clamp installation changed during durability finalization."
  | false ->
      if not (forward_guard ())
      then uncertain "The Clamp installation state is uncertain after a durability failure."
      else
        (try
           Secure_fs.rename_exchange_checked parent_fd target_name parent_fd
             stage_component ~validate:forward_guard;
           if not (restored_guard ())
           then raise Exit;
           Secure_fs.fsync parent_fd;
           if not
                (cleanup_expected ~guard:(fun () ->
                     directory_path_matches parent_path parent_fd parent_identity
                     && (try
                           let _, restored = Secure_fs.inspect parent_fd target_name in
                           same_identity original restored
                         with _ -> false))
                   ~retained:candidate_descriptor parent_fd stage_component
                   candidate)
           then raise Exit;
           if not
                (directory_path_matches parent_path parent_fd parent_identity
                 && entry_absent parent_fd stage_component
                 && (try
                       let _, restored = Secure_fs.inspect parent_fd target_name in
                       same_identity original restored
                     with _ -> false))
           then raise Exit;
           error Internal "upgrade_internal_error"
             "The Clamp upgrade was restored after a durability failure."
         with _ ->
           uncertain "The Clamp installation state is uncertain after a durability failure.")

let installation_root () =
  try
    let executable = Unix.realpath Sys.executable_name in
    let bin = Filename.dirname executable in
    if Filename.basename executable <> "kb" || Filename.basename bin <> "bin" then
      error Validation "upgrade_unsupported_installation"
        "kb upgrade requires a packaged Clamp release installation."
    else
      let root = Filename.dirname bin in
      if required_release_layout root then Ok root
      else
        error Validation "upgrade_unsupported_installation"
          "kb upgrade requires a packaged Clamp release installation."
  with Unix.Unix_error _ ->
    error Validation "upgrade_unsupported_installation"
      "kb upgrade requires a packaged Clamp release installation."

let setup_managed_installation installation_root =
  match
    ( Sys.getenv_opt "HOME",
      read_file_limited (Filename.concat installation_root "REVISION") 128 )
  with
  | Some home, Some revision_marker
    when String.ends_with ~suffix:"\n" revision_marker ->
      let revision =
        String.sub revision_marker 0 (String.length revision_marker - 1)
      in
      if not (valid_revision revision) then false
      else
        (try
           installation_root
           = Unix.realpath
               (Filename.concat home (".local/share/clamp/kb/" ^ revision))
         with Unix.Unix_error _ -> false)
  | _ -> false

let install_archive ~current_version ~installation_root ~version ~archive ~checksum:checksum_contents =
  if version = current_version then
    Ok { previous_version = current_version; version; installation_root; changed = false }
  else if not (valid_version version) then
    error Validation "upgrade_version_invalid"
      "--version must be a stable X.Y.Z release version."
  else if not (required_release_layout installation_root) then
    error Validation "upgrade_unsupported_installation"
      "kb upgrade requires a packaged Clamp release installation."
  else
    match checksum ~version checksum_contents with
    | Error _ as failure -> failure
    | Ok expected ->
        let actual = Digestif.SHA256.(to_hex (digest_string archive)) in
        if actual <> expected then
          error Transient "upgrade_checksum_mismatch"
            "The downloaded Clamp release failed SHA-256 verification."
        else
          let parent = Filename.dirname installation_root in
          let target_name = Filename.basename installation_root in
          let token = random_hex () in
          let temporary_name = ".clamp-upgrade-" ^ token in
          let temporary = Filename.concat parent temporary_name in
          let stage_name = ".clamp-upgrade-stage-" ^ token in
          let archive_root = "clamp-" ^ version ^ "-linux-x86_64" in
          let archive_path = Filename.concat temporary (archive_name version) in
          let listing_path = Filename.concat temporary "archive.list" in
          let sizes_path = Filename.concat temporary "archive.sizes" in
          let version_path = Filename.concat temporary "candidate.version" in
          let extraction = Filename.concat temporary "extract" in
          let parent_descriptor = ref None in
          let temporary_identity = ref None in
          let temporary_descriptor = ref None in
          let temporary_owned = ref false in
          let stage_owned = ref false in
          let stage_identity = ref None in
          let stage_descriptor = ref None in
          let retained_descriptors = ref [] in
          let exchanged = ref false in
          let finish result =
            let temporary_clean =
              if not !temporary_owned then true
              else
                match
                  (!parent_descriptor, !temporary_identity, !temporary_descriptor)
                with
                | Some descriptor, Some identity, Some retained ->
                    let parent_identity = Secure_fs.descriptor_identity descriptor in
                    cleanup_expected
                      ~guard:(fun () ->
                        directory_path_matches parent descriptor parent_identity)
                      ~retained descriptor temporary_name identity
                | _ -> false
            in
            let stage_clean =
              match
                (!stage_owned, !exchanged, !parent_descriptor, !stage_identity,
                  !stage_descriptor)
              with
              | true, false, Some descriptor, Some identity, Some retained ->
                  let parent_identity = Secure_fs.descriptor_identity descriptor in
                  cleanup_expected
                    ~guard:(fun () ->
                      directory_path_matches parent descriptor parent_identity)
                    ~retained descriptor stage_name identity
              | true, false, _, _, _ -> false
              | _ -> true
            in
            let cleanup_ok =
              temporary_clean && stage_clean
            in
            let durable =
              cleanup_ok
            in
            Option.iter
              (fun descriptor ->
                (try Secure_fs.funlock descriptor with _ -> ());
                Unix.close descriptor)
              !parent_descriptor;
            List.iter (fun descriptor -> try Unix.close descriptor with _ -> ())
              !retained_descriptors;
            if durable then result
            else
              error Internal "upgrade_state_uncertain"
                "The Clamp upgrade cleanup state is uncertain."
          in
          try
            let parent_fd = Secure_fs.open_directory parent in
            parent_descriptor := Some parent_fd;
            Secure_fs.flock parent_fd true;
            let parent_identity = Secure_fs.descriptor_identity parent_fd in
            let retained_temporary =
              Secure_fs.mkdir_private_at parent_fd temporary_name
            in
            temporary_descriptor := Some retained_temporary;
            retained_descriptors := retained_temporary :: !retained_descriptors;
            temporary_owned := true;
            temporary_identity :=
              Some (Secure_fs.descriptor_identity retained_temporary);
            Unix.mkdir extraction 0o700;
            write_file archive_path archive;
            let listed =
              run_process ~stdout:listing_path "/usr/bin/tar"
                [ "-tzf"; archive_path ]
            in
            let listing = read_file_limited listing_path maximum_metadata_bytes in
            if not listed || Option.is_none listing then
              finish
                (error Transient "upgrade_archive_invalid"
                   "The downloaded Clamp release archive is invalid.")
            else
              let entries =
                Option.get listing |> String.split_on_char '\n'
                |> List.filter (fun value -> value <> "")
              in
              if
                entries = [] || not (unique_archive_paths entries)
                || not (List.for_all (valid_archive_path ~root:archive_root) entries)
              then
                finish
                  (error Transient "upgrade_archive_invalid"
                     "The downloaded Clamp release archive has an unsafe layout.")
              else if
                not
                  (run_process ~stdout:sizes_path "/usr/bin/tar"
                     [ "-tvzf"; archive_path; "--numeric-owner" ])
                || not
                     (Option.exists archive_sizes_safe
                        (read_file_limited sizes_path maximum_metadata_bytes))
              then
                finish
                  (error Transient "upgrade_archive_too_large"
                     "The downloaded Clamp release expands beyond its safety limit.")
              else if
                not
                  (run_process ~stdout:(Filename.concat temporary "extract.out")
                     "/usr/bin/tar"
                     [ "-xzf"; archive_path; "-C"; extraction;
                       "--no-same-owner"; "--no-same-permissions" ])
              then
                finish
                  (error Transient "upgrade_archive_invalid"
                     "The downloaded Clamp release archive could not be extracted.")
              else
                let candidate = Filename.concat extraction archive_root in
                if not (required_release_layout candidate && regular_tree candidate) then
                  finish
                    (error Transient "upgrade_archive_invalid"
                       "The downloaded Clamp release package is incomplete.")
                else begin
                  Unix.chmod (Filename.concat candidate "bin/kb") 0o755;
                  let candidate_runs =
                    run_process ~stdout:version_path
                      (Filename.concat candidate "bin/kb") [ "--version" ]
                  in
                  let reported = read_file_limited version_path 128 in
                  if not candidate_runs || reported <> Some (version ^ "\n") then
                    finish
                      (error Transient "upgrade_candidate_invalid"
                         "The downloaded Clamp binary did not report the requested version.")
                  else begin
                    let candidate_snapshot = Secure_fs.sync_tree candidate in
                    let _, original = Secure_fs.inspect parent_fd target_name in
                    let original_descriptor =
                      Secure_fs.open_directory_at parent_fd target_name
                    in
                    retained_descriptors :=
                      original_descriptor :: !retained_descriptors;
                    let extraction_fd = Secure_fs.open_directory extraction in
                    let candidate_descriptor =
                      Secure_fs.open_directory_at extraction_fd archive_root
                    in
                    retained_descriptors :=
                      candidate_descriptor :: !retained_descriptors;
                    Fun.protect
                      ~finally:(fun () -> Unix.close extraction_fd)
                      (fun () ->
                        Secure_fs.rename_noreplace_checked extraction_fd archive_root
                          parent_fd stage_name
                          ~validate:(fun () ->
                            directory_path_matches parent parent_fd parent_identity
                            && same_identity original
                                 (Secure_fs.descriptor_identity original_descriptor)
                            && Secure_fs.tree_matches candidate_descriptor
                                 candidate_snapshot));
                    stage_owned := true;
                    let _, candidate = Secure_fs.inspect parent_fd stage_name in
                    stage_identity := Some candidate;
                    stage_descriptor := Some candidate_descriptor;
                    let _, current = Secure_fs.inspect parent_fd target_name in
                    if not (same_identity original current) then
                      finish
                        (error Internal "upgrade_installation_changed"
                           "The Clamp installation changed during upgrade.")
                    else begin
                      let temporary_clean =
                        match (!temporary_identity, !temporary_descriptor) with
                        | Some identity, Some retained ->
                            cleanup_expected
                              ~guard:(fun () ->
                                directory_path_matches parent parent_fd
                                  parent_identity)
                              ~retained parent_fd temporary_name identity
                        | _ -> false
                      in
                      if not temporary_clean then raise Exit;
                      temporary_owned := false;
                      let pre_exchange_guard () =
                        exchange_state_matches ~parent_path:parent ~parent_fd
                          ~parent_identity ~target_name ~target_identity:original
                          ~stage_name ~stage_identity:candidate
                        && same_identity original
                             (Secure_fs.descriptor_identity original_descriptor)
                        && same_identity candidate
                             (Secure_fs.descriptor_identity candidate_descriptor)
                        && Secure_fs.tree_matches candidate_descriptor
                             candidate_snapshot
                      in
                      Secure_fs.rename_exchange_checked parent_fd target_name
                        parent_fd stage_name ~validate:pre_exchange_guard;
                      exchanged := true;
                      let success =
                        { previous_version = current_version; version;
                          installation_root; changed = true }
                      in
                      let result =
                        finalize_exchange ~parent_path:parent ~parent_fd
                          ~parent_identity ~target_name
                          ~stage_component:stage_name ~original
                          ~original_descriptor ~candidate ~candidate_descriptor
                          ~candidate_snapshot success
                      in
                      finish result
                    end
                  end
                end
          with
          | Secure_fs.Atomic_rename_unavailable ->
              finish
                (error Internal "upgrade_atomic_rename_unavailable"
                   "This system cannot atomically replace the Clamp installation.")
          | Unix.Unix_error ((Unix.EACCES | Unix.EPERM | Unix.EROFS), _, _) ->
              finish
                (error Validation "upgrade_installation_not_writable"
                   "The packaged Clamp installation is not writable by this user.")
          | _ ->
              finish
                (error Internal "upgrade_internal_error"
                   "The Clamp upgrade failed unexpectedly.")

let rec copy_release_tree source target =
  Unix.mkdir target 0o755;
  copy_release_tree_into source target

and copy_release_tree_into source target =
  Sys.readdir source |> Array.to_list |> List.sort String.compare
  |> List.iter (fun name ->
         let source_path = Filename.concat source name in
         let target_path = Filename.concat target name in
         match (Unix.lstat source_path).st_kind with
         | Unix.S_DIR -> copy_release_tree source_path target_path
         | Unix.S_REG ->
             let contents =
               match read_file_limited source_path Runtime_metadata.maximum_archive_bytes with
               | Some value -> value
               | None -> raise Exit
             in
             write_file target_path contents;
             let mode =
               if name = "kb" || name = "setup" || name = "resume" then 0o755
               else 0o644
             in
             Unix.chmod target_path mode
         | _ -> raise Exit);
  let descriptor = Unix.openfile target [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> Secure_fs.fsync descriptor)

let install_prepared ~current_version ~installation_root (release : release) =
  let parent = Filename.dirname installation_root in
  let target_name = Filename.basename installation_root in
  let token = random_hex () in
  let stage_name = ".clamp-upgrade-stage-" ^ token in
  let stage = Filename.concat parent stage_name in
  let parent_descriptor = ref None in
  let stage_owned = ref false in
  let stage_identity = ref None in
  let stage_descriptor = ref None in
  let retained_descriptors = ref [] in
  let exchanged = ref false in
  let finish result =
    let durable =
      if !stage_owned && not !exchanged then
        match (!parent_descriptor, !stage_identity, !stage_descriptor) with
        | Some descriptor, Some identity, Some retained ->
            let parent_identity = Secure_fs.descriptor_identity descriptor in
            cleanup_expected
              ~guard:(fun () ->
                directory_path_matches parent descriptor parent_identity)
              ~retained descriptor stage_name identity
        | _ -> false
      else true
    in
    Option.iter
      (fun descriptor ->
        (try Secure_fs.funlock descriptor with _ -> ());
        Unix.close descriptor)
      !parent_descriptor;
    List.iter (fun descriptor -> try Unix.close descriptor with _ -> ())
      !retained_descriptors;
    if durable then result
    else
      error Internal "upgrade_state_uncertain"
        "The Clamp upgrade cleanup state is uncertain."
  in
  try
    let parent_fd = Secure_fs.open_directory parent in
    parent_descriptor := Some parent_fd;
    Secure_fs.flock parent_fd true;
    let parent_identity = Secure_fs.descriptor_identity parent_fd in
    let _, original = Secure_fs.inspect parent_fd target_name in
    Unix.mkdir stage 0o755;
    stage_owned := true;
    let retained_stage = Secure_fs.open_directory_at parent_fd stage_name in
    stage_descriptor := Some retained_stage;
    retained_descriptors := retained_stage :: !retained_descriptors;
    let created_stage = Secure_fs.descriptor_identity retained_stage in
    stage_identity := Some created_stage;
    copy_release_tree_into release.runtime_root stage;
    let candidate_snapshot = Secure_fs.sync_tree stage in
    let _, candidate = Secure_fs.inspect parent_fd stage_name in
    let _, current = Secure_fs.inspect parent_fd target_name in
    if
      not
        (same_identity created_stage candidate && same_identity original current)
    then
      finish
        (error Internal "upgrade_installation_changed"
           "The Clamp installation changed during upgrade.")
    else begin
      let original_descriptor = Secure_fs.open_directory_at parent_fd target_name in
      retained_descriptors := original_descriptor :: !retained_descriptors;
      let pre_exchange_guard () =
        exchange_state_matches ~parent_path:parent ~parent_fd ~parent_identity
          ~target_name ~target_identity:original ~stage_name
          ~stage_identity:candidate
        && same_identity original
             (Secure_fs.descriptor_identity original_descriptor)
        && same_identity candidate
             (Secure_fs.descriptor_identity retained_stage)
        && Secure_fs.tree_matches retained_stage candidate_snapshot
      in
      Secure_fs.rename_exchange_checked parent_fd target_name parent_fd stage_name
        ~validate:pre_exchange_guard;
      exchanged := true;
      finalize_exchange ~parent_path:parent ~parent_fd ~parent_identity
        ~target_name ~stage_component:stage_name ~original ~original_descriptor
        ~candidate ~candidate_descriptor:retained_stage ~candidate_snapshot
        { previous_version = current_version; version = release.version;
          installation_root; changed = true }
      |> finish
    end
  with
  | Secure_fs.Atomic_rename_unavailable ->
      finish
        (error Internal "upgrade_atomic_rename_unavailable"
           "This system cannot atomically replace the Clamp installation.")
  | Unix.Unix_error ((Unix.EACCES | Unix.EPERM | Unix.EROFS), _, _) ->
      finish
        (error Validation "upgrade_installation_not_writable"
           "The packaged Clamp installation is not writable by this user.")
  | _ ->
      finish
        (error Internal "upgrade_internal_error"
           "The Clamp upgrade failed unexpectedly.")

let resolve = function
  | Version value ->
      if valid_version value then Ok value
      else
        error Validation "upgrade_version_invalid"
          "--version must be a stable X.Y.Z release version."
  | Latest ->
      Result.bind
        (fetch ~maximum_bytes:maximum_metadata_bytes
           "https://api.github.com/repos/gvrooyen/clamp/releases/latest"
        |> successful_download ~not_found:"No latest Clamp release exists.")
        latest_version

let uses_manifest version =
  match String.split_on_char '.' version |> List.map int_of_string_opt with
  | [ Some major; Some minor; Some _ ] -> major > 0 || minor >= 2
  | _ -> false

let runtime_download ~maximum_bytes ~too_large url =
  match fetch ~maximum_bytes url with
  | Ok { status = 200; body } -> Ok body
  | Error failure when failure.code = "upgrade_download_too_large" ->
      error Validation too_large "The Clamp release asset exceeds its safety limit."
  | Error _ | Ok _ ->
      error Transient "runtime_download_failed"
        "The Clamp release asset could not be downloaded securely."

let with_manifest_download ~target ~version action =
  let manifest_url, checksum_url = Runtime_metadata.manifest_urls ~version in
  Result.bind
    (runtime_download ~maximum_bytes:Runtime_metadata.maximum_manifest_bytes
       ~too_large:"runtime_manifest_too_large" manifest_url)
    (fun manifest ->
      Result.bind
        (runtime_download ~maximum_bytes:maximum_metadata_bytes
           ~too_large:"runtime_manifest_invalid" checksum_url)
        (fun checksum_contents ->
          Result.bind
            (checksum_named ~expected_name:(Runtime_metadata.manifest_name version)
               ~code:"runtime_manifest_invalid" checksum_contents)
            (fun manifest_sha256 ->
              let actual = Digestif.SHA256.(to_hex (digest_string manifest)) in
              if actual <> manifest_sha256 then
                error Validation "runtime_manifest_checksum_mismatch"
                  "The runtime manifest failed SHA-256 verification."
              else
                match
                  Runtime_metadata.parse_manifest ~expected_version:version
                    manifest
                with
                | Error failure -> metadata_error failure
                | Ok parsed ->
                    (match Runtime_metadata.select_target parsed target with
                    | Error failure -> metadata_error failure
                    | Ok selected ->
                        Result.bind
                          (runtime_download
                             ~maximum_bytes:
                               (min selected.archive_size
                                  Runtime_metadata.maximum_archive_bytes)
                             ~too_large:"runtime_archive_too_large"
                             selected.archive_url)
                          (fun archive ->
                            with_manifest_release ~target ~version ~manifest
                              ~manifest_sha256 ~archive action)))))

let with_release ?target request action =
  Result.bind (resolve request) (fun version ->
      let selected_target =
        match target with Some target -> Ok target | None -> detected_target ()
      in
      Result.bind selected_target (fun target ->
          if uses_manifest version then
            with_manifest_download ~target ~version action
          else if target <> "linux-x86_64" then
            error Validation "runtime_lock_v2_invalid"
              "A legacy runtime release is usable only on Linux x86-64."
          else
            let archive_url, checksum_url = release_urls ~version in
            Result.bind
              (fetch ~maximum_bytes:maximum_archive_bytes archive_url
              |> successful_download
                   ~not_found:("Clamp release " ^ version ^ " does not exist."))
              (fun archive ->
                Result.bind
                  (fetch ~maximum_bytes:maximum_metadata_bytes checksum_url
                  |> successful_download
                       ~not_found:("Clamp release " ^ version
                                  ^ " has no checksum asset."))
                  (fun checksum ->
                    with_release_archive ~version ~archive ~checksum action))))

let read_offline_file ~maximum ~invalid ~too_large path =
  try
    let before = Unix.lstat path in
    if before.st_kind <> Unix.S_REG then
      error Validation invalid
        "An offline release input is not a regular file."
    else if before.st_size > maximum then
      error Validation too_large "An offline release input exceeds its safety limit."
    else
      let descriptor =
        Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0
      in
      Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
          let opened = Unix.fstat descriptor in
          if
            opened.st_kind <> Unix.S_REG || opened.st_dev <> before.st_dev
            || opened.st_ino <> before.st_ino || opened.st_size <> before.st_size
          then
            error Validation invalid
              "An offline release input changed during validation."
          else
            let length = opened.st_size in
            let buffer = Bytes.create length in
            let rec read offset =
              if offset = length then Ok ()
              else
                match Unix.read descriptor buffer offset (length - offset) with
                | 0 ->
                    error Validation invalid
                      "An offline release input changed during validation."
                | count -> read (offset + count)
                | exception Unix.Unix_error (Unix.EINTR, _, _) -> read offset
            in
            Result.bind (read 0) (fun () ->
                let after = Unix.fstat descriptor in
                if
                  after.st_dev <> opened.st_dev || after.st_ino <> opened.st_ino
                  || after.st_size <> opened.st_size
                  || after.st_mtime <> opened.st_mtime
                then
                  error Validation invalid
                    "An offline release input changed during validation."
                else Ok (Bytes.unsafe_to_string buffer)))
  with Unix.Unix_error _ ->
    error Validation invalid
      "An offline release input is unavailable."

let with_offline_release ~target ~version ~manifest_path ~manifest_sha256
    ~archive_path action =
  if not (Runtime_metadata.valid_sha256 manifest_sha256) then
    error Validation "runtime_manifest_checksum_mismatch"
      "The pinned runtime manifest SHA-256 is invalid."
  else
    Result.bind
      (read_offline_file ~maximum:Runtime_metadata.maximum_manifest_bytes
         ~invalid:"runtime_manifest_invalid"
         ~too_large:"runtime_manifest_too_large" manifest_path)
      (fun manifest ->
        Result.bind
          (read_offline_file ~maximum:Runtime_metadata.maximum_archive_bytes
             ~invalid:"runtime_archive_invalid"
             ~too_large:"runtime_archive_too_large" archive_path)
          (fun archive ->
            with_manifest_release ~target ~version ~manifest ~manifest_sha256
              ~archive action))

let run ~current_version request =
  Result.bind (resolve request) (fun version ->
      Result.bind (detected_target ()) (fun target ->
          Result.bind (installation_root ()) (fun installation_root ->
              if setup_managed_installation installation_root then
                error Validation "upgrade_unsupported_installation"
                  "kb upgrade cannot mutate a setup-managed installation."
              else if version = current_version then
                Ok
                  { previous_version = current_version; version;
                    installation_root; changed = false }
              else if uses_manifest version then
                with_manifest_download ~target ~version (fun release ->
                    install_prepared ~current_version ~installation_root release)
                |> Result.join
              else if target <> "linux-x86_64" then
                error Validation "runtime_lock_v2_invalid"
                  "A legacy runtime release is usable only on Linux x86-64."
              else
                let archive_url, checksum_url = release_urls ~version in
                Result.bind
                  (fetch ~maximum_bytes:maximum_archive_bytes archive_url
                  |> successful_download
                       ~not_found:("Clamp release " ^ version
                                  ^ " does not exist."))
                  (fun archive ->
                    Result.bind
                      (fetch ~maximum_bytes:maximum_metadata_bytes checksum_url
                      |> successful_download
                           ~not_found:("Clamp release " ^ version
                                      ^ " has no checksum asset."))
                      (fun checksum ->
                        install_archive ~current_version ~installation_root
                          ~version ~archive ~checksum)))))

module For_test = struct
  let valid_version = valid_version
  let latest_version = latest_version
  let checksum = checksum
  let release_urls = release_urls
  let archive_sizes_safe = archive_sizes_safe
  let detected_target = detected_target
  let with_manifest_release = with_manifest_release
  let install_archive = install_archive
  let install_prepared = install_prepared
  let with_release_archive = with_release_archive
end
