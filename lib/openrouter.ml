let model = "openai/text-embedding-3-small"
let canonical_identity = "openrouter:" ^ model
let dimensions = 1536
let maximum_response_bytes = 1024 * 1024
let endpoint = "https://openrouter.ai/api/v1/embeddings"
let model_endpoint = "https://openrouter.ai/api/v1/model/openai/text-embedding-3-small"

type usage = { prompt_tokens : int; total_tokens : int }
type embedding = { values : float array; usage : usage; identity : string }

type error_kind =
  | Authentication
  | Validation
  | Rate_limited
  | Payment_required
  | Transient
  | Invalid_response
  | Response_too_large

type error = {
  kind : error_kind;
  code : string;
  message : string;
  paid_request_ambiguous : bool;
}

let error ?(ambiguous = false) kind code message =
  Error { kind; code; message; paid_request_ambiguous = ambiguous }

let request_body input =
  `Assoc
    [ ("model", `String model);
      ("input", `String input);
      ("dimensions", `Int dimensions);
      ( "provider",
        `Assoc
          [ ("order", `List [ `String "openai" ]);
            ("allow_fallbacks", `Bool false);
            ("data_collection", `String "deny") ] ) ]
  |> Yojson.Safe.to_string

let context_length_error json =
  let contains value needle =
    let length = String.length needle in
    let rec loop offset =
      offset + length <= String.length value
      && (String.sub value offset length = needle || loop (offset + 1))
    in
    loop 0
  in
  let rec strings = function
    | `String value -> [ String.lowercase_ascii value ]
    | `Assoc fields -> List.concat_map (fun (_, value) -> strings value) fields
    | `List values -> List.concat_map strings values
    | _ -> []
  in
  strings json
  |> List.exists (fun value ->
         List.exists (contains value)
           [ "context length"; "context_length"; "maximum context"; "too many tokens" ])

let classify_http status json =
  if status = 400 && context_length_error json then
    error Validation "embedding_input_too_large"
      "Embedding input exceeds the provider context limit; split it into linked concepts."
  else if status = 401 || status = 403 then
    error Authentication "openrouter_authentication_failed"
      "OpenRouter authentication failed."
  else if status = 402 then
    error Payment_required "openrouter_payment_required"
      "OpenRouter credits are unavailable."
  else if status = 408 then
    error Transient "openrouter_timeout" "OpenRouter request timed out."
  else if status = 429 then
    error Rate_limited "openrouter_rate_limited"
      "OpenRouter rate limited the request."
  else if status >= 500 then
    error Transient "openrouter_unavailable"
      "OpenRouter returned a transient service failure."
  else
    error Validation "openrouter_request_rejected"
      "OpenRouter rejected the embedding request."

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_member name json =
  match member name json with Some (`Int value) -> Some value | _ -> None

let parse_response ~status ~body =
  let parsed = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
  if status < 200 || status >= 300 then
    classify_http status (Option.value parsed ~default:`Null)
  else
    match parsed with
    | None ->
        error Invalid_response "openrouter_invalid_response"
          "OpenRouter returned malformed JSON."
    | Some json ->
        let response_model = member "model" json in
        let usage = member "usage" json in
        let data = member "data" json in
        let list_object = member "object" json = Some (`String "list") in
        let accepted_model =
          response_model = Some (`String model)
          || response_model = Some (`String "text-embedding-3-small")
        in
        (match (data, usage) with
        | Some (`List [ item ]), Some usage when accepted_model && list_object ->
            let prompt_tokens = int_member "prompt_tokens" usage
            and total_tokens = int_member "total_tokens" usage in
            (match
               ( member "embedding" item,
                 member "object" item,
                 member "index" item,
                 prompt_tokens,
                 total_tokens )
             with
            | ( Some (`List values),
                Some (`String "embedding"),
                Some (`Int 0),
                Some prompt_tokens,
                Some total_tokens )
              when prompt_tokens >= 0 && total_tokens >= prompt_tokens
                   && List.length values = dimensions ->
                let floats =
                  List.map
                    (function
                      | `Float value -> Some value
                      | `Int value -> Some (float_of_int value)
                      | _ -> None)
                    values
                in
                if
                  List.for_all
                    (Option.exists (fun value -> Float.is_finite value))
                    floats
                then
                  Ok
                    { values = Array.of_list (List.map Option.get floats);
                      usage = { prompt_tokens; total_tokens };
                      identity = canonical_identity }
                else
                  error Invalid_response "openrouter_invalid_embedding"
                    "OpenRouter returned non-finite or non-numeric embedding values."
            | _ ->
                error Invalid_response "openrouter_invalid_response"
                  "OpenRouter returned invalid embedding or usage metadata.")
        | _ ->
            error Invalid_response "openrouter_invalid_response"
              "OpenRouter returned an incompatible model or response shape.")

type http_result = { status : int; body : string }

type request_kind = Non_paid_get | Paid_post

external monotonic_now : unit -> float = "clamp_monotonic_now"

let retryable request_kind (failure : error) =
  match request_kind with
  | Non_paid_get ->
      failure.kind = Transient || failure.kind = Rate_limited
  | Paid_post ->
      failure.kind = Transient && not failure.paid_request_ambiguous

let run_retry ~request_kind ~total_timeout_ms ~now ~sleep ~jitter ~operation =
  let deadline = now () +. (float_of_int total_timeout_ms /. 1000.) in
  let timeout_failure () =
    error Transient "openrouter_timeout" "OpenRouter request deadline expired."
  in
  let rec attempt number =
    let remaining_ms = int_of_float ((deadline -. now ()) *. 1000.) in
    if remaining_ms <= 0 then timeout_failure ()
    else
      match operation ~timeout_ms:remaining_ms with
      | Ok _ as success -> success
      | Error failure as result ->
          if number >= 3 || not (retryable request_kind failure) then result
          else
            let remaining = deadline -. now () in
            let unit_jitter = Float.max 0. (Float.min 1. (jitter ())) in
            let base = 0.1 *. (2. ** float_of_int (number - 1)) in
            let delay = base *. (0.5 +. (0.5 *. unit_jitter)) in
            if remaining <= delay then result
            else begin
              sleep delay;
              attempt (number + 1)
            end
  in
  attempt 1

let transport_error ~meth code =
  { kind = Transient;
    code =
      (if code = Curl.CURLE_OPERATION_TIMEOUTED then "openrouter_timeout"
       else "openrouter_network_error");
    message = "OpenRouter could not be reached securely.";
    paid_request_ambiguous = meth = `POST }

let curl_setup_hook = ref (fun () -> ())

let perform ~allow_http ~timeout_ms ~meth ~url ~api_key ~body =
  let response = Buffer.create 4096 in
  let oversized = ref false in
  let write chunk =
    if Buffer.length response + String.length chunk > maximum_response_bytes then begin
      oversized := true;
      0
    end else begin
      Buffer.add_string response chunk;
      String.length chunk
    end
  in
  let classify_exception = function
    | Curl.CurlException (_, _, _) when !oversized ->
        error ~ambiguous:(meth = `POST) Response_too_large
          "openrouter_response_too_large"
          "OpenRouter response exceeded the safe size limit."
    | Curl.CurlException (code, _, _) -> Error (transport_error ~meth code)
    | _ ->
        error ~ambiguous:(meth = `POST) Transient "openrouter_network_error"
          "OpenRouter could not be reached securely."
  in
  try
    let handle = Curl.init () in
    let outcome =
      try
        !curl_setup_hook ();
        Curl.set_url handle url;
        Curl.set_protocols handle
          (if allow_http then [ Curl.CURLPROTO_HTTP; Curl.CURLPROTO_HTTPS ]
           else [ Curl.CURLPROTO_HTTPS ]);
        Curl.set_followlocation handle false;
        Curl.set_nosignal handle true;
        Curl.set_connecttimeoutms handle (max 1 (min 3000 timeout_ms));
        Curl.set_timeoutms handle timeout_ms;
        Curl.set_sslverifypeer handle true;
        Curl.set_sslverifyhost handle Curl.SSLVERIFYHOST_HOSTNAME;
        Curl.set_useragent handle "clamp/0.1.1";
        Curl.set_httpheader handle
          ([ "Accept: application/json"; "Authorization: Bearer " ^ api_key ]
          @ if meth = `POST then [ "Content-Type: application/json" ] else []);
        Curl.set_writefunction handle write;
        (match body with
        | Some value ->
            Curl.set_post handle true;
            Curl.set_postfields handle value;
            Curl.set_postfieldsize handle (String.length value)
        | None -> ());
        Curl.perform handle;
        Ok { status = Curl.get_responsecode handle; body = Buffer.contents response }
      with exception_value -> classify_exception exception_value
    in
    let cleanup_failure =
      try
        Curl.cleanup handle;
        None
      with exception_value -> Some (classify_exception exception_value)
    in
    (match (outcome, cleanup_failure) with
    | Error { kind = Response_too_large; _ }, _ -> outcome
    | _, Some failure -> failure
    | _, None -> outcome)
  with exception_value -> classify_exception exception_value

let mark_paid_ambiguity = function
  | Ok _ as success -> success
  | Error failure -> Error { failure with paid_request_ambiguous = true }

let production_effects () =
  let state = Random.State.make_self_init () in
  (monotonic_now, Unix.sleepf, fun () -> Random.State.float state 1.)

let embed_at ~allow_http ~timeout_ms ~now ~sleep ~jitter ~url ~api_key input =
  if api_key = "" then
    error Authentication "openrouter_api_key_missing"
      "OPENROUTER_API_KEY is required."
  else if not (Frontmatter.valid_utf8 input) then
    error Validation "embedding_input_invalid_utf8"
      "Embedding input must be valid UTF-8."
  else if String.length input > Embedding_input.maximum_bytes then
    error Validation "embedding_input_too_large"
      "Embedding input exceeds 8,000 UTF-8 bytes; split it into linked concepts."
  else
    run_retry ~request_kind:Paid_post ~total_timeout_ms:timeout_ms ~now ~sleep
      ~jitter ~operation:(fun ~timeout_ms ->
        match
          perform ~allow_http ~timeout_ms ~meth:`POST ~url ~api_key
            ~body:(Some (request_body input))
        with
        | Ok response ->
            parse_response ~status:response.status ~body:response.body
            |> mark_paid_ambiguity
        | Error failure -> Error failure)

let embed ~api_key input =
  let now, sleep, jitter = production_effects () in
  embed_at ~allow_http:false ~timeout_ms:15000 ~now ~sleep ~jitter ~url:endpoint
    ~api_key input

let authenticated_model_check_at ~allow_http ~timeout_ms ~now ~sleep ~jitter
    ~url ~api_key =
  if api_key = "" then
    error Authentication "openrouter_api_key_missing"
      "OPENROUTER_API_KEY is required."
  else
    run_retry ~request_kind:Non_paid_get ~total_timeout_ms:timeout_ms ~now ~sleep
      ~jitter ~operation:(fun ~timeout_ms ->
        match
          perform ~allow_http ~timeout_ms ~meth:`GET ~url ~api_key ~body:None
        with
        | Error failure -> Error failure
        | Ok response when response.status = 200 ->
            (try
               let json = Yojson.Safe.from_string response.body in
               match Option.bind (member "data" json) (member "id") with
               | Some (`String value) when value = model -> Ok ()
               | _ ->
                   error Invalid_response "openrouter_invalid_model_response"
                     "OpenRouter returned incompatible model metadata."
             with Yojson.Json_error _ ->
               error Invalid_response "openrouter_invalid_model_response"
                 "OpenRouter returned malformed model metadata.")
        | Ok response -> classify_http response.status `Null)

let authenticated_model_check ~api_key =
  let now, sleep, jitter = production_effects () in
  authenticated_model_check_at ~allow_http:false ~timeout_ms:15000 ~now ~sleep
    ~jitter ~url:model_endpoint ~api_key

module For_test = struct
  type nonrec request_kind = request_kind = Non_paid_get | Paid_post

  let run_retry = run_retry

  let with_curl_setup_exception code action =
    let previous = !curl_setup_hook in
    let attempts = ref 0 in
    curl_setup_hook := (fun () ->
        incr attempts;
        raise (Curl.CurlException (code, 0, "test")));
    let result =
      Fun.protect ~finally:(fun () -> curl_setup_hook := previous) action
    in
    (result, !attempts)

  let effects () =
    (Unix.gettimeofday, Unix.sleepf, fun () -> 0.)

  let embed_at ?(timeout_ms = 15000) ~url ~api_key input =
    let now, sleep, jitter = effects () in
    embed_at ~allow_http:true ~timeout_ms ~now ~sleep ~jitter ~url ~api_key input

  let authenticated_model_check_at ~timeout_ms ~url ~api_key =
    let now, sleep, jitter = effects () in
    authenticated_model_check_at ~allow_http:true ~timeout_ms ~now ~sleep
      ~jitter ~url ~api_key
end
