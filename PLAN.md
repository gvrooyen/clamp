# Clamp v1 implementation plan

## Status and authority

This plan sequences implementation of the contract in [PRD.md](./PRD.md).
The PRD remains authoritative for product behavior; this document defines an
implementation order, verification gates, and rollout discipline. If work
uncovers a product ambiguity, stop at the relevant phase gate and update the
PRD deliberately rather than hiding a decision in code.

Clamp v1 and Phases 0–9 are implemented. Version 0.1.3 is the latest published
production release; current source targets 0.1.4.
Repository-owned acceptance remains local-only; production deployment and
release-tag publication are operator-controlled gates.

## Delivery principles

- Deliver each phase as a reviewable vertical slice with passing tests before
  starting the next phase.
- Keep Git at `origin/main` as the only durable knowledge authority. Postgres
  concept data is derived; access telemetry is operational and lossy.
- Keep the executable synchronous and dependency-light. Use Cmdliner,
  `postgresql`/libpq, `curl`/libcurl, Yojson, YAML, Digestif, and Timedesc
  directly; do not introduce an async framework or provider abstraction.
- Make pure behavior independently testable before adding filesystem, Git,
  database, or HTTP effects.
- Keep human-readable output useful, but treat `--json` output, status codes,
  and error codes as the stable skill-facing contract.
- Accept mutation bodies as structured input from a file or stdin in addition
  to simple flags. The skill must not have to shell-quote arbitrary Markdown.
- Never run production migrations, destructive database tests, paid embedding
  probes, or the first production sync from `.agents/setup`.
- Update README usage, command help, the skill, and this plan as behavior lands.

## Target code shape

Use a conventional Dune layout without creating framework layers:

```text
bin/                  Thin Cmdliner command wiring for `kb`
lib/                  Domain logic and direct effect modules
test/
├── unit/             Pure parser, validator, renderer, hash, and ranking tests
├── integration/      Filesystem, Git, local Postgres, and mock HTTP tests
└── fixtures/         OKF bundles, expected TODO output, and Git scenarios
db/migrations/        Authoritative ordered SQL migrations
knowledge/            Versioned OKF bundle created when the local slice lands
```

Prefer modules with one clear responsibility: configuration, frontmatter,
concept validation/serialization, tasks/TODO rendering, embedding input,
ranking, Git object access, database access, OpenRouter, synchronization,
publication, and JSON result encoding. Do not extract interfaces merely to
mirror every external dependency; introduce a test seam only where an effect
must be controlled.

## Phase dependencies

The delivery order is intentionally sequential even where limited parallelism
would be possible:

```text
Phase 0: CLI/test skeleton
    │
    ▼
Phase 1: OKF/config ──▶ Phase 2: local writes/tasks/TODO
    │                              │
    └──────────────┬───────────────┘
                   ▼
Phase 3: schema/libpq ──▶ Phase 4: OpenRouter ──▶ Phase 5: sync
                                                      │
                          ┌───────────────────────────┴──────────┐
                          ▼                                      ▼
                   Phase 6: retrieval                    Phase 7: publish
                          └──────────────────┬───────────────────┘
                                             ▼
                                      Phase 8: Amp skill
                                             │
                                             ▼
                                      Phase 9: acceptance
```

Phase 7 is scheduled after Phase 6 so its post-push sync can be tested as part
of a complete retrieval workflow. Phase 3 production migration, Phase 4 paid
probe, and Phase 5 production sync are explicit rollout gates, not permission
to bypass the remaining local phase exits.

## Phase 0: Native executable and stable command contract

**Status:** implemented. The phase gate is enforced by the locked build, unit
and CLI golden tests, clean-login checks, and idempotent Orb lifecycle checks.

### Goal

Produce an installable native `kb` executable and freeze the cross-command
conventions before implementing product behavior.

### Deliverables

- Add `bin/`, `lib/`, and `test/` Dune stanzas and a thin Cmdliner entry point.
- Add `kb --version`, top-level help, and placeholder command groups matching
  the PRD. Unimplemented commands must return a stable `not_implemented` code,
  not silently succeed.
- Define one JSON envelope for all commands, for example:
  - success: `ok`, stable result `code`, and command-specific `data`;
  - failure: `ok: false`, stable error `code`, safe message, and structured
    details that never contain credentials or knowledge bodies unnecessarily.
- Define stable process exit classes for success, validation/user error,
  conflict, authentication, transient external failure, stale index, and
  internal failure. JSON consumers must not need prose parsing.
- Add common options for repository root, `--json`, and quiet/diagnostic output.
- Build `@install` and update `.agents/setup` to make the native `kb` binary
  available on `PATH` from the repo-local switch without installing anything
  globally or requiring Node.
- Add basic Alcotest and Dune cram/golden-test support as needed; avoid adding a
  second test framework unless exact CLI output cannot be covered otherwise.

### Verification and exit gate

- `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam lint` pass under the committed lockfile.
- A clean login shell in an Orb can run `kb --version` and `kb --json --help`.
- Golden tests cover JSON envelope shape, exit classes, and secret redaction.
- `.agents/setup` succeeds twice and `.agents/resume` succeeds once.

## Production release build

**Status:** implemented and published for version 0.1.3. Future tags and GitHub
releases remain operator-controlled external actions.

### Deliverables

- Build the native executable with Dune's reproducible release mode from the
  exact committed opam lock, after passing the unit suite in the release
  profile.
- Fix the Linux x86_64 build environment by container digest, Debian snapshot,
  opam checksum, and opam-repository commit.
- Bundle the non-glibc shared-library closure behind an origin-relative RPATH,
  with package versions and third-party license notices.
- Produce a deterministic `clamp-<version>-linux-x86_64.tar.gz` and SHA-256
  checksum.
- After an exactly matching `v<version>` tag and commit reach `origin`, use the
  guarded publisher to verify the refs and checksum before creating the GitHub
  release with the prebuilt archive and checksum.
- From 0.1.3, provide repository-independent exact/latest self-upgrades for
  packaged releases. Resolve only the fixed public GitHub release source,
  bound downloads, verify the published SHA-256, archive shape, and candidate
  version, and atomically exchange the complete installation. Reject source,
  opam, and unknown installation layouts without mutation.

### Verification and exit gate

- The staged binary reports the Dune project version under an empty
  environment and renders JSON help.
- Every non-glibc dependency resolves inside the staged archive.
- Repeating the build for the same source epoch produces the same archive
  checksum.
- Unit and command-contract tests cover version/latest selection, strict
  release/checksum parsing, mismatch preservation, candidate validation, and
  verified atomic replacement without updater residue.

## Phase 1: Configuration, OKF parsing, and bundle validation

**Status:** implemented. The deterministic format, strict configuration,
bundle validator, and `kb validate` local exit gate are covered by unit and
CLI tests. Phase 2 builds on this format layer for local mutations and TODO
drift validation.

### Goal

Implement the deterministic local format layer that every later phase trusts.

### Deliverables

- Add the versioned `clamp.yaml` defaults from the PRD and a strict config
  loader for schema version, timezone, inference policy, the optional
  repository-specific human authority (defaulting to `human:owner`), embedding
  identity, routing controls, the embedding input byte ceiling, and retrieval
  coefficients.
- Parse Markdown frontmatter into a representation that retains unknown YAML
  keys and separates the body without claiming comment or scalar-style
  preservation.
- Validate standard OKF fields, Clamp extension fields, verification events,
  task metadata, source mappings, and the v1 taxonomy.
- Warn deterministically for a persisted unknown non-empty type. A later
  mutation/import must require explicit caller intent; malformed or missing
  required metadata remains an error, and no authorization marker is stored.
- Implement bundle-relative concept IDs and path rules, including:
  - reserved `index.md` and `log.md` exclusion;
  - stable paths under `knowledge/` only;
  - `knowledge/journal/<year>/<YYYY-MM-DD>.md` consistency in
    `Africa/Johannesburg`;
  - task filename ULID validation.
- Validate Markdown links that target concepts while allowing ordinary external
  links and non-concept repository links.
- Serialize frontmatter deterministically with LF endings and stable field
  ordering while preserving unknown values.
- Implement verification-clearing classification needed to clear stale
  `verified` events, with explicit non-semantic cases for formatting/link-only
  changes. This predicate is deliberately distinct from the Phase 4
  re-embedding predicate: a link-only body edit may preserve verification but
  still changes embedding input and therefore requires re-embedding.
- Implement `kb validate` for a complete bundle and stable JSON diagnostics.
- Enforce the PRD's fixed file, YAML depth/node, bundle file/link, and returned
  diagnostic ceilings with body-free diagnostics; these are constants rather
  than configuration settings.

### Tests

- Table-driven valid/invalid fixtures for every standard and Clamp field.
- Round-trip tests proving unknown keys and nested values survive, explicitly
  covering integers, integers beyond IEEE-754's exact range, floats, booleans,
  nulls, nested sequences/mappings, and multiline strings. If the selected
  YAML value representation cannot preserve a valid unknown scalar's value,
  stop and resolve the representation or obtain a PRD-approved limitation;
  silent precision loss is not acceptable.
- Explicit tests documenting that YAML comments and exact scalar formatting do
  not survive a rewrite.
- Path traversal, symlink escape, reserved document, malformed frontmatter,
  timezone/date, journal, taxonomy, and link-validation cases.
- Determinism tests that serialize identical values byte-for-byte.

### Exit gate

`kb validate --json` can validate a fixture bundle deterministically without
Git, Postgres, OpenRouter, or production credentials.

## Phase 2: Local concept mutations, journals, tasks, and TODO rendering

**Status:** complete. Mutations consume exactly one complete UTF-8 Markdown
document from `--input` or `--stdin`; authority and exceptional permissions
are explicit CLI options, including claim origin, inference confirmation,
unknown-type authorization, task closure authority, and direct user intent for
policy changes. Task mutations regenerate TODO locally. The local write
protocol uses shared/exclusive Linux `flock` on the open repository-root inode,
an ignored `.clamp/transactions/<128-bit-random>/` private namespace, fsynced temporary files, ordered
Linux no-replace/exchange renames, operation-private quarantine capture, full
managed-ancestor descriptor retention/revalidation, private staged directory
installation, and verified bounded rollback for reported
failures. An unverifiable
post-recovery state returns `rollback_state_uncertain`. A process or host crash
between the task and TODO renames can leave detectable TODO drift, repaired by
`kb todo` (there is deliberately no WAL marker).
Canonical concept bytes are serialized once and checked against the Phase 1
size, UTF-8, frontmatter, YAML-depth, YAML-node, and concept rules before any
managed directory creation or replacement. Rollback success requires a
durable restoring operation and directory fsync, exact snapshot equality, and
verified cleanup of every temporary file created across bounded attempts.
Entry identities distinguish original snapshots and operation-owned files or
directories from foreign replacements; foreign entries are preserved and make
the rollback state uncertain. Cleanup atomically captures entries without
overwrite before removal and fsyncs its parent; unsupported atomic rename
semantics fail closed without an ordinary-rename fallback.
Clamp-created private files are mode `0600`; a descriptor-retained displaced
original narrowly retains its exact public mode under the mode-`0700` private
chain, with identity and exact saved-byte verification immediately before
cleanup, so hard-link aliases are not mutated.

### Goal

Deliver useful, fully local knowledge/task management before any external
indexing or publication behavior.

### Deliverables

- Implement `kb add`, `kb edit`, `kb verify`, and `kb deprecate` using atomic
  write-then-rename operations and the Phase 1 validator/serializer.
- Require mutation input to state whether a claim was explicit user input or
  an agent inference. Enforce `confirm` versus `auto_draft` in command logic;
  the skill may orchestrate confirmation but cannot bypass the CLI invariant.
  Unconfirmed `auto_draft` creations are draft and unverified; edits preserve
  the stored lifecycle status and use semantic classification to preserve or
  clear prior verification.
- Encode `generated.by`, `clamp.asserted_by`, `verified`, status transitions,
  stale verification clearing, and `clamp.superseded_by` exactly as specified.
  Require explicit current-user verification authority at the CLI/local
  mutation boundary; agent review alone must not create human verification.
  Deprecation relationship changes require explicit claim/confirmation
  authority; omitting a replacement preserves an existing relationship.
- Support one daily journal concept per Johannesburg calendar date at the
  stable journal path, updating that file rather than creating duplicates.
- Implement a collision-resistant ULID generator/validator and stable initial
  task slug generation. The standard timestamp prefix sorts generated IDs
  across milliseconds and random entropy supplies collision resistance;
  same-millisecond monotonic order is not required. Prefer a small maintained
  package only if it reduces code and lockfile cost; otherwise keep a focused,
  specification-tested module.
- Implement task lifecycle validation and
  `kb task add|list|start|block|done|cancel`, including due-date exclusivity,
  dependency IDs, completion timestamps, and an explicit `task list` history
  flag for done/cancelled tasks.
- Implement a pure deterministic TODO renderer and `kb todo`:
  - generated-file warning;
  - doing/blocked/todo sections;
  - active-task filtering and overdue/draft markers;
  - priority, due date/time, title, then concept-ID sorting;
  - Johannesburg display timezone and LF output.
- Detect TODO drift in `kb validate`; regenerate TODO after every task mutation.
- Implement `kb config set inferred-writes` while requiring an explicit caller
  intent flag that the skill sets only after a direct user instruction.

### Tests

- Golden files for every TODO section, ordering tie-breaker, overdue boundary,
  timezone conversion, draft marker, and empty state.
- Mutation tests for provenance, confirmation policy, unknown-key retention,
  semantic versus non-semantic verification handling, deprecation, and journals.
- Task state-machine tests, invalid transitions, ULID collision resistance,
  dependency references, and done/cancelled history retention.
- Filesystem failure tests proving writes do not leave truncated concepts or a
  partially regenerated TODO.

### Exit gate

A credential-free Orb can create, update, inspect, and validate concepts
locally; task mutations deterministically update the authoritative task
concept and the generated TODO view.

## Phase 3: Database schema, migrations, and direct libpq boundary

**Status:** complete. The authoritative schema, checksum ledger, maintenance
command, bounded synchronous libpq boundary, and local integration coverage are
present.

### Goal

Create the authoritative application schema and a safe synchronous database
boundary against local PostgreSQL before using production Neon.

### Deliverables

- Add the next ordered SQL migration for `concepts`, `access_stats`,
  `index_state`, constraints, foreign keys, and the HNSW cosine index shown in
  the PRD. Keep vector dimensions fixed at 1536.
- Add a minimal migration ledger/checksum mechanism and an explicit maintenance
  command for applying ordered migrations. It must use the direct URL, refuse
  changed checksums, and never run against Neon from Orb setup.
- Handle the existing pre-ledger production state explicitly: migration 0001
  is idempotently reapplied (`CREATE EXTENSION IF NOT EXISTS`) and checksum-
  recorded on the first ledger-managed run before any later migration. The
  production approval gate verifies this baseline record.
- Let `.agents/setup` apply the same migrations only to local `clamp_test`, so
  local integration tests start from the production schema without touching
  production.
- Validate remote URLs before connection: PostgreSQL scheme, TLS mode at least
  `require`, and `channel_binding=require`. Preserve accepted URL settings and
  authentication and TLS settings, adding internally resolved host addresses
  and a tighter per-address timeout needed for the connection deadline, and
  redact URLs from all errors.
- Require a literal lowercase PostgreSQL URI scheme and reject fragments before
  any reconstruction or libpq call.
- Implement bounded connection/query timeouts and capped transient initial
  connection retry with exponential backoff and jitter. Use one monotonic
  client deadline across bounded DNS resolution, every host/address,
  nonblocking libpq connection polling, retries, backoff, and cleanup. Use an
  incremental preference-preserving host/address race with 250 ms staggered
  starts so a failed DNS lookup or slow connection cannot suppress later healthy
  targets, and apply jitter to actual retry sleeps from a self-seeded per-process
  random state. Treat ordinary network and route failures as failover-eligible,
  close every losing connection, and reap resolver children through
  deadline-bounded nonblocking polling. Use an explicit transaction plus
  `SET LOCAL statement_timeout` for each bounded query unit, including
  pooled reads; never use a session-level `SET` with the pooler. If a query
  cannot be safely enclosed that way, use libpq's nonblocking send/result API
  with a client deadline. Classify auth, validation, and deterministic SQL
  failures as non-retryable.
- Use the pooled URL only for short read/access-stat operations that do not
  depend on session state or named prepared statements. Use the direct URL for
  migrations, advisory locks, sync transactions, and writes.
- Add typed row conversion and transaction helpers only for the actual schema;
  do not add a generic ORM or repository framework.
- Keep migrations and SQL compatible with local PostgreSQL 15 even though the
  verified Neon server currently runs PostgreSQL 18.4. Ledger validation must
  require PostgreSQL 15's absence of `pg_constraint` NOT NULL rows and require
  the complete expected system-generated NOT NULL constraint set on PostgreSQL
  18 and later, based on `server_version_num` read through the same locked
  migration connection; malformed, duplicate, partial, or additional
  constraint rows fail closed.

### Tests and rollout gate

- Apply all migrations to a fresh disposable local database, rerun them
  idempotently through the ledger, and reject a modified historical migration.
- Test all constraints and cascade behavior, including task due-date
  exclusivity and nonnegative access counts.
- Test timeout/retry classification without sleeping in unit tests by injecting
  a clock/backoff function at that narrow seam.
- Run read-only native OCaml smoke tests against pooled and direct Neon.
- **Approval gate:** review and apply the schema migration to Neon through
  `KB_DATABASE_DIRECT_URL`, including the migration-0001 ledger baseline. Do
  not place production migration in an automated test or continue to
  production sync until this succeeds. Record environment-specific results
  outside the reusable public baseline.

## Phase 4: Deterministic embedding input and OpenRouter client

**Status:** complete. Deterministic embedding identity,
bounded security-constrained OpenRouter transport, strict response validation,
mock HTTP coverage, and explicit credentialed model/cost gates are present.
No synchronization or retrieval behavior is included in this phase.

### Goal

Produce stable embedding identities and a direct, security-constrained
OpenRouter client before coupling embeddings to synchronization.

### Deliverables

- Build embedding input from type, title, description, tags, and Markdown body
  only, with stable ordering and normalized LF endings.
- Hash the exact embedding input with SHA-256. Metadata-only changes must retain
  the same hash.
- Validate the provider input limit before any request and return actionable
  split/link guidance; never truncate or chunk silently. Validate UTF-8, then
  reject normalized embedding input longer than the configured 8,000-byte
  ceiling. Provider context-length errors must map to the same stable
  validation code even after local preflight passes.
- Implement the fixed `/embeddings` request with:
  `openai/text-embedding-3-small`, 1536 dimensions, OpenAI-only provider order,
  fallbacks disabled, and data collection denied.
- Keep libcurl CA and hostname verification enabled and apply bounded connect,
  total, and response-size limits.
- Validate HTTP status, JSON shape, exactly 1536 finite values, and usage
  metadata. Accept OpenRouter's documented provider-normalized response model
  label while persisting only the canonical configured identity
  `openrouter:openai/text-embedding-3-small`.
- Return redacted, classified errors. Do not include knowledge text, API keys,
  response bodies, or embedding values in normal logs.
- Keep retries conservative: retry only failures known not to have produced a
  usable response, cap attempts, and surface possible paid-request ambiguity.

### Tests and cost gate

- Exact embedding-input/hash fixtures showing metadata-only versus semantic
  changes.
- Cross-tests for the intentionally different verification-clearing and
  re-embedding predicates, especially formatting-only and link-only edits.
- Boundary tests for 8,000/8,001-byte ASCII and multibyte UTF-8 inputs, invalid
  UTF-8, and a provider context-length rejection below the local ceiling.
- Mock HTTP tests for routing payload, normalized model labels, dimensions,
  nonfinite values, malformed/oversized responses, timeouts, 4xx/5xx, and
  redaction.
- Authenticated model-specific GET as a non-paid integration check.
- **Approval/cost gate:** make one minimal paid embedding request and verify its
  dimensions and routing behavior without printing values.

## Phase 5: Git-object synchronization and atomic index maintenance

**Status:** implemented. Git-object planning, embedding integration, atomic
PostgreSQL convergence, deletion safeguards, and advisory-lock coverage are
present.

### Goal

Implement the shallow-clone-safe, history-independent `kb sync` path and make
Postgres converge to an exact remote Git tree.

### Deliverables

- Implement Git subprocess execution with argv arrays, bounded output, monotonic
  deadlines covering setup through reap, CLOEXEC descriptors, owned
  process-group cleanup, a pre-exec readiness/ACK handshake, a minimal
  environment isolated from ambient Git repository/config/object overrides with
  replacement objects disabled, safe error capture, and no shell interpolation
  of paths or refs.
- For exact Amp HTTPS origins, validate the Amp runtime helper/home and derived
  `$HOME/.config` XDG location, pass only its minimal runtime auth environment,
  explicitly reset credential/askpass
  selection, and reject dangerous repository-local credential, HTTP, URL
  rewrite/include, hooks-path, and upload-pack configuration. Never provide Amp
  auth to local/file remotes or place it in argv or errors.
- Fetch and select the exact `origin/main` target SHA.
- Require the repository-reported object format to be SHA-1 for v1 and return a
  stable unsupported-format failure before fetch otherwise.
- Permit publication to pass the exact just-pushed SHA to sync, while verifying
  it is the fetched `origin/main` tip; normal standalone sync selects that tip
  itself.
- Enumerate `knowledge/**` with `git ls-tree -r` and read content with
  `git cat-file` from the selected commit, never from the mutable worktree.
- Inspect the target commit's root `knowledge` entry first: absence is an empty
  bundle, while a present entry must be exactly one Git tree.
- Read and fully validate the target commit's root `clamp.yaml` and require its
  identity to match the preflight/lock identity and stored index identity.
- Exclude reserved OKF documents from indexing, but read and validate their
  bounds, frontmatter, structure, and links alongside every target concept
  before writing any database state.
- Normalize all accepted YAML integers and finite decimal floats exactly to
  JSON numbers without binary floating point. Enforce PostgreSQL `numeric`'s
  131,072-before/16,383-after decimal digit limits and reject non-finite or
  out-of-range values before planning embeddings or database mutation.
- Acquire a repository-specific Postgres advisory lock through the direct URL
  with bounded `pg_try_advisory_lock` attempts and a stable
  `sync_already_running` result. Under that lock, insert the singleton
  `index_state` row with the expected repository/ref when absent; on every
  later sync, verify its identity before making changes.
- Require the versioned non-secret `source_repository` identity. If the
  checkpoint is absent while concept rows exist, fail closed with
  `index_state_missing` before fetch-dependent embeddings or mutation; v1
  requires an intentional administrative clear and adds no repair command.
- Compare target paths/blob IDs to indexed rows and build a deterministic plan:
  add, metadata-only update, semantic update/re-embed, unchanged, and delete.
- Obtain all required embeddings before starting the database transaction.
- In one transaction, apply upserts/deletes and update the checkpoint only
  after all parsing and embeddings have succeeded. Preserve `access_stats` for
  surviving paths and unchanged rows.
- Implement `--reembed`, model/dimension mismatch rebuild, empty-index rebuild,
  and the exact mass-deletion safeguards from the PRD.
- Return the exact indexed commit and structured counts/statuses in JSON.
- Return deterministic body-free `unknown_type`, `link_invalid_uri`, and
  `link_unresolved` diagnostics without blocking a successful sync; distinguish
  `sync_complete` from `sync_complete_with_warnings`. Share validation's stable
  collector and fail with `diagnostic_limit` plus the 999 smallest diagnostics
  when the bundle produces more than 1,000.

### Tests

- Use local bare remotes and shallow clones; do not rely on repository history.
- Cover empty rebuild, idempotent repeated SHA, new/change/delete/rename,
  telemetry preservation, metadata-only no-reembed, forced reembed, model
  mismatch, reserved documents, portable and case-fold-collision-free Git-tree
  paths, absent and non-directory root `knowledge`, parse failure, embedding
  failure, and rollback.
- Cover repointed-origin identity rejection and complete Git process-group
  cleanup on deadline, output-limit, exception, setup, EOF-before-exit, and
  normal/nonzero paths, including poisoned ambient Git environments and a
  same-identity replacement-object ref. Cover readiness-before-ACK deadline and
  ACK acquisition, I/O, close, and cleanup failures without helper execution.
- Cover authenticated Amp HTTPS through a loopback Git HTTPS fixture, missing or
  invalid helper/auth, hostile global/local credential configuration, secret
  redaction, helper timeout/output/error cleanup, and unchanged local/file
  remote behavior.
- Cover empty-tree and majority/ten-row deletion protection plus explicit
  approval.
- Cover exact decimal/radix integer and decimal-float normalization at the
  PostgreSQL boundaries, non-finite and out-of-range rejection, resource-safe
  long inputs, idempotence, and warning overflow with zero side effects.
- Run concurrent sync attempts to verify the advisory lock and checkpoint
  invariants without duplicate writes.

### Exit and production gate

- A local destructive integration suite converges repeatedly from Git.
- Before production sync, create a small user-approved, non-sensitive bundle
  containing representative concept/task/journal files and commit it to
  `origin/main` through the ordinary development changes workflow. `kb publish`
  does not exist yet and must not be used for this bootstrap. If no real bundle
  is approved, defer the production gate rather than treating an empty-tree
  sync as meaningful acceptance evidence.
- **Approval gate:** run the first production sync, verify checkpoint/model/
  dimensions/counts, rerun idempotently, and perform only read-only inspection.
  Record environment-specific results outside the reusable public baseline.

## Phase 6: Semantic retrieval, reranking, and access telemetry

**Status:** complete. The synchronous slice includes freshness/compatibility
checks, ANN candidate selection, deterministic OCaml reranking, independent
history visibility, full-content retrieval, and atomic access telemetry.

### Goal

Deliver `kb search` and `kb get` over a fresh, compatible index with exact
visibility and telemetry semantics.

### Deliverables

- Embed queries with the same fixed OpenRouter routing and model identity.
- Use pgvector cosine ANN to fetch the configured candidate set before applying
  recency/frequency reranking in OCaml. Keep the ANN order expression indexable,
  and use bounded strict-order iterative HNSW scanning to fill the candidate set
  through selective visibility filters.
- Implement the pure scoring functions and clamps exactly as specified,
  including fallback timestamps and frequency saturation.
- Apply normal visibility filters for deprecated/stale concepts and closed
  tasks; add explicit history flags for each excluded class.
- Keep drafts searchable while returning status, trust tier, and assertion
  origin.
- Check checkpoint compatibility and freshness against the locally known
  `refs/remotes/origin/main`. Search does not implicitly fetch on every call;
  the skill's required pre-retrieval sync refreshes that ref. Return a stable
  stale-index error/warning instead of claiming freshness. Read configuration
  from the captured commit object and recheck the actual ref at each final
  success/telemetry boundary.
- Make `kb search` return metadata/snippets without updating telemetry.
- Keep default human search concise by presenting only the top snippet and
  source; expose all returned matches and four-decimal ranking components with
  `-v`/`--verbose`, without changing stable JSON or describing rank as calibrated
  confidence.
- Keep ANN materialization lightweight, then preflight and validate complete
  candidate rows in bounded batches under one operation deadline and fixed
  aggregate/row transfer budgets. Return structured degraded failures rather
  than skipping validation or risking unbounded client allocation.
- Pin and verify UTF8 transaction-locally before retrieval values cross libpq,
  and cap the final local-ref Git subprocess to the remaining operation
  deadline. Check client-side row/reranking/response work at bounded boundaries.
  Recompute the remaining budget immediately before COMMIT dispatch and reject
  dispatch without a positive safe window. Mark dispatch only after blocking
  libpq accepts the COMMIT send; setup/send failure remains pre-dispatch.
  Document that COMMIT execution and synchronous acknowledgement may finish
  late and in-flight connection loss leaves telemetry uncertain.
- Generate snippets deterministically from the indexed body with a fixed
  documented length and explicit truncation marker.
- Make `kb get` return full indexed content and atomically upsert/increment
  access telemetry only after an exact-number-safe complete response is
  constructed. Reject non-JSON quiet gets before retrieval.
- Provide structured degraded errors that let the skill fall back to local
  Markdown/`rg` without implying semantic equivalence.

### Tests

- Exact score fixtures for semantic normalization, age boundaries, timestamp
  fallback, logarithmic frequency, saturation, and deterministic tie-breaking.
- Filter/history tests at Johannesburg date boundaries.
- Candidate-versus-returned-result tests proving search never records access.
- Concurrent `get` tests proving atomic access increments.
- Stale checkpoint, missing index, lost telemetry, Neon failure, and OpenRouter
  failure behavior.
- Real HNSW plan/candidate-fill coverage with selective filters, exact
  frontmatter-number response coverage, committed-config/ref-race tests, and
  quiet/no-telemetry CLI coverage. Exercise the production lightweight ANN and
  aggregate candidate-validation limit at the 1,000-candidate cap, hostile
  client-encoding defaults, and deterministic final-ref deadline exhaustion.
  Exercise expiry before COMMIT dispatch, late successful acknowledgement from
  delayed COMMIT execution, and in-flight connection-loss classification through
  the real PostgreSQL path. Assert operation-specific caller-visible uncertainty
  for post-dispatch get/search failures and generic pre-dispatch loss.

### Exit gate

Search returns ranked indexed results from the exact synced commit, and only
full-content retrieval changes operational telemetry.

## Phase 7: Safe Git publication and conflict preservation

**Status:** complete. Managed-only preflight/staging, exact-byte candidate and
post-rebase validation, atomic local publication state, repository-local author
and ref safety, normal fetch/rebase/push retries, user-safe retryable semantic
conflict state, generated TODO regeneration, durable conflict/recovery branches,
and exact-pushed-SHA post-push sync are covered against disposable local bare
remotes.

### Goal

Implement product-runtime publication to `origin/main` without risking
unrelated work, history, or unresolved knowledge.

### Deliverables

- Implement a publication preflight that regenerates TODO when needed,
  validates the managed tree, and identifies exactly which managed files may be
  staged.
- Refuse unrelated staged changes, local history ahead of or diverged from the
  known tracking ref, dirty unmanaged files that would be affected, wrong
  remotes/refs, detached unsafe states, and every force-push path. Accept a
  clean local main that is an ancestor of the known tracking ref.
- Commit with the author from the repository's Git configuration, fetch, and
  rebase onto current `origin/main`. Accept the current Amp thread ID as an
  explicit validated CLI argument supplied by the skill; do not infer it from
  unrelated environment state.
- Regenerate TODO to resolve generated-file conflicts; never choose a side for
  TODO manually.
- Expose genuine concept conflicts as a structured state the skill can inspect.
  Allow the agent to make a semantic resolution and retry without discarding
  either side.
- Retry a clean-rebase push race at most three times. Exhaustion returns a
  distinct `publish_race_exhausted` result, is not labeled a content conflict,
  and never triggers email. Push the latest rebased commit without force to
  `recovery/<thread-id>/<UTC timestamp>` and return that branch and commit SHA;
  do not add the pending commit to `origin/main`.
- When the agent declines or cannot resolve a genuine content conflict, abort
  the rebase so the original commit is intact and preserve that commit on
  `conflicts/<thread-id>/<UTC timestamp>`.
- For a genuine unresolved conflict, return the conflict branch, original
  commit SHA, and paths without knowledge bodies. The skill–not the CLI–uses
  Amp owner-email capability for that notification.
- After a successful push, sync the exact pushed SHA. If sync fails, report a
  stale index but never revert or rewrite the successful Git publication.
- If `origin/main` advances again between the successful push and post-push
  sync verification, report the index as stale rather than misreporting the
  already-successful publication as failed; a later sync converges to the new
  tip.

### Tests

- Local bare-remote scenarios for clean publish, out-of-date publish, another
  writer winning once/repeatedly, race exhaustion as a distinct non-email
  outcome with the latest rebased commit on `recovery/`, generated TODO
  conflict, resolvable concept conflict, unresolved conflict preservation on
  `conflicts/`, shallow clones, managed deletion, and push failure. Cover an
  out-of-date local main both before and after its tracking ref has fetched the
  remote advancement.
- Safety tests with unrelated staged files, unrelated commits, dirty untracked
  files, wrong remotes, and attempts to force.
- Verify `recovery/` refs contain the latest rebased commit, `conflicts/` refs
  contain the original pre-rebase commit, and structured results contain no
  body/secret data.
- Verify successful-push/index-failure semantics explicitly.
- Inject conflict-preservation cleanup failure after the conflict ref is
  durable; verify the distinct body-free preserved cleanup-pending contract,
  remote ref/original SHA check, cleanup-only retry without repush, ref removal,
  and a later normal publication.
- Reject the first conflict-branch push, then retry through the production CLI;
  verify exact branch/SHA/path reuse, authoritative remote absence before the
  one allowed retry push, proof recording before cleanup, no knowledge loss,
  and a later publication. Keep the proven cleanup retry no-repush test.
- Load every representable reviewed Phase 7 v1 publication state: genuine
  conflict/baseline, clean raced state, and durable-main cleanup state. Verify
  atomic v1 migration preserves original/race/conflict fingerprints, resumes
  safely, and leaves old refs unchanged when migration update fails.
- Create the accepted post-abort v1 conflict state with the actual reviewed
  Phase 7 CLI. Verify the final CLI proves exact clean original
  main/HEAD/index/worktree and retained baseline shape before atomically
  allocating a pending branch; cover owner-state, allocation, and first-push
  failures without state loss, then prove recovery and a later publication.
- Exercise v2's branch-bearing state as conservatively push-pending for both an
  absent branch and an already exact remote branch; only the absent branch may
  push, while exact remote proof transitions without repush.
- Inject simultaneous exact-SHA sync and local state-cleanup failures; verify
  the combined body-free contract retains both causes, diagnostics, published
  SHA, and state refs, then retry cleanup and prove a later normal publication
  succeeds.

### Exit gate

Every PRD publication acceptance scenario passes against disposable Git
remotes. No test publishes knowledge to the real `origin/main`.

## Phase 8: Repo-local Amp skill and end-to-end agent workflow

**Status:** complete. The discoverable `managing-clamp-knowledge` repo-local
skill, deterministic static/fixture-JSON contract tests, disposable
shallow-clone/Postgres workflow, classified local fallback, and
preservation-gated notification simulation are present.

### Goal

Make the verified CLI safely usable by a fresh Amp thread without requiring the
agent to rediscover product policy.

### Deliverables

- Create the repo-local Amp skill using the current Amp skill conventions and
  validate it with the skill tooling available at implementation time.
- Teach the skill to:
  - run sync before first indexed retrieval in a fresh thread;
  - prefer `kb search`/`kb get` and interpret only stable JSON codes;
  - fall back to local Markdown/`rg` only from the structured non-equivalent
    fallback details returned for classified external failures;
  - distinguish explicit statements from inferences and ask for confirmation
    before inferred writes under `confirm`;
  - require direct authenticated-current-user authority before human
    verification and pass returned `tasks/` IDs unchanged;
  - use task commands and never edit generated TODO directly;
  - publish completed managed mutations;
  - attempt semantic concept-conflict resolution without inventing facts;
  - email the current thread owner only after an unresolved conflict has been
    preserved, including thread URL/ref/SHA/paths but no bodies or secrets.
- Add examples for facts, journals, tasks, verification, deprecation, search,
  degraded retrieval, publication, and conflict escalation.
- Keep recipient identity and thread URL runtime-derived; commit no email
  address or thread-specific value.

### Tests

- Skill static validation plus command-example tests against fixture JSON.
- Exact executable fixture comparisons against production sync/publication
  envelopes and policy decisions, including verification authority,
  `auto_draft`, task IDs, degraded sync, races, and cleanup variants.
- Compare sync fixture code/kind rows directly with the authoritative production
  Sync fallback-producer definition, then construct each row through its real
  adapter or production constructor and serialize it with `Sync.cli_result`.
- End-to-end disposable workflow: fresh Orb, sync, search/get, explicit write,
  inferred-write confirmation, task/TODO update, publish, and resync.
- Simulated external outages proving local fallback.
- Simulated unresolved conflict proving preservation occurs before one
  correctly scoped email request.

### Exit gate

A new thread can use the skill from a fresh checkout without undocumented
manual steps or prose/error scraping.

## Phase 9: Acceptance, documentation, and controlled v1 rollout

**Status:** complete. The registered criterion matrix,
documentation/help/skill drift checks, hermetic runner test,
staged-candidate/result/notification leakage audit, and local acceptance runner
are implemented. Production rollout remains operator-controlled.

### Goal

Prove the complete PRD contract, document the actual interface, and perform a
controlled production rollout without conflating bootstrap success with
application success.

### Deliverables

- Build an acceptance matrix mapping every PRD criterion to named automated
  tests and any explicit manual/credentialed check.
- Run the full unit/integration suite from a clean local test database and
  disposable bare remotes.
- Run a fresh-Orb clean-room test from `origin/main`, including setup
  idempotence, locked build, local pgvector, CLI availability, skill discovery,
  and non-destructive native service checks.
- Update README with real installation, command examples, JSON behavior,
  degraded operation, recovery procedures, and production migration/sync
  instructions. Remove every remaining “planned” claim only when implemented.
- Ensure command help and the skill match the README and PRD.
- Audit repository files, normal logs, structured errors, conflict refs, and
  email payloads for secrets and knowledge-body leakage.
- Record baseline setup/sync/search behavior as observations, not hard limits.

### Public acceptance boundary

The public baseline contains no immutable old Phase 7 binary, private
clean-room record, production rollout evidence, or credential-incident history.
The normal Phase 9 runner reports the historical cross-version case as not
included. Operators must record environment-specific rollout evidence outside
the reusable source baseline.

### Source-free private-consumer distribution

- Build a reproducible Linux x86-64 runtime archive from an exact clean source
  commit with `kb`, migrations, templates, license, and revision/version
  markers only.
- Publish its SHA-256 beside the archive and require generated private
  repositories to pin version, revision, HTTPS URL, and digest.
- Provide `kb init` to create a complete local private knowledge repository on
  `main` with one clean generic initial commit, without implementation source,
  a remote, a push, production access, or paid requests.
- Let `kb init --release X.Y.Z` and `kb init --latest` derive the exact runtime
  lock from a checksum-verified public package and use that package's own
  templates. Preserve all four explicit pin options for offline and controlled
  test initialization.
- Have generated Orb setup verify and install the runtime outside the private
  repository, apply bundled migrations only to disposable local PostgreSQL,
  and atomically retain the previous executable if installation fails.
- Acceptance requires a fresh No Project Amp Orb to initialize the private
  repository, run setup twice and resume once, validate the empty bundle, and
  confirm a clean tracked initial tree and that no implementation tree or
  remote was introduced.

### Final rollout sequence

1. Confirm all local tests and static checks pass under the lockfile.
2. Obtain explicit approval for any unapplied production migration.
3. Apply migrations through the direct URL and inspect schema read-only.
4. Run initial/repair sync; verify exact remote SHA and rerun idempotently.
5. Perform one bounded real search/get and verify telemetry semantics.
6. Publish one low-risk test concept through the skill, verify Git durability,
   sync, and retrieval, then deprecate it through the same managed workflow if
   it should not remain.
7. Launch a separate fresh Orb and repeat the normal skill bootstrap/search
   path before declaring v1 operational.

### V1 definition of done

- All PRD acceptance criteria have evidence.
- `origin/main` is demonstrably sufficient to rebuild the content index from a
  shallow clone.
- Production migration and sync paths have been exercised without production
  destructive tests.
- The skill uses stable JSON contracts and honors confirmation, task, conflict,
  email, and degraded-operation policies.
- README and command help describe implemented behavior only.
- Known limitations match the PRD non-goals; no deferred feature was smuggled
  into the critical path.

## Acceptance-criteria traceability

Exact names below use `test executable` / `Alcotest group` / `test case`; cram
evidence names the containing file and scenario heading. “None” means no
credentialed or production operation is needed beyond the named local evidence;
“Complete” records completed manual or credentialed evidence. The Phase 9
matrix test validates every Alcotest citation against the executable's `list`
output and every cram citation against the registered cram source heading.

| PRD criterion | Named automated evidence | Manual/credentialed evidence |
| --- | --- | --- |
| 1. Fresh Orb installs, validates, syncs, and searches | `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase5_sync_test` / `sync` / `retrieval vertical slice`; `command_contract.t` / `Top-level metadata is available without executing product behavior.` | **Operator gate:** repeat in the target environment. |
| 2. Explicit user fact records agent producer and configured human assertion | `phase2_test` / `mutation` / `provenance and verification`; `phase2_test` / `mutation` / `configured human authority` | **None:** the persisted parsed metadata is asserted exactly as `generated.by: amp/agent` and the configured authority, including the omitted-setting default `human:owner`. |
| 3. `confirm` blocks an unconfirmed inference | `phase2_test` / `mutation` / `provenance and verification`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase8_skill_test` / `skill` / `command fixture policy` | **None:** the no-write invariant is local and credential-free. |
| 4. Explicit `auto_draft` policy creates an unverified draft | `phase2_test` / `mutation` / `auto draft, unknown type, config`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase8_skill_test` / `skill` / `command fixture policy`; `command_contract.t` / `Changing inferred-write policy requires explicit direct-user intent.` | **None:** the CLI rejection proves explicit intent is required, and the local mutation/workflow evidence proves unverified draft creation after the policy is selected. |
| 5. Human verification requires direct current-user authority | `phase2_test` / `mutation` / `provenance and verification`; `phase2_test` / `mutation` / `configured human authority`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `command_contract.t` / `Phase 2 accepts complete Markdown documents from files and stdin without shell-quoting their bodies, while authority remains separate CLI input.` | **None:** current-user authority acceptance, configured canonical identity, and agent-only rejection are deterministic CLI policy. |
| 6. Stable task mutation deterministically updates TODO and detects drift | `phase2_test` / `tasks` / `lifecycle/history/drift`; `phase2_test` / `TODO` / `ordering and boundaries`; `command_contract.t` / `Phase 2 accepts complete Markdown documents from files and stdin without shell-quoting their bodies, while authority remains separate CLI input.` | **None:** concept/TODO identity, rendering, and drift are local filesystem behavior. |
| 7. Directly performed and verified work may be closed without another confirmation | `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase2_test` / `tasks` / `lifecycle/history/drift`; `phase8_skill_test` / `skill` / `command fixture policy` | **None:** closure authority is enforced locally. |
| 8. Out-of-date non-force publication, TODO regeneration, and race recovery | `phase7_publication_test` / `publication` / `clean, shallow, and out-of-date`; `phase7_publication_test` / `publication` / `generated TODO conflict`; `phase7_publication_test` / `publication` / `clean races and recovery` | **None:** disposable bare remotes cover all required Git races without risking `origin/main`. |
| 9. Unresolved conflict is preserved before one owner email and cleanup retry does not repush | `phase8_workflow_test` / `workflow` / `conflict preservation gates one email request`; `phase7_publication_test` / `publication` / `resolve and preserve conflicts`; `phase7_publication_test` / `publication` / `preserved conflict cleanup recovery`; `phase7_publication_test` / `publication` / `reviewed Phase 7 CLI cross-version migration` | **None:** disposable workflows prove preservation before one request and cleanup without repush. |
| 10. Shallow unchanged sync needs no previous commit and no redundant embedding | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** both tests use disposable depth-1 clones. |
| 11. Repeated target SHA is idempotent and preserves telemetry | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** exact repeat counts and access preservation are asserted against local PostgreSQL. |
| 12. Empty concepts table rebuilds to the Git tree | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** each fixture begins with an empty disposable application schema and converges from Git. |
| 13. Semantic changes re-embed while verification/task state changes do not | `phase4_test` / `embedding input` / `predicate cross-tests`; `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase5_sync_test` / `sync` / `task state metadata-only` | **None:** embedding calls and sync classifications are counted in-process. |
| 14. Normal and explicit-history search visibility is correct | `phase5_sync_test` / `sync` / `retrieval vertical slice`; `phase6_test` / `scoring` / `Johannesburg visibility` | **None:** all history classes and independent flags are covered locally. |
| 15. Search records no access while full get does | `phase5_sync_test` / `sync` / `retrieval vertical slice`; `phase5_sync_test` / `sync` / `retrieval COMMIT finalization boundary` | **None:** local tests assert telemetry transitions. |
| 16. Index failure never reverts a successful Git push | `phase7_publication_test` / `safety` / `push and index failure semantics`; `phase7_publication_test` / `safety` / `CLI JSON and human contract`; `phase8_skill_test` / `skill` / `publication production envelopes` | **None:** injected index failures prove the durable disposable remote SHA remains published. |
| 17. Classified outages permit non-equivalent local readable fallback | `phase8_workflow_test` / `workflow` / `classified outage uses local fallback`; `phase8_skill_test` / `skill` / `authoritative sync fallback producer envelopes`; `phase8_skill_test` / `skill` / `sync fallback preserves diagnostics` | **None:** fallback is exercised without external credentials. |
| 18. Repository files, normal logs, results, and notification payloads leak no credentials or knowledge body | `phase9_acceptance_test` / `acceptance` / `bounded repository and output leakage audit`; `contract_test` / `envelopes` / `environment secret redaction`; `phase5_sync_test` / `sync` / `Amp authenticated sanitized fetch`; `phase7_publication_test` / `safety` / `CLI JSON and human contract`; `phase8_workflow_test` / `workflow` / `conflict preservation gates one email request` | **None:** repository/result/notification audits are local and credential-free. |
| 19. Fresh setup is pinned, idempotent, local-only, and pgvector-ready | `phase9_acceptance_test` / `acceptance` / `hermetic runner behavior and plan`; `phase3_database_test` / `migrations and schema` / `fresh, repeat, drift, constraints`; `command_contract.t` / `Top-level metadata is available without executing product behavior.` | **Operator gate:** repeat setup twice and resume once in a fresh target Orb. |

## Cross-phase risk register

| Risk | Mitigation and required evidence |
| --- | --- |
| YAML rewrite changes comments or scalar style | Document limitation; preserve unknown values; golden round-trip tests |
| A semantic edit retains stale verification | Dedicated verification-clearing predicate, distinct from embedding hashes; transition/cross-predicate tests |
| TODO becomes a second source of truth | Pure renderer; drift detection; regenerate on every task mutation and conflict |
| OpenRouter changes vector space or normalizes model labels | Fixed routing and dimensions; canonical persisted identity; response validation and compatibility tests |
| Embedding failure leaves a partial index | Complete embeddings before one transactional database update |
| Production migration 0001 predates the ledger | Idempotently baseline and checksum-record it before applying later migrations |
| Neon pooled sessions lose state | No session state/named prepared statements on pooled reads; direct URL for locks and writes |
| Pooled query timeout leaks across transactions | Use transaction-scoped `SET LOCAL statement_timeout`; test with transaction pooling semantics |
| Shallow clones lack history | Tree/blob comparison only; shallow-clone integration suite |
| Sync mass deletion is accidental | Empty-tree and majority/ten-row guards plus explicit approval |
| Concurrent publication loses work | Non-force fetch/rebase/retry; latest rebased commit on `recovery/` after clean-race exhaustion; original commit on `conflicts/` after genuine conflict |
| Indexing failure undoes durable knowledge | Push is final; checkpoint remains stale and later sync repairs it |
| Secrets or knowledge leak in errors/email | Central redaction, bounded error capture, fixtures scanning all result paths |
| Fresh Orb setup regresses materially | Preserve clean-room setup/idempotence checks and investigate against observed baseline |

## Clarifications

No additional product clarification is required to begin implementation. The
two decisions raised during Oracle review are now settled in the PRD: exhausted
clean push races use a distinct non-email `recovery/` branch, and embedding
input uses a conservative configured 8,000-byte UTF-8 ceiling instead of an
exact tokenizer. Any newly discovered choice affecting durability,
confirmation, provider routing, retrieval semantics, publication safety, or
notification behavior requires explicit user review and a PRD update before
implementation continues.
