open Cmdliner

type common_options = {
  repo_root : string;
  json : bool;
  quiet : bool;
  diagnostic : bool;
}

let version = "0.1.0"

let exits =
  let info kind doc = Cmd.Exit.info ~doc (Clamp.Exit_class.code kind) in
  let open Clamp.Exit_class in
  [
    info Success "The command completed successfully.";
    info User_error "The request or local input was invalid.";
    info Conflict "A durable publication conflict requires resolution.";
    info Authentication "Authentication failed.";
    info Transient_external "A transient external dependency failed.";
    info Stale_index "The derived index is stale or incompatible.";
    info Internal "An unexpected internal failure occurred.";
  ]

let command_info ?version name doc = Cmd.info name ?version ~doc ~exits

let common_options =
  let repo_root =
    let doc = "Use $(docv) as the repository root." in
    Arg.(value & opt string "." & info [ "repo"; "repo-root" ] ~docv:"PATH" ~doc)
  in
  let json =
    Arg.(value & flag & info [ "json" ] ~doc:"Emit the stable JSON result envelope.")
  in
  let quiet =
    Arg.(value & flag & info [ "q"; "quiet" ] ~doc:"Suppress human-oriented command output.")
  in
  let diagnostic =
    Arg.(value & flag & info [ "diagnostic" ] ~doc:"Emit safe diagnostic context on standard error.")
  in
  Term.(const (fun repo_root json quiet diagnostic -> { repo_root; json; quiet; diagnostic })
        $ repo_root $ json $ quiet $ diagnostic)

let emit_diagnostic options ~command ~exit_class =
  if options.diagnostic && not options.quiet then
    Printf.eprintf
      "kb: diagnostic: command=%s exit_class=%s status=%d repo=%s\n" command
      (Clamp.Exit_class.name exit_class) (Clamp.Exit_class.code exit_class)
      (Clamp.Redact.string options.repo_root)

let run_placeholder command options =
  let result = Clamp.Cli_result.not_implemented ~command in
  emit_diagnostic options ~command ~exit_class:Clamp.Exit_class.User_error;
  if options.json then print_endline (Clamp.Cli_result.to_json_string result)
  else if not options.quiet then
    Printf.eprintf "%s\n" (Clamp.Cli_result.message result |> Option.get);
  Clamp.Cli_result.exit_code result

let emit ?human ~command options code data =
  let result = Clamp.Cli_result.success ~code ~data in
  emit_diagnostic options ~command ~exit_class:Clamp.Exit_class.Success;
  if options.json then print_endline (Clamp.Cli_result.to_json_string result)
  else if not options.quiet then
    Printf.printf "%s\n" (Option.value human ~default:code);
  0

let local_human command data =
  let open Yojson.Safe.Util in
  match command with
  | "add" | "edit" ->
      let id = data |> member "id" |> to_string in
      Some
        (Printf.sprintf "Concept %s: %s (knowledge/%s.md)."
           (if command = "add" then "added" else "updated") id id)
  | "verify" | "deprecate" ->
      let id = data |> member "id" |> to_string in
      Some
        (Printf.sprintf "Concept %s: %s."
           (if command = "verify" then "verified" else "deprecated") id)
  | "config set inferred-writes" ->
      Some
        (Printf.sprintf "Inference policy set to %s."
           (data |> member "inferred_writes" |> to_string))
  | _ -> None

let emit_local ~command options = function
  | Ok (code, data) -> emit ?human:(local_human command data) ~command options code data
  | Error (error : Clamp.Local.error) ->
      let exit_class = Clamp.Local.exit_class error in
      let result = Clamp.Cli_result.failure ~exit_class ~code:error.code ~message:error.message ~details:(`Assoc []) in
      emit_diagnostic options ~command ~exit_class;
      if options.json then print_endline(Clamp.Cli_result.to_json_string result) else if not options.quiet then Printf.eprintf "kb: %s\n" error.message;
      Clamp.Exit_class.code exit_class

let input_term =
  let file = Arg.(value & opt (some string) None & info ["input"] ~docv:"PATH" ~doc:"Read the complete Markdown document from PATH.") in
  let stdin = Arg.(value & flag & info ["stdin"] ~doc:"Read the complete Markdown document from standard input.") in
  Term.(const (fun file stdin -> match file,stdin with
    | Some path,false -> Clamp.Local.read path
    | None,true ->
        let b=Buffer.create 4096 and chunk=Bytes.create 65536 in
        let rec loop total =
          if total > Clamp.Limits.max_file_bytes then Error {Clamp.Local.code="file_size_limit";message="Input exceeds the 8 MiB safety limit."}
          else let wanted = min (Bytes.length chunk) (Clamp.Limits.max_file_bytes - total + 1) in
          match input Stdlib.stdin chunk 0 wanted with
          | 0 -> let text=Buffer.contents b in if Clamp.Frontmatter.valid_utf8 text then Ok text else Error {Clamp.Local.code="invalid_utf8";message="Input must be UTF-8."}
          | count -> Buffer.add_subbytes b chunk 0 count; loop (total+count) in
        loop 0
    | _ -> Error {Clamp.Local.code="invalid_input_source";message="Supply exactly one of --input or --stdin."}) $ file $ stdin)

let authority_term =
  let claim=Arg.(required & opt (some string) None & info ["claim"] ~docv:"AUTHORITY" ~doc:"Required: explicit or inferred.") in
  let confirmed=Arg.(value & flag & info ["confirmed"] ~doc:"Record user confirmation of an inferred claim. Unconfirmed auto_draft creates drafts; edits preserve the stored status.") in
  let allow=Arg.(value & flag & info ["allow-unknown-type"] ~doc:"Authorize this supplied unknown OKF type.") in
  Term.(const (fun claim confirmed allow->claim,confirmed,allow)$claim$confirmed$allow)

let deprecation_authority_term =
  let claim=Arg.(required & opt (some string) None & info ["claim"] ~docv:"AUTHORITY" ~doc:"Required: explicit or inferred.") in
  let confirmed=Arg.(value & flag & info ["confirmed"] ~doc:"Record user confirmation of an inferred replacement relationship.") in
  Term.(const (fun claim confirmed -> claim, confirmed) $ claim $ confirmed)

let run_mutation create id input authority options =
  let command = if create then "add" else "edit" in
  match
    Result.bind input (fun contents ->
        let claim, confirmed, allow_unknown = authority in
        Clamp.Local.mutate_with_outcome ~repo:options.repo_root
          ~id:(Option.value id ~default:"") ~contents ~claim ~confirmed
          ~allow_unknown ~create)
  with
  | Error issue -> emit_local ~command options (Error issue)
  | Ok outcome ->
      let data = `Assoc [ ("id", `String outcome.id) ] in
      let human_command =
        match outcome.disposition with
        | Clamp.Local.Created -> command
        | Updated -> "edit"
      in
      emit ?human:(local_human human_command data) ~command options
        (if create then "concept_added" else "concept_edited") data

let render_validation options (validation : Clamp.Bundle.result) =
  let diagnostics = `List (List.map Clamp.Diagnostic.json validation.diagnostics) in
  let has_errors = List.exists Clamp.Diagnostic.is_error validation.diagnostics in
  let result = if not has_errors then
    Clamp.Cli_result.success ~code:(if validation.diagnostics=[] then "bundle_valid" else "bundle_valid_with_warnings") ~data:(`Assoc ["concepts",`Int validation.concepts;"reserved_documents",`Int validation.reserved;"diagnostics",diagnostics])
  else Clamp.Cli_result.failure ~exit_class:Clamp.Exit_class.User_error ~code:"validation_failed" ~message:"Bundle validation failed." ~details:(`Assoc ["concepts",`Int validation.concepts;"reserved_documents",`Int validation.reserved;"diagnostics",diagnostics]) in
  emit_diagnostic options ~command:"validate"
    ~exit_class:(if not has_errors then Success else User_error);
  if options.json then print_endline(Clamp.Cli_result.to_json_string result)
  else if not options.quiet then
    if not has_errors then begin
      let warnings =
        List.filter (fun diagnostic -> not (Clamp.Diagnostic.is_error diagnostic))
          validation.diagnostics
      in
      let concept_noun = if validation.concepts = 1 then "concept" else "concepts" in
      if warnings = [] then
        Printf.printf "Bundle valid: %d %s.\n" validation.concepts concept_noun
      else begin
        Printf.printf "Bundle valid: %d %s (%d warning%s).\n"
          validation.concepts concept_noun (List.length warnings)
          (if List.length warnings = 1 then "" else "s");
        List.iter
          (fun diagnostic ->
            Printf.printf "warning: %s [%s]%s\n" diagnostic.Clamp.Diagnostic.path
              diagnostic.code
              (if diagnostic.field = "" then ""
               else " field=" ^ diagnostic.field))
          warnings
      end
    end else begin
      let count = List.length validation.diagnostics in
      Printf.eprintf "kb: validate: Bundle validation failed (%d diagnostic%s).\n"
        count (if count = 1 then "" else "s")
    end;
  Clamp.Cli_result.exit_code result

let run_validate options =
  match Clamp.Bundle.validate_checked options.repo_root with
  | Ok validation -> render_validation options validation
  | Error issue -> emit_local ~command:"validate" options (Error issue)

let placeholder_term command operands =
  Term.(const (fun _ options -> run_placeholder command options) $ operands $ common_options)

let no_operands = Term.const ()

let required_positional position docv doc =
  Arg.(required & pos position (some string) None & info [] ~docv ~doc)

let optional_positional position docv doc =
  Arg.(value & pos position (some string) None & info [] ~docv ~doc)

let leaf name doc command operands =
  Cmd.v (command_info name doc) (placeholder_term command operands)

let validate = Cmd.v (command_info "validate" "Validate the knowledge bundle.") Term.(const run_validate $ common_options)

let history_term =
  let include_deprecated =
    Arg.(value & flag & info [ "include-deprecated" ]
      ~doc:"Include deprecated concepts independently of other history classes.")
  and include_stale =
    Arg.(value & flag & info [ "include-stale" ]
      ~doc:"Include concepts stale on the Africa/Johannesburg date.")
  and include_closed_tasks =
    Arg.(value & flag & info [ "include-closed-tasks" ]
      ~doc:"Include done and cancelled tasks independently of other history classes.")
  in
  Term.(const (fun include_deprecated include_stale include_closed_tasks ->
      { Clamp.Retrieval.include_deprecated; include_stale; include_closed_tasks })
    $ include_deprecated $ include_stale $ include_closed_tasks)

let emit_retrieval_error ~command options (error : Clamp.Retrieval.error) =
  let exit_class = Clamp.Retrieval.exit_class error in
  let result = Clamp.Retrieval.cli_result error in
  emit_diagnostic options ~command ~exit_class;
  if options.json then print_endline (Clamp.Cli_result.to_json_string result)
  else if not options.quiet then Printf.eprintf "kb: %s\n" error.message;
  Clamp.Cli_result.exit_code result

let database_url () =
  match Sys.getenv_opt "KB_DATABASE_URL" with
  | Some url when url <> "" -> Ok url
  | _ ->
      Error { Clamp.Retrieval.kind = Validation; code = "database_url_missing";
              message = "KB_DATABASE_URL is required for retrieval." }

let search =
  let query = required_positional 0 "QUERY" "The semantic search query." in
  let verbose =
    Arg.(value & flag & info [ "v"; "verbose" ]
      ~doc:"Show every returned match with ranking score components.")
  in
  Cmd.v
    (command_info "search"
       "Search the fresh compatible index without fetching or recording access.")
    Term.(const (fun query history verbose options ->
      let result =
        Result.bind (database_url ()) (fun url ->
            Clamp.Retrieval.search ~repo:options.repo_root ~url ~query ~history)
      in
      match result with
      | Error error -> emit_retrieval_error ~command:"search" options error
      | Ok results ->
          let data = `Assoc [ ("results", `List (List.map Clamp.Retrieval.result_json results)) ] in
          let human = Clamp.Retrieval.human_results ~verbose results in
          emit ~human ~command:"search" options "search_complete" data)
      $ query $ history_term $ verbose $ common_options)

let get =
  let concept = required_positional 0 "CONCEPT-ID" "The concept identifier." in
  Cmd.v
    (command_info "get"
       "Return full indexed content and atomically record one successful access; non-JSON --quiet is rejected before retrieval.")
    Term.(const (fun id history options ->
      let result =
        if options.quiet && not options.json then
          Error
            { Clamp.Retrieval.kind = Validation;
              code = "get_quiet_requires_json";
              message = "kb get --quiet requires --json so full content is returned." }
        else
          Result.bind (database_url ()) (fun url ->
              Clamp.Retrieval.get ~repo:options.repo_root ~url ~id ~history)
      in
      match result with
      | Error error -> emit_retrieval_error ~command:"get" options error
      | Ok concept ->
          emit_diagnostic options ~command:"get" ~exit_class:Success;
          if options.json then print_endline (Clamp.Retrieval.concept_json concept)
          else print_string concept.document;
          0)
      $ concept $ history_term $ common_options)

let concept_mutation name doc =
  let concept =
    if name = "add" then
      optional_positional 0 "CONCEPT-ID"
        "The concept identifier; omit only for a journal document."
    else
      Term.(const Option.some $ required_positional 0 "CONCEPT-ID" "The concept identifier.")
  in
  Cmd.v (command_info name doc) Term.(const (run_mutation (name="add")) $ concept $ input_term $ authority_term $ common_options)

let task_leaf name doc =
  let concept = optional_positional 0 "CONCEPT-ID" "The task concept identifier." in
  leaf name doc ("task " ^ name) concept

let run_task_add input authority options =
  match
    Result.bind input (fun contents ->
        let claim, confirmed, _ = authority in
        Clamp.Local.add_task ~repo:options.repo_root ~contents ~claim ~confirmed)
  with
  | Error issue -> emit_local ~command:"task add" options (Error issue)
  | Ok id ->
      emit ~human:(Printf.sprintf "Task created: %s (knowledge/%s.md)" id id)
        ~command:"task add" options "task_added" (`Assoc [ ("id", `String id) ])

let task_add = Cmd.v (command_info "add" "Create a task concept with a timestamp-sortable, randomly entropic ULID; same-millisecond order is not guaranteed.") Term.(const run_task_add $ input_term $ authority_term $ common_options)
let task_list =
  let history=Arg.(value & flag & info ["history"] ~doc:"Include done and cancelled tasks.") in
  Cmd.v (command_info "list" "List tasks.") Term.(const(fun history options->
    match Clamp.Local.list_tasks options.repo_root with
    | Error issue -> emit_local ~command:"task list" options (Error issue)
    | Ok tasks ->
        let tasks=tasks |> List.filter(fun (t:Clamp.Local.task)->history||not(List.mem t.state ["done";"cancelled"])) |> List.sort Clamp.Local.compare_task in
        let items=List.map(fun (t:Clamp.Local.task)->`Assoc["id",`String t.id;"state",`String t.state;"priority",`String t.priority;"title",`String t.title]) tasks in
        let human=match tasks with []->"No tasks." | _->tasks |> List.map(fun (t:Clamp.Local.task)->Printf.sprintf "%s  %-9s %-6s %s" t.id t.state t.priority (Clamp.Local.markdown_label t.title)) |> String.concat "\n" in
        emit ~human ~command:"task list" options "tasks_listed" (`Assoc["tasks",`List items]))$history$common_options)

let simple_id ?human name code doc operation =
  let concept=required_positional 0 "CONCEPT-ID" "The concept identifier." in
  Cmd.v (command_info name doc) Term.(const(fun id options->
    let command = if Option.is_some human then "task " ^ name else name in
    match operation options.repo_root id with
    | Error issue -> emit_local ~command options (Error issue)
    | Ok id ->
        let data = `Assoc [ "id", `String id ] in
        let output =
          match human with
          | Some phrase -> Some (Printf.sprintf "Task %s: %s" phrase id)
          | None -> local_human command data
        in
        emit ?human:output ~command options code data)$concept$common_options)

let task =
  let done_command =
    let concept=required_positional 0 "CONCEPT-ID" "The task concept identifier." in
    let authority=Arg.(required & opt (some string) None & info ["closure-authority"] ~docv:"AUTHORITY" ~doc:"performed-and-verified, user-explicit, or confirmed.") in
    Cmd.v (command_info "done" "Complete a task.") Term.(const(fun id authority options ->
      if not (List.mem authority ["performed-and-verified";"user-explicit";"confirmed"]) then emit_local ~command:"task done" options (Error {Clamp.Local.code="invalid_closure_authority";message="A valid --closure-authority is required."})
      else match Clamp.Local.transition ~closure_authority:authority options.repo_root id "done" with
      | Error issue -> emit_local ~command:"task done" options (Error issue)
      | Ok id -> emit ~human:("Task completed: " ^ id) ~command:"task done" options "task_done" (`Assoc["id",`String id]))$concept$authority$common_options) in
  let commands =
    [
      task_add;
      task_list;
      simple_id ~human:"started" "start" "task_started" "Move a task to doing." (fun r id->Clamp.Local.transition r id "doing");
      simple_id ~human:"blocked" "block" "task_blocked" "Move a task to blocked." (fun r id->Clamp.Local.transition r id "blocked");
      done_command;
      simple_id ~human:"cancelled" "cancel" "task_cancelled" "Cancel a task." (fun r id->Clamp.Local.transition r id "cancelled");
    ]
  in
  Cmd.group (command_info "task" "Manage task concepts.") commands

let inferred_writes =
  let policy =
    required_positional 0 "POLICY" "Either confirm or auto_draft."
  in
  let intent=Arg.(value & flag & info ["direct-user-intent"] ~doc:"Assert this policy change was directly requested by the user.") in
  Cmd.v (command_info "inferred-writes" "Set the inferred-write policy.") Term.(const(fun policy intent options->if not intent then emit_local ~command:"config set inferred-writes" options (Error {Clamp.Local.code="direct_user_intent_required";message="--direct-user-intent is required."}) else emit_local ~command:"config set inferred-writes" options (Clamp.Local.set_policy options.repo_root policy |> Result.map(fun()->("config_updated",`Assoc["inferred_writes",`String policy]))))$policy$intent$common_options)

let config_set =
  Cmd.group (command_info "set" "Set a versioned configuration value.")
    [ inferred_writes ]

let config =
  Cmd.group (command_info "config" "Manage versioned Clamp configuration.")
    [ config_set ]

let emit_database options = function
  | Ok (report : Clamp.Database.migration_report) ->
      let strings values = `List (List.map (fun value -> `String value) values) in
      let human =
        if report.applied = [] then
          Printf.sprintf "Database schema is current (%d migrations)." report.ledger_count
        else
          Printf.sprintf "Applied %d database migration%s: %s"
            (List.length report.applied)
            (if List.length report.applied = 1 then "" else "s")
            (String.concat ", " report.applied)
      in
      emit ~human ~command:"database migrate" options "database_migrated"
        (`Assoc
          [ ("applied", strings report.applied);
            ("already_applied", strings report.already_applied);
            ("ledger_count", `Int report.ledger_count) ])
  | Error (failure : Clamp.Database.error) ->
      let exit_class = Clamp.Database.exit_class failure in
      let result =
        Clamp.Cli_result.failure ~exit_class ~code:failure.code
          ~message:failure.message ~details:(`Assoc [])
      in
      emit_diagnostic options ~command:"database migrate" ~exit_class;
      if options.json then print_endline (Clamp.Cli_result.to_json_string result)
      else if not options.quiet then Printf.eprintf "kb: %s\n" failure.message;
      Clamp.Cli_result.exit_code result

let database =
  let local_database =
    Arg.(value & opt (some string) None & info [ "local-database" ] ~docv:"NAME"
      ~doc:"Apply by identifier to the configured local PostgreSQL 15 main Unix-socket cluster. Ignores ambient libpq targets and never accepts a URL or service.")
  in
  let migrate =
    Cmd.v (command_info "migrate" "Apply checksum-verified ordered SQL migrations using the direct database connection.")
      Term.(const (fun local_database options ->
        let result =
          match local_database with
          | Some database -> Clamp.Database.migrate_local ~repo:options.repo_root ~database
          | None ->
              (match Sys.getenv_opt "KB_DATABASE_DIRECT_URL" with
              | Some url when url <> "" -> Clamp.Database.migrate_remote ~repo:options.repo_root ~url
              | _ -> Error { Clamp.Database.kind = Validation;
                             code = "database_direct_url_missing";
                             message = "KB_DATABASE_DIRECT_URL is required.";
                             finalization = Before_commit_dispatch })
        in
        emit_database options result) $ local_database $ common_options)
  in
  Cmd.group (command_info "database" "Maintain the Clamp database schema.") [ migrate ]

let emit_sync options = function
  | Ok (report : Clamp.Sync.report) ->
      let counts = report.counts in
      let diagnostics =
        `List (List.map Clamp.Diagnostic.json report.diagnostics)
      in
      let human =
        let summary =
          Printf.sprintf
            "Indexed origin/main at %s (added=%d, metadata-updated=%d, re-embedded=%d, unchanged=%d, deleted=%d)."
            report.commit counts.added counts.metadata_updated counts.reembedded
            counts.unchanged counts.deleted
        in
        if report.diagnostics = [] then summary
        else
          summary ^ "\n"
          ^ (report.diagnostics
             |> List.map Clamp.Diagnostic.human
             |> String.concat "\n")
      in
      emit ~human ~command:"sync" options (Clamp.Sync.completion_code report)
        (`Assoc
          [ ("commit", `String report.commit);
            ("rebuilt", `Bool report.rebuilt);
            ("diagnostics", diagnostics);
            ( "counts",
              `Assoc
                [ ("added", `Int counts.added);
                  ("metadata_updated", `Int counts.metadata_updated);
                  ("reembedded", `Int counts.reembedded);
                  ("unchanged", `Int counts.unchanged);
                  ("deleted", `Int counts.deleted) ] ) ])
  | Error (failure : Clamp.Sync.error) ->
      let exit_class = Clamp.Sync.exit_class failure in
      let result = Clamp.Sync.cli_result failure in
      emit_diagnostic options ~command:"sync" ~exit_class;
      if options.json then print_endline (Clamp.Cli_result.to_json_string result)
      else if not options.quiet then begin
        Printf.eprintf "kb: %s\n" failure.message;
        List.iter
          (fun diagnostic -> Printf.eprintf "%s\n" (Clamp.Diagnostic.human diagnostic))
          failure.diagnostics
      end;
      Clamp.Cli_result.exit_code result

let sync =
  let reembed =
    Arg.(value & flag & info [ "reembed" ]
      ~doc:"Regenerate every concept embedding even when semantic input is unchanged.")
  in
  let allow_mass_deletion =
    Arg.(value & flag & info [ "allow-mass-deletion" ]
      ~doc:"Explicitly approve an empty-tree or protected majority deletion.")
  in
  let target_commit =
    Arg.(value & opt (some string) None & info [ "commit" ] ~docv:"SHA"
      ~doc:"Require this exact commit to equal the freshly fetched origin/main tip.")
  in
  Cmd.v (command_info "sync"
    "Validate and synchronize the exact origin/main Git tree into the index.")
    Term.(const (fun reembed allow_mass_deletion target_commit options ->
      match Clamp.Sync.preflight_repository options.repo_root with
      | Error failure -> emit_sync options (Error failure)
      | Ok () ->
          (match Sys.getenv_opt "KB_DATABASE_DIRECT_URL" with
          | Some url when url <> "" ->
              Clamp.Sync.run ~repo:options.repo_root ~url ~reembed
                ~allow_mass_deletion ~target_commit
              |> emit_sync options
          | _ ->
              emit_sync options
                (Error
                   (Clamp.Sync.fallback_error
                      ~code:"database_direct_url_missing"
                      ~message:"KB_DATABASE_DIRECT_URL is required."))))
      $ reembed $ allow_mass_deletion $ target_commit $ common_options)

let publication_sync_json (report : Clamp.Sync.report) =
  let counts = report.counts in
  `Assoc
    [ ("code", `String (Clamp.Sync.completion_code report));
      ("commit", `String report.commit);
      ("rebuilt", `Bool report.rebuilt);
      ("diagnostics", `List (List.map Clamp.Diagnostic.json report.diagnostics));
      ( "counts",
        `Assoc
          [ ("added", `Int counts.added);
            ("metadata_updated", `Int counts.metadata_updated);
            ("reembedded", `Int counts.reembedded);
            ("unchanged", `Int counts.unchanged);
            ("deleted", `Int counts.deleted) ] ) ]

let emit_publication options = function
  | Ok (report : Clamp.Publication.report) ->
      let human =
        Printf.sprintf "Published and indexed origin/main at %s." report.commit
      in
      emit ~human ~command:"publish" options "publish_complete"
        (`Assoc
          [ ("commit", `String report.commit);
            ("sync", publication_sync_json report.sync) ])
  | Error (failure : Clamp.Publication.error) ->
      let exit_class = Clamp.Publication.exit_class failure in
      let result =
        Clamp.Cli_result.failure ~exit_class ~code:failure.code
          ~message:failure.message
          ~details:(Clamp.Publication.error_details failure)
      in
      emit_diagnostic options ~command:"publish" ~exit_class;
      if options.json then print_endline (Clamp.Cli_result.to_json_string result)
      else if not options.quiet then begin
        Printf.eprintf "kb: %s\n" failure.message;
        let label =
          match failure.kind with
          | Clamp.Publication.Conflict -> "conflict"
          | _ -> "path"
        in
        List.iter
          (fun path -> Printf.eprintf "%s: %s\n" label path)
          failure.paths
      end;
      Clamp.Cli_result.exit_code result

let publish =
  let thread_id =
    Arg.(required & opt (some string) None & info [ "thread-id" ] ~docv:"THREAD-ID"
      ~doc:"Required exact Amp thread ID from authenticated current-thread context, used only in durable conflict or recovery branch names; never infer it from environment state.")
  in
  let preserve_conflict =
    Arg.(value & flag & info [ "preserve-conflict" ]
      ~doc:"Abort an active genuine publication conflict and preserve the original commit on a conflicts branch.")
  in
  Cmd.v
    (command_info "publish"
       "Validate, commit, non-force rebase/push managed knowledge, and synchronize the exact pushed commit.")
    Term.(const (fun thread_id preserve_conflict options ->
      Clamp.Publication.run ~repo:options.repo_root ~thread_id
        ~preserve_conflict
      |> emit_publication options)
      $ thread_id $ preserve_conflict $ common_options)

let verify =
  let concept = required_positional 0 "CONCEPT-ID" "The concept identifier." in
  let authority =
    Arg.
      (value & opt (some string) None
      & info [ "verification-authority" ] ~docv:"AUTHORITY"
          ~doc:
            "Required: user-explicit. Assert only when the authenticated current user directly requested verification or confirmed the exact current concept content.")
  in
  Cmd.v
    (command_info "verify" "Record direct user verification of a concept.")
    Term.
      (const
         (fun id authority options ->
           emit_local ~command:"verify" options
             (Clamp.Local.verify ~authority options.repo_root id
             |> Result.map (fun id ->
                    ("concept_verified", `Assoc [ ("id", `String id) ]))))
      $ concept $ authority $ common_options)

let command =
  let doc = "Native CLI for the Clamp knowledge base." in
  let commands =
    [
      search;
      get;
      concept_mutation "add" "Create a concept.";
      concept_mutation "edit" "Edit a concept while preserving its stored lifecycle status.";
      verify;
      (let concept=required_positional 0 "CONCEPT-ID" "The concept identifier." in
       let replacement=Arg.(value & opt (some string) None & info ["superseded-by"] ~docv:"CONCEPT-ID") in
       Cmd.v (command_info "deprecate" "Deprecate a concept.") Term.(const(fun id replacement authority options->let claim,confirmed=authority in emit_local ~command:"deprecate" options (Clamp.Local.deprecate_checked ~claim ~confirmed options.repo_root id replacement |> Result.map(fun id->("concept_deprecated",`Assoc["id",`String id]))))$concept$replacement$deprecation_authority_term$common_options));
      task;
      Cmd.v (command_info "todo" "Render or regenerate the TODO view.") Term.(const(fun options->match Clamp.Local.todo options.repo_root with Error issue->emit_local ~command:"todo" options (Error issue) | Ok text->emit ~human:"TODO regenerated at TODO.md." ~command:"todo" options "todo_rendered" (`Assoc["content",`String text]))$common_options);
      validate;
      sync;
      publish;
      database;
      config;
    ]
  in
  Cmd.group (command_info "kb" ~version doc) commands

type fallback_selection = Top | Task | Database | Config_set | Config_leaf | Complete

type fallback_context = {
  fallback_options : common_options;
  fallback_command : string;
  missing_value : bool;
  normalized_argv : string array;
}

let inspect_fallback_argv argv =
  let length = Array.length argv in
  let common = Array.make length false in
  let json = ref false and quiet = ref false and diagnostic = ref false in
  let missing_value = ref false in
  let repo = ref "." and command = ref "kb" and selection = ref Top in
  let top_commands =
    [ "add"; "edit"; "verify"; "deprecate"; "todo"; "validate"; "task";
      "database"; "config"; "search"; "get"; "sync"; "publish" ]
  in
  let task_commands = [ "add"; "list"; "start"; "block"; "done"; "cancel" ] in
  let value_options =
    [ "--repo"; "--repo-root"; "--input"; "--claim"; "--superseded-by";
      "--closure-authority"; "--verification-authority"; "--local-database";
      "--commit"; "--thread-id" ]
  in
  let boolean_options =
    [ "--json"; "--quiet"; "-q"; "--diagnostic"; "--stdin";
      "--confirmed"; "--allow-unknown-type"; "--history";
      "--direct-user-intent"; "--reembed"; "--allow-mass-deletion";
      "--preserve-conflict";
      "--include-deprecated"; "--include-stale"; "--include-closed-tasks";
      "--verbose"; "-v" ]
  in
  let output_options = [ "--json"; "--quiet"; "-q"; "--diagnostic" ] in
  let attached_value argument =
    List.find_map
      (fun name ->
        let prefix = name ^ "=" in
        if String.starts_with ~prefix argument then
          Some (name, String.sub argument (String.length prefix)
                  (String.length argument - String.length prefix))
        else None)
      value_options
  in
  let select argument =
    match !selection with
    | Top ->
        if List.mem argument top_commands then begin
          command := argument;
          selection :=
            if argument = "task" then Task
            else if argument = "database" then Database
            else if argument = "config" then Config_set
            else Complete
        end
        else selection := Complete
    | Task ->
        if List.mem argument task_commands then command := "task " ^ argument;
        selection := Complete
    | Database ->
        if argument = "migrate" then command := "database migrate";
        selection := Complete
    | Config_set ->
        if argument = "set" then begin
          command := "config set";
          selection := Config_leaf
        end
        else selection := Complete
    | Config_leaf ->
        if argument = "inferred-writes" then
          command := "config set inferred-writes";
        selection := Complete
    | Complete -> ()
  in
  let rec scan index =
    if index >= length || argv.(index) = "--" then index
    else
      let argument = argv.(index) in
      if List.mem argument value_options then begin
        let is_repo = List.mem argument [ "--repo"; "--repo-root" ] in
        if is_repo then common.(index) <- true;
        if index + 1 < length && argv.(index + 1) <> "--"
           && not (List.mem argv.(index + 1) output_options)
        then begin
          if is_repo then begin
            common.(index + 1) <- true;
            if not (String.starts_with ~prefix:"-" argv.(index + 1)) then
              repo := argv.(index + 1)
          end;
          scan (index + 2)
        end
        else begin
          if index + 1 < length
             && List.mem argv.(index + 1) output_options
          then missing_value := true;
          scan (index + 1)
        end
      end
      else
        match attached_value argument with
        | Some (name, value) ->
            if List.mem name [ "--repo"; "--repo-root" ] then begin
              common.(index) <- true;
              if value <> "" && not (String.starts_with ~prefix:"-" value) then
                repo := value
            end;
            scan (index + 1)
        | None when List.mem argument boolean_options ->
            if List.mem argument output_options then common.(index) <- true;
            if argument = "--json" then json := true;
            if List.mem argument [ "--quiet"; "-q" ] then quiet := true;
            if argument = "--diagnostic" then diagnostic := true;
            scan (index + 1)
        | None when String.starts_with ~prefix:"-" argument ->
            if !selection <> Complete then selection := Complete;
            scan (index + 1)
        | None -> select argument; scan (index + 1)
  in
  let terminator = scan 1 in
  let regular = ref [] and common_arguments = ref [] in
  for index = 1 to terminator - 1 do
    if common.(index) then common_arguments := argv.(index) :: !common_arguments
    else regular := argv.(index) :: !regular
  done;
  let suffix =
    Array.sub argv terminator (length - terminator) |> Array.to_list
  in
  { fallback_options =
      { repo_root = !repo; json = !json; quiet = !quiet;
        diagnostic = !diagnostic };
    fallback_command = !command;
    missing_value = !missing_value;
    normalized_argv =
      Array.of_list
        (argv.(0)
         :: (List.rev !regular @ List.rev !common_arguments @ suffix)) }

let () =
  let context = inspect_fallback_argv Sys.argv in
  let fallback_options = context.fallback_options in
  let fallback_command = context.fallback_command in
  let normalized_argv = context.normalized_argv in
  let json = fallback_options.json and quiet = fallback_options.quiet in
  let sink = Buffer.create 256 |> Format.formatter_of_buffer in
  let status =
    match
      if Sys.getenv_opt "CLAMP_TEST_FORCE_CMDLINER_EXCEPTION" = Some "1" then
        Error `Exn
      else if context.missing_value then Error `Parse
      else Cmd.eval_value ~err:sink ~argv:normalized_argv command
    with
    | Ok (`Ok status) -> status
    | Ok (`Version | `Help) -> Clamp.Exit_class.code Success
    | Error (`Parse | `Term) ->
        emit_diagnostic fallback_options ~command:fallback_command
          ~exit_class:User_error;
        if json then
          Clamp.Cli_result.failure ~exit_class:User_error
            ~code:"invalid_arguments" ~message:"Invalid command arguments."
            ~details:(`Assoc [])
          |> Clamp.Cli_result.to_json_string |> print_endline;
        if (not json) && not quiet then
          prerr_endline "kb: Invalid command arguments.";
        Clamp.Exit_class.code User_error
    | Error `Exn ->
        emit_diagnostic fallback_options ~command:fallback_command
          ~exit_class:Internal;
        if json then
          Clamp.Cli_result.failure ~exit_class:Internal ~code:"internal_error"
            ~message:"An unexpected internal failure occurred."
            ~details:(`Assoc [])
          |> Clamp.Cli_result.to_json_string |> print_endline;
        if (not json) && not quiet then
          prerr_endline "kb: An unexpected internal failure occurred.";
        Clamp.Exit_class.code Internal
  in
  exit status
