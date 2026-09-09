# PRD: Clamp Agent Knowledge Base

## Status

Clamp v1, Phases 0–9, and the pinned 0.1.2 production-release build are
implemented. The blocking product and architecture decisions are resolved;
retrieval coefficients remain tunable operational defaults rather than product
invariants. Repository-owned acceptance is local-only; production deployment
and release-tag publication remain operator-controlled.

## Product summary

Clamp is a personal, agent-managed knowledge base designed to run inside Amp
Orbs. A thread uses a repo-local Amp skill and CLI to search, read, create, and
update knowledge. Durable knowledge is stored as human-readable Markdown in
this Git repository and pushed directly to its default branch. An external
Postgres database with pgvector provides a fast, disposable content index plus
lossy access telemetry.

Orbs are compute substrates, not storage substrates. They sleep when idle,
fresh threads receive fresh checkouts, and local commits are not durable until
they reach the remote repository. The remote `origin/main` tip is therefore the
only authoritative version of the knowledge store.

## Goals

1. Keep durable knowledge in an OKF v0.2-compatible, human-readable,
   Git-versioned store that survives every individual Orb.
2. Let an Amp thread search and retrieve relevant knowledge with low latency,
   without embedding or scanning the full corpus for every query.
3. Let an Amp thread safely update knowledge and tasks, publish the update to
   `origin/main`, and synchronize the external index.
4. Distinguish who produced a document from who asserted and verified its
   claims.
5. Organize concepts through stable paths and ordinary Markdown links without
   requiring an offline clustering process.
6. Include practical task management through one concept file per task and a
   deterministic, generated `TODO.md` view.
7. Recover cleanly from a lost or stale index without risking the Git source of
   truth.

## Non-goals for v1

- Multi-tenant or multi-user knowledge storage.
- General-purpose enterprise knowledge catalog functionality.
- Fully automatic semantic resolution when two Orbs modify the same concept.
- Recurring tasks, reminders, or scheduled due-date notifications.
- A background index daemon, Git hook, or polling service.
- Chunking a concept into multiple embeddings.
- Automated link suggestions or batch clustering.
- Weighting trust tiers in retrieval ranking.
- Guaranteed email delivery independently of the active Amp agent.
- Preserving access telemetry if the external database is lost.

## Architecture and durability model

```text
┌─────────────────────┐
│ Amp thread in Orb   │
│ repo-local KB skill │
└──────────┬──────────┘
           │ invokes
           ▼
┌─────────────────────┐       publish       ┌───────────────────────────┐
│ Native OCaml `kb`   │────────────────────▶│ Git `origin/main`         │
│ CLI                 │                     │ authoritative OKF bundle  │
│ - search / get      │◀────────────────────│ under `knowledge/`        │
│ - add / edit        │       checkout      └─────────────┬─────────────┘
│ - task management   │                                   │ sync exact SHA
│ - publish / sync    │                                   ▼
└──────────┬──────────┘                     ┌───────────────────────────┐
           │ embed                          │ Neon Postgres + pgvector  │
           ▼                                │ - derived content index   │
┌─────────────────────┐                     │ - lossy access telemetry  │
│ OpenRouter API      │                     │ - index checkpoint        │
│ openai/text-        │                     └───────────────────────────┘
│ embedding-3-small   │
└─────────────────────┘
```

The system has three data classes:

1. **Durable knowledge:** concept Markdown and configuration committed to
   `origin/main`. This is the source of truth.
2. **Derived index data:** parsed metadata, bodies, and embeddings in
   Postgres. This is fully reconstructable from Git plus the configured
   embedding model.
3. **Operational telemetry:** access counts and last-accessed timestamps in
   Postgres. This is deliberately not written to Git. Losing it degrades
   ranking to semantic and content-date signals but does not lose knowledge.

Postgres as a whole is therefore not described as a fully rebuildable cache;
only its concept index is rebuildable. Neon-managed recovery is useful for
telemetry, but telemetry loss is an accepted v1 failure mode.

## Production distribution

The 0.1.2 release provides a stripped native Linux x86_64 `kb` executable,
bundles its non-system shared-library closure, and carries the authoritative
migrations and source-free private-repository templates. A fresh Amp Orb with
glibc 2.36 or newer must run `kb --version`, `kb --json --help`, and `kb init`
from the extracted archive without installing OCaml, opam, libpq, or libcurl.
The executable uses an origin-relative RPATH so its libraries do not modify the
process environment or affect Git subprocesses.

The canonical release build pins the container image digest, Debian archive
snapshot, opam binary checksum, opam-repository commit, OCaml compiler, Dune,
and all transitive OCaml packages. It emits a deterministic tar archive, a
SHA-256 checksum, bundled-library versions, and applicable third-party license
notices. A release tag must exactly match the version declared by the Dune
project and executable. The publisher must verify that the local commit, remote
main, and remote release tag agree before creating a GitHub release. Tag and
release publication remain operator-controlled external actions.

## Repository layout

```text
clamp.yaml                         # versioned behavior and ranking config
TODO.md                            # generated; never edited directly
knowledge/                         # OKF v0.2 bundle root
├── index.md                       # optional OKF progressive-disclosure index
├── facts/
├── preferences/
├── people/
├── projects/
├── decisions/
├── journal/
│   └── <year>/
│       └── <date>.md              # one daily journal entry
└── tasks/
    └── <ulid>-<initial-slug>.md   # stable path; one task per file
```

Files outside `knowledge/`, including this PRD and the generated root
`TODO.md`, are not OKF concepts and are not indexed. Within the bundle,
`index.md` and `log.md` are reserved OKF documents and are excluded from
concept indexing. A log may use parseable OKF frontmatter (for example,
`type: Log` and a title); its Markdown structure is one leading H1 followed by
a flat, newest-first sequence of H2 date groups.

## Requirement 1: OKF-compatible Git knowledge store

The `knowledge/` directory is an [OKF v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
bundle. Every non-reserved Markdown file has parseable YAML frontmatter and a
non-empty `type`. A concept ID is its bundle-relative path without `.md`; for
example, `knowledge/projects/clamp.md` has concept ID `projects/clamp`.

### Standard OKF fields

Clamp uses these standard fields with their OKF semantics:

- `type` — required, non-empty concept category.
- `title`, `description`, `tags` — optional descriptive metadata.
- `generated: { by, at }` — who produced the current document content and
  when it last changed meaningfully. It does **not** identify who originally
  asserted the claim.
- `verified: [ { by, at } ]` — independent confirmation events. Clamp always
  writes list form even though OKF consumers also accept a single mapping.
- `status` — `draft`, `stable`, or `deprecated`; omission means `stable`.
- `stale_after` — absolute `YYYY-MM-DD` date. A concept is stale when the
  current date in `Africa/Johannesburg` is greater than or equal to this date.
- `sources` — optional source mappings. Every entry has a `resource`; other
  OKF credibility fields may also be present.

`generated.by` is `human:owner` only when the user literally authored or
edited the document content. Content written by the Amp agent uses
`amp/agent`; a more specific producer/version may be used only when the runtime
can identify it reliably.

A `verified.by: human:owner` event records direct current-user authority,
not agent review. `kb verify` requires
`--verification-authority user-explicit`, which the skill may assert only when
the authenticated current user directly requested verification of that concept
or directly confirmed its exact current content. Missing authority and
agent-only authority fail before mutation with stable JSON codes.

### Clamp extension namespace

Application-specific metadata lives under one OKF-compatible extension key:

```yaml
clamp:
  asserted_by: human:owner
  superseded_by: preferences/replacement-concept  # optional
```

`clamp.asserted_by` records who originated the claim represented by the
concept. Its value is normally `human:owner` for an explicit user statement
or `amp/agent` for an agent inference. This remains independent of
`generated.by`, which records document production.

Unknown frontmatter keys must be preserved when a document is round-tripped.
Clamp must not redefine standard OKF keys with incompatible shapes.

### Initial taxonomy

The supported v1 taxonomy is:

- `fact`
- `preference`
- `person`
- `project`
- `decision`
- `journal`
- `task`

OKF permits unknown types. Validation of an already-persisted non-empty unknown
type emits a deterministic warning, not an error. Explicit intent is enforced
only when a future mutation or import supplies that type; no authorization
marker is persisted in the concept.

### Validation safety ceilings

Clamp v1 applies fixed, non-configurable resource ceilings while loading local
configuration and bundles: 8 MiB per `clamp.yaml`, concept, or reserved file;
64 levels and 100,000 nodes per YAML document; 10,000 Markdown files and
100,000 Markdown links per bundle; and 1,000 returned diagnostics. Exceeding a
ceiling produces a stable, body-free validation diagnostic. These limits are
product safety boundaries, not `clamp.yaml` tuning parameters. If more than
1,000 diagnostics are found, validation fails with body-free
`diagnostic_limit` plus the 999 smallest diagnostics in stable order.

Every accepted finite YAML integer or decimal float is normalized without
binary floating-point conversion and persisted as an exact JSON number, never
as a JSON string. This includes signed decimal and binary/octal/hex integers,
underscores, decimal fractions, and decimal exponents. Clamp normalizes signs,
leading zeroes, negative zero, and insignificant fractional zeroes without
changing the value. The normalized value must fit PostgreSQL `numeric`: at
most 131,072 digits before and 16,383 digits after the decimal point. The
fixed file and database limits bound otherwise arbitrary-precision conversion.
Non-finite values fail with `numeric_non_finite`; values outside those limits
fail with `numeric_out_of_range`. Both fail before embedding or index mutation.

All bundle-relative path components must be valid UTF-8, portable, and
URI-safe. Validation does not follow symlinks, accepts only regular files, and
detects file identity or size changes across its bounded read. This applies to
`clamp.yaml`, concepts, and reserved documents.

### Daily journal entries

Daily journal entries use the stable path
`knowledge/journal/<year>/<date>.md`. `<year>` is the four-digit year and
`<date>` is the full ISO `YYYY-MM-DD` date in `Africa/Johannesburg`, for example
`knowledge/journal/2026/2026-08-05.md`. There is at most one journal concept per
local calendar date, and it uses `type: journal`. Journal entries are ordinary
indexed OKF concepts, not reserved log documents.

### Identity and updates

- One file represents one enduring subject, not one historical value.
- A changed value for the same subject edits the existing file. Git retains
  the old value in history.
- Paths are stable and should not be renamed merely because a title or value
  changed.
- A genuinely distinct replacement receives a new file. The old concept is
  marked `status: deprecated` and receives `clamp.superseded_by` in the same
  commit.
- Relationships use ordinary Markdown links. The surrounding prose describes
  the relationship; v1 does not introduce typed graph edges.
- OKF bundle-absolute links such as `/facts/example.md` resolve from the
  `knowledge/` root. Relative links that traverse outside that root remain
  ordinary non-concept repository links.
- A semantic edit made without renewed confirmation clears prior `verified`
  events because those events described the previous content. Formatting-only
  or link-only edits may preserve them. A user-confirmed semantic edit records
  a new human verification event.
- For task verification classification, `state`, `priority`, and the
  state-coupled `completed_at` field are lifecycle-only. Changes to `due_on`,
  `due_at`, `depends_on`, or unknown task metadata are semantic and clear stale
  verification.

## Requirement 2: Assertion and confirmation policy

The repository-level `inferred_writes` setting controls inferred knowledge:

- `confirm` — the default. The skill asks the user before persisting an
  agent-inferred fact or inferred task.
- `auto_draft` — the agent may persist an inference without asking. The
  newly created concept uses `status: draft`, `clamp.asserted_by: amp/agent`,
  and no human verification entry. Editing an existing concept preserves its
  stored lifecycle status exactly. Semantic edits clear stale verification;
  formatting-only or link-only edits preserve the exact prior verification
  events. Caller-supplied status never changes an existing concept's status,
  and only `kb deprecate` transitions a concept to `deprecated`.

Only an explicit user instruction may change this setting. An agent may not
suppress future confirmation merely because prior confirmations were granted.

Explicit user statements may be persisted without a second confirmation. For
agent-authored Markdown representing such a statement:

```yaml
generated: { by: amp/agent, at: 2026-08-04T12:00:00Z }
clamp:
  asserted_by: human:owner
```

When the user confirms an agent inference, the concept retains its true
assertion origin and gains a human verification:

```yaml
generated: { by: amp/agent, at: 2026-08-04T12:00:00Z }
verified:
  - { by: human:owner, at: 2026-08-04T12:05:00Z }
clamp:
  asserted_by: amp/agent
```

The index derives the standard OKF trust tier from `verified`:

- no verification events: `unverified`
- only non-human verifiers: `machine-confirmed`
- at least one `human:` verifier: `human-reviewed`

Trust tier and assertion origin are returned to consumers but do not affect
the v1 retrieval score.

## Requirement 3: Task management and generated TODO view

Every task is a stable OKF concept under `knowledge/tasks/`. The filename starts
with a ULID to avoid collisions between Orbs and includes an initial readable
slug. The file is never moved when its state changes.

Clamp uses standard ULID timestamp encoding: the 48-bit millisecond prefix
sorts chronologically across different milliseconds, followed by 80 bits of
collision-resistant random entropy. Generation is stateless; monotonic order
within one millisecond is neither guaranteed nor required.

Task lifecycle metadata is a Clamp extension rather than an overload of OKF's
`status` field:

```yaml
---
type: task
title: Provision the Clamp database
description: Create the external Neon database and configure project secrets.
generated: { by: amp/agent, at: 2026-08-04T12:00:00Z }
status: stable
clamp:
  asserted_by: human:owner
  task:
    state: todo
    priority: normal
    due_on: 2026-08-10
    # due_at: 2026-08-10T15:00:00+02:00  # mutually exclusive with due_on
    depends_on: []
    # completed_at: 2026-08-09T11:30:00Z
---
```

Task rules:

- `state` is one of `todo`, `doing`, `blocked`, `done`, or `cancelled`.
- `priority` is one of `low`, `normal`, `high`, or `urgent`; default is
  `normal`.
- `due_on` is an optional all-day date. `due_at` is an optional RFC 3339
  timestamp. They are mutually exclusive.
- `depends_on` is an optional list of concept IDs, normally other tasks.
- `completed_at` is required when state becomes `done` and absent otherwise.
- Timestamps are stored with offsets or as UTC and displayed in
  `Africa/Johannesburg`.
- An inferred task follows the same confirmation policy as any other inferred
  concept.
- The agent may mark a task done without asking when it directly performed and
  verified the work, or when the user explicitly said it was complete. In
  other cases it asks before closing the task.
- v1 has no recurrence or proactive reminders.

`TODO.md` is a deterministic generated projection, not a source of truth. It:

- contains a prominent generated-file warning;
- links to task concept files;
- shows `doing`, `blocked`, and `todo` sections;
- omits `done` and `cancelled` tasks by default;
- marks overdue and unverified draft tasks;
- sorts within a section by priority descending, due date/time ascending, then
  title and concept ID;
- is regenerated after every task mutation and when resolving a rebase
  conflict involving `TODO.md`.

Direct edits to `TODO.md` are unsupported and overwritten by regeneration.
Completed and cancelled tasks remain in their stable concept files and are
available through explicit task/history queries.

Mutation input is one complete UTF-8 Markdown document supplied through
exactly one of `--input <path>` and `--stdin`; authority is supplied separately
with `--claim explicit|inferred`. A confirmed inference additionally requires
`--confirmed`; an explicitly supplied unknown type requires
`--allow-unknown-type`. The CLI canonicalizes producer, assertion,
verification, status, and current timestamps rather than trusting authority
metadata in the supplied document. Before creating managed directories or
replacing files, Clamp serializes the final canonical document once, enforces
the 8 MiB output ceiling, and reparses and revalidates those exact bytes under
the Phase 1 frontmatter, YAML depth, and YAML node limits. `task done` requires
one explicit `--closure-authority` value: `performed-and-verified`,
`user-explicit`, or `confirmed`. Changing `inferred_writes` requires
`--direct-user-intent`. `kb verify` separately requires
`--verification-authority user-explicit`; agent inspection or successful tests
cannot supply that human authority.

`kb deprecate` also requires `--claim explicit|inferred`; a new or changed
`--superseded-by` relationship is a semantic assertion and follows the same
confirmation policy. Omitting `--superseded-by` leaves any existing
relationship unchanged. Clearing a relationship requires a complete `kb edit`
document. Status-only deprecation is idempotent and preserves verification;
adding or changing the relationship clears stale verification. An explicit
relationship records `clamp.asserted_by: human:owner`. A confirmed inferred
relationship records `clamp.asserted_by: amp/agent` and appends a fresh human
verification event after clearing stale events.

Readers take a shared Linux `flock` and writers take an exclusive `flock` on
the already-open repository-root directory inode; no lock pathname is used.
Clamp reopens and revalidates the root path before reporting success. The
ignored `.clamp/transactions/<128-bit-random>/` namespace contains every
operation's prepared entries, receipts, displaced targets, and quarantine.
Clamp accepts that private chain only when every directory is owned by the
effective UID and has mode `0700`. Clamp-created private files have mode `0600`.
A descriptor-retained original displaced by atomic exchange narrowly retains
its exact public mode while inside that `0700` chain so hard-link aliases are
not mutated; its identity and exact saved bytes are verified immediately before
private cleanup.
Other same-UID processes are contractually forbidden from modifying `.clamp/`;
these mode checks do not claim kernel isolation from a prohibited same-UID
actor. Any ownership, mode, identity, or linkage mismatch fails closed before
public mutation or returns `rollback_state_uncertain` during recovery.
Task and TODO replacement is serialized by that repository lock. Both
outputs are validated and fsynced as temporary files, then the task is renamed
before TODO. Reported ordinary I/O failures restore the previous bytes (or
remove a newly created task and TODO), clean up temporary files and newly
created empty directories, and verify the final snapshots. After bounded
recovery, rollback is reported as successful only after a restoring rename or
removal, directory fsync, exact snapshot verification, and verified cleanup of
all operation-owned temporary files. Linux `renameat2` no-replace/exchange
operations atomically install or capture entries; there is no check-then-
destruct sequence and no fallback to ordinary replacing rename when those
capabilities are unavailable. Cleanup first moves an entry without overwrite
to a random operation-private quarantine name, verifies the captured identity
and bytes, then removes it and fsyncs the parent. Clamp revalidates the complete
root-to-transaction private chain and root-to-leaf managed directory chain
before installation, private destruction, and success. New managed
directories are created under private random names and installed without
replacement, so an `EEXIST` winner is adopted rather than recorded as owned. A
foreign replacement or detached ancestor is preserved and returns
`rollback_state_uncertain` or `repository_changed`.
Any unverifiable final state returns
`rollback_state_uncertain` instead of claiming rollback. An abrupt process or
host crash between the two renames may leave TODO drift, which `kb validate`
detects and `kb todo` repairs; v1 deliberately uses no write-ahead marker.

## Requirement 4: Agent interface

The implementation is a native OCaml CLI named `kb`, accompanied by a
repo-local Amp skill. There is no v1 MCP server, plugin, or long-running
service.

The CLI provides at least:

- `kb init` — create a source-free private knowledge repository from a pinned
  Linux x86-64 runtime release, without creating or pushing a remote.
- `kb search <query>` — semantic search returning metadata and snippets.
- `kb get <concept-id>` — return full concept content and record an access.
- `kb add`, `kb edit`, `kb verify`, `kb deprecate` — concept mutations.
- `kb task add|list|start|block|done|cancel` — task lifecycle operations.
- `kb todo` — regenerate or print the TODO view.
- `kb validate` — validate bundle, links, extensions, and generated files.
- `kb sync` — synchronize the remote default branch into Postgres.
- `kb publish` — validate, commit managed knowledge changes, rebase, push, and
  invoke sync for the pushed commit.
- `kb config set inferred-writes <confirm|auto_draft>` — change the inference
  policy after an explicit user instruction.

Commands offer machine-readable `--json` output so the skill can distinguish
validation, conflict, authentication, network, and indexing failures without
parsing prose.

The public distribution also provides a Linux x86-64 runtime archive containing
only the native executable, authoritative migrations, private-repository
templates, license, and exact version/revision markers. `kb init` copies those
templates into a newly initialized private Git repository and records a
four-field runtime lock (version, revision, HTTPS release URL, and SHA-256).
Initialization records all durable generated files in a hook-free initial
commit under a generic local-only author identity. Empty taxonomy directories
are recreated by setup because Git does not track directories. The generated
setup verifies and installs that exact archive outside the private repository;
it never checks out or builds the implementation source.
V1 does not create a remote, push, migrate production, synchronize production,
or make an embedding request during initialization or setup.

The repo-local `managing-clamp-knowledge` Amp skill instructs an agent to:

1. use `kb search` and `kb get` instead of scanning blindly;
2. follow assertion and confirmation policy before writes;
3. use task commands rather than editing `TODO.md`;
4. publish completed knowledge mutations to `origin/main`;
5. fall back to local Markdown and `rg` when external services are unavailable;
6. invoke Amp's email capability after the CLI preserves an unresolved
   conflict, as specified below.

## Requirement 5: Publication, direct pushes, and conflict notification

The remote `origin/main` tip is the only durable source of truth. Local files,
the current branch name, and unpushed commits are not authoritative.

The publication sequence is:

1. Regenerate `TODO.md` when tasks changed.
2. Validate all managed changes.
3. Stage only `knowledge/**`, `TODO.md`, and versioned Clamp configuration.
4. Refuse to continue if publication would push unrelated unpublished commits
   or stage unrelated working-tree changes. A clean local main may equal or be
   an ancestor of the already-known `origin/main` tracking ref; refuse local
   history that is ahead of or diverged from that ref.
5. Commit the managed change with the Amp project's configured author.
6. Fetch `origin/main` and rebase the commit onto it.
7. Resolve a `TODO.md` conflict by regenerating it from the merged task files.
8. Let the agent attempt a semantic resolution for genuine concept conflicts.
9. Push normally to `origin/main`; force-push is forbidden.
10. If another writer wins the race, fetch/rebase/retry, up to three attempts.
11. After a successful push, run `kb sync` against the exact pushed SHA.

The intended discipline is one active writer, but the workflow safely detects
races. Directory layout and one-file-per-task reduce collisions; they do not
pretend to solve simultaneous edits to the same concept.

If all three push attempts lose a clean race without producing a content
conflict, push the latest rebased commit without force to
`recovery/<thread-id>/<YYYYMMDDTHHMMSSZ>`. Return the recovery branch and commit
SHA under a distinct `publish_race_exhausted` result and leave the pending
change out of `origin/main`. This is durable preservation, not a content
conflict, so it does not send conflict email.

### Unresolved conflicts

If the agent cannot resolve a genuine content conflict confidently:

1. Abort the rebase so the original local commit is intact.
2. Push that commit to
   `conflicts/<thread-id>/<YYYYMMDDTHHMMSSZ>` so the work survives the Orb.
3. Return a structured conflict result containing the conflict branch, commit
   SHA, and conflicting paths.
4. Use Amp's email capability to email the current thread owner with:
   - subject: `[Clamp] Knowledge update needs conflict resolution`;
   - a direct link to the current Amp Orb thread;
   - the conflict branch and commit SHA;
   - the conflicting paths, but no knowledge content or secrets.

The recipient is derived from the authenticated Amp thread owner rather than a
hard-coded address, so no recipient email address is stored in this repository.

Before the first conflict-branch push, Clamp durably records the allocated
branch as push-pending without claiming preservation. A failed or uncertain
push returns body-free `preservation_pending: true` with the original commit,
recorded branch, and paths. On the same preserve-command retry, Clamp first
queries that exact remote branch. If it is authoritatively absent, retry the
same original-commit-to-recorded-branch non-force push; if it already resolves
to the original commit, record proof without repushing. Another SHA or uncertain
availability retains state and fails closed. After proof is recorded, the
result includes `preserved: true` and no preservation retry may repush.

If atomic cleanup of the retained local publication refs after proof
fails, return `publish_conflict_preserved_cleanup_pending` with conflict exit
class, `cleanup_pending: true`, `cleanup_cause`, and the same body-free branch,
original commit, and paths. This still permits the one preservation-gated email
because durable preservation succeeded; cleanup is a separate obligation.
Rerunning the same `kb publish --preserve-conflict` command verifies that the
recorded remote branch still resolves to the original commit, then atomically
removes only the retained local refs. It does not push again. A verification
mismatch or external verification failure retains local state and never
silently loses or replaces the durable identity.

Publication-state loading accepts the reviewed Phase 7
`clamp-publish-state-v1` format and atomically migrates it to the current format
without changing the original commit, race count, conflict paths, or conflict
baseline fingerprints. A v1 conflict maps to an explicit legacy-unresolved
state. If its rebase is active, normal conflict resolution/preservation
continues. If legacy Clamp already aborted the rebase, `--preserve-conflict`
first proves that original commit, attached main/HEAD, index tree, clean
worktree, absent rebase, and retained conflict/baseline path shape are the exact
safe post-abort state. Only then does Clamp atomically allocate a new
push-pending branch and enter the ordinary exact-original preservation flow.
An unprovable state or allocation failure retains all refs and owner bytes and
returns a stable body-free result; it never hard-resets or returns generic
invalid-state for that accepted legacy shape. A migration update verifies both
retained refs and replaces only the state blob in one ref transaction; failure
leaves the valid v1 refs intact and retryable.

Email is sent only for unresolved Git content conflicts. Authentication,
network, OpenRouter, Neon, and post-push index failures are reported in the
active thread without email. Amp-based email is best-effort; an independent
external email provider is outside v1.

If Git publication succeeds but indexing fails, the Git commit remains valid
and must not be reverted. The index checkpoint remains unchanged, the thread
reports that the index is stale, and a later sync repairs it.

Local publication-state cleanup and exact-SHA synchronization have four
explicit terminal combinations after a durable main publication. Success of
both returns normal publication success. Cleanup failure alone retains the
exact published SHA and reports cleanup pending. Sync failure alone retains the
exact published SHA and reports the stale index. If both fail, return
`publish_complete_index_stale_cleanup_pending` with stale-index exit class,
`published: true`, the exact SHA, the sync cause and diagnostics, and a separate
cleanup cause. Keep the valid local publication refs until the same publication
command can retry cleanup; standalone synchronization does not clear those
refs. Never hide either repair obligation or misreport the durable commit as
unpublished.

## Requirement 6: Idempotent Git-to-Postgres synchronization

Full and incremental indexing use one `kb sync` algorithm. It compares the
target Git tree with Postgres rather than diffing two commits, so it works in a
fresh shallow Orb without fetching repository history.

The sync algorithm:

1. Open the direct Neon connection with bounded timeouts and acquire a Postgres
   advisory lock that serializes index writers. Retry transient connection
   failures with capped exponential backoff and jitter; do not retry
   authentication or deterministic query errors.
2. Fetch `origin/main` and select its exact commit SHA as the target. Git
   subprocesses use argument arrays, a minimal environment that excludes
   ambient repository/config/object overrides and disables replacement-object
   processing, CLOEXEC descriptors, one monotonic setup-through-reap deadline,
   bounded output, and an owned process group whose leader identity is retained
   through complete cleanup. A readiness/ACK handshake keeps the child blocked
   before exec until the parent has confirmed and anchored that process group.
   For an exact Amp HTTPS origin, use the Amp runtime's validated credential
   helper with a writable validated home, a validated `XDG_CONFIG_HOME` derived
   as `$HOME/.config`, and only the Amp API key and Amp URL required by that
   helper. Explicitly clear inherited/configured credential
   helpers and askpass behavior, keep global/system configuration disabled, and
   reject repository-local credential, HTTP proxy/header, URL rewrite/include,
   hooks-path, or upload-pack overrides before placing Amp auth in the Git
   process environment. Never place the key in argv or surfaced output. Local
   and `file://` remotes remain unauthenticated and receive no Amp auth.
   Clamp v1 requires the repository-reported object format to be SHA-1 and
   returns `git_object_format_unsupported` before fetch for another format.
3. Read and fully validate root `clamp.yaml` from that exact commit through Git
   objects. Require its `source_repository` to match the preflight/advisory-lock
   identity and `index_state`, which must also identify `refs/heads/main`;
   refuse to synchronize a different source accidentally.
4. Enumerate concept paths and Git blob IDs with `git ls-tree -r` for the target
   commit, after requiring a present root `knowledge` entry to be exactly one
   Git tree; an absent entry is an empty bundle. Read content from Git objects,
   not the mutable working tree. Read and validate reserved `index.md`/`log.md`
   bytes and include them in fixed bundle file, YAML, and Markdown-link
   ceilings, while excluding them from concept rows and embeddings.
5. Compare the tree with `concepts.path` and `concepts.blob_hash`:
   - new path: parse, embed, and insert;
   - changed blob: parse and update, re-embedding only if the deterministic
     embedding input hash changed;
   - identical blob: leave the row and access telemetry untouched;
   - database path absent from the tree: delete it.
6. Apply all concept upserts, deletions, and the checkpoint update in one
   database transaction after all required embeddings have succeeded.
7. Record the target commit, model, dimensions, and completion timestamp.
8. Release the advisory lock.

A successful sync returns `sync_complete` when it has no warnings, or
`sync_complete_with_warnings` with stably ordered body-free `diagnostics` for
persisted unknown non-empty types and invalid or unresolved Markdown links.
These `unknown_type`, `link_invalid_uri`, and `link_unresolved` warnings match
`kb validate` semantics and do not prevent index convergence. Sync uses the
same diagnostic collector as local validation. More than 1,000 warnings fails
before embeddings or mutation with `diagnostic_limit` and the 999 smallest
diagnostics rather than silently truncating the warning set.

A sync against an empty concepts table is a full rebuild. `kb sync --reembed`
forces every embedding to be regenerated. A configured model or dimensions
mismatch also forces a full re-embedding; it must never silently reuse vectors
from another model.

The expected repository identity is the required versioned
`clamp.yaml.source_repository`, not a clone URL. It is persisted exactly in
`index_state.source_repository`. If `index_state` is absent while `concepts` is
nonempty, synchronization fails closed with `index_state_missing` before fetch-
dependent embedding work or database mutation. V1 does not authenticate or
adopt those rows or their access telemetry. An operator must intentionally
clear the derived index before rebuilding; no automated repair command exists
in v1.

Deletion safeguards refuse a non-forced sync when the target tree is empty but
the index is not, or when at least ten rows and more than half the index would
be deleted. The user must explicitly approve an intentional mass deletion.

A rename is treated as delete plus add and therefore resets that concept's
access telemetry. Stable paths make this an accepted v1 tradeoff.

The skill runs sync explicitly after every successful publication and before
the first indexed retrieval in a fresh thread. There is no post-commit hook,
polling loop, or daemon.

## Requirement 7: Embedding and indexed content

Clamp buys embedding access with OpenRouter credits and calls OpenRouter's
OpenAI-compatible embeddings endpoint at
`https://openrouter.ai/api/v1/embeddings`. The model ID is
`openai/text-embedding-3-small`, with an explicit output size of 1536
dimensions. Retrieval uses cosine distance.

Requests pin the upstream provider to OpenAI, disable provider fallbacks, and
deny data collection through OpenRouter's provider-routing controls:

```json
{
  "model": "openai/text-embedding-3-small",
  "dimensions": 1536,
  "provider": {
    "order": ["openai"],
    "allow_fallbacks": false,
    "data_collection": "deny"
  }
}
```

This prevents a transient routing decision from silently changing the vector
space. Clamp does not configure an OpenAI BYOK key in OpenRouter. The persisted
model identity is `openrouter:openai/text-embedding-3-small`; the gateway,
model, dimensions, and routing policy are part of index compatibility and are
recorded with indexed state and concept rows.

One concept produces one embedding. The deterministic embedding input is:

1. `type`;
2. `title`;
3. `description`;
4. `tags`;
5. Markdown body.

Volatile or filtering metadata—such as `generated.at`, `verified`, task state,
priority, and access telemetry—is excluded. Consequently, confirming a fact or
closing a task updates indexed metadata without paying to re-embed unchanged
semantic content.

Input uses normalized LF line endings and stable field ordering. Its SHA-256 is
stored as `embedding_input_hash`. A concept exceeding the embedding provider's
input limit fails validation with guidance to split it into linked concepts;
v1 does not silently truncate or chunk it. V1 avoids an exact tokenizer
dependency by rejecting an embedding input longer than 8,000 UTF-8 bytes before
making a request. This is a conservative bound below the model's 8,191-token
limit and may reject some inputs the provider would accept. A provider
context-length rejection is mapped to the same validation result and guidance.

Postgres stores the parsed frontmatter and Markdown body as derived data so a
search result can be served consistently for the indexed commit even if the
current worktree differs.

## Requirement 8: Retrieval and access telemetry

Retrieval has two stages so pgvector's ANN index remains usable:

1. Apply normal visibility filters and use cosine distance to select the top
   semantic candidates (default `K = 100`).
2. Normalize and rerank that candidate set, returning the requested top results
   (default `N = 10`).

Normal retrieval excludes:

- `status: deprecated`;
- concepts where `today >= stale_after` in `Africa/Johannesburg`;
- tasks in `done` or `cancelled` state.

Independent explicit history flags can include each excluded class without
implicitly including the others. Draft concepts remain searchable but are
clearly labeled as drafts and unverified.

The default reranking score is:

```text
score = 0.70 * semantic + 0.20 * recency + 0.10 * frequency
```

where:

- `semantic` maps cosine similarity from `[-1, 1]` into `[0, 1]` and clamps
  out-of-range numerical noise;
- `recency = 2 ^ (-age_days / 30)`, using `last_accessed_at`, then
  `generated_at`, then `indexed_at` as fallbacks;
- `frequency = min(1, log(1 + access_count) / log(101))`, saturating at 100
  accesses so popular concepts cannot dominate indefinitely.

Candidate count, result count, weights, half-life, and frequency saturation are
versioned configuration defaults and may be tuned from observed retrieval
quality without changing the product contract. No offline scoring job is used.
V1 fixes operational bounds at `candidate_limit <= 1000`,
`result_limit <= 100`, `recency_half_life_days <= 3650`, and
`frequency_saturation_count <= 1000000`; every value is positive and the result
limit must not exceed the candidate limit. Invalid retrieval configuration
fails before database or embedding access.

Candidate selection orders only by pgvector cosine distance so the HNSW index
remains usable. Its bounded transaction enables strict-order pgvector 0.8.1
iterative scanning (and disables sequential plans for this ANN query) so
selective visibility filters continue scanning to fill the configured candidate
limit when enough visible rows exist. Final score and path tie ordering remains
pure OCaml behavior.

The ANN result initially transfers only paths, scores, timestamps, counts, and
a bounded aggregate path size. Search then preflights full indexed rows and
validates them in batches of 16 under one five-second monotonic operation
deadline. V1 fixes a non-configurable 16 MiB aggregate candidate-validation
selected-value payload budget and 9 MiB per-row payload bound, in addition to
the existing 8 MiB concept limit and same-sized corruption guards on stored
content fields. PostgreSQL protocol framing is not charged to those payload
limits; candidate count and batch size bound it, while the row estimate includes
a conservative 512-byte allowance for fixed-width selected projections not
otherwise counted exactly.
`get` applies the same preflight to its single row. An otherwise valid large
candidate set may therefore return
`retrieval_validation_limit`; deadline exhaustion returns
`retrieval_validation_timeout`. Both are structured degraded results suitable
for local Markdown/`rg` fallback, never semantic success, and neither records
access telemetry. Full candidate rows are not silently skipped.

Every retrieval transaction sets `client_encoding` locally to `UTF8` and
verifies the effective value before candidate-controlled text crosses libpq.
This defeats ambient and role/database encoding defaults without relying on
pooled session state and aligns server `octet_length` preflight bytes with the
selected value bytes delivered to the client.

Retrieval captures the already-local remote-tracking commit first and reads the
versioned root configuration from that exact Git object, never from mutable
worktree bytes. It rechecks both the database checkpoint and actual local ref at
the final search success/get telemetry boundary; a changed ref returns stale,
and `get` records no access. The same five-second deadline caps that final Git
resolution, including child cleanup, and is checked before and after it. Client
parsing, validation, reranking, and response construction are checked at every
row/batch or result boundary; one row's synchronous parsing is not preempted,
but an overrun becomes `retrieval_validation_timeout` before COMMIT dispatch.
Immediately before COMMIT dispatch, Clamp recomputes the immutable deadline and
requires at least one millisecond remaining; failed deadline admission rolls
back, so that timeout records no access. Clamp then uses blocking libpq
`PQsendQuery`; setup or send rejection remains pre-dispatch, while only an
accepted send crosses the post-dispatch uncertainty boundary. V1 deliberately
does not claim that PostgreSQL transaction-local `statement_timeout` bounds
COMMIT finalization:
deferred commit work can continue beyond it. After dispatch, the synchronous
client waits for acknowledgement, which may succeed after the local deadline;
connection loss returns `database_connection_lost` and leaves the telemetry
outcome uncertain. Callers must not infer “definitely no access” from an
in-flight connection loss or blindly retry a `get` when exact telemetry count
matters. The post-dispatch `get` message must expose both uncertainty and the
double-count risk; the post-dispatch search message exposes uncertain transaction
acknowledgement without implying telemetry was written. Pre-dispatch connection
loss retains the ordinary generic failure. Search has no telemetry but uses the
same honest transaction-finalization boundary.

`kb search` returns metadata and deterministic whitespace-normalized snippets
bounded to 240 UTF-8 bytes, with an explicit `…` truncation marker, but does not
record an access merely because a concept was an ANN candidate or search
result. Human output presents the top snippet and its source without exposing a
raw ranking value as confidence. `-v`/`--verbose` instead presents every
returned match with four-decimal ranking and component scores; those values are
ranking signals, not calibrated probabilities. The stable `--json` result is
identical in either mode. `kb get` returns the complete indexed frontmatter and body, preserving
every JSON number exactly without binary floating point, and records an access
only when that complete response has been constructed and can be returned to
the caller. Non-JSON `kb get --quiet` is rejected before retrieval;
`--json --quiet` returns the complete JSON response. The access update
atomically creates the stats row if needed, increments `access_count`, and sets
`last_accessed_at` in Postgres only.

## Requirement 9: Degraded operation and security

- If Neon or OpenRouter is unavailable, the skill falls back to local
  Markdown, `rg`, and generated `TODO.md`; semantic ranking and access updates
  are temporarily unavailable.
- The Sync boundary owns one authoritative code/kind definition for every
  fallback-eligible production `kb sync` producer. `Sync.cli_result` emits
  `{fallback: "local_markdown_or_rg", semantic_equivalent: false}` only when
  the returned code and kind match that definition. Database and OpenRouter
  adapters and direct Sync/Git constructors use the same definition; changing
  the production set or kind requires changing that source and its exact
  fixture comparison. Deterministic validation/internal failures and
  publication-only remote-ref verification are excluded.
- Database clients use bounded connection and query timeouts. They retry only
  transient initial connection failures, which can occur while Neon resumes
  idle compute; retries are capped and use exponential backoff with jitter.
- Direct PostgreSQL URLs use a literal lowercase PostgreSQL URI scheme and no
  fragment. DNS and connection attempts preserve configured host/address
  preference. Resolved targets are started in preference order with a 250 ms
  stagger and polled concurrently; the first fully authenticated TLS connection
  wins and every losing connection is closed. Resolution, connection racing,
  nonblocking child cleanup, and jittered backoff share one monotonic deadline.
  Network and route failures remain failover-eligible, and production jitter
  uses independently self-seeded per-process random state.
- If the index checkpoint differs from the target commit, indexed search warns
  or fails as stale rather than claiming freshness. A subsequent sync repairs
  it.
- Retrieval compares the checkpoint with the already-local
  `refs/remotes/origin/main` and never fetches implicitly. Missing, stale, or
  incompatible index state returns stable structured errors suitable for a
  local Markdown/`rg` fallback that does not claim semantic equivalence.
- Candidate validation that exceeds the fixed byte budget or shared deadline
  returns `retrieval_validation_limit` or `retrieval_validation_timeout` with
  the same explicitly non-equivalent fallback contract.
- Retrieval validation timeout before COMMIT dispatch rolls back. After COMMIT
  dispatch, a connection loss is a structured degraded result with uncertain
  get-telemetry outcome; operational access telemetry remains deliberately
  lossy and must not be treated as a durable exactly-once record.
- Losing the concepts table triggers a rebuild from Git. Losing access stats is
  accepted and resets recency/frequency behavior gracefully.
- Git publication is never rolled back solely because indexing failed.
- Knowledge content passes through OpenRouter to OpenAI for embedding. Both
  services process that content; this is an accepted v1 data-flow requirement.
- Database URLs and API keys live only in Amp project secrets. They must not be
  committed, included in generated files, printed in logs, or placed in email.
- `AMP_API_KEY` and `AMP_URL` are Amp runtime authentication inputs, not Clamp
  configuration. Clamp passes them only to a sanitized Git fetch whose sole
  configured credential helper is the validated Amp runtime executable.
- All Neon connections require TLS.
- Error output may include concept IDs and paths but must redact credentials and
  avoid including knowledge bodies in conflict emails.

## Postgres data model sketch

The migration files are authoritative; this sketch establishes the required
shape and invariants.

```sql
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

-- Derived from the Git bundle and fully rebuildable.
CREATE TABLE concepts (
    path                 TEXT PRIMARY KEY,
    blob_hash            TEXT NOT NULL,
    embedding_input_hash TEXT NOT NULL,
    type                 TEXT NOT NULL,
    title                TEXT,
    description          TEXT,
    tags                 TEXT[] NOT NULL DEFAULT '{}',
    body                 TEXT NOT NULL,
    frontmatter          JSONB NOT NULL,
    status               TEXT NOT NULL DEFAULT 'stable'
                         CHECK (status IN ('draft', 'stable', 'deprecated')),
    stale_after          DATE,
    generated_by         TEXT,
    generated_at         TIMESTAMPTZ,
    asserted_by          TEXT,
    verified_tier        TEXT NOT NULL
                         CHECK (verified_tier IN (
                             'unverified',
                             'machine-confirmed',
                             'human-reviewed'
                         )),
    task_state           TEXT CHECK (task_state IS NULL OR task_state IN (
                             'todo', 'doing', 'blocked', 'done', 'cancelled'
                         )),
    task_priority        TEXT CHECK (task_priority IS NULL OR task_priority IN (
                             'low', 'normal', 'high', 'urgent'
                         )),
    task_due_on          DATE,
    task_due_at          TIMESTAMPTZ,
    task_completed_at    TIMESTAMPTZ,
    embedding_model      TEXT NOT NULL,
    embedding            public.vector(1536) NOT NULL,
    indexed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (task_due_on IS NULL OR task_due_at IS NULL)
);

CREATE INDEX concepts_embedding_hnsw_idx
    ON concepts USING hnsw (embedding public.vector_cosine_ops);

-- Mutable, lossy operational telemetry. Never written back to Git.
CREATE TABLE access_stats (
    concept_path         TEXT PRIMARY KEY
                         REFERENCES concepts(path) ON DELETE CASCADE,
    last_accessed_at     TIMESTAMPTZ,
    access_count         BIGINT NOT NULL DEFAULT 0
                         CHECK (access_count >= 0)
);

-- Single-repository index identity and checkpoint.
CREATE TABLE index_state (
    id                   SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    source_repository    TEXT NOT NULL,
    source_ref           TEXT NOT NULL DEFAULT 'refs/heads/main',
    last_indexed_commit  TEXT,
    embedding_model      TEXT NOT NULL,
    embedding_dimensions INTEGER NOT NULL,
    last_indexed_at      TIMESTAMPTZ
);
```

## Configuration and external services

Versioned non-secret configuration lives in `clamp.yaml`:

```yaml
schema_version: 1
source_repository: github.com/gvrooyen/clamp
timezone: Africa/Johannesburg
inferred_writes: confirm
embedding:
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
  model: openai/text-embedding-3-small
  dimensions: 1536
  max_input_bytes: 8000
  provider_order: [openai]
  allow_fallbacks: false
  data_collection: deny
retrieval:
  candidate_limit: 100
  result_limit: 10
  semantic_weight: 0.70
  recency_weight: 0.20
  frequency_weight: 0.10
  recency_half_life_days: 30
  frequency_saturation_count: 100
```

`source_repository` is a stable non-secret identifier. It uses a lowercase DNS
host followed by a slash-separated repository path; path components may use
the literal `@` spelling required by Amp identities. It has no scheme,
userinfo, query, fragment, surrounding whitespace, trailing slash, or trailing
`.git`. Clamp never derives, persists, or exposes repository identity from the
clone URL. Local fixtures may use deterministic identities such as
`local.test/clamp-fixture`.

External services are fixed for v1:

- **Postgres:** Neon Free in `aws-eu-west-2` (London), created manually.
- **Embedding gateway and billing:** OpenRouter credits.
- **Upstream embedding model:** OpenAI `text-embedding-3-small`, pinned through
  OpenRouter as `openai/text-embedding-3-small`, 1536 dimensions.
- **Agent runtime:** Amp Orbs.

Required Amp project secrets:

- `KB_DATABASE_URL` — Neon pooled connection string for searches.
- `KB_DATABASE_DIRECT_URL` — Neon direct connection string for migrations and
  synchronization.
- `OPENROUTER_API_KEY` — credit-limited OpenRouter API key for document and
  query embeddings.

Manual Neon provisioning does not require a Neon account API key at runtime.
No OpenAI API key or OpenRouter BYOK provider key is required. The first
database migration enables pgvector; later migrations create the application
schema. Tests must not run destructive operations against the production Neon
branch.

The public baseline contains no production rollout evidence or credentials.
Operators must perform the migration, connectivity, synchronization, and
retrieval gates in their own environment with explicit approval.

## V1 acceptance criteria

1. A fresh Orb with the three project secrets can install the CLI, validate the
   bundle, synchronize the remote main branch, and search it.
2. A user-stated fact written by the agent records `generated.by: amp/agent`
   and `clamp.asserted_by: human:owner`.
3. With `inferred_writes: confirm`, the skill does not persist an inference
   before the user confirms it.
4. Changing the policy to `auto_draft` requires an explicit user instruction
   and causes inferred concepts to be persisted as unverified drafts.
5. Human verification is recorded only after explicit current-user authority;
   agent review alone is rejected without changing the concept.
6. A task mutation changes its stable concept file and deterministically
   regenerates `TODO.md`; manually introduced TODO drift is detected.
7. The agent may close a task it directly completed and verified without an
   extra confirmation.
8. Publishing from an out-of-date checkout fetches, rebases, and pushes without
   force. A generated TODO conflict is resolved by regeneration. Three
   exhausted clean push races preserve the latest rebased commit on a
   `recovery/` branch and do not send conflict email.
9. An unresolved concept conflict is preserved on a `conflicts/` branch and
   causes one Amp email containing a direct link to the current thread. A local
   cleanup failure reports a distinct preserved cleanup-pending result; retry
   verifies the same remote branch/SHA, does not repush, and clears only local
   publication state.
10. A shallow checkout synchronizes unchanged concepts without re-embedding
   them and without needing the previous commit object.
11. Synchronizing the same target SHA twice is idempotent and preserves access
    stats.
12. Rebuilding an empty concepts table converges to the Git tree at
    `origin/main`.
13. A semantic-content change re-embeds the concept; a verification-only or
    task-state-only change does not.
14. Deprecated, stale, and closed-task concepts are excluded from normal search
    and available through explicit historical search.
15. Search candidates do not update access stats; retrieving full content does.
16. A successful Git push is never reverted because OpenRouter or Neon failed.
17. When external services are unavailable, the skill can still locate and
    read knowledge locally.
18. No committed file, normal log, or notification email contains a database
    credential or API key.
19. Fresh-Orb setup is idempotent, provides the pinned OCaml/opam/Dune
    toolchain and a local PostgreSQL 15 `clamp_test` database with pgvector
    0.8.1, and never mutates Neon or OpenRouter.

## Deferred and tunable work

- Tune candidate count, weighting, decay, and frequency saturation using a
  retrieval evaluation set and observed usage.
- Add automated semantic-neighbor link suggestions.
- Add multi-writer coordination beyond fetch/rebase/retry and human escalation.
- Add chunked concepts if corpus documents outgrow one-embedding retrieval.
- Consider trust-tier ranking after enough verified and unverified examples
  exist to evaluate it.
- Consider recurring tasks, reminders, or scheduled task checks in a later
  product phase.
- Consider telemetry export or longer retention if access history becomes
  valuable enough to require stronger durability.
- Consider an external email provider only if conflict notification must become
  independent of the active Amp thread.
- Support additional database or embedding providers only when a concrete need
  justifies the abstraction.

## References

- Open Knowledge Format v0.1: https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing
- Open Knowledge Format v0.2: https://cloud.google.com/blog/products/data-analytics/okf-v0-2-adds-trust-signals
- OKF v0.2 specification and reference implementations: https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf
- Neon pgvector: https://neon.com/docs/extensions/pgvector
- Neon branching and restore: https://neon.com/docs/introduction/branching
- OpenRouter embeddings API: https://openrouter.ai/docs/api_reference/embeddings
- OpenRouter model page: https://openrouter.ai/openai/text-embedding-3-small
- OpenAI embeddings: https://developers.openai.com/api/docs/guides/embeddings
- Amp Orbs: https://ampcode.com/notes/putting-an-agent-in-an-orb
- Amp manual: https://ampcode.com/manual
