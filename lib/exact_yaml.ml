type scalar_kind = String | Integer | Float | Bool | Null | Plain
type t = Scalar of scalar_kind * string | Seq of t list | Map of (string * t) list

type numeric_error = Non_finite | Out_of_range

let max_numeric_integer_digits = 131_072
let max_numeric_fractional_digits = 16_383

let lower = String.lowercase_ascii

let unsigned value =
  if String.length value > 0 && (value.[0] = '+' || value.[0] = '-') then
    String.sub value 1 (String.length value - 1)
  else value

let based_digits base value =
  let digit = function
    | '0' .. '9' as character -> Char.code character - Char.code '0'
    | 'a' .. 'f' as character -> 10 + Char.code character - Char.code 'a'
    | 'A' .. 'F' as character -> 10 + Char.code character - Char.code 'A'
    | _ -> base
  in
  let length = String.length value in
  length > 0 && value.[0] <> '_' && value.[length - 1] <> '_'
  && String.for_all (fun character -> character = '_' || digit character < base) value

let prefixed_integer value =
  let value = lower (unsigned value) in
  let suffix prefix =
    String.sub value (String.length prefix) (String.length value - String.length prefix)
  in
  (String.starts_with ~prefix:"0x" value && based_digits 16 (suffix "0x"))
  || (String.starts_with ~prefix:"0o" value && based_digits 8 (suffix "0o"))
  || (String.starts_with ~prefix:"0b" value && based_digits 2 (suffix "0b"))

let decimal_digits value = based_digits 10 value
let decimal_integer value = decimal_digits (unsigned value)

let without_underscores value =
  let output = Bytes.create (String.length value) and length = ref 0 in
  String.iter
    (fun character ->
      if character <> '_' then begin
        Bytes.set output !length character;
        incr length
      end)
    value;
  Bytes.sub_string output 0 !length

let strip_leading_zeroes value =
  let index = ref 0 in
  while !index < String.length value && value.[!index] = '0' do incr index done;
  if !index = String.length value then "0"
  else String.sub value !index (String.length value - !index)

let canonical_decimal_integer value =
  let negative = String.length value > 0 && value.[0] = '-' in
  let digits = without_underscores (unsigned value) |> strip_leading_zeroes in
  if String.length digits > max_numeric_integer_digits then Error Out_of_range
  else if negative && digits <> "0" then Ok ("-" ^ digits)
  else Ok digits

let based_digit_limit = function 2 -> 435_413 | 8 -> 145_138 | 16 -> 108_854 | _ -> 0

let canonical_based_integer value =
  let negative = String.length value > 0 && value.[0] = '-' in
  let lowered = lower (unsigned value) in
  let base = match lowered.[1] with 'x' -> 16 | 'o' -> 8 | _ -> 2 in
  let payload =
    String.sub lowered 2 (String.length lowered - 2) |> without_underscores
    |> strip_leading_zeroes
  in
  if String.length payload > based_digit_limit base then Error Out_of_range
  else
    let decimal =
      Big_int.big_int_of_string
        ((match base with 16 -> "0x" | 8 -> "0o" | _ -> "0b") ^ payload)
      |> Big_int.string_of_big_int
    in
    if String.length decimal > max_numeric_integer_digits then Error Out_of_range
    else if negative && decimal <> "0" then Ok ("-" ^ decimal)
    else Ok decimal

let canonical_integer_result value =
  if decimal_integer value then canonical_decimal_integer value
  else if prefixed_integer value then canonical_based_integer value
  else Error Out_of_range

let canonical_integer value = Result.to_option (canonical_integer_result value)

let split_once value characters =
  let found = ref None and multiple = ref false in
  for index = 0 to String.length value - 1 do
    if String.contains characters value.[index] then
      match !found with None -> found := Some index | Some _ -> multiple := true
  done;
  match (!found, !multiple) with
  | Some index, false ->
      Some
        ( String.sub value 0 index,
          String.sub value (index + 1) (String.length value - index - 1) )
  | None, _ | _, true -> None

let float_lexeme value =
  let value = lower value in
  List.mem value [ ".inf"; "+.inf"; "-.inf"; ".nan" ]
  || begin
    let value = unsigned value in
    let mantissa, exponent =
      match split_once value "eE" with
      | Some (mantissa, exponent) -> (mantissa, Some (unsigned exponent))
      | None -> (value, None)
    in
    let exponent_valid = Option.for_all decimal_digits exponent in
    let mantissa_valid =
      match split_once mantissa "." with
      | Some (left, right) ->
          (left = "" || decimal_digits left)
          && (right = "" || decimal_digits right)
          && (left <> "" || right <> "")
      | None -> Option.is_some exponent && decimal_digits mantissa
    in
    exponent_valid && mantissa_valid
  end

let bounded_exponent ~limit value =
  let negative = String.length value > 0 && value.[0] = '-' in
  let digits = unsigned value in
  let magnitude = ref 0 and overflow = ref false in
  String.iter
    (fun character ->
      if character <> '_' && not !overflow then begin
        let digit = Char.code character - Char.code '0' in
        if !magnitude > (limit - digit) / 10 then overflow := true
        else magnitude := (!magnitude * 10) + digit
      end)
    digits;
  if !overflow then None else Some (if negative then - !magnitude else !magnitude)

let canonical_float value =
  let lowered = lower value in
  if List.mem lowered [ ".inf"; "+.inf"; "-.inf"; ".nan" ] then
    Error Non_finite
  else
    let negative = String.length value > 0 && value.[0] = '-' in
    let unsigned_value = unsigned value in
    let mantissa, exponent_lexeme =
      match split_once unsigned_value "eE" with
      | Some pair -> pair
      | None -> (unsigned_value, "0")
    in
    let left, right =
      match split_once mantissa "." with
      | Some pair -> pair
      | None -> (mantissa, "")
    in
    let left = without_underscores left and right = without_underscores right in
    let all = left ^ right in
    let first = ref 0 in
    while !first < String.length all && all.[!first] = '0' do incr first done;
    if !first = String.length all then Ok "0"
    else
      let last = ref (String.length all - 1) in
      while !last > !first && all.[!last] = '0' do decr last done;
      let trailing = String.length all - 1 - !last in
      let significant = String.sub all !first (!last - !first + 1) in
      let exponent_limit =
        String.length value + max_numeric_integer_digits
        + max_numeric_fractional_digits + 1
      in
      match bounded_exponent ~limit:exponent_limit exponent_lexeme with
      | None -> Error Out_of_range
      | Some exponent ->
          let power = exponent - String.length right + trailing in
          let significant_length = String.length significant in
          if
            (power >= 0
             && significant_length + power > max_numeric_integer_digits)
            || (power < 0 && -power > max_numeric_fractional_digits)
            || (power < 0 && significant_length + power > max_numeric_integer_digits)
          then Error Out_of_range
          else
            let magnitude =
              if power >= 0 then significant ^ String.make power '0'
              else
                let point = significant_length + power in
                if point > 0 then
                  String.sub significant 0 point ^ "."
                  ^ String.sub significant point (significant_length - point)
                else "0." ^ String.make (-point) '0' ^ significant
            in
            if negative then Ok ("-" ^ magnitude) else Ok magnitude

let canonical_number kind value =
  match kind with
  | Integer -> canonical_integer_result value
  | Float -> canonical_float value
  | String | Bool | Null | Plain -> Error Out_of_range

let numeric_error_code = function
  | Non_finite -> "numeric_non_finite"
  | Out_of_range -> "numeric_out_of_range"

let numeric_error_message = function
  | Non_finite -> "YAML non-finite numbers cannot be stored as JSON numbers"
  | Out_of_range -> "YAML number exceeds PostgreSQL numeric limits"

let numeric_issues value =
  let rec collect field issues = function
    | Scalar ((Integer | Float as kind), lexeme) ->
        (match canonical_number kind lexeme with
        | Ok _ -> issues
        | Error failure -> (field, failure) :: issues)
    | Scalar _ -> issues
    | Seq values ->
        List.mapi (fun index item -> (index, item)) values
        |> List.fold_left
             (fun issues (index, item) ->
               collect (Printf.sprintf "%s[%d]" field index) issues item)
             issues
    | Map fields ->
        List.fold_left
          (fun issues (name, item) ->
            collect (if field = "" then name else field ^ "." ^ name) issues item)
          issues fields
  in
  collect "" [] value |> List.rev

let standard_tag tag name =
  tag = "!!" ^ name || tag = "tag:yaml.org,2002:" ^ name

let kind_of_scalar (scalar : Yaml.scalar) =
  match scalar.tag with
  | Some tag when standard_tag tag "str" -> Ok String
  | Some tag when standard_tag tag "int" -> Ok Integer
  | Some tag when standard_tag tag "float" -> Ok Float
  | Some tag when standard_tag tag "bool" -> Ok Bool
  | Some tag when standard_tag tag "null" -> Ok Null
  | Some _ -> Error "unsupported YAML tag"
  | None when scalar.style <> `Plain -> Ok String
  | None when decimal_integer scalar.value || prefixed_integer scalar.value ->
      Ok Integer
  | None when float_lexeme scalar.value -> Ok Float
  | None
    when List.mem (lower scalar.value)
           [ "true"; "false"; "yes"; "no"; "y"; "n"; "on"; "off" ] ->
      Ok Bool
  | None when List.mem (lower scalar.value) [ "null"; "~"; "" ] -> Ok Null
  | None -> Ok String

let valid_kind_value kind value =
  match kind with
  | String | Plain -> true
  | Integer -> decimal_integer value || prefixed_integer value
  | Float -> float_lexeme value || decimal_integer value
  | Bool ->
      List.mem (lower value)
        [ "true"; "false"; "yes"; "no"; "y"; "n"; "on"; "off" ]
  | Null -> List.mem (lower value) [ "null"; "~"; "" ]

let collection_tag kind = function
  | None -> true
  | Some tag -> standard_tag tag kind

let duplicate keys =
  let rec adjacent = function
    | left :: (right :: _ as rest) -> left = right || adjacent rest
    | _ -> false
  in
  adjacent (List.sort String.compare keys)

let parse input =
  let open Yaml.Stream in
  let nodes = ref 0 in
  let count_node () =
    incr nodes;
    if !nodes > Limits.max_yaml_nodes then Error "YAML node limit exceeded"
    else Ok ()
  in
  let next parser =
    match do_parse parser with
    | Ok (event, _) -> Ok event
    | Error (`Msg _) -> Error "malformed YAML"
  in
  let rec node parser depth event =
    if depth > Limits.max_yaml_depth then Error "YAML depth limit exceeded"
    else Result.bind (count_node ()) (fun () -> match event with
    | Event.Alias _ -> Error "YAML aliases are not supported"
    | Event.Scalar scalar when Option.is_some scalar.anchor ->
        Error "YAML anchors are not supported"
    | Event.Scalar scalar ->
        Result.bind (kind_of_scalar scalar) (fun kind ->
            if valid_kind_value kind scalar.value then
              Ok (Scalar (kind, scalar.value))
            else Error "invalid explicitly tagged YAML scalar")
    | Event.Sequence_start { anchor = Some _; _ }
    | Event.Mapping_start { anchor = Some _; _ } ->
        Error "YAML anchors are not supported"
    | Event.Sequence_start { tag; _ } when not (collection_tag "seq" tag) ->
        Error "unsupported YAML collection tag"
    | Event.Mapping_start { tag; _ } when not (collection_tag "map" tag) ->
        Error "unsupported YAML collection tag"
    | Event.Sequence_start _ -> sequence parser depth []
    | Event.Mapping_start _ -> mapping parser depth []
    | _ -> Error "malformed YAML document"
    )
  and sequence parser depth values =
    Result.bind (next parser) (function
      | Event.Sequence_end -> Ok (Seq (List.rev values))
      | event ->
          Result.bind (node parser (depth + 1) event) (fun value ->
              sequence parser depth (value :: values)))
  and mapping parser depth fields =
    Result.bind (next parser) (function
      | Event.Mapping_end ->
          if duplicate (List.map fst fields) then
            Error "duplicate YAML mapping key"
          else Ok (Map (List.rev fields))
      | Event.Scalar key ->
          Result.bind (count_node ()) (fun () ->
              if Option.is_some key.anchor then Error "YAML anchors are not supported"
              else Result.bind (kind_of_scalar key) (function
                | String ->
                    Result.bind (next parser) (fun event ->
                        Result.bind (node parser (depth + 1) event) (fun value ->
                            mapping parser depth ((key.value, value) :: fields)))
                | _ -> Error "YAML mapping keys must be strings"))
      | _ -> Error "YAML mapping keys must be strings")
  in
  match parser input with
  | Error (`Msg _) -> Error "malformed YAML"
  | Ok parser ->
      Result.bind (next parser) (function
        | Event.Stream_start _ ->
            Result.bind (next parser) (function
              | Event.Document_start _ ->
                  Result.bind (next parser) (fun event ->
                      Result.bind (node parser 1 event) (fun value ->
                          Result.bind (next parser) (function
                            | Event.Document_end _ ->
                                Result.bind (next parser) (function
                                  | Event.Stream_end -> Ok value
                                  | _ -> Error "YAML must contain exactly one document")
                            | _ -> Error "malformed YAML document")))
              | _ -> Error "YAML must contain exactly one document")
        | _ -> Error "malformed YAML stream")

let quote value = Yojson.Safe.to_string (`String value)

let scalar = function
  | String, value -> quote value
  | Integer, value -> "!!int " ^ value
  | Float, value -> "!!float " ^ value
  | Bool, value ->
      let value = lower value in
      if List.mem value [ "true"; "yes"; "y"; "on" ] then "!!bool true"
      else "!!bool false"
  | Null, _ -> "!!null null"
  | Plain, value -> value

let known_order =
  [ "type"; "title"; "description"; "resource"; "tags"; "generated";
    "verified"; "status"; "stale_after"; "sources"; "runtime"; "parameters";
    "computation"; "executor"; "attester"; "usage_count"; "last_modified";
    "usage_window"; "clamp" ]

let rank key =
  match List.find_index (String.equal key) known_order with
  | Some index -> (0, index, key)
  | None -> (1, 0, key)

let rec emit indent = function
  | Scalar (kind, value) -> scalar (kind, value)
  | Seq [] -> "[]"
  | Map [] -> "{}"
  | Seq values ->
      values
      |> List.map (fun value ->
             match value with
             | Scalar _ | Seq [] | Map [] ->
                 String.make indent ' ' ^ "- " ^ emit (indent + 2) value ^ "\n"
             | _ ->
                 String.make indent ' ' ^ "-\n" ^ emit_block (indent + 2) value)
      |> String.concat ""
  | Map fields ->
      fields
      |> List.sort (fun (left, _) (right, _) -> compare (rank left) (rank right))
      |> List.map (fun (key, value) ->
             let prefix = String.make indent ' ' ^ quote key ^ ":" in
             match value with
             | Scalar _ | Seq [] | Map [] ->
                 prefix ^ " " ^ emit (indent + 2) value ^ "\n"
             | _ -> prefix ^ "\n" ^ emit_block (indent + 2) value)
      |> String.concat ""
and emit_block indent = function
  | Scalar _ as value -> String.make indent ' ' ^ emit indent value ^ "\n"
  | value -> emit indent value

let to_string value =
  let output =
    match value with Scalar (kind, value) -> scalar (kind, value) | value -> emit 0 value
  in
  if String.ends_with ~suffix:"\n" output then output else output ^ "\n"

let find key = function Map fields -> List.assoc_opt key fields | _ -> None
let string = function Scalar (String, value) -> Some value | _ -> None
let scalar_text = function Scalar (_, value) -> Some value | _ -> None
