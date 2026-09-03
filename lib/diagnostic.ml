type severity = Error | Warning

type t = {
  severity : severity;
  path : string;
  code : string;
  field : string;
  message : string;
}

let make ?(severity = Error) ?(field = "") path code message =
  { severity; path; code; field; message }

let severity_name = function Error -> "error" | Warning -> "warning"

let compare left right =
  compare
    (left.path, left.code, left.field, left.message, left.severity)
    (right.path, right.code, right.field, right.message, right.severity)

let json diagnostic =
  `Assoc
    [ ("severity", `String (severity_name diagnostic.severity));
      ("path", `String diagnostic.path);
      ("code", `String diagnostic.code);
      ("field", `String diagnostic.field);
      ("message", `String diagnostic.message) ]

let human diagnostic =
  Printf.sprintf "%s: %s [%s]%s: %s"
    (severity_name diagnostic.severity) diagnostic.path diagnostic.code
    (if diagnostic.field = "" then "" else " field=" ^ diagnostic.field)
    diagnostic.message

let is_error diagnostic = diagnostic.severity = Error

module Collector = struct
  type diagnostic = t
  type t = {
    heap : diagnostic option array;
    mutable size : int;
    mutable exceeded : bool;
  }

  let create () =
    { heap = Array.make Limits.max_diagnostics None; size = 0; exceeded = false }

  let get collector index = Option.get collector.heap.(index)

  let swap collector left right =
    let value = collector.heap.(left) in
    collector.heap.(left) <- collector.heap.(right);
    collector.heap.(right) <- value

  let rec sift_up collector index =
    if index > 0 then
      let parent = (index - 1) / 2 in
      if compare (get collector parent) (get collector index) < 0 then begin
        swap collector parent index;
        sift_up collector parent
      end

  let rec sift_down collector index =
    let left = (2 * index) + 1 in
    if left < collector.size then begin
      let right = left + 1 in
      let largest =
        if right < collector.size && compare (get collector left) (get collector right) < 0
        then right else left
      in
      if compare (get collector index) (get collector largest) < 0 then begin
        swap collector index largest;
        sift_down collector largest
      end
    end

  let push collector diagnostic =
    collector.heap.(collector.size) <- Some diagnostic;
    collector.size <- collector.size + 1;
    sift_up collector (collector.size - 1)

  let remove_max collector =
    collector.size <- collector.size - 1;
    collector.heap.(0) <- collector.heap.(collector.size);
    collector.heap.(collector.size) <- None;
    if collector.size > 0 then sift_down collector 0

  let consider collector diagnostic =
    if compare diagnostic (get collector 0) < 0 then begin
      collector.heap.(0) <- Some diagnostic;
      sift_down collector 0
    end

  let add collector diagnostic =
    if not collector.exceeded && collector.size < Limits.max_diagnostics then
      push collector diagnostic
    else begin
      if not collector.exceeded then begin
        collector.exceeded <- true;
        remove_max collector
      end;
      consider collector diagnostic
    end

  let exceeded collector = collector.exceeded

  let diagnostics collector =
    let retained =
      Array.sub collector.heap 0 collector.size |> Array.to_list
      |> List.filter_map Fun.id
    in
    let retained =
      if collector.exceeded then
        make "knowledge" "diagnostic_limit"
          "bundle exceeds the 1,000-diagnostic safety limit"
        :: retained
      else retained
    in
    List.sort compare retained
end
