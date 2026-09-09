# Clamp repository guidance

## Start here

- Read `PRD.md` before making product, data-model, storage, indexing, task, or
  publication changes. It is the authoritative v1 contract.
- Read `PLAN.md` for implementation order, phase gates, and acceptance-criteria
  traceability.
- Read `README.md` for the user-facing project status and setup flow.
- Clamp v1 and Phases 0–9 are implemented. Repository-owned acceptance is
  local-only and does not authorize or prove production operations.
- If this file or the README conflicts with the PRD, preserve the PRD behavior
  and fix the stale document in the same change.

## Product invariants

- The remote `origin/main` tip is the only durable knowledge source of truth.
  An Orb worktree, local file, or unpushed commit is not durable.
- The OKF v0.2 bundle lives under `knowledge/`. Files outside that directory
  are not concepts.
- Postgres concept rows and embeddings are derived from Git. Access telemetry
  is operational state and may be lost without losing knowledge.
- Synchronization compares the target Git tree and blob IDs with Postgres. Do
  not reintroduce history-dependent incremental indexing; fresh Orbs can have
  shallow clones.
- Embeddings go through OpenRouter credits using
  `openai/text-embedding-3-small`, 1536 dimensions. Pin the upstream provider
  to OpenAI, disable fallbacks, and deny data collection. Treat any gateway,
  model, dimensions, or routing-policy change as index-incompatible.
- Reject normalized embedding input over the configured 8,000 UTF-8 byte
  ceiling before calling OpenRouter. Do not add an exact tokenizer, truncate,
  or chunk input for v1.
- Normal retrieval uses semantic ANN candidates followed by recency/frequency
  reranking. A search candidate is not an access; returning full content is.
- Retrieval captures configuration from the exact local remote-tracking commit,
  not mutable worktree bytes, and rechecks that ref at its success/telemetry
  boundary. V1 caps candidates/results/half-life/frequency saturation at
  1,000/100/3,650/1,000,000 respectively.
- Search validates lightweight ANN candidates in 16-row batches under one
  5-second deadline, a 16 MiB aggregate selected-value payload budget, and a
  9 MiB row bound. Every retrieval transaction pins and verifies UTF8 locally;
  the deadline includes the final local-ref Git subprocess and governs admission
  to a blocking libpq COMMIT send accepted by `PQsendQuery`, not COMMIT execution
  or synchronous acknowledgement.
  Expiry before dispatch rolls back; connection loss after dispatch leaves get
  telemetry outcome uncertain.
  Deterministic resource-limit degradation is not semantic success.
- There is one stable concept file per task. Root `TODO.md` is generated from
  task concepts and must never become a second source of truth.
- Generated task ULIDs sort by their standard timestamp prefix across
  milliseconds and use random entropy; same-millisecond monotonic order is not
  guaranteed or required.
- The configured timezone is `Africa/Johannesburg`. V1 has no recurring tasks
  or proactive reminders.

## OKF and Clamp metadata

- Preserve OKF v0.2 semantics. In particular, `generated.by` identifies who
  produced the current document content, not who asserted the claim.
- Agent-authored content normally uses `generated.by: amp/agent`.
- Record claim origin under `clamp.asserted_by`, normally
  `human:owner` or `amp/agent`.
- Keep Clamp-specific metadata under the top-level `clamp` extension mapping.
- Preserve unknown frontmatter keys when round-tripping a concept.
- Use the v1 taxonomy from the PRD. Persisted unknown non-empty OKF types
  produce deterministic warnings. Future mutation/import commands must require
  explicit intent and must not persist an authorization marker.
- Keep concept paths stable. Update the same file when the enduring subject is
  unchanged; use `status: deprecated` and `clamp.superseded_by` for a genuine
  replacement.
- Clear stale verification events after an unconfirmed semantic edit. Preserve
  them only for non-semantic edits or replace them with a new confirmation.
- Record `verified.by: human:owner` only when the authenticated current user
  directly requested verification or confirmed the exact current content;
  agent review alone is not verification authority.

## Inference and task behavior

- `inferred_writes: confirm` is the default. Do not persist an agent inference
  until the user confirms it.
- Only an explicit user request may change inference policy to `auto_draft`.
  Do not infer consent from previous confirmations.
- Under `auto_draft`, an unconfirmed inferred creation is a draft without
  verification. An edit preserves the existing lifecycle status and preserves
  exact verification only when semantic classification says the edit is
  non-semantic; semantic edits clear stale verification.
- Explicit user statements can be recorded without asking the same question a
  second time.
- An inferred task follows the same policy as an inferred fact.
- The agent may close a task without another confirmation only when it directly
  performed and verified the work or the user explicitly marked it complete.
- Never edit generated `TODO.md` directly. Change task concepts and regenerate
  the view deterministically.
- Phase 2 mutation documents come from exactly one of `--input` and `--stdin`;
  authority comes only from the explicit CLI flags documented in the PRD.
- Task/TODO writes roll back reported failures but deliberately have no WAL.
  After an abrupt crash, use `kb validate` to detect drift and `kb todo` to
  repair it.
- Reserve ignored `.clamp/transactions/<128-bit-random>/` for operation-private
  prepared entries, receipts, displaced targets, and quarantine. Readers and
  writers use shared/exclusive Linux `flock` on the open root directory inode;
  never recreate a lock pathname.
- Treat root `.clamp/` as Clamp-private: directories must be effective-UID-owned
  mode `0700` and Clamp-created private files mode `0600`. A descriptor-retained
  displaced original may retain its exact public mode inside that private chain
  to avoid mutating hard-link aliases, but its identity and exact saved bytes
  must be verified immediately before cleanup. Same-UID actors must not mutate
  it; permissions do not provide kernel isolation from prohibited same-UID tampering.

## Implementation constraints

- Implement the v1 interface as a native OCaml `kb` CLI plus a repo-local
  Amp skill. Do not add an MCP server, plugin, daemon, Git hook, or poller for
  v1.
- Use Dune and the repo-local opam switch. Prefer Cmdliner for the CLI,
  `postgresql`/libpq for Neon, and `curl`/libcurl plus Yojson for OpenRouter.
  Keep these clients synchronous unless measured CLI behavior requires
  concurrency; do not add an async framework preemptively.
- Preserve unknown YAML keys when rewriting frontmatter. The selected YAML
  value parser does not preserve comments or exact scalar formatting, so do
  not promise byte-for-byte frontmatter round-tripping.
- Prefer a small dependency set and direct, testable modules over framework
  layers. Do not add provider abstractions for hypothetical future providers.
- Keep parsing, validation, TODO rendering, embedding-input construction,
  ranking, Git publication, and database synchronization independently
  testable where they have distinct behavior.
- Keep the fixed v1 validation ceilings non-configurable: 8 MiB per config,
  concept, or reserved file; YAML depth 64; 100,000 YAML nodes per file; 10,000
  Markdown files and 100,000 links per bundle; and 1,000 returned diagnostics.
  More than 1,000 diagnostics fails with `diagnostic_limit` plus the 999
  smallest diagnostics. Limit diagnostics must be stable and body-free.
- Preserve every accepted finite YAML integer and decimal float as an exact
  JSON number, never a string or binary float. Normalize exactly, then enforce
  PostgreSQL `numeric` limits of 131,072 digits before and 16,383 digits after
  the decimal point. Reject non-finite and out-of-range values before embedding
  or index mutation with stable body-free diagnostics.
- Make serialization and generated output deterministic: stable field order,
  stable sort order, LF line endings, and explicit timezone handling.
- Validate the exact final canonical concept bytes against the fixed size,
  UTF-8, frontmatter, YAML-depth, YAML-node, and concept rules before creating
  managed directories or replacing files. A reported rollback requires a
  durable restoring operation and directory fsync, exact snapshot equality,
  and verified cleanup of every operation-owned temporary file.
- Track entry identities for original snapshots and operation-owned temporary
  files/directories. Use Linux atomic no-replace/exchange renames and private
  quarantine capture rather than check-then-destruct operations; fail closed
  without an ordinary-rename fallback. Stage new directories under private
  random names and install them without replacement. Retain and revalidate the
  complete managed parent chain. Never remove or overwrite a foreign replacement; preserve it and
  report `rollback_state_uncertain`. Fsync the parent after removing an owned
  quarantined entry before reporting ordinary cleanup.
- `--json` CLI output is a contract for the skill. Use stable status/error
  codes rather than requiring prose parsing.
- SQL migration files are authoritative for the database schema. Migrations
  must be reviewable and safe to run once; tests must not target the production
  Neon branch.
- `.agents/setup` prepares only the Orb's local `clamp_test` database and checks
  secret presence without printing values. It must never apply migrations to
  Neon. `.agents/resume` only repairs the local PostgreSQL process and must stay
  fast.
- Use the versions and dependencies pinned by `.ocaml-version`, `clamp.opam`,
  and `clamp.opam.locked`. Keep `.agents/setup` non-interactive, idempotent, and
  safe to run after an Orb snapshot restore.
- Keep the Linux x86-64 runtime archive source-free except for the `kb`
  executable, versioned migrations, private-repository templates, license, and
  exact version/revision markers. Generated private repositories pin its HTTPS
  URL and SHA-256 and must not contain or build Clamp implementation source.
- Read concept content for synchronization from Git objects at the selected
  remote commit, not from the mutable worktree.
- Preserve existing access stats when a path survives sync. Apply concept
  changes, deletions, and the checkpoint atomically after required embeddings
  succeed.
- Keep mass-deletion safeguards and repository/ref identity checks in the sync
  path.

## Git and publication safety

- Distinguish product runtime publication from repository development. The
  eventual `kb publish` command pushes managed knowledge directly to
  `origin/main`; ordinary development work must still follow the user's active
  Amp changes workflow and must not be pushed merely because the product uses
  direct publication.
- Never force-push.
- Never stage unrelated files or include unrelated commits in a knowledge
  publication.
- Reject local Git staging/merge transformations, stage exact managed
  snapshots without filters, and validate the exact candidate tree again after
  every rebase before a publication push.
- Preserve concurrent work. Do not reset, restore, or rewrite changes you did
  not make.
- Generated `TODO.md` conflicts are resolved by regenerating from merged task
  files. Genuine concept conflicts require semantic review.
- If a genuine conflict cannot be resolved confidently, preserve the commit on
  `conflicts/<thread-id>/<YYYYMMDDTHHMMSSZ>` before notifying the user.
- If three clean-rebase push races are exhausted, preserve the latest rebased
  commit on `recovery/<thread-id>/<YYYYMMDDTHHMMSSZ>` and return a distinct
  non-email result. Do not treat this as a content conflict.
- Treat an allocated conflict branch as push-pending until remote branch/SHA
  proof is durably recorded. Retry a pending push only after authoritative
  absence, using the exact original SHA and recorded branch; never repush after
  proof. Preserve valid v1 publication refs during atomic state migration. A
  migrated post-abort v1 conflict may allocate a new pending branch only after
  exact clean original main/HEAD/index/worktree and baseline-shape checks; fail
  closed without discarding user work when those checks do not hold.
- Conflict email uses Amp's current-thread-owner email capability. Include the
  direct thread URL, branch, commit, and paths—never knowledge bodies or
  secrets. Do not email for ordinary network, authentication, embedding,
  database, or stale-index failures.
- A successful Git publication is never reverted solely because indexing
  failed.

## Security

- Required runtime secrets are `KB_DATABASE_URL`,
  `KB_DATABASE_DIRECT_URL`, and `OPENROUTER_API_KEY`.
- Never print, commit, attach, or email secret values. Redact connection URLs
  because they contain database credentials.
- No OpenAI key, OpenRouter BYOK key, Neon account API key, or recipient email
  address belongs in this repository.
- Validate that Neon URLs require TLS and SCRAM channel binding. For bounded
  failover, reconstruct each validated authority target with its matching
  resolved `hostaddr` and a capped `connect_timeout`; preserve credentials,
  path, and all other accepted query parameters unchanged. Do not use the
  server-side `pg_stat_ssl` view to
  infer client-to-Neon transport security because Neon terminates that session
  at its proxy. Pooled reads must not rely on session state or named prepared
  statements; advisory locks, synchronization writes, and migrations use the
  direct URL.
- Keep libcurl certificate and hostname verification enabled for OpenRouter.
- Use bounded database connection/query timeouts and retry transient initial
  connection failures with capped exponential backoff and jitter. Do not retry
  authentication, validation, or deterministic SQL errors.
- Knowledge sent for embedding is processed by both OpenRouter and OpenAI. Do
  not route it to another provider through fallback behavior.
- Authenticated Amp HTTPS Git fetches must use only the validated Amp runtime
  credential helper, validated derived `$HOME/.config` XDG location, and minimal
  Amp auth environment. Keep system/global Git configuration disabled, reset
  credential helpers explicitly, reject local
  credential/proxy/rewrite configuration before exposing Amp auth, and never
  put `AMP_API_KEY` in argv, output, persisted files, or artifacts.
- Keep production and test databases separate. Destructive tests against the
  production Neon branch are forbidden.

## Verification

- Scale checks to the change. Documentation-only changes need Markdown and
  link/sanity checks; deterministic renderers need snapshot or exact-output
  tests; Git/database workflows need focused integration tests.
- Once package scripts exist, use the repository's pinned package manager and
  documented scripts. Do not invent a passing command or claim it ran.
- After changing Orb lifecycle behavior, run `.agents/setup` twice and
  `.agents/resume` once. Verify OCaml/Dune from a clean login shell and verify
  local pgvector with a read-only version query.
- Do not suppress `opam lint` warnings or errors.
- Cover the acceptance criteria in `PRD.md`, especially shallow-clone sync,
  idempotence, telemetry preservation, no re-embedding for metadata-only
  changes, generated TODO drift, conflict preservation, and degraded local
  search.
- If external credentials are unavailable, run local/unit checks and report
  which Neon/OpenRouter integration behavior remains unverified.

## Documentation maintenance

- Keep `README.md` honest about what is implemented now versus planned.
- Update `README.md`, the Amp skill, command help, and examples when CLI
  behavior changes.
- Change `PRD.md` deliberately when the product contract changes; do not hide a
  product decision inside implementation or agent guidance.
