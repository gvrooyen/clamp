Top-level metadata is available without executing product behavior.

  $ unset KB_DATABASE_URL KB_DATABASE_DIRECT_URL OPENROUTER_API_KEY
  $ repo="$PWD/fixture"; mkdir -p "$repo/knowledge"; cp -L ../../clamp.yaml "$repo/"; kb --repo "$repo" todo --quiet
  $ kb --version
  0.1.0

Retrieval commands fail safely before external access when credentials are absent.

  $ kb --repo "$repo" search --json "where is the roadmap?"
  {"ok":false,"code":"database_url_missing","message":"KB_DATABASE_URL is required for retrieval.","details":{"fallback":"local_markdown_or_rg","semantic_equivalent":false}}
  [2]
  $ kb --repo "$repo" search -v --json "where is the roadmap?"
  {"ok":false,"code":"database_url_missing","message":"KB_DATABASE_URL is required for retrieval.","details":{"fallback":"local_markdown_or_rg","semantic_equivalent":false}}
  [2]
  $ kb search --help=plain | grep -F -- '-v, --verbose'
         -v, --verbose
  $ kb verify --help=plain | grep -F -- '--verification-authority=AUTHORITY'
         --verification-authority=AUTHORITY
  $ kb --repo "$repo" get --json facts/example
  {"ok":false,"code":"database_url_missing","message":"KB_DATABASE_URL is required for retrieval.","details":{"fallback":"local_markdown_or_rg","semantic_equivalent":false}}
  [2]
  $ kb --repo "$repo" get --quiet facts/example
  [2]

The Phase 3 maintenance command has a stable credential-free failure contract
when its direct connection secret is absent.

  $ env -u KB_DATABASE_DIRECT_URL kb database migrate --json
  {"ok":false,"code":"database_direct_url_missing","message":"KB_DATABASE_DIRECT_URL is required.","details":{}}
  [2]
  $ kb task done --json tasks/01TEST
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb --repo "$repo" --json validate
  {"ok":true,"code":"bundle_valid","data":{"concepts":0,"reserved_documents":0,"diagnostics":[]}}

Phase 1 validates a representative bundle without credentials or services, and
the JSON result is byte-for-byte deterministic.

  $ valid="$PWD/valid"; mkdir -p "$valid"; cp -LR ../fixtures/phase1-valid/. "$valid/"
  $ kb --repo "$valid" --json validate | tee first.json
  {"ok":true,"code":"bundle_valid","data":{"concepts":4,"reserved_documents":1,"diagnostics":[]}}
  $ kb --repo "$valid" --json validate >second.json
  $ cmp first.json second.json
  $ invalid="$PWD/invalid"; mkdir -p "$invalid/knowledge"; cp -L ../../clamp.yaml "$invalid/"; kb --repo "$invalid" todo --quiet; printf '%s\n' '---' 'type: fact' >"$invalid/knowledge/bad.md"
  $ kb --repo "$invalid" --json validate
  {"ok":false,"code":"validation_failed","message":"Bundle validation failed.","details":{"concepts":1,"reserved_documents":0,"diagnostics":[{"severity":"error","path":"knowledge/bad.md","code":"frontmatter_invalid","field":"","message":"frontmatter is malformed or unsupported"}]}}
  [2]
  $ kb --repo "$invalid" validate 2>&1
  kb: validate: Bundle validation failed (1 diagnostic).
  [2]
  $ warning="$PWD/warning"; mkdir -p "$warning/knowledge"; cp -L ../../clamp.yaml "$warning/"; kb --repo "$warning" todo --quiet; printf '%s\n' '---' 'type: future-type' 'clamp: {asserted_by: human:x}' '---' 'Visible body.' >"$warning/knowledge/future.md"
  $ kb --repo "$warning" --json validate
  {"ok":true,"code":"bundle_valid_with_warnings","data":{"concepts":1,"reserved_documents":0,"diagnostics":[{"severity":"warning","path":"knowledge/future.md","code":"unknown_type","field":"type","message":"unknown non-empty OKF type"}]}}
  $ kb --repo "$warning" validate
  Bundle valid: 1 concept (1 warning).
  warning: knowledge/future.md [unknown_type] field=type
  $ kb --repo "$warning" --quiet validate
  $ single="$PWD/single"; mkdir -p "$single/knowledge"; cp -L ../../clamp.yaml "$single/"; kb --repo "$single" todo --quiet; printf '%s\n' '---' 'type: fact' 'clamp: {asserted_by: human:x}' '---' 'One.' >"$single/knowledge/one.md"
  $ kb --repo "$single" validate
  Bundle valid: 1 concept.
  $ warning_limit="$PWD/warning-limit"; mkdir -p "$warning_limit/knowledge"; cp -L ../../clamp.yaml "$warning_limit/"; kb --repo "$warning_limit" todo --quiet
  $ for i in $(seq -w 1 1000); do printf '%s\n' '---' 'type: future-type' 'clamp: {asserted_by: human:x}' '---' 'Visible body.' >"$warning_limit/knowledge/future-$i.md"; done
  $ kb --repo "$warning_limit" --json validate >warning-limit.json; echo $?
  0
  $ sed -n 's/^{"ok":true,"code":"\([^"]*\)".*/\1/p' warning-limit.json
  bundle_valid_with_warnings
  $ grep -o '"severity":"warning"' warning-limit.json | wc -l
  1000
  $ grep -q 'diagnostic_limit' warning-limit.json; echo $?
  1
  $ cp "$invalid/knowledge/bad.md" "$warning/knowledge/bad.md"
  $ kb --repo "$warning" --json validate
  {"ok":false,"code":"validation_failed","message":"Bundle validation failed.","details":{"concepts":2,"reserved_documents":0,"diagnostics":[{"severity":"error","path":"knowledge/bad.md","code":"frontmatter_invalid","field":"","message":"frontmatter is malformed or unsupported"},{"severity":"warning","path":"knowledge/future.md","code":"unknown_type","field":"type","message":"unknown non-empty OKF type"}]}}
  [2]
  $ kb --repo "$warning" validate 2>&1
  kb: validate: Bundle validation failed (2 diagnostics).
  [2]

Changing inferred-write policy requires explicit direct-user intent.

  $ kb config set inferred-writes --json confirm
  {"ok":false,"code":"direct_user_intent_required","message":"--direct-user-intent is required.","details":{}}
  [2]

Every PRD command leaf is wired to its current implementation contract.

  $ check_leaf() { label="$1"; shift; output="$(kb "$@" --json)"; status="$?"; code="$(printf '%s\n' "$output" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')"; printf '%s: status=%s code=%s\n' "$label" "$status" "$code"; }
  $ check_leaf search --repo "$repo" search query
  search: status=2 code=database_url_missing
  $ check_leaf get --repo "$repo" get facts/example
  get: status=2 code=database_url_missing
  $ check_leaf add add
  add: status=2 code=invalid_arguments
  $ check_leaf edit edit facts/example
  edit: status=2 code=invalid_arguments
  $ check_leaf verify verify facts/example
  verify: status=2 code=verification_authority_required
  $ check_leaf deprecate deprecate facts/example
  deprecate: status=2 code=invalid_arguments
  $ check_leaf task-add task add
  task-add: status=2 code=invalid_arguments
  $ check_leaf task-list task list
  task-list: status=0 code=tasks_listed
  $ check_leaf task-start task start tasks/example
  task-start: status=2 code=file_not_found
  $ check_leaf task-block task block tasks/example
  task-block: status=2 code=file_not_found
  $ check_leaf task-done task done tasks/example
  task-done: status=2 code=invalid_arguments
  $ check_leaf task-cancel task cancel tasks/example
  task-cancel: status=2 code=file_not_found
  $ check_leaf todo todo
  todo: status=0 code=todo_rendered
  $ check_leaf validate validate --repo "$repo"
  validate: status=0 code=bundle_valid
  $ check_leaf sync sync
  sync: status=2 code=source_repository_missing
  $ check_leaf publish publish
  publish: status=2 code=invalid_arguments
  $ kb publish 2>&1
  kb: Invalid command arguments.
  [2]
  $ kb publish --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb publish --thread-id T-00000000-0000-0000-0000-000000000007 --force --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb publish --help=plain | grep -E -- '--thread-id|--preserve-conflict'
         --preserve-conflict
         --thread-id=THREAD-ID (required)
  $ check_leaf config-policy config set inferred-writes confirm
  config-policy: status=2 code=direct_user_intent_required

Common options work through aliases and nested command positions.

  $ kb --repo /tmp task done tasks/example --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb task --repo-root=/tmp list --json
  {"ok":false,"code":"repository_changed","message":"Repository root changed during the operation.","details":{}}
  [70]

Quiet mode suppresses human output but preserves the stable exit class.

  $ kb validate --repo "$repo" --quiet

Invalid invocations use the user-error exit class and a JSON envelope rather
than Cmdliner-specific exit codes or prose.

  $ kb search --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]

Phase 2 accepts complete Markdown documents from files and stdin without
shell-quoting their bodies, while authority remains separate CLI input.

  $ phase2="$PWD/phase2"; mkdir -p "$phase2/knowledge"; cp -L ../../clamp.yaml "$phase2/"; kb --repo "$phase2" todo --quiet
  $ cat >fact.md <<'EOF'
  > ---
  > type: fact
  > title: Structured body
  > clamp: {asserted_by: ignored/caller-value}
  > ---
  > Markdown with `code`, "quotes", and a $dollar.
  > EOF
  $ kb --repo "$phase2" add facts/structured --input fact.md --claim explicit --json
  {"ok":true,"code":"concept_added","data":{"id":"facts/structured"}}
  $ sed 's/Structured body/Structured body edited/' fact.md | kb --repo "$phase2" edit facts/structured --stdin --claim explicit --json
  {"ok":true,"code":"concept_edited","data":{"id":"facts/structured"}}
  $ cp "$phase2/knowledge/facts/structured.md" structured.before-verification
  $ kb --repo "$phase2" verify facts/structured --json
  {"ok":false,"code":"verification_authority_required","message":"--verification-authority user-explicit is required.","details":{}}
  [2]
  $ cmp structured.before-verification "$phase2/knowledge/facts/structured.md"
  $ kb --repo "$phase2" verify facts/structured --verification-authority agent-reviewed --json
  {"ok":false,"code":"invalid_verification_authority","message":"--verification-authority must be user-explicit.","details":{}}
  [2]
  $ cmp structured.before-verification "$phase2/knowledge/facts/structured.md"
  $ kb --repo "$phase2" verify facts/structured --verification-authority user-explicit --json
  {"ok":true,"code":"concept_verified","data":{"id":"facts/structured"}}
  $ kb --repo "$phase2" add facts/human-output --input fact.md --claim explicit
  Concept added: facts/human-output (knowledge/facts/human-output.md).
  $ kb --repo "$phase2" edit facts/human-output --input fact.md --claim explicit
  Concept updated: facts/human-output (knowledge/facts/human-output.md).
  $ kb --repo "$phase2" verify facts/human-output --verification-authority user-explicit
  Concept verified: facts/human-output.
  $ kb --repo "$phase2" deprecate facts/human-output --claim explicit
  Concept deprecated: facts/human-output.
  $ kb --repo "$phase2" config set inferred-writes confirm --direct-user-intent
  Inference policy set to confirm.
  $ cat >journal.md <<'EOF'
  > ---
  > type: journal
  > title: Daily output
  > clamp: {asserted_by: human:owner}
  > ---
  > Journal output.
  > EOF
  $ kb --repo "$phase2" add --input journal.md --claim explicit | sed -E 's#journal/[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}#journal/YYYY/YYYY-MM-DD#g'
  Concept added: journal/YYYY/YYYY-MM-DD (knowledge/journal/YYYY/YYYY-MM-DD.md).
  $ kb --repo "$phase2" add --input journal.md --claim explicit | sed -E 's#journal/[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}#journal/YYYY/YYYY-MM-DD#g'
  Concept updated: journal/YYYY/YYYY-MM-DD (knowledge/journal/YYYY/YYYY-MM-DD.md).
  $ journal_json="$PWD/journal-json"; mkdir -p "$journal_json/knowledge"; cp -L ../../clamp.yaml "$journal_json/"; kb --repo "$journal_json" todo --quiet
  $ kb --repo "$journal_json" add --input journal.md --claim explicit --json | sed -E 's#journal/[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}#journal/YYYY/YYYY-MM-DD#g'
  {"ok":true,"code":"concept_added","data":{"id":"journal/YYYY/YYYY-MM-DD"}}
  $ kb --repo "$journal_json" add --input journal.md --claim explicit --json | sed -E 's#journal/[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}#journal/YYYY/YYYY-MM-DD#g'
  {"ok":true,"code":"concept_added","data":{"id":"journal/YYYY/YYYY-MM-DD"}}
  $ kb --repo phase2 add facts/diagnostic --input fact.md --claim explicit --diagnostic --json 2>&1
  {"ok":true,"code":"concept_added","data":{"id":"facts/diagnostic"}}
  kb: diagnostic: command=add exit_class=success status=0 repo=phase2
  $ kb --repo phase2 add facts/diagnostic-failed --input fact.md --claim inferred --diagnostic --json 2>&1
  {"ok":false,"code":"confirmation_required","message":"Inferred writes require confirmation.","details":{}}
  kb: diagnostic: command=add exit_class=user_error status=2 repo=phase2
  [2]
  $ kb --repo "$phase2" add facts/diagnostic-quiet --input fact.md --claim explicit --diagnostic --quiet --json 2>diagnostic-quiet.err
  {"ok":true,"code":"concept_added","data":{"id":"facts/diagnostic-quiet"}}
  $ test ! -s diagnostic-quiet.err
  $ kb --repo phase2 task list --diagnostic --json 2>&1
  {"ok":true,"code":"tasks_listed","data":{"tasks":[]}}
  kb: diagnostic: command=task list exit_class=success status=0 repo=phase2
  $ kb task list --repo 'postgresql://alice:hunter2@db.example/clamp' --diagnostic 2>&1
  kb: diagnostic: command=task list exit_class=user_error status=2 repo=postgresql://[REDACTED]@db.example/clamp
  kb: Repository root is unreadable or unsafe.
  [2]

Cmdliner parse, term, and exception fallbacks use the same single redacted
diagnostic without changing the JSON stdout envelope.

  $ kb --diagnostic --json --not-a-kb-option 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=kb exit_class=user_error status=2 repo=.
  [2]
  $ kb task list --json --not-a-task-option --repo 'postgresql://alice:hunter2@db.example/clamp' --diagnostic 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task list exit_class=user_error status=2 repo=postgresql://[REDACTED]@db.example/clamp
  [2]
  $ kb --diagnostic --json task list --not-a-task-option 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task list exit_class=user_error status=2 repo=.
  [2]
  $ kb task add --input --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb task add --input --diagnostic --json 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task add exit_class=user_error status=2 repo=.
  [2]
  $ kb task list --not-a-task-option --diagnostic --quiet --json 2>fallback-quiet.err
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test ! -s fallback-quiet.err
  $ CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task list --diagnostic --json 2>&1
  {"ok":false,"code":"internal_error","message":"An unexpected internal failure occurred.","details":{}}
  kb: diagnostic: command=task list exit_class=internal status=70 repo=.
  [70]
  $ kb task add --input 'SENTINEL-postgresql://alice:hunter2@db.example/body' --diagnostic --json 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task add exit_class=user_error status=2 repo=.
  [2]
  $ kb task add --input --quiet --diagnostic --json 2>missing-input-quiet.err
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test ! -s missing-input-quiet.err
  $ kb --repo --quiet --diagnostic --json task list 2>missing-repo-quiet.err
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test ! -s missing-repo-quiet.err
  $ kb task list --repo-root -q --diagnostic --json 2>missing-repo-root-quiet.err
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test ! -s missing-repo-root-quiet.err
  $ kb task add --input fact.md --claim --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb deprecate facts/missing --claim explicit --superseded-by --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb task done tasks/missing --closure-authority --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb --json task add --input
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ for option in --input --repo --repo-root --claim --superseded-by --closure-authority --thread-id; do kb task add "$option" --json >missing-value.json 2>missing-value.err; test $? = 2 || exit 1; grep -q '"code":"invalid_arguments"' missing-value.json || exit 1; test ! -s missing-value.err || exit 1; done
  $ for option in --input --repo --repo-root --claim --superseded-by --closure-authority --thread-id; do kb task add "$option" --diagnostic --json >missing-value.json 2>missing-value.err; test $? = 2 || exit 1; grep -q '"code":"invalid_arguments"' missing-value.json || exit 1; test "$(grep -c '^kb: diagnostic:' missing-value.err)" = 1 || exit 1; done
  $ for quiet in --quiet -q; do for option in --input --repo --repo-root --claim --superseded-by --closure-authority --thread-id; do kb task add "$option" "$quiet" --diagnostic --json >missing-value.json 2>missing-value.err; test $? = 2 || exit 1; grep -q '"code":"invalid_arguments"' missing-value.json || exit 1; test ! -s missing-value.err || exit 1; done; done
  $ cat >task-rebind.md <<'EOF'
  > ---
  > type: task
  > title: Rebind guard task
  > clamp:
  >   asserted_by: human:owner
  >   task: {state: todo, priority: high}
  > ---
  > Guard task.
  > EOF
  $ rebind="$PWD/rebind"; mkdir -p "$rebind/knowledge"; cp -L ../../clamp.yaml "$rebind/"; kb --repo "$rebind" todo --quiet
  $ kb --repo "$rebind" add facts/source --input fact.md --claim explicit --quiet
  $ kb --repo "$rebind" add facts/replacement --input fact.md --claim explicit --quiet
  $ rebind_task_id=$(kb --repo "$rebind" task add --input task-rebind.md --claim explicit --json | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'); test -n "$rebind_task_id"
  $ cat >missing-value-rebind.sh <<'EOF'
  > phase2=$1
  > task_id=$2
  > snapshot() { find "$phase2" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum; }
  > before=$(snapshot)
  > n=0
  > for output in --json --quiet -q --diagnostic; do
  >   for option in --input --repo --repo-root --claim --superseded-by --closure-authority; do
  >     n=$((n + 1)); out=missing-rebind.out; err=missing-rebind.err
  >     case $option in
  >       --input) kb --repo "$phase2" add "facts/rebind-$n" --input "$output" fact.md --claim explicit >"$out" 2>"$err" ;;
  >       --repo|--repo-root) kb task list "$option" "$output" "$phase2" >"$out" 2>"$err" ;;
  >       --claim) kb --repo "$phase2" add "facts/rebind-$n" --input fact.md --claim "$output" explicit >"$out" 2>"$err" ;;
  >       --superseded-by) kb --repo "$phase2" deprecate facts/source --claim explicit --superseded-by "$output" facts/replacement >"$out" 2>"$err" ;;
  >       --closure-authority) kb --repo "$phase2" task done "$task_id" --closure-authority "$output" performed-and-verified >"$out" 2>"$err" ;;
  >     esac
  >     test $? = 2 || exit 1
  >     case $output in
  >       --json) grep -q '"code":"invalid_arguments"' "$out" && test ! -s "$err" || exit 1 ;;
  >       --quiet|-q) test ! -s "$out" && test ! -s "$err" || exit 1 ;;
  >       --diagnostic) test ! -s "$out" && test "$(grep -c '^kb: diagnostic:' "$err")" = 1 && grep -q 'kb: Invalid command arguments.' "$err" || exit 1 ;;
  >     esac
  >   done
  > done
  > test "$before" = "$(snapshot)"
  > EOF
  $ sh missing-value-rebind.sh "$rebind" "$rebind_task_id"
  $ before_edit=$(sha256sum "$rebind/knowledge/facts/source.md")
  $ kb --repo "$rebind" edit facts/source --input --json fact.md --claim explicit
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test "$before_edit" = "$(sha256sum "$rebind/knowledge/facts/source.md")"
  $ kb --repo="$phase2" add facts/attached-values --input=fact.md --claim=explicit --json
  {"ok":true,"code":"concept_added","data":{"id":"facts/attached-values"}}
  $ kb --repo --diagnostic --json 'SENTINEL-postgresql://alice:hunter2@db.example/body' 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=kb exit_class=user_error status=2 repo=.
  [2]
  $ kb task mystery --diagnostic --json 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task exit_class=user_error status=2 repo=.
  [2]
  $ kb mystery task list --diagnostic --json 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=kb exit_class=user_error status=2 repo=.
  [2]
  $ kb task list -- --diagnostic --json 2>&1
  kb: Invalid command arguments.
  [2]
  $ kb task add --input -- --diagnostic --json 2>&1
  kb: Invalid command arguments.
  [2]
  $ kb task add --input SENTINEL --quiet --diagnostic --json 2>lexical-quiet.err
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ test ! -s lexical-quiet.err
  $ CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task add --claim task --diagnostic --json 2>&1
  {"ok":false,"code":"internal_error","message":"An unexpected internal failure occurred.","details":{}}
  kb: diagnostic: command=task add exit_class=internal status=70 repo=.
  [70]
  $ CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb --input task --diagnostic --json 2>&1
  {"ok":false,"code":"internal_error","message":"An unexpected internal failure occurred.","details":{}}
  kb: diagnostic: command=kb exit_class=internal status=70 repo=.
  [70]
  $ CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task add --input --diagnostic --json 2>&1
  {"ok":false,"code":"internal_error","message":"An unexpected internal failure occurred.","details":{}}
  kb: diagnostic: command=task add exit_class=internal status=70 repo=.
  [70]
  $ CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task add --input --quiet --diagnostic --json 2>exception-quiet.err
  {"ok":false,"code":"internal_error","message":"An unexpected internal failure occurred.","details":{}}
  [70]
  $ test ! -s exception-quiet.err
  $ for option in --input --repo --repo-root --claim --superseded-by --closure-authority; do CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task add "$option" --json >missing-value.json 2>missing-value.err; test $? = 70 || exit 1; grep -q '"code":"internal_error"' missing-value.json || exit 1; test ! -s missing-value.err || exit 1; done
  $ for quiet in --quiet -q; do for option in --input --repo --repo-root --claim --superseded-by --closure-authority; do CLAMP_TEST_FORCE_CMDLINER_EXCEPTION=1 kb task add "$option" "$quiet" --diagnostic --json >missing-value.json 2>missing-value.err; test $? = 70 || exit 1; grep -q '"code":"internal_error"' missing-value.json || exit 1; test ! -s missing-value.err || exit 1; done; done
  $ kb task add --input --not-a-global-output-flag --diagnostic --json 2>&1
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  kb: diagnostic: command=task add exit_class=user_error status=2 repo=.
  [2]
  $ kb --repo "$phase2" task list --diagnostic --quiet --json 2>task-diagnostic-quiet.err
  {"ok":true,"code":"tasks_listed","data":{"tasks":[]}}
  $ test ! -s task-diagnostic-quiet.err
  $ kb --repo "$phase2" add facts/rejected --input fact.md --claim inferred --json
  {"ok":false,"code":"confirmation_required","message":"Inferred writes require confirmation.","details":{}}
  [2]
  $ head -c 8388609 /dev/zero | kb --repo "$phase2" add facts/too-large --stdin --claim explicit --json
  {"ok":false,"code":"file_size_limit","message":"Input exceeds the 8 MiB safety limit.","details":{}}
  [2]
  $ kb --repo "$phase2" config set inferred-writes auto_draft --direct-user-intent --json
  {"ok":true,"code":"config_updated","data":{"inferred_writes":"auto_draft"}}
  $ sed '/^clamp:/i status: deprecated' fact.md >status-deprecated.md
  $ sed '/^clamp:/i status: draft' fact.md >status-draft.md
  $ sed '/^clamp:/i status: stable' fact.md >status-stable.md
  $ kb --repo "$phase2" add facts/status-explicit --input status-deprecated.md --claim explicit --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "stable"
  $ kb --repo "$phase2" add facts/status-confirmed --input status-draft.md --claim inferred --confirmed --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-confirmed.md"
  "status": "stable"
  $ kb --repo "$phase2" add facts/status-auto --input status-deprecated.md --claim inferred --quiet
  $ grep -F '"status": "draft"' "$phase2/knowledge/facts/status-auto.md"
  "status": "draft"
  $ kb --repo "$phase2" edit facts/status-explicit --input status-deprecated.md --claim explicit --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "stable"
  $ verification_events() { awk 'seen && /^"[^"]+":/ { exit } /^"verified":$/ { seen=1 } seen { print }' "$1"; }
  $ kb --repo "$phase2" verify facts/status-explicit --verification-authority user-explicit --quiet
  $ verification_events "$phase2/knowledge/facts/status-explicit.md" >status-format.before
  $ sed 's/^Markdown/  Markdown  /' status-deprecated.md >status-format.md
  $ kb --repo "$phase2" edit facts/status-explicit --input status-format.md --claim inferred --confirmed --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "stable"
  $ verification_events "$phase2/knowledge/facts/status-explicit.md" >status-format.after
  $ cmp status-format.before status-format.after
  $ sed 's/Structured body/Changed stable claim/' status-draft.md >status-semantic.md
  $ kb --repo "$phase2" edit facts/status-explicit --input status-semantic.md --claim inferred --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "stable"
  $ grep -q '^"verified":' "$phase2/knowledge/facts/status-explicit.md"; echo $?
  1
  $ kb --repo "$phase2" verify facts/status-auto --verification-authority user-explicit --quiet
  $ kb --repo "$phase2" edit facts/status-auto --input status-stable.md --claim inferred --quiet
  $ grep -F '"status": "draft"' "$phase2/knowledge/facts/status-auto.md"
  "status": "draft"
  $ kb --repo "$phase2" deprecate facts/status-explicit --claim explicit --quiet
  $ kb --repo "$phase2" edit facts/status-explicit --input status-stable.md --claim explicit --quiet
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "deprecated"
  $ kb --repo "$phase2" verify facts/status-explicit --verification-authority user-explicit --quiet
  $ sed 's/Structured body/Changed deprecated claim/' status-draft.md >status-deprecated-semantic.md
  $ kb --repo "$phase2" edit facts/status-explicit --input status-deprecated-semantic.md --claim inferred --quiet
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/status-explicit.md"
  "status": "deprecated"
  $ grep -q '^"verified":' "$phase2/knowledge/facts/status-explicit.md"; echo $?
  1
  $ sed 's/Structured body/Confirmed edit/' status-deprecated.md >status-confirmed-edit.md
  $ kb --repo "$phase2" edit facts/status-confirmed --input status-confirmed-edit.md --claim inferred --confirmed --quiet
  $ grep -F '"status": "stable"' "$phase2/knowledge/facts/status-confirmed.md"
  "status": "stable"
  $ grep -q '^"verified":' "$phase2/knowledge/facts/status-confirmed.md"; echo $?
  0
  $ sed 's/Markdown with.*/See [target](facts\/one)./' status-stable.md >status-link.md
  $ kb --repo "$phase2" add facts/status-link --input status-link.md --claim explicit --quiet
  $ kb --repo "$phase2" deprecate facts/status-link --claim explicit --quiet
  $ kb --repo "$phase2" verify facts/status-link --verification-authority user-explicit --quiet
  $ verification_events "$phase2/knowledge/facts/status-link.md" >status-link.before
  $ sed 's#facts/one#facts/two#; s/status: stable/status: draft/' status-link.md >status-link-edited.md
  $ kb --repo "$phase2" edit facts/status-link --input status-link-edited.md --claim inferred --confirmed --quiet
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/status-link.md"
  "status": "deprecated"
  $ verification_events "$phase2/knowledge/facts/status-link.md" >status-link.after
  $ cmp status-link.before status-link.after
  $ for id in status-only relation target invalid-relation inferred-relation; do kb --repo "$phase2" add "facts/$id" --input fact.md --claim explicit --quiet; done
  $ for id in status-only relation invalid-relation inferred-relation; do kb --repo "$phase2" verify "facts/$id" --verification-authority user-explicit --quiet; done
  $ verification_events "$phase2/knowledge/facts/status-only.md" >status-verification.before
  $ kb --repo "$phase2" deprecate facts/status-only --claim explicit --json
  {"ok":true,"code":"concept_deprecated","data":{"id":"facts/status-only"}}
  $ verification_events "$phase2/knowledge/facts/status-only.md" >status-verification.after
  $ cmp status-verification.before status-verification.after
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/status-only.md"
  "status": "deprecated"
  $ cp "$phase2/knowledge/facts/status-only.md" status-only.idempotent
  $ kb --repo "$phase2" deprecate facts/status-only --claim inferred --quiet
  $ cmp status-only.idempotent "$phase2/knowledge/facts/status-only.md"
  $ kb --repo "$phase2" deprecate facts/relation --superseded-by facts/target --claim explicit --json
  {"ok":true,"code":"concept_deprecated","data":{"id":"facts/relation"}}
  $ grep -q '^"verified":' "$phase2/knowledge/facts/relation.md"; echo $?
  1
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/relation.md"
  "status": "deprecated"
  $ grep -F '  "superseded_by": "facts/target"' "$phase2/knowledge/facts/relation.md"
    "superseded_by": "facts/target"
  $ grep -F '  "asserted_by": "human:owner"' "$phase2/knowledge/facts/relation.md"
    "asserted_by": "human:owner"
  $ grep -F '  "by": "amp/agent"' "$phase2/knowledge/facts/relation.md"
    "by": "amp/agent"
  $ cp "$phase2/knowledge/facts/relation.md" relation.idempotent
  $ kb --repo "$phase2" deprecate facts/relation --claim inferred --json
  {"ok":true,"code":"concept_deprecated","data":{"id":"facts/relation"}}
  $ cmp relation.idempotent "$phase2/knowledge/facts/relation.md"
  $ grep -F '  "superseded_by": "facts/target"' "$phase2/knowledge/facts/relation.md"
    "superseded_by": "facts/target"
  $ cp "$phase2/knowledge/facts/inferred-relation.md" inferred-relation.before
  $ kb --repo "$phase2" config set inferred-writes confirm --direct-user-intent --quiet
  $ kb --repo "$phase2" add facts/cross-origin --input fact.md --claim inferred --confirmed --quiet
  $ verification_events "$phase2/knowledge/facts/cross-origin.md" >cross-origin-verification.before
  $ grep -F '  "asserted_by": "amp/agent"' "$phase2/knowledge/facts/cross-origin.md" >cross-origin-origin.before
  $ kb --repo "$phase2" deprecate facts/cross-origin --claim explicit --quiet
  $ verification_events "$phase2/knowledge/facts/cross-origin.md" >cross-origin-verification.after
  $ grep -F '  "asserted_by": "amp/agent"' "$phase2/knowledge/facts/cross-origin.md" >cross-origin-origin.after
  $ cmp cross-origin-verification.before cross-origin-verification.after
  $ cmp cross-origin-origin.before cross-origin-origin.after
  $ grep -F '"status": "deprecated"' "$phase2/knowledge/facts/cross-origin.md"
  "status": "deprecated"
  $ kb --repo "$phase2" deprecate facts/inferred-relation --superseded-by facts/target --claim inferred --json
  {"ok":false,"code":"confirmation_required","message":"Inferred writes require confirmation.","details":{}}
  [2]
  $ cmp inferred-relation.before "$phase2/knowledge/facts/inferred-relation.md"
  $ kb --repo "$phase2" deprecate facts/inferred-relation --superseded-by facts/target --claim inferred --confirmed --json
  {"ok":true,"code":"concept_deprecated","data":{"id":"facts/inferred-relation"}}
  $ grep -q '^"verified":' "$phase2/knowledge/facts/inferred-relation.md"; echo $?
  0
  $ cp "$phase2/knowledge/facts/invalid-relation.md" invalid-relation.before
  $ kb --repo "$phase2" deprecate facts/invalid-relation --superseded-by facts/missing --claim explicit --json
  {"ok":false,"code":"superseded_by_unresolved","message":"The replacement concept does not exist.","details":{}}
  [2]
  $ cmp invalid-relation.before "$phase2/knowledge/facts/invalid-relation.md"
  $ locked="$PWD/locked"; mkdir -p "$locked/knowledge"; cp -L ../../clamp.yaml "$locked/"; ln -s nowhere "$locked/.clamp.lock"
  $ kb --repo "$locked" todo --json
  {"ok":true,"code":"todo_rendered","data":{"content":"<!-- GENERATED by kb todo; DO NOT EDIT. -->\n# TODO\n\n## Doing\n\n_None._\n\n## Blocked\n\n_None._\n\n## Todo\n\n_None._\n"}}
  $ ownership="$PWD/ownership"; mkdir -p "$ownership/knowledge/facts"; cp -L ../../clamp.yaml "$ownership/"
  $ printf '%s\n' '---' 'type: fact' 'title: Ownership race' 'clamp: {}' '---' >large-fact.md; head -c 4000000 /dev/zero | tr '\000' x >>large-fact.md; printf '\n' >>large-fact.md
  $ (while ! find "$ownership/.clamp/transactions" -type f -name 'file-*' -print -quit 2>/dev/null | grep . >/dev/null; do :; done; printf 'foreign target\n' >"$ownership/knowledge/facts/race.md") & watcher=$!
  $ kb --repo "$ownership" add facts/race --input large-fact.md --claim explicit --json; status=$?; wait "$watcher"; (exit "$status")
  {"ok":false,"code":"rollback_state_uncertain","message":"Could not verify local state after a failed mutation.","details":{}}
  [70]
  $ cat "$ownership/knowledge/facts/race.md"
  foreign target
  $ human="$PWD/human"; mkdir -p "$human/knowledge"; cp -L ../../clamp.yaml "$human/"; kb --repo "$human" todo --quiet
  $ kb --repo "$human" task list
  No tasks.
  $ kb --repo "$human" todo
  TODO regenerated at TODO.md.
  $ cat >task.md <<'EOF'
  > ---
  > type: task
  > title: CLI task
  > clamp:
  >   asserted_by: ignored/caller-value
  >   task:
  >     state: todo
  >     priority: high
  > ---
  > A body that needs no shell quoting.
  > EOF
  $ kb --repo "$human" task add --input task.md --claim explicit 2>/dev/null | sed -E 's/tasks\/[A-Z0-9]{26}-cli-task/tasks\/<ID>-cli-task/g'
  Task created: tasks/<ID>-cli-task (knowledge/tasks/<ID>-cli-task.md)
  $ kb --repo "$human" task list | sed -E 's/tasks\/[A-Z0-9]{26}-cli-task/tasks\/<ID>-cli-task/g'
  tasks/<ID>-cli-task  todo      high   CLI task
  $ kb --repo "$phase2" task add --stdin --claim explicit --json <task.md >task-result.json
  $ sed -n 's/.*"code":"\([^"]*\)".*/\1/p' task-result.json
  task_added
  $ task_id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' task-result.json)
  $ kb --repo "$phase2" task start "$task_id" --json | sed -n 's/.*"code":"\([^"]*\)".*/\1/p'
  task_started
  $ kb --repo "$phase2" task done "$task_id" --json
  {"ok":false,"code":"invalid_arguments","message":"Invalid command arguments.","details":{}}
  [2]
  $ kb --repo "$phase2" task done "$task_id" --closure-authority performed-and-verified --json | sed -n 's/.*"code":"\([^"]*\)".*/\1/p'
  task_done
  $ kb --repo "$phase2" task list --json
  {"ok":true,"code":"tasks_listed","data":{"tasks":[]}}
  $ kb --repo "$phase2" task list --history --json | sed -n 's/.*"state":"\([^"]*\)".*/\1/p'
  done
  $ kb --repo "$phase2" validate --json | sed -n 's/.*"code":"\([^"]*\)".*/\1/p'
  bundle_valid

Malformed human invocations never replay rejected credentials or body text.

  $ kb validate 'postgresql://alice:hunter2@db.example/clamp' 'KNOWLEDGE_BODY_SENTINEL' >stdout 2>stderr
  [2]
  $ cat stdout
  $ cat stderr
  kb: Invalid command arguments.
  $ grep -E 'hunter2|KNOWLEDGE_BODY_SENTINEL' stdout stderr >/dev/null; echo $?
  1

The option terminator preserves escaped operands and stops output-control
detection.

  $ kb --repo "$repo" search --json -- -literal
  {"ok":false,"code":"database_url_missing","message":"KB_DATABASE_URL is required for retrieval.","details":{"fallback":"local_markdown_or_rg","semantic_equivalent":false}}
  [2]
  $ kb --repo "$repo" search -- --json
  kb: KB_DATABASE_URL is required for retrieval.
  [2]
  $ kb --repo "$repo" search -- --quiet
  kb: KB_DATABASE_URL is required for retrieval.
  [2]
  $ kb validate -- --json
  kb: Invalid command arguments.
  [2]

Command help freezes every process exit class.

  $ kb search --help=plain | sed -n '/EXIT STATUS/,/SEE ALSO/p' | sed '/^[[:space:]]*$/d'
  EXIT STATUS
         kb search exits with:
         0   The command completed successfully.
         2   The request or local input was invalid.
         3   A durable publication conflict requires resolution.
         4   Authentication failed.
         5   A transient external dependency failed.
         6   The derived index is stale or incompatible.
         70  An unexpected internal failure occurred.
  SEE ALSO

Operational validation errors never echo credential-bearing repository arguments.

  $ kb validate --diagnostic --repo 'postgresql://alice:hunter2@db.example/clamp' 2>&1
  kb: diagnostic: command=validate exit_class=user_error status=2 repo=postgresql://[REDACTED]@db.example/clamp
  kb: Repository root is unreadable or unsafe.
  [2]
