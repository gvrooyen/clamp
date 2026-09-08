# Clamp

Clamp is a personal, agent-managed knowledge base for Amp Orbs. It keeps durable
knowledge and tasks as human-readable, Git-versioned Markdown while using Neon
Postgres and pgvector for fast semantic retrieval.

> **Status:** Clamp v1 and Phases 0–9 are implemented. The pinned 0.1.0
> production-release build is also implemented. Repository-owned acceptance is
> local-only and does not authorize production database or publication
> operations.

The full product and architecture contract is in [PRD.md](./PRD.md), and the
phased delivery sequence is in [PLAN.md](./PLAN.md). Guidance for agents
working in this repository is in [AGENTS.md](./AGENTS.md).

## Why Clamp

Each Amp thread can run in a fresh Orb, so local disk and unpushed commits are
not a durable memory store. Clamp separates durable knowledge from disposable
compute and indexing:

- **Git `origin/main`** stores authoritative OKF v0.2 Markdown.
- **Neon Postgres + pgvector** stores a rebuildable content index and lossy
  access telemetry.
- **OpenRouter** supplies pinned OpenAI embeddings using OpenRouter credits.
- **A repo-local Amp skill and native OCaml CLI** give threads a consistent way
  to search, read, update, publish, and synchronize knowledge.

```text
┌────────────────┐      search/update      ┌──────────────────┐
│ Amp Orb thread │────────────────────────▶│ `kb` CLI + skill │
└────────────────┘                         └───────┬──────────┘
                                                  │
                         ┌────────────────────────┼──────────────────────┐
                         │ publish               │ sync                 │ embed
                         ▼                       ▼                      ▼
                ┌────────────────┐      ┌─────────────────┐   ┌────────────────┐
                │ Git main       │      │ Neon + pgvector │   │ OpenRouter API │
                │ source of truth│      │ derived index   │   │ pinned OpenAI  │
                └────────────────┘      └─────────────────┘   └────────────────┘
```

## V1 capabilities

The approved v1 includes:

- OKF v0.2-compatible concepts under `knowledge/`.
- Facts, preferences, people, projects, decisions, and tasks.
- Explicit provenance for document generation, claim assertion, and
  verification.
- Confirmation before persisting agent-inferred knowledge, with a durable
  `auto_draft` opt-out.
- One stable concept file per task and a deterministic generated `TODO.md`.
- Semantic search followed by recency/frequency reranking.
- Blob-hash synchronization that works in shallow Orb checkouts.
- Direct, non-force publication to `origin/main`.
- Recovery branches and Amp owner-email escalation for unresolved concept
  conflicts.
- Local Markdown/`rg` fallback when Neon or OpenRouter is unavailable.

V1 intentionally excludes recurring tasks, reminders, background indexers,
automatic link suggestions, multi-user storage, and independently guaranteed
email delivery.

## Native command-line interface

The native OCaml `kb` CLI now exposes the approved command tree:

```text
kb search <query>
kb get <concept-id>
kb add [concept-id]
kb edit <concept-id>
kb verify <concept-id>
kb deprecate <concept-id>
kb task add
kb task list
kb task start <concept-id>
kb task block <concept-id>
kb task done <concept-id>
kb task cancel <concept-id>
kb todo
kb validate
kb database migrate
kb sync
kb publish
kb config set inferred-writes <confirm|auto_draft>
```

Phase 1–3 local and maintenance commands, Phase 5 `sync`, Phase 6 `search` and
`get`, and Phase 7 `publish` are implemented. Help and version metadata are
available now:

```bash
kb --version
kb --json --help
kb validate --json
kb search "query" --json
kb get facts/example --json
kb sync --json
kb sync --commit <exact-origin-main-sha> --json
kb sync --reembed --json
kb sync --allow-mass-deletion --json
kb publish --thread-id T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --json
```

All executable commands accept `--repo`/`--repo-root`, `--json`, `--quiet`, and
`--diagnostic`. Machine-readable results use one envelope:

```json
{"ok":false,"code":"publish_thread_id_invalid","message":"--thread-id must be an exact Amp thread ID.","details":{"published":false}}
```

Stable exit classes are `0` success, `2` validation/user error, `3` conflict,
`4` authentication, `5` transient external failure, `6` stale index, and `70`
internal failure. JSON callers use result codes rather than parsing messages.

## Repository layout

```text
AGENTS.md                         Repository guidance for Amp agents
README.md                         User-facing overview and setup
PRD.md                            Authoritative v1 product contract
PLAN.md                           Phased implementation and verification gates
.agents/setup                     Idempotent fresh-Orb bootstrap
.agents/resume                    Fast local PostgreSQL wake-up check
.agents/skills/
└── managing-clamp-knowledge/
    └── SKILL.md                  Stable JSON agent workflow and policy
.ocaml-version                    Pinned OCaml compiler version
dune-project                      Dune project metadata
clamp.opam                        Direct OCaml dependencies and version bounds
clamp.opam.locked                 Locked transitive OCaml dependencies
release/                          Pinned Linux x86_64 release builders
db/migrations/                    Versioned production database migrations
clamp.yaml                        Versioned non-secret configuration
TODO.md                           Generated task view; never edit directly
knowledge/                        OKF v0.2 bundle
├── facts/
├── preferences/
├── people/
├── projects/
├── decisions/
├── journal/
│   └── <year>/
│       └── <date>.md
└── tasks/
    └── <ulid>-<initial-slug>.md
```

## Repo-local Amp skill

Amp discovers the `managing-clamp-knowledge` skill from
`.agents/skills/managing-clamp-knowledge/SKILL.md`. A fresh thread should use it
for Clamp search, retrieval, mutation, task, publication, or conflict work. It
contains the complete bootstrap and policy workflow; no MCP server, plugin,
daemon, hook, or companion script is required.

The normal machine-facing sequence is:

```bash
kb validate --json
kb sync --json                 # before the first indexed retrieval in a thread
kb search "query" --json
kb get facts/example --json
# perform an authority-classified mutation or task command
kb publish --thread-id <current-authenticated-amp-thread-id> --json
```

The skill branches only on stable JSON `code`, `data`, and `details` fields. It
uses lexical local Markdown/`rg` fallback only for classified external or stale
retrieval results and explicitly does not call that fallback semantically
equivalent. It asks before inferred writes under `confirm`, changes
`auto_draft` only on direct user instruction, never edits `TODO.md`, and uses
the exact task closure authority required by the CLI. A human verification is
allowed only after the authenticated current user directly requests it or
confirms the exact current concept content; the skill then passes
`--verification-authority user-explicit`. Agent review alone is rejected.

For a genuine semantic conflict, it first attempts a fact-preserving resolution.
If that is not possible, it runs publication conflict preservation and requests
exactly one Amp current-thread-owner email only after receiving
`publish_conflict_preserved` or
`publish_conflict_preserved_cleanup_pending` with `details.preserved: true`.
That body contains only the authenticated direct thread URL, conflict ref,
preserved SHA, and paths. A cleanup-pending preservation result still gets the
same one email because the branch is durable; the skill separately retries
cleanup without repushing. The CLI itself sends no email, and races,
authentication/network/provider/database/index failures and ordinary cleanup
failures never trigger email.

The repository owns deterministic static and command-fixture tests plus a
disposable shallow-clone/local-Postgres workflow covering sync, search/get,
explicit and confirmed-inferred writes, task/TODO updates, publication, resync,
outage fallback, and conflict-preservation notification gating. This local
evidence is not a claim that the production skill workflow has run.

The strict versioned configuration, exact-scalar YAML syntax-tree parser,
canonical frontmatter serializer, and bundle/path/link validator now exist.
Canonical rewrites preserve unknown semantic values (including large integer
lexemes and nested multiline strings) but intentionally do not preserve YAML
comments, exact quote/literal scalar styles, or original key ordering. YAML
anchors, aliases, application-specific tags, duplicate keys, and unsupported
scalar semantics are rejected rather than rewritten ambiguously.
Markdown links and verification-relevant visible text use a strict CommonMark
parse rather than handwritten delimiter scanning. Persisted unknown non-empty
OKF types produce warnings; malformed concepts produce errors, and only errors
make `kb validate` exit with status `2`. JSON diagnostics include a stable
`severity` field and never include concept bodies.

Validation uses fixed v1 safety ceilings: 8 MiB per config, concept, or reserved
file; YAML depth 64 and 100,000 nodes; 10,000 Markdown files and 100,000 links
per bundle; and 1,000 returned diagnostics. These bounds are not configurable.
More than 1,000 diagnostics fails with body-free `diagnostic_limit` plus the
999 smallest diagnostics in stable order.
Accepted signed decimal/radix YAML integers and finite decimal/exponent floats
are normalized exactly and stored as JSON numbers without binary floating point
or stringification. PostgreSQL `numeric` bounds the normalized value to 131,072
digits before and 16,383 digits after the decimal point. Non-finite values fail
with `numeric_non_finite`; out-of-range values fail with
`numeric_out_of_range`, before embedding or index mutation.
Paths must be valid UTF-8, portable, and URI-safe; symlinks and non-regular
Markdown files are rejected. Noncanonical case-fold variants of reserved
`index.md` and `log.md` names are rejected at every knowledge depth.
Mutations require exactly one of `--input PATH` or `--stdin` containing a
complete UTF-8 Markdown document and `--claim explicit|inferred`. Confirmed
inferences add `--confirmed`; supplied unknown types require
`--allow-unknown-type`. Task closure requires
`--closure-authority performed-and-verified|user-explicit|confirmed`. Policy
changes require `--direct-user-intent`. Human verification requires
`--verification-authority user-explicit` after direct current-user authority;
missing or agent-only authority does not mutate the concept. The CLI ignores caller-supplied
authority metadata and writes canonical producer, assertion, verification,
status, and current timestamps.
Under `auto_draft`, an unconfirmed inferred creation is draft and unverified.
An edit instead preserves the stored lifecycle status: semantic edits clear
stale verification, while formatting-only or link-only edits preserve the
exact verification events. Input status cannot deprecate or undeprecate a
concept; use `kb deprecate` for that transition.

For example, arbitrary Markdown can be passed without shell quoting:

```bash
kb add facts/example --input /tmp/example.md --claim explicit --json
cat /tmp/revised.md | kb edit facts/example --stdin --claim inferred --confirmed --json
kb verify facts/example --verification-authority user-explicit --json
kb deprecate facts/example --superseded-by facts/replacement --claim explicit --json
kb task add --input /tmp/task.md --claim explicit --json
kb task done tasks/<ulid>-example \
  --closure-authority performed-and-verified --json
kb task list --history --json
kb todo --json
kb config set inferred-writes auto_draft --direct-user-intent --json
```

Local mutations use no-follow managed paths and atomic fsynced replacement.
Readers/writers use shared/exclusive Linux `flock` on the already-open root
directory inode (there is no lock file), and the root path is revalidated
before success. Operational entries belong under the ignored
`.clamp/transactions/<128-bit-random>/` namespace. Task/TODO pairs are
serialized by that repository lock and rolled back on reported
ordinary write failures after exact snapshot verification. Temporary files and
private state are accepted only through an effective-UID-owned chain with
`0700` directories; Clamp-created private files use `0600`. A retained original
displaced by atomic exchange keeps its exact public mode inside that private
chain so hard-link aliases are unchanged, and Clamp verifies its descriptor,
identity, and exact saved bytes immediately before cleanup. Other same-UID processes must not modify
`.clamp/`; these checks establish a trust boundary but do not claim kernel
isolation from prohibited same-UID tampering. Temporary files and
new empty directories are cleaned up with bounded recovery; if final state
cannot be verified, the stable result is `rollback_state_uncertain` rather than
a rollback claim. A successful rollback additionally requires a restoring
rename or removal and directory fsync plus verified cleanup of every temporary
file from all attempts. Final canonical concept bytes and generated outputs are
size-checked before managed directory creation or replacement; concepts are
also reparsed under the Phase 1 frontmatter, YAML-depth, and YAML-node limits.
Cleanup atomically moves entries without overwrite to random private quarantine
names, verifies the captured identity and bytes, then removes them and fsyncs
the containing directory. Installs use Linux `renameat2` no-replace/exchange
semantics with no unsafe ordinary-rename fallback. Clamp revalidates the full
managed ancestor chain. New directories are staged under random private names
and installed without replacement. Clamp preserves foreign replacements;
ownership or parent linkage uncertainty is reported as `rollback_state_uncertain` or
`repository_changed`. Operational write, lock, and rollback-integrity
failures use process exit 70, while invalid input, authority, paths, and
references remain exit 2. Human task/TODO commands print generated task IDs,
task rows or an explicit empty state, and the TODO regeneration result; JSON
and quiet output remain stable.
A process or host crash in the brief interval between the task rename and TODO
rename can leave drift; `kb validate` reports `todo_drift`, and `kb todo`
repairs it. Clamp deliberately does not use a local write-ahead marker in v1.
Generated task ULIDs use the standard timestamp prefix and random entropy, so
they sort across different milliseconds without guaranteeing monotonic order
within one millisecond.
The Phase 4 library builds deterministic, LF-normalized embedding input from
type, title, description, sorted tags, and the exact Markdown body, then hashes
those bytes with SHA-256. It rejects invalid UTF-8 and inputs over 8,000 bytes
before network access. The direct synchronous OpenRouter client fixes the
model, dimensions, OpenAI-only routing, disabled fallbacks, and denied data
collection; bounds connection time, total time, and response size; verifies
TLS certificates and hostnames; and strictly validates model, usage, vector
dimensions, and finite values. It returns only the canonical model identity to
later phases and classifies redacted failures, including paid-request
ambiguity.

`kb sync` requires the direct database URL and the versioned non-secret
`source_repository` identity in `clamp.yaml`. It fetches and verifies the exact
`origin/main` commit, revalidates that commit's complete root configuration and
repository identity, and reads concepts and reserved documents only through
bounded argument-array `git ls-tree`/`git cat-file` processes. Git subprocesses
run with a minimal environment that excludes ambient Git repository, object,
index, and configuration overrides and disables replacement-object processing.
For an exact `https://ampcode.com/...` origin, Clamp validates the Amp runtime
helper path, writable home, and derived `$HOME/.config` XDG location, resets
credential helpers and askpass behavior, and passes only `AMP_API_KEY` and
`AMP_URL` in addition to that sanitized
environment. Dangerous repository-local credential, HTTP, URL rewrite/include,
hooks-path, and upload-pack configuration is rejected before auth is exposed.
Global/system Git configuration remains disabled; local and `file://` remotes
receive no Amp credentials. The API key is never placed in argv or errors.
Their single monotonic deadline starts before pipe acquisition, and an owned
session/process group is cleaned without releasing the leader PID early. A
readiness/ACK handshake prevents helper execution until the parent has anchored
that group for safe cleanup. Sync validates portable, case-fold-collision-free
Git-tree paths and every selected concept and reserved document, including
bundle-wide file/link ceilings, and completes required embeddings before one
atomic index transaction. It preserves
access telemetry for surviving paths, avoids re-embedding metadata-only changes,
and returns deterministic add/update/reembed/unchanged/delete counts.
An absent target-commit `knowledge` entry is an empty bundle; a present entry
must be exactly one Git tree, never a blob or another object kind.
Clamp v1 requires the repository to report SHA-1 object format and fails with
`git_object_format_unsupported` before fetch when another format is configured.
Successful sync returns `sync_complete`, or `sync_complete_with_warnings` with
stably ordered body-free diagnostics for unknown types and invalid or unresolved
links. These warnings match `kb validate` and do not block index convergence;
more than 1,000 fails closed with `diagnostic_limit` rather than truncating.
The production Sync boundary centrally defines the fallback-eligible code/kind
pairs used by database/OpenRouter adapters and direct Git/Sync producers.
`Sync.cli_result` emits the non-equivalent local-Markdown fallback only for an
exact match; the checked fixture is derived from that authoritative list.
Deterministic validation/internal failures and publication-only remote-ref
verification remain outside it.
Fetched frontmatter numbers are exact JSON numbers under the PostgreSQL numeric
limits described above, and invalid numeric values produce no embeddings or
index/checkpoint changes.
`--commit` verifies a publication-supplied exact SHA against the fetched tip;
`--reembed` regenerates every vector; and `--allow-mass-deletion` is the explicit
approval required by the empty-tree and majority-deletion safeguards. There is
no implicit sync, hook, daemon, or publication behavior.

`kb search <query>` requires the pooled `KB_DATABASE_URL` and an OpenRouter key.
It checks the index identity and checkpoint against the already-local
`refs/remotes/origin/main` without fetching, embeds the query with the same
pinned provider contract as sync, selects the configured pgvector cosine
candidate set using strict-order iterative HNSW scanning, and reranks it in
OCaml with the versioned semantic, recency, and frequency settings. Retrieval
configuration is read from `clamp.yaml` at the captured local remote-tracking
commit, not the mutable worktree. V1 caps candidates at 1,000, results at 100,
recency half-life at 3,650 days, and frequency saturation at 1,000,000 accesses;
all are positive and results cannot exceed candidates. Normal search excludes
deprecated and stale concepts and
done/cancelled tasks; `--include-deprecated`, `--include-stale`, and
`--include-closed-tasks` independently restore those classes. Drafts remain
visible with status, verification tier, and assertion origin. Results contain
deterministic whitespace-normalized snippets bounded to 240 UTF-8 bytes with an
explicit `…` marker when truncated. Search candidates and returned search rows
never update access telemetry. Human output shows the top snippet and source by
default; `-v`/`--verbose` shows every returned match plus four-decimal ranking,
semantic, recency, and frequency scores. These are ranking signals, not
calibrated confidence, and `--json` is unchanged by verbose mode. The initial ANN result is lightweight; complete
candidate rows are SQL-size-preflighted and validated in 16-row batches under
one five-second deadline, a fixed 16 MiB aggregate selected-value payload
budget, and a 9 MiB row payload bound. Protocol framing is separately bounded
by candidate and batch counts and is not charged to those payload limits. Every
retrieval transaction pins and verifies UTF8 before indexed text crosses libpq,
so server byte preflight and selected client values use the same encoding even
with hostile ambient or role/database defaults. An individually valid but
too-large candidate set deterministically returns `retrieval_validation_limit`
rather than being skipped or materialized without a client memory bound;
deadline exhaustion returns
`retrieval_validation_timeout`.

`kb get <concept-id>` applies the same freshness and independent history rules,
returns the complete indexed frontmatter and Markdown body with exact JSON
numbers, and atomically creates or increments its access row only after the full
response is constructed and final checkpoint/local-ref rechecks pass. Human
output is a complete deterministic frontmatter document; JSON preserves exact
number lexemes. Non-JSON `--quiet` is rejected before retrieval, while
`--json --quiet` returns the full JSON response. Missing, stale, or incompatible
indexes and unavailable database or
embedding services return stable structured failures. Transient,
authentication, and stale JSON failures explicitly recommend
`local_markdown_or_rg` while stating that fallback is not semantically
equivalent. The validation limit and timeout use this same degraded fallback
contract and record no access. Retrieval does not implicitly fetch or
synchronize; run `kb sync` separately when the local remote-tracking ref or
index needs refresh. The five-second validation deadline also caps the final
local-ref Git subprocess and checks client-side work at row/batch/result
boundaries; synchronous work on one row is not preempted. Clamp recomputes the
remaining budget immediately before COMMIT dispatch and requires at least one
millisecond remaining. A blocking libpq `PQsendQuery` acceptance is the exact
dispatch boundary; setup or send failure remains pre-dispatch. Expiry before
dispatch rolls back and records no access.
PostgreSQL transaction-local statement timeout does not reliably bound deferred
COMMIT finalization, so v1 makes no server-execution deadline claim after
dispatch. The synchronous client waits for acknowledgement, which may succeed
after the local deadline; connection loss returns `database_connection_lost`
but leaves the telemetry outcome uncertain. Because access telemetry is lossy
operational state, callers should not blindly retry such an ambiguous `get` when
an exact count matters. Human and JSON get errors explicitly warn that the
access may already have committed and a retry can double-count. Post-dispatch
search errors instead report uncertain transaction acknowledgement and state
that search wrote no access telemetry. Pre-dispatch connection loss keeps the
ordinary generic message. Search shares the transaction-finalization boundary.

`kb publish` requires an attached local `main` tracking `origin/main`, one
identical fetch/push URL matching the configured source identity, and
repository-local `user.name` and `user.email`. It accepts only managed changes
under `knowledge/**`, `TODO.md`, and `clamp.yaml`; unrelated staged, tracked, or
untracked work and pre-existing local commits ahead of or diverged from the
known `origin/main` tracking ref are refused. A clean local main equal to or
behind that already-known ref is accepted and rebased by the normal publication
flow. The caller must pass the exact current Amp thread ID explicitly with
`--thread-id`; Clamp does not infer it from environment state. Publication
regenerates TODO when task changes or drift require it, rejects repository-local
staging/merge transformation configuration, snapshots and stages exact managed
bytes without filters, and validates the exact candidate tree. It re-renders
TODO and repeats that exact-tree validation after every rebase before committing
or pushing.
Clamp commits with the repository-local author, fetches and rebases without
force. Three completed conflict-free rebase losses exhaust the clean-race
budget; genuine content conflicts do not consume that budget.

A generated-only TODO rebase conflict is regenerated from the merged task
concepts. A genuine managed-content conflict returns `publish_conflict`, the
original pre-rebase commit, and a persisted body-free path set while leaving
the rebase intact. Conflict retry and preservation refuse owner changes outside
those resolution paths. After making and explicitly staging a semantic
resolution, rerun the same publish command. If the conflict cannot be resolved
confidently, run it with `--preserve-conflict`; Clamp safely aborts the rebase
without a hard reset and normally pushes the original commit to
`conflicts/<thread-id>/<UTC timestamp>`, returning
`publish_conflict_preserved` with exit class 3 and `preserved: true`. The CLI never sends email;
the repo-local Amp skill owns the one permitted unresolved-conflict
notification.

If the conflict branch push succeeds but deleting retained local publication
refs fails, Clamp returns `publish_conflict_preserved_cleanup_pending` with
exit class 3, `preserved: true`, `cleanup_pending: true`, `cleanup_cause`, and
the same body-free branch/SHA/paths. The skill requests the same one email
because preservation is durable, while separately reporting cleanup. Rerunning
the same publish command with `--preserve-conflict` verifies that the remote
branch still points to the original commit and deletes only those retained
local refs; it never repushes. Failed verification retains the refs.

Clamp records a newly allocated conflict branch as
`preservation_pending` before its first push, not as remotely preserved. If
that push is rejected or uncertain, rerunning the same preserve command first
queries the exact recorded branch. Authoritative absence permits one normal
non-force retry of the original commit to that same branch; an existing exact
original SHA records proof without a push. Another SHA or uncertain
availability retains state and fails closed. Once `preserved: true` is recorded,
the no-repush cleanup rule above applies. Valid active Phase 7 v1 publication
state is atomically migrated on load while retaining its original commit, race
count, conflict paths, and baseline fingerprints; migration failure leaves the
v1 refs intact for retry. A v1 conflict is marked legacy-unresolved. When its
rebase was already aborted by the old CLI, a preserve retry first verifies the
exact original commit, attached main/HEAD, matching index tree, clean worktree,
absent rebase, and retained conflict/baseline path shape. It allocates a new
push-pending branch only after those checks. A mismatch or ref-allocation
failure returns a stable body-free result and retains both publication state
and owner work without reset.

Three exhausted clean races preserve the latest rebased commit on
`recovery/<thread-id>/<UTC timestamp>` and return
`publish_race_exhausted` with transient exit class 5, not content-conflict
class 3. No publication push uses force. After a successful main push, Clamp
synchronizes the exact pushed SHA. Any sync failure, including a newly advanced
remote tip, returns `publish_complete_index_stale` with exit class 6 and
`published: true`; it never reverts the successful Git publication.
If exact-SHA sync and local publication-state cleanup both fail after the main
push, Clamp instead returns
`publish_complete_index_stale_cleanup_pending` with exit class 6,
`published: true`, the exact pushed SHA, the sync cause and diagnostics, and a
separate `cleanup_cause`. The valid local publication refs remain so cleanup is
not silently forgotten. After repairing the local Git cleanup problem, rerun
the same `kb publish --thread-id ...` command: while that SHA remains durable on
main, Clamp recognizes it, retries state cleanup and exact-SHA sync, and only
then permits a later publication to start. A standalone `kb sync` can repair
the index but cannot clear publication refs.

## Phase 9 local acceptance and rollout runbook

The repeatable repository-owned acceptance entry point is:

```bash
.agents/phase9-acceptance
```

Run `.agents/setup` first in a new Orb, then stage the exact source candidate.
The runner rejects unstaged tracked changes and non-ignored untracked files;
its bounded leakage audit reads only regular blobs from the Git index. It
re-executes itself with an empty private `HOME`, an allowlist of required
variables, fixed system/repository-local tool paths, and disabled psql startup
files. Ambient PATH entries, Git/Amp/cloud/libpq configuration and credentials,
and `CLAMP_REVIEWED_PHASE7_KB` cannot reach child checks.

The runner authenticates the local PostgreSQL 15 cluster, creates and migrates
a random disposable database, builds `@all` and `@install`, validates the
repository bundle, forces the repository-owned Dune unit, integration, cram,
contract, documentation-drift, and bounded leakage tests, runs `opam lint`, and
attempts an idempotent database drop after every creation attempt. Its direct
database predicate is only an extension/ledger/key-table smoke check; exact
schema evidence comes from the migration ledger validation and the named Phase
3 suite.

One Dune case, `reviewed Phase 7 CLI cross-version migration`, is not included
by this command because no immutable reviewed old binary is repository-owned.
Its separately controlled historical evidence is complete below. The runner
never inherits or executes an old-binary path; its forced Dune invocation shows
the case as `[SKIP]`, then reports it as not included in this invocation rather
than as globally pending. It does not claim that the ordinary suite executed
the case. `--self-check` records the sanitized child environment and the
local-only commands from the normal runner control path without creating a
database.

The runner contains no Neon, OpenRouter, Amp Git fetch/publication, or email
command and makes no production credential/configuration available. This is an
environment and command-plan guarantee, not a network-namespace proof that
arbitrary future test code could make no unauthenticated network request.
The exact criterion-to-evidence matrix is in
[PLAN.md](./PLAN.md#acceptance-criteria-traceability).

### Historical compatibility boundary

The normal acceptance runner does not execute the historical Phase 7
cross-version migration case because no immutable old binary is part of the
public source tree. A future compatibility run must use a separately reviewed
old CLI in an isolated process. The runner rejects an ambient old-binary path.

### Degraded and recovery checklist

- Use local Markdown/`rg` fallback only when a structured sync/retrieval result
  says `"fallback":"local_markdown_or_rg"` and
  `"semantic_equivalent":false`; report that no semantic ranking or access
  update occurred.
- Repair an ordinary stale index with `kb sync --json`. A successful Git push
  remains durable when this fails; `publish_complete_index_stale` is not a
  rollback.
- Treat `index_state_missing` with surviving concept rows as an explicit
  administrative recovery requiring separate approval; never adopt or destroy
  those rows automatically.
- For `publish_race_exhausted`, retain the returned `recovery/` ref and do not
  email. For a genuine conflict, email once only after
  `publish_conflict_preserved` or
  `publish_conflict_preserved_cleanup_pending` proves the exact remote
  `conflicts/` ref and SHA. Cleanup retry must not repush.

### Production rollout

This public baseline contains no private rollout history or production
credentials. Before any production action, operators must review the local
suite and acceptance matrix, configure their own repository identity and
secrets, obtain explicit approval, inspect the migration ledger, verify an
exact-tip idempotent sync, exercise search/get telemetry, and test publication
and conflict preservation against their environment. Local acceptance grants
no production authority.

## External service setup

The resources can be created before implementation. Never paste their secret
values into this repository, a thread message, an issue, or normal logs.

### 1. Neon

Create a Neon Free project manually:

- **Region:** `aws-eu-west-2` (London)
- **Purpose:** Postgres content index and access telemetry
- **Database:** a supported PostgreSQL deployment
- **Extension:** pgvector 0.8.1

Neon provides both pooled and direct connection strings. Store them separately
because search uses the pooler while migrations and synchronized index writes
need a direct connection.

Do not run development migrations or destructive integration tests against the
production Neon branch.

Ordered migrations are applied explicitly through the checksum ledger and
direct connection:

```bash
kb database migrate --json
```

The command reads `KB_DATABASE_DIRECT_URL`, requires a PostgreSQL URL with
`sslmode=require` or stronger and `channel_binding=require`, applies migrations
in canonical numeric filename order, and requires the recorded ledger to be an
exact positional name/checksum prefix before applying the remaining suffix.
The transaction advisory lock is acquired before creating or reading the
ledger. PostgreSQL then holds an `ACCESS EXCLUSIVE` relation lock across exact
catalog/history validation, migration SQL, final revalidation, and commit, so
non-cooperating sessions serialize or fail safely. Changed, missing, inserted,
reordered, renamed, ambiguous, or rogue history is refused atomically. A legacy
pre-positional ledger is upgraded under the same locks only after its schema and
ordered history prove an exact prefix.
Migration 0001 must also match its independently pinned trusted checksum before
any database connection or privileged local bootstrap. Clamp opens it once
without following symlinks, bounds and hashes bytes from that descriptor, and
revalidates descriptor/path identity; those exact retained bytes are the only
bytes it can execute. The vector extension, `public.vector` type, and public
HNSW `vector_cosine_ops` opclass must have their exact public namespace and
extension-owned catalog dependencies before application schema SQL runs.
Current and legacy
ledgers must have the exact trusted columns, defaults, constraints, indexes,
rules, and trigger-free shape; each applied migration must return exactly its
expected inserted ledger row. The locked validation reads `server_version_num`
from the migration connection: releases before PostgreSQL 18 require the
`attnotnull`-only catalog form, while PostgreSQL 18 and later require the
complete canonical system-generated NOT NULL constraint set. Cross-version,
partial, duplicate, malformed, or unexpected constraint sets are rejected.
Production migrations require explicit operator approval and are never
performed by Orb setup.
Remote URLs must use the literal lowercase `postgres://` or `postgresql://`
scheme and must not contain a URI fragment, preventing libpq from interpreting
an unrecognized URI as an ambient-default connection string.

### 2. OpenRouter

Create a credit-limited OpenRouter API key and fund the account with OpenRouter
credits. Clamp does not need an OpenAI key or OpenRouter BYOK configuration.

Embedding requests use:

```yaml
endpoint: https://openrouter.ai/api/v1/embeddings
model: openai/text-embedding-3-small
dimensions: 1536
provider_order: [openai]
allow_fallbacks: false
data_collection: deny
```

Knowledge content passes through OpenRouter to OpenAI for embedding. Provider
pinning prevents a fallback from silently changing the vector space.

### 3. Amp project secrets

Add these secrets to the Clamp Amp project:

| Secret | Value |
| --- | --- |
| `KB_DATABASE_URL` | Neon pooled connection string |
| `KB_DATABASE_DIRECT_URL` | Neon direct connection string |
| `OPENROUTER_API_KEY` | Credit-limited OpenRouter API key |

No Neon account API key, OpenAI API key, OpenRouter BYOK key, or notification
email address is required in the repository or Orb environment.

## Orb development environment

Every fresh Orb runs `.agents/setup`. It:

- installs checksum-pinned opam and creates a repo-local switch with the pinned
  OCaml compiler and locked Dune/project dependencies;
- installs PostgreSQL 15 client/server/build prerequisites when missing;
- builds pgvector 0.8.1 for local PostgreSQL when missing;
- creates an ephemeral local `clamp_test` database and applies the same
  ledger-managed schema migrations (pgvector's local PostgreSQL 15 installation
  requires one administrator bootstrap step before migration 0001 is recorded);
- tunes only that local database for disposable test performance;
- reports required project secrets as present or missing without printing
  values; and
- does not contact or mutate Neon or OpenRouter.

Local setup and `kb database migrate --local-database NAME` read the
Debian-managed PostgreSQL 15 `main` cluster's configured port through
`pg_conftool`, require its canonical `/var/run/postgresql` socket and
`/var/lib/postgresql/15/main` data directory, and pass the socket endpoint
explicitly. They clear ambient libpq target/service variables and authenticate
the connected server's version, port, Unix transport, and exact data directory
inside every setup writer session immediately before mutation; the local
migration owner repeats the check in the migration transaction. Resume performs
the same authenticated identity check before reporting ready. Local database
names are identifiers only; connection strings and service names are rejected.
There is no TCP or ambient-service fallback.

Migration transactions set `search_path` locally to `pg_catalog, public` before
evaluating SQL and use schema-qualified ledger, catalog, and application
objects. Direct URLs containing libpq `options` are rejected rather than
allowing connection options to influence the pre-transaction environment.

The switch is retained in Orb snapshots, so subsequent setup runs reuse it.
Setup installs `kb` into the
repo-local switch and adds that switch's `bin` directory to clean-login
`PATH`. Use `opam exec -- dune build @all` and `opam exec -- dune runtest` so
tools and dependencies always come from the repo-local switch.

Neon and OpenRouter do not require language-specific SDKs. The synchronous
database boundary uses libpq-backed PostgreSQL bindings with bounded connection
and transaction-scoped statement timeouts. A single monotonic connection
deadline covers bounded out-of-process DNS resolution, every accepted host and
address, nonblocking libpq polling, retry backoff, and cleanup. Clamp retains
the accepted URL's authentication and TLS settings while internally adding the
resolved `hostaddr` targets and a one-second libpq connect timeout. Resolved
targets start in configured preference order with a 250 ms stagger and are
polled concurrently; the first fully authenticated TLS connection wins and all
losing connections are closed. This prevents one slow address from consuming
the deadline without reordering resolver preference. All surfaced errors are
credential-free. A failed or timed-out DNS lookup, unreachable network/route,
or unavailable preferred IPv6 address cannot prevent a later healthy IPv4
address or host from being attempted. Resolver children are killed and reaped
with deadline-bounded nonblocking polling. Retry jitter uses a self-seeded state
that is renewed after a process fork rather than OCaml's process-global default
random state.
Pooled Neon reads must avoid
session state and named prepared statements; advisory locks, synchronization
writes, and migrations use the direct URL. The implemented-under-review
OpenRouter client uses bounded libcurl-backed HTTPS.
`.agents/resume` performs only a fast readiness check and restarts local
PostgreSQL after an Orb wakes. The local test database is available through the
default Unix socket:

```bash
psql --dbname clamp_test
```

Run the lifecycle scripts directly when changing them:

```bash
.agents/setup
.agents/setup   # the second run verifies idempotence
.agents/resume
```

## Knowledge and task model

The `knowledge/` directory is the OKF bundle. A concept's identity is its path
relative to that directory without `.md`. Paths remain stable when titles,
values, or task states change.

Daily journal entries are indexed concepts stored at
`knowledge/journal/<year>/<date>.md`, using the `Africa/Johannesburg` calendar
date in `YYYY-MM-DD` form. An ID-less `kb add` reports the first write as added
and a repeated same-day journal write as updated; the stable JSON contract
remains `concept_added` with the canonical journal ID in both cases.

OKF `generated.by` records who produced the current document content. Clamp's
`clamp.asserted_by` extension records who originated the claim. This avoids
misrepresenting an agent-authored transcription of a user statement as a
human-authored document.

Tasks are ordinary `type: task` concepts with Clamp lifecycle metadata. The
generated root `TODO.md` shows active tasks in `doing`, `blocked`, and `todo`
sections. Completed and cancelled tasks remain in their concept files and are
available through explicit history queries. Task times display in
`Africa/Johannesburg`.

## Durability and failure behavior

- A knowledge update is durable only after it reaches `origin/main`.
- Force-pushing is forbidden.
- An unresolved content conflict is preserved on a `conflicts/` branch before
  the active Amp agent emails the thread owner with a direct thread link.
- Preserved-conflict cleanup failure is reported separately and retried only
  after verifying the exact remote conflict branch/original commit; retry does
  not repush.
- Three exhausted clean push races preserve the latest rebased commit on a
  `recovery/` branch without sending conflict email.
- A successful Git push is never reverted because indexing failed.
- If the index is stale or lost, synchronization reconstructs concept rows and
  embeddings from Git.
- Access counts and last-accessed timestamps are intentionally lossy; losing
  them does not lose knowledge.
- If external services are down, Markdown and generated task views remain
  locally searchable.

If `index_state` is missing while `concepts` still contains rows, sync returns
`index_state_missing` without fetching content for embedding or mutating the
database. Those rows have no authenticated repository identity and are not
adopted. V1 recovery is a deliberate administrative operation that destroys
the derived index and lossy telemetry, then rebuilds from Git. After obtaining
explicit approval for the target database, connect with the direct URL and run:

```sql
BEGIN;
SELECT pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('github.com/gvrooyen/clamp', 0)
);
TRUNCATE TABLE public.access_stats, public.concepts;
DELETE FROM public.index_state;
COMMIT;
```

Then run `kb sync --json`. Substitute the exact configured
`source_repository` for another repository. Never print the direct URL, and do
not perform this destructive procedure against production without separate
explicit approval. Phase 5 intentionally adds no automated repair command.

## Development

The native executable, local behavior, and database boundary use Dune,
Alcotest, Dune cram tests, and disposable local PostgreSQL integration tests:

```bash
opam exec -- dune build @all
opam exec -- dune build @install
opam exec -- dune runtest
opam lint clamp.opam
.agents/phase9-acceptance  # hermetic local checks
```

Environment setup and local acceptance are documented above. During review:

1. follow [AGENTS.md](./AGENTS.md);
2. treat [PRD.md](./PRD.md) acceptance criteria as the definition of done;
3. keep the README accurate about implemented versus planned behavior;
4. keep secrets outside the repository; and
5. test against local or isolated database resources, never the production
   Neon branch.

## Production release

Version 0.1.0 is distributed as `clamp-0.1.0-linux-x86_64.tar.gz`. The archive
contains a stripped native `bin/kb` and its non-system shared libraries. It
requires only an x86_64 Linux environment with glibc 2.36 or newer; a fresh Orb
does not need OCaml, opam, libpq, or libcurl installed to run it.

After downloading the archive and its `.sha256` file from the GitHub release:

```bash
sha256sum --check clamp-0.1.0-linux-x86_64.tar.gz.sha256
tar -xzf clamp-0.1.0-linux-x86_64.tar.gz
./clamp-0.1.0-linux-x86_64/bin/kb --version
```

The binary operates on a Clamp checkout. Run it from the checkout or pass
`--repo /path/to/clamp`. Keep the extracted `bin/` and `lib/` directories
together because the executable resolves its bundled libraries relative to
itself.

`release/build` creates and validates the archive locally from the committed
opam lock and runs the unit suite in Dune's release profile. The canonical
container builder additionally fixes the Debian build image by digest, Debian
package snapshot, opam executable checksum, opam repository commit, OCaml
version, and transitive OCaml dependencies. After an exactly matching
`v<dune-project version>` tag and commit are present on `origin`,
`release/publish` verifies the clean source, remote refs, and archive checksum
before publishing the archive and checksum to the corresponding GitHub release.

Clamp is distributed under the [MIT License](./LICENSE). Package metadata points
to the intended public repository at `github.com/gvrooyen/clamp`.

## References

- [Open Knowledge Format v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf)
- [Amp Orbs](https://ampcode.com/manual/orbs)
- [OCaml](https://ocaml.org/)
- [opam](https://opam.ocaml.org/)
- [Dune](https://dune.build/)
- [Neon pgvector](https://neon.com/docs/extensions/pgvector)
- [OpenRouter embeddings](https://openrouter.ai/docs/api_reference/embeddings)
- [OpenRouter: OpenAI Text Embedding 3 Small](https://openrouter.ai/openai/text-embedding-3-small)
