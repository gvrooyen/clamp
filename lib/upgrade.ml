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
  url : string;
  sha256 : string;
  runtime_root : string;
}

let error kind code message = Error { kind; code; message }

let exit_class error =
  match error.kind with
  | Validation -> Exit_class.User_error
  | Transient -> Exit_class.Transient_external
  | Internal -> Exit_class.Internal

let valid_version value =
  let valid_component component =
    component <> ""
    && String.for_all (function '0' .. '9' -> true | _ -> false) component
    && (component = "0" || component.[0] <> '0')
  in
  String.length value <= 63
  && match String.split_on_char '.' value with
  | [ major; minor; patch ] ->
      List.for_all valid_component [ major; minor; patch ]
  | _ -> false

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

let checksum ~version contents =
  let expected_name = archive_name version in
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
          error Transient "upgrade_checksum_invalid"
            "The release checksum file is invalid."
      else
        error Transient "upgrade_checksum_invalid"
          "The release checksum file is invalid."
  | [] ->
      error Transient "upgrade_checksum_invalid"
        "The release checksum file is invalid."
  | _ ->
      error Transient "upgrade_checksum_invalid"
        "The release checksum file is invalid."

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
      Unix.fsync descriptor)

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

let valid_archive_path ~root path =
  let path = if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path in
  match String.split_on_char '/' path with
  | first :: rest ->
      first = root && List.for_all (fun part -> part <> "" && part <> "." && part <> "..") rest
  | [] -> false

let archive_sizes_safe contents =
  let rec total size = function
    | [] -> Some size
    | line :: rest when line = "" -> total size rest
    | line :: rest ->
        (match
           String.split_on_char ' ' line
           |> List.filter (fun part -> part <> "")
        with
        | _mode :: _owner :: bytes :: _ ->
            (match Int64.of_string_opt bytes with
            | Some bytes when bytes >= 0L ->
                let next = Int64.add size bytes in
                if next < size || next > maximum_extracted_bytes then None
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
                entries = []
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
                              { version; revision; url; sha256 = expected;
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

let same_identity left right = left.Secure_fs.device = right.Secure_fs.device && left.inode = right.inode

let installation_root () =
  try
    let executable = Unix.readlink "/proc/self/exe" in
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
          let temporary = Filename.concat parent (".clamp-upgrade-" ^ token) in
          let stage_name = ".clamp-upgrade-stage-" ^ token in
          let stage = Filename.concat parent stage_name in
          let archive_root = "clamp-" ^ version ^ "-linux-x86_64" in
          let archive_path = Filename.concat temporary (archive_name version) in
          let listing_path = Filename.concat temporary "archive.list" in
          let sizes_path = Filename.concat temporary "archive.sizes" in
          let version_path = Filename.concat temporary "candidate.version" in
          let extraction = Filename.concat temporary "extract" in
          let parent_descriptor = ref None in
          let exchanged = ref false in
          let finish result =
            Option.iter
              (fun descriptor ->
                (try Secure_fs.funlock descriptor with _ -> ());
                Unix.close descriptor)
              !parent_descriptor;
            cleanup temporary;
            if not !exchanged then cleanup stage;
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
              if entries = [] || not (List.for_all (valid_archive_path ~root:archive_root) entries) then
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
                  else
                    let parent_fd = Secure_fs.open_directory parent in
                    parent_descriptor := Some parent_fd;
                    Secure_fs.flock parent_fd true;
                    let _, original = Secure_fs.inspect parent_fd target_name in
                    let extraction_fd = Secure_fs.open_directory extraction in
                    Fun.protect
                      ~finally:(fun () -> Unix.close extraction_fd)
                      (fun () ->
                        Secure_fs.rename_noreplace extraction_fd archive_root parent_fd stage_name);
                    let _, current = Secure_fs.inspect parent_fd target_name in
                    if not (same_identity original current) then
                      finish
                        (error Internal "upgrade_installation_changed"
                           "The Clamp installation changed during upgrade.")
                    else begin
                      Secure_fs.rename_exchange parent_fd target_name parent_fd stage_name;
                      exchanged := true;
                      Unix.fsync parent_fd;
                      cleanup stage;
                      finish
                        (Ok
                           { previous_version = current_version; version;
                             installation_root; changed = true })
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

let with_release request action =
  Result.bind (resolve request) (fun version ->
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
              with_release_archive ~version ~archive ~checksum action)))

let run ~current_version request =
  Result.bind (resolve request) (fun version ->
      if version = current_version then
        Result.map
          (fun installation_root ->
            { previous_version = current_version; version; installation_root;
              changed = false })
          (installation_root ())
      else
        Result.bind (installation_root ()) (fun installation_root ->
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
                    install_archive ~current_version ~installation_root ~version
                      ~archive ~checksum))))

module For_test = struct
  let valid_version = valid_version
  let latest_version = latest_version
  let checksum = checksum
  let release_urls = release_urls
  let install_archive = install_archive
  let with_release_archive = with_release_archive
end
