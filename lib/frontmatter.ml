type t = { metadata : Exact_yaml.t; body : string }

let valid_utf8 input =
  let length = String.length input in
  let continuation index =
    index < length
    && let byte = Char.code input.[index] in
       byte >= 0x80 && byte <= 0xBF
  in
  let rec loop index =
    if index = length then true
    else
      let byte = Char.code input.[index] in
      if byte <= 0x7F then loop (index + 1)
      else if byte >= 0xC2 && byte <= 0xDF then
        continuation (index + 1) && loop (index + 2)
      else if byte = 0xE0 then
        index + 2 < length
        && Char.code input.[index + 1] >= 0xA0
        && Char.code input.[index + 1] <= 0xBF
        && continuation (index + 2) && loop (index + 3)
      else if (byte >= 0xE1 && byte <= 0xEC) || (byte >= 0xEE && byte <= 0xEF) then
        continuation (index + 1) && continuation (index + 2) && loop (index + 3)
      else if byte = 0xED then
        index + 2 < length
        && Char.code input.[index + 1] >= 0x80
        && Char.code input.[index + 1] <= 0x9F
        && continuation (index + 2) && loop (index + 3)
      else if byte = 0xF0 then
        index + 3 < length
        && Char.code input.[index + 1] >= 0x90
        && Char.code input.[index + 1] <= 0xBF
        && continuation (index + 2) && continuation (index + 3)
        && loop (index + 4)
      else if byte >= 0xF1 && byte <= 0xF3 then
        continuation (index + 1) && continuation (index + 2)
        && continuation (index + 3) && loop (index + 4)
      else if byte = 0xF4 then
        index + 3 < length
        && Char.code input.[index + 1] >= 0x80
        && Char.code input.[index + 1] <= 0x8F
        && continuation (index + 2) && continuation (index + 3)
        && loop (index + 4)
      else false
  in
  loop 0

let normalize_newlines input =
  let buffer = Buffer.create (String.length input) in
  let rec loop index =
    if index < String.length input then
      if input.[index] = '\r' then begin
        Buffer.add_char buffer '\n';
        loop (index + if index + 1 < String.length input && input.[index + 1] = '\n' then 2 else 1)
      end else begin
        Buffer.add_char buffer input.[index];
        loop (index + 1)
      end
  in
  loop 0;
  Buffer.contents buffer

let has_opening_delimiter input =
  let input = normalize_newlines input in
  input = "---" || String.starts_with ~prefix:"---\n" input

let closing_delimiter input =
  let rec lines start =
    match String.index_from_opt input start '\n' with
    | None ->
        if String.sub input start (String.length input - start) = "---" then
          Some (start, String.length input)
        else None
    | Some stop ->
        if String.sub input start (stop - start) = "---" then Some (start, stop + 1)
        else lines (stop + 1)
  in
  if String.length input < 4 then None else lines 4

let body_after_delimiters input =
  let input = normalize_newlines input in
  if not (has_opening_delimiter input) then None
  else
    Option.map
      (fun (_, body_start) ->
        String.sub input body_start (String.length input - body_start))
      (closing_delimiter input)

let parse input =
  let input = normalize_newlines input in
  if not (valid_utf8 input) then Error "concept must be valid UTF-8"
  else if not (has_opening_delimiter input) then
    Error "frontmatter must start at byte 0"
  else if String.length input = 3 then
    Error "frontmatter closing delimiter is missing"
  else
    match closing_delimiter input with
    | None -> Error "frontmatter closing delimiter is missing"
    | Some (delimiter, body_start) ->
        let yaml = String.sub input 4 (delimiter - 4) in
        Result.bind (Exact_yaml.parse yaml) (function
          | Exact_yaml.Map _ as metadata ->
              Ok { metadata; body = String.sub input body_start (String.length input - body_start) }
          | _ -> Error "frontmatter metadata must be a mapping")

let serialize value =
  let body = normalize_newlines value.body in
  let body =
    let rec drop index =
      if index < String.length body && body.[index] = '\n' then drop (index + 1) else index
    in
    let start = drop 0 in
    let rec ending index =
      if index > start && body.[index - 1] = '\n' then ending (index - 1) else index
    in
    let stop = ending (String.length body) in
    String.sub body start (stop - start)
  in
  "---\n" ^ Exact_yaml.to_string value.metadata ^ "---\n\n" ^ body ^ "\n"
