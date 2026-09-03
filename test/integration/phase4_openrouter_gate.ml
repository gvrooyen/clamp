let fail stage (error : Clamp.Openrouter.error) =
  Printf.eprintf "%s failed: code=%s paid_request_ambiguous=%b\n%!" stage
    error.code error.paid_request_ambiguous;
  exit 1

let () =
  match Sys.getenv_opt "OPENROUTER_API_KEY" with
  | None | Some "" ->
      Printf.printf "SKIP: OPENROUTER_API_KEY unavailable; requests=0 paid=0\n%!"
  | Some api_key ->
      (match Clamp.Openrouter.authenticated_model_check ~api_key with
      | Error error -> fail "model GET" error
      | Ok () ->
          Printf.printf
            "model GET: authenticated model identity verified; requests=1 paid=0\n%!");
      (match Clamp.Openrouter.embed ~api_key "clamp phase 4 cost gate" with
      | Error error -> fail "embedding POST" error
      | Ok embedding ->
          Printf.printf
            "embedding POST: dimensions=%d identity=%s usage_valid=true; requests=1 paid=1\n%!"
            (Array.length embedding.values) embedding.identity)
