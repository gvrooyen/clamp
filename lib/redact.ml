let replace_all ~needle ~replacement input =
  if needle = "" then input
  else
    let needle_length = String.length needle in
    let input_length = String.length input in
    let buffer = Buffer.create input_length in
    let rec loop offset =
      if offset >= input_length then ()
      else
        match String.index_from_opt input offset needle.[0] with
        | None -> Buffer.add_substring buffer input offset (input_length - offset)
        | Some index ->
            if index + needle_length <= input_length
               && String.sub input index needle_length = needle
            then (
              Buffer.add_substring buffer input offset (index - offset);
              Buffer.add_string buffer replacement;
              loop (index + needle_length))
            else (
              Buffer.add_substring buffer input offset (index - offset + 1);
              loop (index + 1))
    in
    loop 0;
    Buffer.contents buffer

let redact_environment input =
  [ "KB_DATABASE_URL"; "KB_DATABASE_DIRECT_URL"; "OPENROUTER_API_KEY" ]
  |> List.fold_left
       (fun text variable ->
         match Sys.getenv_opt variable with
         | Some value when value <> "" ->
             replace_all ~needle:value ~replacement:"[REDACTED]" text
         | _ -> text)
       input

let is_boundary = function
  | ' ' | '\t' | '\r' | '\n' | '\'' | '"' | '<' | '>' -> true
  | _ -> false

let redact_token_prefix prefix input =
  let prefix_length = String.length prefix in
  let rec find_from offset text =
    if offset + prefix_length > String.length text then text
    else if String.sub text offset prefix_length = prefix then
      let stop = ref (offset + prefix_length) in
      while !stop < String.length text && not (is_boundary text.[!stop]) do
        incr stop
      done;
      let redacted =
        String.sub text 0 offset ^ "[REDACTED]"
        ^ String.sub text !stop (String.length text - !stop)
      in
      find_from (offset + String.length "[REDACTED]") redacted
    else find_from (offset + 1) text
  in
  find_from 0 input

let redact_uri_userinfo input =
  let rec loop offset text =
    match String.index_from_opt text offset ':' with
    | None -> text
    | Some colon ->
        if colon + 2 < String.length text && String.sub text colon 3 = "://"
        then
          let authority_start = colon + 3 in
          let authority_end = ref authority_start in
          while
            !authority_end < String.length text
            && not (is_boundary text.[!authority_end])
            && text.[!authority_end] <> '/'
          do
            incr authority_end
          done;
          let at =
            match String.index_from_opt text authority_start '@' with
            | Some index when index < !authority_end -> Some index
            | _ -> None
          in
          (match at with
          | None -> loop (colon + 3) text
          | Some at ->
              let redacted =
                String.sub text 0 authority_start ^ "[REDACTED]@"
                ^ String.sub text (at + 1) (String.length text - at - 1)
              in
              loop (authority_start + String.length "[REDACTED]@") redacted)
        else loop (colon + 1) text
  in
  loop 0 input

let string input =
  input |> redact_environment |> redact_uri_userinfo
  |> redact_token_prefix "sk-or-v1-"

let rec yojson = function
  | `String value -> `String (string value)
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> (key, yojson value)) fields)
  | `List values -> `List (List.map yojson values)
  | value -> value
