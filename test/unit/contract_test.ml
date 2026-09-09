let check_json name expected actual =
  Alcotest.check Alcotest.string name expected
    (Yojson.Safe.to_string (Clamp.Cli_result.to_yojson actual))

let success_envelope () =
  let result =
    Clamp.Cli_result.success ~code:"ready"
      ~data:(`Assoc [ ("version", `String "0.1.3") ])
  in
  check_json "success envelope"
    {|{"ok":true,"code":"ready","data":{"version":"0.1.3"}}|}
    result;
  Alcotest.(check int) "success exit" 0 (Clamp.Cli_result.exit_code result)

let failure_envelope () =
  let result = Clamp.Cli_result.not_implemented ~command:"future" in
  check_json "failure envelope"
    {|{"ok":false,"code":"not_implemented","message":"kb future is not implemented yet.","details":{"command":"future"}}|}
    result;
  Alcotest.(check int) "user error exit" 2 (Clamp.Cli_result.exit_code result)

let exit_classes () =
  let open Clamp.Exit_class in
  let cases =
    [
      (Success, 0);
      (User_error, 2);
      (Conflict, 3);
      (Authentication, 4);
      (Transient_external, 5);
      (Stale_index, 6);
      (Internal, 70);
    ]
  in
  List.iter (fun (kind, expected) -> Alcotest.(check int) (name kind) expected (code kind)) cases

let secret_redaction () =
  let input =
    "postgresql://alice:hunter2@db.example/clamp sk-or-v1-secret-token"
  in
  Alcotest.(check string) "URI credentials and API token"
    "postgresql://[REDACTED]@db.example/clamp [REDACTED]"
    (Clamp.Redact.string input)

let redacted_failure () =
  let result =
    Clamp.Cli_result.failure ~exit_class:Clamp.Exit_class.Authentication
      ~code:"authentication_failed"
      ~message:"Could not use postgresql://alice:hunter2@db.example/clamp"
      ~details:
        (`Assoc
          [
            ( "endpoint",
              `String "postgresql://alice:hunter2@db.example/clamp" );
          ])
  in
  check_json "redacted message"
    {|{"ok":false,"code":"authentication_failed","message":"Could not use postgresql://[REDACTED]@db.example/clamp","details":{"endpoint":"postgresql://[REDACTED]@db.example/clamp"}}|}
    result

let nested_success_redaction () =
  let result =
    Clamp.Cli_result.success ~code:"nested"
      ~data:
        (`Assoc
          [
            ( "items",
              `List
                [
                  `Assoc
                    [
                      ( "endpoint",
                        `String
                          "postgresql://alice:hunter2@db.example/clamp" );
                    ];
                  `String "sk-or-v1-nested-token";
                ] );
          ])
  in
  check_json "nested success data"
    {|{"ok":true,"code":"nested","data":{"items":[{"endpoint":"postgresql://[REDACTED]@db.example/clamp"},"[REDACTED]"]}}|}
    result

let environment_secret_redaction () =
  let variable = "OPENROUTER_API_KEY" in
  let previous = Sys.getenv_opt variable in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv variable (Option.value previous ~default:""))
    (fun () ->
      Unix.putenv variable "environment-secret-sentinel";
      let result =
        Clamp.Cli_result.success ~code:"environment"
          ~data:
            (`Assoc
              [
                ( "nested",
                  `List [ `String "environment-secret-sentinel" ] );
              ])
      in
      check_json "environment secret"
        {|{"ok":true,"code":"environment","data":{"nested":["[REDACTED]"]}}|}
        result)

let () =
  Alcotest.run "Phase 0 command contract"
    [
      ( "envelopes",
        [
          Alcotest.test_case "success" `Quick success_envelope;
          Alcotest.test_case "failure" `Quick failure_envelope;
          Alcotest.test_case "redacted failure" `Quick redacted_failure;
          Alcotest.test_case "nested success redaction" `Quick
            nested_success_redaction;
          Alcotest.test_case "environment secret redaction" `Quick
            environment_secret_redaction;
        ] );
      ( "exit classes",
        [ Alcotest.test_case "stable values" `Quick exit_classes ] );
      ( "redaction",
        [ Alcotest.test_case "known credential forms" `Quick secret_redaction ] );
    ]
