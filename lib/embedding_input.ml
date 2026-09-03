open Exact_yaml

type t = { text : string; sha256 : string }

type error = Invalid_utf8 | Too_large of { actual : int; maximum : int }

let maximum_bytes = 8000

let scalar = function Scalar (String, value) -> value | _ -> ""

let tags metadata =
  match Exact_yaml.find "tags" metadata with
  | Some (Seq values) -> List.map scalar values
  | _ -> []

let normalize = Frontmatter.normalize_newlines

let make concept =
  let metadata = concept.Frontmatter.metadata in
  let field name =
    Exact_yaml.find name metadata |> Option.map scalar |> Option.value ~default:""
    |> normalize
  in
  let text =
    `Assoc
      [ ("type", `String (field "type"));
        ("title", `String (field "title"));
        ("description", `String (field "description"));
        ( "tags",
          `List
            (tags metadata |> List.map normalize |> List.sort String.compare
            |> List.map (fun tag -> `String tag)) );
        ("body", `String (normalize concept.body)) ]
    |> Yojson.Safe.to_string |> fun json -> json ^ "\n"
  in
  if not (Frontmatter.valid_utf8 text) then Error Invalid_utf8
  else
    let actual = String.length text in
    if actual > maximum_bytes then Error (Too_large { actual; maximum = maximum_bytes })
    else
      Ok
        { text;
          sha256 = Digestif.SHA256.(to_hex (digest_string text)) }

let changed before after =
  Result.bind (make before) (fun left ->
      Result.map (fun right -> left.sha256 <> right.sha256) (make after))

let error_code = function
  | Invalid_utf8 -> "embedding_input_invalid_utf8"
  | Too_large _ -> "embedding_input_too_large"

let error_message = function
  | Invalid_utf8 -> "Embedding input must be valid UTF-8."
  | Too_large _ ->
      "Embedding input exceeds 8,000 UTF-8 bytes; split it into linked concepts."
