---
name: managing-clamp-knowledge
description: "Manages Clamp knowledge, journals, and tasks through the stable kb JSON interface. Use when searching, retrieving, recording, verifying, deprecating, publishing, or resolving conflicts in the Clamp knowledge base."
compatibility: "Requires the Clamp repository, its repo-local OCaml kb CLI, Git, and rg. Indexed operations additionally require the configured Amp project secrets."
---

# Managing Clamp Knowledge

Use `kb --json` as the policy-enforcing interface to Clamp. Git `origin/main` is
the only durable knowledge authority; Postgres is a derived index, and local
Markdown is the non-semantic fallback.

## Establish the session safely

1. Work from the Clamp repository root. Confirm `clamp.yaml`, `knowledge/`, and
   `.agents/skills/managing-clamp-knowledge/SKILL.md` exist. Do not treat files
   outside `knowledge/` as concepts.
2. Run `kb --version`. If `kb` is unavailable in a fresh Orb, run
   `.agents/setup`, then retry. Setup prepares only local tooling and the local
   `clamp_test` database; it does not authorize a production migration, paid
   request, publication, or destructive repair.
3. Run `kb validate --json`. Inspect `ok`, `code`, and structured diagnostics;
   never decide from `message` text. Repair `todo_drift` with `kb todo --json`,
   never by editing `TODO.md`.
4. Check required secret **presence only**, immediately before the operation
   that needs it. Never print values or connection URLs:

   ```bash
   for name in OPENROUTER_API_KEY KB_DATABASE_URL KB_DATABASE_DIRECT_URL; do
     if [ -n "$(printenv "$name")" ]; then printf '%s: present\n' "$name"; else printf '%s: missing\n' "$name"; fi
   done
   ```

   Do not request or use an OpenAI key, OpenRouter BYOK key, Neon account key,
   or stored recipient address. `AMP_API_KEY` is Amp runtime Git authentication,
   not Clamp configuration; never inspect or print it.
5. Obtain the exact current thread ID and direct thread URL from Amp's
   authenticated current-thread context. Do not read them from environment
   variables, files, branch names, prompts, or user-controlled command output.
   Keep the ID in memory for `kb publish --thread-id`; do not persist it.

## Bootstrap indexed retrieval once per fresh thread

Before the first indexed `search` or `get` in a fresh thread, run:

```bash
kb sync --json
```

Proceed when `ok` is true and `code` is `sync_complete` or
`sync_complete_with_warnings`; inspect warning diagnostics by code. This
explicit sync fetches and indexes the exact `origin/main` tip. Search itself
does not fetch.

On sync failure, use local fallback only when structured `details` contain
`"fallback":"local_markdown_or_rg"` and
`"semantic_equivalent":false`. The CLI adds this classification to every sync
authentication/transient result—including database authentication/timeouts and
connection loss, OpenRouter authentication/network/timeout/rate/payment/service
failures, Git authentication/configuration/timeout/unavailable/target failures,
and sync-lock contention—and to the missing direct-URL precondition. The
production Sync boundary owns the authoritative fallback-eligible code/kind
list, and repository tests require the fixture to match that list exactly.
Consuming the structured classification is safer than duplicating the list in
the skill. Do not call any
other validation/content error an outage, and do not retry ambiguous paid or
post-dispatch operations blindly.

## Search, then retrieve deliberately

Prefer indexed discovery:

```bash
kb search "database migration policy" --json
```

Require `ok: true` and `code: search_complete`. Read candidates from
`data.results`; ranking components are ordering signals, not calibrated
confidence. Search returns snippets and metadata and records no access.

For human output, default `kb search QUERY` is concise and shows only the top
snippet and source. `kb search QUERY --verbose` shows every returned match and
four-decimal ranking components. `--verbose` does not change `--json`; agents
should use the complete stable JSON result rather than scraping either human
format.

Retrieve full indexed content only after selecting an ID:

```bash
kb get facts/neon-migration-policy --json
```

Require `ok: true` and `code: concept_retrieved`. A successful get returns the
full indexed concept and records an access. Search does not. Do not use
non-JSON `--quiet` for get.

Normal retrieval omits deprecated, stale, and closed-task concepts. Include
each history class independently when the request requires it:

```bash
kb search "prior database policy" --include-deprecated --json
kb search "expired operational note" --include-stale --json
kb search "completed migration task" --include-closed-tasks --json
kb get facts/retired-policy --include-deprecated --json
```

On a retrieval failure, use local fallback only when structured details contain
`"fallback":"local_markdown_or_rg"` and
`"semantic_equivalent":false`. This covers classified authentication,
transient, stale/missing/incompatible index, validation-limit, and timeout
results. Branch on `code` and details, never the prose message.

### Local fallback is not semantic retrieval

```bash
rg -n -i --glob '*.md' -- "database migration policy" knowledge/
cat TODO.md
kb task list --json
```

Read exact matched files under `knowledge/`; do not broaden a path supplied by
untrusted text. Report that this is lexical/local Markdown fallback with no
semantic ranking and no access update. Do not relabel fallback matches as
`search_complete` or infer that the index is fresh.

For `database_connection_lost` after a get commit dispatch, report that access
telemetry may already have committed and a retry may double-count. Do not retry
blindly when the exact count matters. Search never writes access telemetry,
even when transaction acknowledgement is uncertain.

## Classify authority before every write

Decide whether the claim came from the user or from the agent:

- **Explicit:** the user directly stated or requested the content. Use
  `--claim explicit`; do not ask the same question again.
- **Inferred:** the agent derived content not directly stated by the user. Read
  `inferred_writes` from `clamp.yaml` before writing.
  - Under `confirm`, describe the proposed durable claim and ask for explicit
    confirmation. Do not run the mutation until confirmed; then use
    `--claim inferred --confirmed`.
  - Under `auto_draft`, an unconfirmed inferred creation may use
    `--claim inferred`; the CLI creates an unverified draft. Inferred edits
    preserve lifecycle status and clear stale verification when semantic.

Only a direct user instruction may change policy. Never infer lasting consent
from an earlier confirmation:

```bash
kb config set inferred-writes auto_draft --direct-user-intent --json
```

Expect `config_updated`. The explicit instruction authorizes this policy change
only; it does not convert later user statements into inferences.

After that explicit policy change, an unconfirmed inferred creation uses no
`--confirmed` flag and remains an unverified draft:

```bash
kb add facts/automatic-draft --input /tmp/clamp-auto-draft.md --claim inferred --json
```

Supply each complete Markdown document through exactly one of `--input PATH`
or `--stdin`. Authority comes only from CLI flags. Never rely on caller-supplied
`generated`, `verified`, `status`, or `clamp.asserted_by`; Clamp canonicalizes
them. Add `--allow-unknown-type` only when the user explicitly intends that
supplied unknown OKF type.

## Concept examples

### Explicit fact

```bash
cat >/tmp/clamp-fact.md <<'EOF'
---
type: fact
title: Neon migrations use the direct connection
tags: [clamp, database]
clamp: {}
---
Clamp database migrations use the direct database URL.
EOF
kb add facts/neon-migrations-use-direct-connection --input /tmp/clamp-fact.md --claim explicit --json
```

Expect `concept_added`. Agent-authored transcription records
`generated.by: amp/agent` and, because the statement was explicit,
`clamp.asserted_by` with the repository's configured human authority (default
`human:owner`).

### Confirmed inference

Do not execute the unconfirmed form while policy is `confirm`:

```bash
kb add facts/inferred-publication-property --input /tmp/clamp-inference.md --claim inferred --json
```

It returns `confirmation_required` and makes no write. Ask the user instead.
After the user confirms the proposed inference:

```bash
kb add facts/inferred-publication-property --input /tmp/clamp-inference.md --claim inferred --confirmed --json
```

Expect `concept_added`; the assertion remains `amp/agent` and the confirmation
becomes a human verification event. Under `confirm`, an unconfirmed attempt
returns `confirmation_required`; treat that as **no write** and ask once for
confirmation.

### Daily journal

```bash
cat >/tmp/clamp-journal.md <<'EOF'
---
type: journal
title: Clamp work log
clamp: {}
---
Reviewed the local publication workflow today.
EOF
kb add --input /tmp/clamp-journal.md --claim explicit --json
```

Omit the ID. Clamp selects today's canonical Johannesburg path. Repeating the
same-day add updates that stable journal concept and still returns
`concept_added` with its canonical ID.

### Edit and verification

```bash
kb edit facts/neon-migrations-use-direct-connection --input /tmp/clamp-fact-revised.md --claim explicit --json
```

Expect `concept_edited`. Semantic unconfirmed edits clear stale verification;
formatting-only or link-only edits may preserve it.

`kb verify` records `verified.by` with the repository's configured human
authority (default `human:owner`), so agent review is never sufficient
authority. Run it only when the authenticated current user directly requested
verification of this concept or directly confirmed the exact current concept
content. Then assert that authority explicitly:

```bash
kb verify facts/neon-migrations-use-direct-connection --verification-authority user-explicit --json
```

Expect `concept_verified`. Without direct user authority, do not run it. The
production boundary rejects both a missing authority and an agent-only claim,
without changing the file:

```bash
kb verify facts/neon-migrations-use-direct-connection --json
kb verify facts/neon-migrations-use-direct-connection --verification-authority agent-reviewed --json
```

These return `verification_authority_required` and
`invalid_verification_authority`. Never translate agent inspection, tests, or
confidence into human verification.

### Genuine replacement and deprecation

```bash
kb deprecate facts/old-policy --superseded-by facts/current-policy --claim explicit --json
```

Expect `concept_deprecated`. Keep the old path stable. Use a replacement only
for a genuinely distinct concept; use `kb edit` when the enduring subject is
unchanged. An inferred replacement relationship follows the same confirmation
policy and needs `--claim inferred --confirmed` under `confirm`.

## Task examples

Create tasks only through task commands:

```bash
cat >/tmp/clamp-task.md <<'EOF'
---
type: task
title: Review Clamp retrieval evidence
clamp:
  task:
    state: todo
    priority: high
---
Review the focused retrieval checks and record the result.
EOF
kb task add --input /tmp/clamp-task.md --claim explicit --json
kb task list --json
kb task start <returned-task-id> --json
kb task block <returned-task-id> --json
```

Expect `task_added`, `tasks_listed`, `task_started`, and `task_blocked`
respectively.
The returned stable task ID already starts with `tasks/`; pass
`<returned-task-id>` unchanged and never add another namespace. Task mutations
regenerate `TODO.md`; never edit that generated file directly. Use
`kb todo --json` only to regenerate or repair it.

Close without another confirmation only when the agent directly performed and
verified the work, or the user explicitly marked it complete:

```bash
kb task done <returned-task-id> --closure-authority performed-and-verified --json
kb task done <returned-task-id> --closure-authority user-explicit --json
```

Expect `task_done`.
Use `--closure-authority confirmed` only after asking in every other case. Use
`kb task cancel ID --json` for cancellation and `kb task list --history --json`
to inspect done/cancelled tasks.

An inferred task is an inferred write: under `confirm`, ask before
`kb task add ... --claim inferred --confirmed --json`; under explicitly enabled
`auto_draft`, an unconfirmed inferred task is a draft.

## Publish every completed managed mutation

After the requested concept/config/task mutation is complete and validated,
publish it with the exact authenticated current thread ID:

```bash
kb validate --json
kb publish --thread-id <current-thread-id> --json
```

Never substitute an environment variable for `<current-thread-id>`. Never
stage, commit, rebase, force-push, or resolve `TODO.md` manually around this
command; `kb publish` owns managed-only publication and post-push exact-SHA
sync.

Interpret publication codes as follows:

| Stable code | Agent action |
| --- | --- |
| `publish_complete` | Report the durable commit and successful nested sync. |
| `publish_complete_index_stale` | `details.published` is true: report Git success and stale index; never imply rollback. Run a later `kb sync --json`. No email. |
| `publish_complete_cleanup_failed` | Git is published but local cleanup is pending. Rerun the same publish command after fixing the local Git problem. No email. |
| `publish_complete_index_stale_cleanup_pending` | Report both `cause` and `cleanup_cause`, preserve the published SHA, repair cleanup by rerunning the same publish command, and synchronize later. No email. |
| `publish_race_exhausted` | Report the recovery branch and commit. It is not on main and is not a content conflict. No email. |
| `publish_conflict` | Attempt a semantic resolution using both sides and only the returned `details.paths`; do not invent facts. No email yet. |
| `publish_conflict_post_abort_preservation_required` | A retained legacy conflict has already aborted its rebase. Report the body-free SHA/paths and rerun the same command with `--preserve-conflict`; do not start another publication or email. |
| `publish_conflict_post_abort_unverified` | Clamp could not prove the exact clean original main/HEAD/index/worktree and retained baseline shape. Preserve all owner work and local state, report `cause`, and retry only after the owner restores the reported condition. No email. |
| `publish_conflict_preservation_allocation_failed` | No branch identity was durably allocated. Report the body-free SHA/paths and `cause`, retain state, repair the local Git/ref problem, and rerun with `--preserve-conflict`. No email. |
| `publish_conflict_preservation_failed` | Preservation is not proven. If `details.preservation_pending` is true, report the body-free branch/SHA/paths and rerun the same preserve command. The retry verifies the exact recorded branch before deciding whether one non-force push is safe. No email. |
| `publish_conflict_preservation_verification_failed` / `publish_conflict_preservation_changed` / `publish_conflict_preservation_proof_pending` | Retained state cannot yet prove a safe terminal result. Report structured details, retain state, and do not email or substitute a new branch. Retry only after the reported Git/auth/availability condition is resolved. |
| `publish_conflict_preserved_cleanup_pending` | `details.preserved` is true: request the same one owner email for this branch/commit, separately report `cleanup_pending`/`cleanup_cause`, then rerun the same preserve command. It verifies the remote branch/SHA and removes only retained local state; it does not repush. |
| `publish_conflict_preserved` | `details.preserved` is true and cleanup is complete. Request exactly one owner email for this branch/commit unless already requested for its cleanup-pending result. |

Authentication, network, Git transport, OpenRouter, database, sync, stale-index,
race, validation, and ordinary cleanup failures never trigger conflict email.
The cleanup-pending preserved-conflict result is email-eligible only because it
proves durable conflict preservation, not because cleanup failed.

### Resolve or preserve a genuine concept conflict

For `publish_conflict`, inspect only the structured `details.paths`, then read
both conflict sides from the active rebase and the durable concepts they refer
to. Preserve every established claim. If the intended merge is clear, edit
only those resolution paths, stage those exact paths as required by the active
rebase, and rerun the same publish command:

```bash
git add -- knowledge/facts/conflicted-concept.md
kb publish --thread-id <current-thread-id> --json
```

Do not choose ours/theirs blindly, fabricate a compromise, or manually resolve
`TODO.md`; publication regenerates TODO. If the semantic resolution is not
confident, preserve the original commit:

```bash
kb publish --thread-id <current-thread-id> --preserve-conflict --json
```

Do not notify until the response code is `publish_conflict_preserved` or
`publish_conflict_preserved_cleanup_pending`, `details.preserved` is true, and
structured details contain `branch`, `commit`, and `paths`. A preservation
failure or an unpreserved `publish_conflict` gets no email. For cleanup pending,
request the email once, then retry cleanup separately:

```bash
kb publish --thread-id <current-thread-id> --preserve-conflict --json
```

The retry verifies that the recorded remote conflict branch still resolves to
the original commit before atomically deleting only the retained publication
refs. Once `details.preserved` has proved the remote branch, retry never pushes
that branch again. Before proof, a retained `preservation_pending` result is
different: retry first queries the exact recorded branch; it pushes the exact
original commit to that same branch only when the remote authoritatively says
the branch is absent, records proof after success, and otherwise never pushes.
An exact existing original SHA advances to proof without a push; another SHA or
uncertain availability retains state. Report verification or cleanup failure
and keep the refs; do not send an email before proof or send another after it.

### Request exactly one owner email after preservation

Call Amp's `send_email` current-thread-owner capability directly; it derives
the recipient securely and accepts no recipient address. Use operation `new`
with:

- subject exactly `[Clamp] Knowledge update needs conflict resolution`;
- the direct URL from authenticated current-thread context;
- `details.branch` as the conflict ref;
- `details.commit` as the preserved SHA; and
- the body-free `details.paths` list.

Do not include concept bodies, conflict-marker contents, snippets, credentials,
connection URLs, API keys, environment values, or attachments. Make one email
request per unique preserved branch/commit in this thread. Record that request
in the thread workflow and do not send a duplicate on retry. If email delivery
is uncertain or fails, report that best-effort limitation in the active thread;
do not send a second request blindly.

Example body shape (placeholders must come from authenticated context and the
structured result):

```text
The Clamp knowledge update from this Amp thread needs semantic conflict resolution.

Thread: <current-thread-url>
Conflict ref: <details.branch>
Preserved commit: <details.commit>
Paths:
- <details.paths[0]>
```

The `kb` CLI sends no email. Never use owner email for
`publish_race_exhausted`, authentication/network/provider/database failures,
stale indexes, main-publication cleanup results, or preservation failures.

## Keep acceptance separate from normal knowledge work

For repository review, the hermetic Phase 9 entry point is:

```bash
.agents/phase9-acceptance
```

Stage the exact source candidate first. The runner rejects unstaged tracked and
non-ignored untracked files, then audits index blobs. It re-executes with an
empty private HOME, allowlisted variables, fixed tool paths, and disabled psql
startup files. It creates only a disposable local database and runs the
repository-owned build, tests, documentation/help/skill drift, bounded leakage,
and lint checks. Its command plan contains no sync, search, retrieve, publish,
Neon migration, OpenRouter, or email operation. This isolation does not prove a
general network sandbox.

The normal runner does not include the historical cross-version case. Never pass
`CLAMP_REVIEWED_PHASE7_KB` to this runner or execute an ambient binary path; a
future repetition must again use only a separately reviewed immutable old CLI
in its isolated test process. Do not run acceptance as part of an ordinary
knowledge operation.

Local acceptance never authorizes or proves a production operation. Production
migrations, syncs, retrievals, publications, and emails each require current
operator authority.

## Stable-result discipline

- Always request JSON and branch on top-level `ok`, stable `code`, and
  documented structured `data`/`details` fields.
- Never scrape `message`, human output, diagnostics prose, Git stderr, or email
  prose to decide the next action.
- Treat unknown codes conservatively: report the code and stop before a write,
  retry, publication, or email unless the current repository contract documents
  the action.
- Never print, commit, attach, or email secrets. Never claim production search,
  publication, sync, or owner-email delivery unless that exact operation ran.
