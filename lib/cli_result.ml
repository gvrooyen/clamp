type t = {
  ok : bool;
  code : string;
  message : string option;
  data : Yojson.Safe.t option;
  details : Yojson.Safe.t option;
  exit_class : Exit_class.t;
}

let success ~code ~data =
  {
    ok = true;
    code;
    message = None;
    data = Some data;
    details = None;
    exit_class = Success;
  }

let failure ~exit_class ~code ~message ~details =
  {
    ok = false;
    code;
    message = Some (Redact.string message);
    data = None;
    details = Some (Redact.yojson details);
    exit_class;
  }

let not_implemented ~command =
  failure ~exit_class:User_error ~code:"not_implemented"
    ~message:(Printf.sprintf "kb %s is not implemented yet." command)
    ~details:(`Assoc [ ("command", `String command) ])

let exit_code result = Exit_class.code result.exit_class

let to_yojson result =
  let envelope =
    if result.ok then
      `Assoc
        [
          ("ok", `Bool true);
          ("code", `String result.code);
          ("data", Option.value result.data ~default:(`Assoc []));
        ]
    else
      `Assoc
        [
          ("ok", `Bool false);
          ("code", `String result.code);
          ( "message",
            `String (Option.value result.message ~default:"An error occurred.") );
          ("details", Option.value result.details ~default:(`Assoc []));
        ]
  in
  Redact.yojson envelope

let to_json_string result = Yojson.Safe.to_string (to_yojson result)
let message result = result.message
