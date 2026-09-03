open Cmarkit

let document markdown = Doc.of_string ~strict:true markdown

let definition_destination definitions link =
  match Inline.Link.reference_definition definitions link with
  | Some (Link_definition.Def (definition, _)) ->
      Option.map fst (Link_definition.dest definition)
  | Some _ | None -> None

let fold_bounded ~limit ~retain markdown =
  if limit <= 0 then ([], 0, true)
  else
  let document = document markdown in
  let definitions = Doc.defs document in
  let count = ref 0 and truncated = ref false and destinations = ref [] in
  let add destination =
    if !count < limit then begin
      incr count;
      if retain then destinations := destination :: !destinations
    end else truncated := true
  in
  let inline _folder () = function
    | Inline.Link (link, _) ->
        (match definition_destination definitions link with
        | Some destination -> add destination
        | None -> ());
        Folder.default
    | Inline.Autolink (link, _) ->
        add (fst (Inline.Autolink.link link));
        Folder.ret ()
    | Inline.Image _ -> Folder.ret ()
    | _ -> Folder.default
  in
  let folder = Folder.make ~inline () in
  ignore (Folder.fold_doc folder () document);
  (List.rev !destinations, !count, !truncated)

let extract_bounded ~limit markdown =
  let destinations, _, truncated = fold_bounded ~limit ~retain:true markdown in
  (destinations, truncated)

let count_bounded ~limit markdown =
  let _, count, truncated = fold_bounded ~limit ~retain:false markdown in
  (count, truncated)

let extract markdown = fst (extract_bounded ~limit:max_int markdown)

let add_inline_text buffer inline =
  Inline.to_plain_text ~break_on_soft:false inline
  |> List.iteri (fun line fragments ->
         if line > 0 then Buffer.add_char buffer '\n';
         List.iter (Buffer.add_string buffer) fragments)

let root_blocks document =
  match Doc.block document with
  | Block.Blocks (blocks, _) -> blocks
  | block -> [ block ]

let heading_text heading =
  let buffer = Buffer.create 64 in
  add_inline_text buffer (Block.Heading.inline heading);
  Buffer.contents buffer

let log_structure markdown =
  let contains_heading root_block =
    let block _folder found = function
      | Block.Heading _ -> Folder.ret true
      | _ -> if found then Folder.ret true else Folder.default
    in
    Folder.fold_block (Folder.make ~block ()) false root_block
  in
  let substantive = function
    | Block.Blank_line _ | Block.Link_reference_definition _ -> false
    | _ -> true
  in
  match root_blocks (document markdown) |> List.filter substantive with
  | Block.Heading (title, _) :: rest
    when Block.Heading.level title = 1
         && String.trim (heading_text title) <> "" ->
      List.fold_left
        (fun (valid, dates) block ->
          match block with
          | Block.Heading (heading, _) when Block.Heading.level heading = 2 ->
              (valid, heading_text heading :: dates)
          | Block.Heading _ -> (false, dates)
          | block -> (valid && not (contains_heading block), dates))
        (true, []) rest
      |> fun (valid, dates) -> (valid, List.rev dates)
  | _ -> (false, [])

let index_entries markdown =
  let document = document markdown in
  let definitions = Doc.defs document in
  let section = ref false and destinations = ref [] in
  let rec leading_link = function
    | Inline.Link (link, _) -> definition_destination definitions link
    | Inline.Inlines (inlines, _) ->
        let rec first = function
          | [] -> None
          | Inline.Text (text, _) :: rest when String.trim text = "" -> first rest
          | inline :: _ -> leading_link inline
        in
        first inlines
    | _ -> None
  in
  let rec item_entry = function
    | Block.Blocks (blocks, _) ->
        let rec first = function
          | [] -> None
          | Block.Blank_line _ :: rest -> first rest
          | block :: _ -> item_entry block
        in
        first blocks
    | Block.Paragraph (paragraph, _) ->
        leading_link (Block.Paragraph.inline paragraph)
    | _ -> None
  in
  root_blocks document
  |> List.iter (function
       | Block.Heading (heading, _)
         when Block.Heading.level heading = 1 ->
           section := String.trim (heading_text heading) <> ""
       | Block.List (list, _) when !section ->
        (match Block.List'.type' list with
        | `Unordered _ ->
            Block.List'.items list
            |> List.iter (fun (item, _) ->
                   Option.iter
                     (fun destination -> destinations := destination :: !destinations)
                     (item_entry (Block.List_item.block item)))
        | `Ordered _ -> ())
       | _ -> ());
  List.rev !destinations

let visible_text markdown =
  let buffer = Buffer.create (String.length markdown) in
  let pending_space = ref false in
  let separate () =
    pending_space := false;
    if Buffer.length buffer > 0 && Buffer.nth buffer (Buffer.length buffer - 1) <> '\n'
    then Buffer.add_char buffer '\n'
  in
  let prose text =
    String.iter
      (fun character ->
        if List.mem character [ ' '; '\t'; '\r'; '\n' ] then
          pending_space := Buffer.length buffer > 0
        else begin
          if !pending_space then Buffer.add_char buffer ' ';
          pending_space := false;
          Buffer.add_char buffer character
        end)
      text
  in
  let exact kind text =
    pending_space := false;
    Buffer.add_char buffer '\000';
    Buffer.add_string buffer kind;
    Buffer.add_char buffer ':';
    Buffer.add_string buffer (string_of_int (String.length text));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer text;
    Buffer.add_char buffer '\000'
  in
  let lines to_string values =
    values |> List.map to_string |> String.concat "\n"
  in
  let inline _folder () = function
    | Inline.Text (text, _) ->
        prose text;
        Folder.ret ()
    | Inline.Autolink (link, _) ->
        prose (fst (Inline.Autolink.link link));
        Folder.ret ()
    | Inline.Break _ ->
        pending_space := Buffer.length buffer > 0;
        Folder.ret ()
    | Inline.Code_span (code, _) ->
        exact "inline-code" (Inline.Code_span.code code);
        Folder.ret ()
    | Inline.Raw_html (html, _) ->
        exact "inline-html" (lines Block_line.tight_to_string html);
        Folder.ret ()
    | _ -> Folder.default
  in
  let block _folder () = function
    | Block.Paragraph _ | Block.Heading _ ->
        separate ();
        Folder.default
    | Block.Code_block (code, _) ->
        separate ();
        exact "code-block"
          (lines Block_line.to_string (Block.Code_block.code code));
        Folder.ret ()
    | Block.Html_block (html, _) ->
        separate ();
        exact "html-block" (lines Block_line.to_string html);
        Folder.ret ()
    | _ -> Folder.default
  in
  let folder = Folder.make ~inline ~block () in
  ignore (Folder.fold_doc folder () (document markdown));
  Buffer.contents buffer |> String.trim
