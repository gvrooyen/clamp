# Clamp architecture

Clamp keeps durable knowledge separate from disposable compute and derived
search state.

The product behavior and exact safety invariants are normative in
[PRD.md](./PRD.md). This document records the enduring implementation shape and
engineering boundaries. Clamp v1 is implemented; it is not an implementation
roadmap.

```text
┌──────────────────────┐
│ Amp thread           │
│ skill + native `kb`  │
└───────┬──────────────┘
        │
        ├──── publish ─────▶ Git `origin/main`
        │                     authoritative Markdown
        │
        ├──── sync ─────────▶ Neon Postgres + pgvector
        │                     derived concepts and lossy access stats
        │
        └──── embed ────────▶ OpenRouter
                              pinned OpenAI embedding model
```

## Implementation principles

- Keep Git at `origin/main` as the only durable knowledge authority. Postgres
  concept data is derived, and access telemetry is operational and lossy.
- Keep the native executable synchronous and dependency-light. Use direct,
  testable modules rather than an async framework, generic ORM, or provider
  abstraction without a concrete need.
- Make pure behavior independently testable before coupling it to filesystem,
  Git, database, or HTTP effects.
- Treat human-readable output as presentation. Stable JSON envelopes, result
  codes, and exit classes are the skill-facing contract.
- Accept mutation bodies through files or standard input so agents never need
  to shell-quote arbitrary Markdown.
- Forbid destructive tests against production databases; run required
  destructive integration coverage only against disposable local databases.
- Keep production migrations, paid embedding probes, first production
  synchronization, and release publication outside Orb setup and
  repository-owned tests.

## Source layout and module boundaries

```text
bin/                  Thin Cmdliner command wiring for `kb`
lib/                  Domain logic and direct effect modules
test/
├── unit/             Pure parser, validator, renderer, hash, and ranking tests
├── integration/      Filesystem, Git, local Postgres, and mock HTTP tests
└── fixtures/         OKF bundles, expected TODO output, and Git scenarios
db/migrations/        Authoritative ordered SQL migrations
knowledge/            Versioned OKF bundle
```

The intended responsibilities are configuration, frontmatter,
validation/serialization, tasks and TODO rendering, embedding input, ranking,
Git object access, database access, OpenRouter, synchronization, publication,
and JSON result encoding. Interfaces and test seams should exist only where
they isolate a real responsibility or controllable effect, not merely to mirror
every external dependency.

## Data ownership

Clamp has three data classes:

1. **Durable knowledge.** Concept Markdown, `clamp.yaml`, and generated
   `TODO.md` at the exact remote `origin/main` tip.
2. **Derived index data.** Parsed metadata, bodies, and embeddings in Postgres.
   These can be reconstructed from Git and the pinned embedding configuration.
3. **Operational telemetry.** Access counts and last-accessed timestamps in
   Postgres. These improve ranking but may be lost without losing knowledge.

An orb worktree, local commit, or local file is not durable until publication
reaches the remote. Conversely, Postgres is not the knowledge authority.

## Local writes

Concept and task writes are canonicalized by the CLI. It preserves unknown
frontmatter values while controlling provenance, verification, lifecycle, and
timestamps. Task changes and the generated TODO view are written as one
reported operation.

The implementation uses platform-specific no-follow traversal behind one
`Secure_fs` boundary, a lock on the open repository-root directory inode,
durably synchronized temporary files, no-replace/exchange renames, private
transaction directories, and post-write identity checks. Linux uses `O_PATH`
and `renameat2`; Darwin uses `O_EVTONLY`/`O_SYMLINK`, `renameatx_np`, and local
APFS `fsync` plus `F_FULLFSYNC`. Neither target falls back to an unsafe ordinary
overwrite. A crash can still occur between the task and TODO renames; this is
detectable `todo_drift`, repaired by `kb todo`.

The exact mutation and rollback invariants are normative in
[PRD.md](./PRD.md).

## Database and migrations

Versioned SQL migrations are authoritative. The checksum ledger rejects any
changed historical migration and idempotently baselines migration 0001 before
applying later migrations. Migration SQL remains compatible with PostgreSQL 15.

Ledger validation reads `server_version_num` through the same locked migration
connection. PostgreSQL 15 must have no `pg_constraint` rows for NOT NULL;
PostgreSQL 18 and later must have exactly the complete expected
system-generated NOT NULL constraint set. Malformed, duplicate, partial, or
additional rows fail closed.

Pooled reads use no session state or named prepared statements and set timeouts
transaction-locally. Migrations, advisory locks, synchronization writes, and
other stateful operations use the direct URL.

## Runtime distribution

Source-free private repositories pin an exact checksum-verified runtime and
install it outside the repository. Their setup applies bundled migrations only
to disposable local PostgreSQL. Runtime replacement is atomic and retains the
previous executable when verification or installation fails. Release/latest
initialization uses the selected package's templates; explicit version,
revision, URL, and digest pins support offline and controlled initialization.

`Runtime_metadata` owns the portable v2 lock and release-manifest grammar,
limits, deterministic serialization, and exact target selection. `Upgrade`
owns target detection, fixed-source downloads, checksum and archive validation,
candidate execution, and atomic standalone replacement. `Initializer` consumes
only a prepared verified release and atomically emits either the legacy lock or
canonical v2 lock with that release's templates. The tracked Python bootstrap
parser enforces the same metadata acceptance rules before `kb` is available;
release generation verifies byte-identical templates across target archives.

### Planned 0.2 local execution boundary

The planned 0.2 architecture preserves one native `kb` implementation and one
tracked skill across Orbs and qualified local machines. A generated
repository-owned `.agents/kb` launcher discovers its own retained Git root,
verifies that repository's v2 runtime lock, selects an immutable installation
by exact target and archive digest, and invokes the absolute executable with an
explicit `--repo`. There is no process-global active runtime requirement, so
two repositories may retain different pins.

`.agents/setup` remains Orb lifecycle code. `.agents/setup-local` performs only
explicit local preflight, verified runtime installation, enrollment, and
validation; it neither adapts tracked files nor runs Orb PostgreSQL setup.
Machine-local Amp enrollment lives outside the checkout in an effective-user-
private XDG state tree and contains no secret. Local Git operations retain the
existing `Sync`/`Publication` ownership boundary: only a revalidated official
Amp helper receives a minimal credential environment for an exact Amp-hosted
origin, while all Git safety, preservation, retry, and exact-SHA indexing rules
remain shared.

Scaffold migration is a distinct `Initializer`/upgrade responsibility. It
recognizes exact generated identities, updates the scaffold and lock as one
recoverable repository operation, and never publishes or replaces `.git`.
Runtime-manifest parsing, target detection, local enrollment, and platform
filesystem primitives must remain independently testable boundaries rather
than shell overrides around Linux behavior.

The portable runtime metadata and native Linux/macOS runtime-package boundaries
are implemented toward 0.2. The repository launcher, local setup, enrollment,
and scaffold migration described above remain later-phase work. The target
qualification record is in [Phase 1](./docs/local-clone-phase1.md), with native
runtime evidence in [Phase 3](./docs/macos-phase3.md).

## Embeddings and synchronization

Embedding input is deterministic: type, title, description, sorted tags, and
the exact Markdown body are normalized to LF and hashed with SHA-256. Input over
8,000 UTF-8 bytes is rejected before an external request.

OpenRouter requests are fixed to `openai/text-embedding-3-small`, 1,536
dimensions, OpenAI-only routing, disabled fallbacks, and denied data
collection. A gateway, model, dimension, or routing-policy change is
index-incompatible.

The client bounds connection time, total request time, and response size. It
validates HTTP status and response shape, exactly 1,536 finite values, and usage
metadata. Provider-normalized model labels are accepted only while persisting
the canonical configured identity. Retries are capped and limited to eligible
failures known not to have produced a usable response; possible paid-request
ambiguity is surfaced to the caller.

`kb sync` fetches and verifies the exact `origin/main` commit, then reads
configuration and concepts from Git objects rather than mutable worktree files.
It compares Git tree/blob identities with Postgres, embeds required content,
and applies additions, changes, deletions, and the index checkpoint atomically.
Changes to verification or task state reuse embeddings when the embedding
input is unchanged; surviving paths preserve access telemetry. Explicit
mass-deletion approval is required when a nonempty index becomes empty, or when
at least ten rows and more than half the index would be deleted.

This object-based design works with shallow orb checkouts and does not depend
on local Git history.

## Retrieval

`kb search` checks the local remote-tracking commit and index checkpoint before
embedding the query. Postgres supplies pgvector cosine candidates; OCaml reranks
them with the configured semantic, recency, and frequency weights. Search does
not update access telemetry.

`kb get` returns the full indexed concept and updates access telemetry only
after content validation and final freshness checks. Retrieval configuration
comes from the captured remote commit, not uncommitted `clamp.yaml` bytes.

Candidate validation runs in bounded batches under one five-second deadline,
with fixed aggregate and per-row payload limits. Deterministic resource-limit
failure is not reported as semantic success. See the PRD's retrieval section
for the exact transaction dispatch and uncertain-acknowledgement boundary.

## Publication

`kb publish` accepts only managed changes under `knowledge/**`, `TODO.md`, and
`clamp.yaml`. It requires an attached local `main` tracking a matching
`origin/main`, repository-local author identity, and the current Amp thread ID.

The command regenerates TODO when necessary, validates and stages exact bytes,
commits, fetches, rebases, validates again, and pushes without force. A
successful push is never rolled back solely because exact-commit indexing
fails. Content conflicts and exhausted clean races are preserved differently;
see [Failure recovery](./docs/recovery.md).

## Trust boundaries

- Git publication uses the validated Amp HTTPS credential helper only for an
  exact Amp origin. Ambient Git configuration is removed before credentials
  are exposed.
- Database URLs require encrypted transport and channel binding. Errors redact
  credentials.
- OpenRouter TLS certificate and hostname verification remain enabled.
- Knowledge sent for embeddings is processed by both OpenRouter and OpenAI.
- Other processes running as the same user must not modify `.clamp/`; its
  permissions do not isolate it from them.

## Cross-cutting risks and controls

| Risk | Architectural control and evidence |
| --- | --- |
| YAML rewrite changes comments or scalar style | Document the limitation, preserve unknown values, and use golden round-trip tests. |
| A semantic edit retains stale verification | Keep the verification-clearing predicate distinct from embedding hashes and cover transitions and cross-predicate cases. |
| TODO becomes a second source of truth | Use a pure renderer, detect drift, and regenerate after task mutations and publication conflicts. |
| OpenRouter changes vector space or model labels | Fix routing and dimensions, persist a canonical identity, and validate responses and compatibility. |
| Embedding failure leaves a partial index | Obtain all required embeddings before one transactional database update. |
| Production migration 0001 predates the ledger | Idempotently baseline and checksum-record it before later migrations. |
| Neon pooled sessions lose or leak state | Avoid session state and named prepared statements on pooled reads; use transaction-scoped timeouts and the direct URL for locks and writes. |
| Shallow clones lack history | Compare Git trees and blobs rather than commit history, with shallow-clone integration coverage. |
| Synchronization deletes too much | Require explicit approval for the empty-tree and majority/ten-row deletion thresholds. |
| Concurrent publication loses work | Fetch, rebase, and retry without force; preserve exhausted races under `recovery/` and genuine conflicts under `conflicts/`. |
| Indexing failure undoes durable knowledge | Treat a successful push as final and repair a stale checkpoint with later synchronization. |
| Secrets or knowledge leak in errors or email | Centralize redaction, bound captured output, and scan result and notification fixtures. |
| Fresh Orb setup regresses | Preserve clean-room setup and idempotence checks and investigate changes against the observed baseline. |

New decisions that affect durability, confirmation, provider routing,
retrieval semantics, publication safety, or notifications require explicit
user review and a deliberate PRD update before implementation.
