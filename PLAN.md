# Clamp 0.2.0 local-clone implementation plan

## Status and authority

This plan defines the work needed for a user to clone an already initialized
Amp-hosted Clamp assistant onto a supported local machine and use it through the
local Amp CLI with the same knowledge, index, mutation, publication, and safety
semantics as an Orb.

[PRD.md](./PRD.md) remains authoritative for product behavior.
[ARCHITECTURE.md](./ARCHITECTURE.md) defines current implementation boundaries,
and [ACCEPTANCE.md](./ACCEPTANCE.md) remains the v1 evidence baseline. Before
implementation changes behavior, update the PRD deliberately with the settled
0.2.0 contract and extend acceptance traceability without weakening any v1
criterion.

Only planning is in scope for this change. No implementation, template,
documentation, version, migration, or release change is authorized by this
plan alone.

## Outcome

The supported workflow is:

```text
┌───────────────────────┐        amp clone         ┌──────────────────────┐
│ Amp-hosted assistant  │─────────────────────────▶│ Local clean checkout │
│ origin/main + index   │                          └──────────┬───────────┘
└───────────┬───────────┘                                     │
            │                                      .agents/setup-local
            │                                                  │
            │                                                  ▼
            │                                      ┌──────────────────────┐
            │                                      │ Verified native kb   │
            │                                      │ portable skill       │
            │                                      │ local credentials    │
            │                                      └──────────┬───────────┘
            │                                                  │ amp
            │                                                  ▼
            │       non-force publish + exact-tip sync ┌──────────────────┐
            └──────────────────────────────────────────│ Local Amp agent  │
                                                       └──────────────────┘
```

For a freshly initialized 0.2.0 assistant, the user should need only:

```bash
amp clone OWNER/PROJECT [TARGET]
cd TARGET
.agents/setup-local
amp
```

The setup command may require the user to install an explicitly documented
system prerequisite or expose Clamp's three service credentials from a secure
local secret manager. Publication also requires an explicitly configured
repository-local Git author if `amp clone` does not provide one. Setup cannot
alter its parent shell, so correct agent behavior must use the repository's
pinned launcher rather than depend on `kb` already being on `PATH`. Setup must
not require editing tracked files, copying implementation source into the
private repository, manually rewriting the skill, or weakening Git and
filesystem checks.

## Verified current gaps

- `amp clone OWNER/PROJECT [TARGET]` clones an Amp-hosted project and normally
  configures Amp's Git credential helper. Amp matches a local CLI thread to a
  project by the checkout remote.
- Amp project secrets are documented as environment variables for project
  Orbs, not as secrets exported into local CLI processes. Local `amp` therefore
  needs `KB_DATABASE_URL`, `KB_DATABASE_DIRECT_URL`, and
  `OPENROUTER_API_KEY` from the user's local environment or secret manager.
- Generated private-repository `AGENTS.md` and the skill hard-code
  `/home/user/workspace/repo` and describe only the Orb lifecycle.
- Generated `.agents/setup` and `.agents/resume` assume Debian, `sudo`, the
  PostgreSQL 15 `main` cluster, Orb filesystem paths, and Linux x86-64 release
  assets. They are not safe general-purpose local installers.
- `kb sync` and `kb publish` accept only an exact Amp origin and an Orb-specific
  trusted Amp runtime consisting of `AMP_BIN_DIR`, `AMP_API_KEY`, `AMP_URL`, and
  `$HOME/.amp/bin/amp`. The credential helper configured by `amp clone` is not
  currently a supported `kb` authentication source.
- The `kb` filesystem stubs, linker configuration, executable discovery,
  upgrader, packaging, and some tests are Linux-specific. A shell-only change
  cannot provide safe macOS mutation or publication.
- A 0.1.x assistant has no local setup entry point or scaffold migration
  command. Updating only `kb init` would strand existing assistants.

## 0.2.0 scope and decisions

### Supported targets

The candidate 0.2.0 target matrix is:

- Linux x86-64 with glibc 2.36 or newer; and
- Apple-silicon macOS (`macos-arm64`) on a minimum macOS version selected and
  recorded before implementation of the package builder.

Both become supported release targets only after Phase 1 feasibility and the
target-specific acceptance gates pass. If native runners, Amp helper behavior,
filesystem primitives, or a disposable database harness cannot satisfy the
existing safety contract on macOS, defer macOS rather than publishing a reduced-
safety target or weakening Linux behavior.

Intel macOS, Linux ARM, Windows, a local PostgreSQL installation, and arbitrary
non-Amp Git hosts are deferred. The release manifest and installer must be
target-extensible, but untested targets must fail with a stable unsupported
target result rather than attempting a source build or selecting a nearby
binary.

### Full local behavior

The local workflow targets parity with the hosted workflow, not merely lexical
offline editing:

- validate and mutate the checked-out bundle;
- synchronize and retrieve against the already provisioned Neon/OpenRouter
  index when local credentials are present;
- degrade to explicitly non-semantic local Markdown search under the existing
  classified failures;
- publish managed changes to the Amp-hosted `origin/main` without force and
  synchronize the exact pushed commit; and
- preserve the existing confirmation, provenance, verification, task,
  conflict, stale-index, and telemetry semantics. Notification parity is gated
  by the local Amp capability decision in Phase 1.

Credentials are required per operation, not globally. Local validation,
mutation, task, TODO, and lexical fallback need no service credential; database
reads need the pooled URL. Semantic search requires `KB_DATABASE_URL` and
`OPENROUTER_API_KEY`. Indexed `get` requires only `KB_DATABASE_URL`, subject to
the existing local-ref freshness and index-compatibility checks; it neither
embeds nor requires authenticated Git. Synchronization separately requires
authenticated Git, `KB_DATABASE_DIRECT_URL`, and OpenRouter only when embeddings
are necessary. Publication needs authenticated Amp Git and may additionally
report a stale index when post-push sync lacks a service credential.

No database schema or embedding identity change is expected. A schema or model
change discovered during implementation is a separate compatibility decision
requiring PRD review and migration/reindex planning.

### Tracked versus machine-local state

- The private repository remains source-free. It contains portable scripts,
  instructions, a repository-scoped skill, and reviewed runtime metadata, but
  no Clamp implementation source or credentials.
- The tracked skill is made environment-portable once; local setup verifies it
  and does not rewrite it per checkout. A setup that dirties the worktree would
  interfere with publication safety and is not acceptable.
- Generated repositories contain a small portable `.agents/kb` launcher. It
  resolves that repository's verified lock to an immutable installation keyed
  by target and archive digest, then executes the absolute `bin/kb` path. The
  skill uses this launcher plus an explicit validated `--repo`; behavior never
  depends on a globally active `kb` symlink. This allows two repositories pinned
  to different releases to work concurrently.
- Installed binaries and local authentication metadata live outside tracked
  Git state. Secrets remain only in the invoking process or the user's secure
  secret manager; setup never copies Orb project secrets, writes a `.env`, or
  prints credential-bearing URLs.
- `.agents/setup` remains the automatic Orb entry point. A distinct executable
  `.agents/setup-local` is the explicit human-invoked local entry point. Common
  runtime-lock verification may be shared by a small tracked helper, but Orb
  PostgreSQL lifecycle logic must not run locally.

## Phase 1: Freeze the 0.2 contract and fixtures

**Status: complete.** The repository-owned contract, sanitized fixtures, tests,
and immutable-0.1.4 prepublication compatibility mechanism are implemented and
Oracle-approved. Native ext4/APFS, source-free consumer bootstrap, isolated
authenticated read-only Amp Git, local-runner identity and notification
interfaces, ordinary-update behavior, and disposable database feasibility have
passed on both candidate targets. Native runtime/package, application
durability, signing, and end-to-end work remain later-phase gates, not Phase 1
prerequisites. No local target is supported yet.

### Deliverables

- Add a PRD 0.2 section defining local-clone behavior, supported targets,
  credential boundaries, portable repository-root discovery, scaffold
  ownership, local publication, and backward compatibility.
- Define stable JSON result/error codes for target selection, local setup
  preflight, scaffold migration, runtime-manifest validation, Amp helper
  validation, missing local service credentials, and partially supported
  environments. Human setup prose may wrap these codes but tests must not parse
  prose.
- Capture sanitized fixtures for:
  - a freshly initialized 0.2 repository;
  - the exact known 0.1.4 generated scaffold;
  - a 0.1.x scaffold with owner modifications;
  - Orb and local Amp authentication contexts;
  - Linux x86-64 and macOS arm64 release metadata; and
  - missing, malformed, hostile, and stale local configuration.
- Qualify the proposed minimum macOS version, filesystem primitives, native
  runners, disposable PostgreSQL/pgvector harness, and required local Amp CLI
  version before promising the target. Record supported filesystem types and
  fail-closed behavior for unsupported/network filesystems.
- Before freezing local authentication, verify on each candidate target the
  exact helper configuration produced by `amp clone`, official executable
  layout and indirections, credential-store environment, noninteractive helper
  behavior under Clamp's intended sanitized environment, and behavior after an
  ordinary Amp update. Do not infer this contract from Orb variables or an
  ordinary successful `git pull`.
- Decide whether the supported local Amp executor exposes authenticated current
  thread identity and the current-thread-owner email capability. If email is
  unavailable, obtain explicit approval for a local notification limitation and
  encode it in the future PRD and acceptance contract; otherwise local support
  remains gated on full preservation-triggered notification behavior. Delivery
  remains one best-effort request per preserved branch/commit, not guaranteed
  delivery.

### Tests and exit gate

- Contract tests enumerate every new code and enforce body/secret-free results.
- Existing v1 JSON envelopes and exit classes remain unchanged unless the PRD
  explicitly versions them.
- The accepted target matrix and exact existing-repository upgrade path have no
  unresolved product ambiguity.
- The exact local bootstrap prerequisites are fixed per target: shell and
  version, Git, HTTPS downloader, checksum and manifest parser, archive tool,
  and `rg`. Do not assume GNU `mapfile`, `mv`, `readlink`, tar, or shell behavior
  exists on macOS.

## Phase 2: Portable runtime metadata and release selection

### Design

Replace the single-target four-line runtime lock with a versioned v2 lock that
pins one bounded, credential-free HTTPS release manifest by version, revision,
URL, and SHA-256. The deterministic manifest maps exact target identifiers to
archive URL, archive SHA-256, archive root, size bound, and required files.
Setup selects only the exact detected OS/architecture entry after verifying the
manifest checksum; it then applies the existing archive path, type, size,
version, revision, and executable validation to the selected asset.

The manifest is not embedded in an archive whose checksum it contains. Release
builders produce target archives first, then the deterministic manifest and
its checksum. Guarded publication verifies all artifacts before creating the
release. Existing v1 locks remain readable for their Linux x86-64 target but
must produce a clear migration requirement on other targets.

Specify the exact lock grammar, manifest filename and adjacent checksum naming,
fixed public release-discovery source, and pre-`kb` bootstrap parser. The
bootstrap and native verifier consume the same hostile fixtures and enforce
equivalent acceptance rules. Fix the manifest at no more than 1 MiB and 16
target records, the downloaded archive at no more than 64 MiB, and extracted
regular-file payload at no more than 64 MiB unless measured target packaging
proves a different fixed ceiling is necessary before the contract is frozen.
Manifest values may tighten but never raise verifier ceilings or remove
mandatory package contents. Authenticate the complete selected target record
before extraction or execution.

### Deliverables

- Add strict v2 lock and manifest parsers with fixed byte/item/depth limits,
  duplicate/unknown target rejection, exact number handling where applicable,
  deterministic serialization, HTTPS-only URLs, and no fallback target.
- Make `kb init --release` and `--latest` resolve the verified manifest and
  generate a v2 lock. Preserve the explicit offline form with enough arguments
  to pin supplied local manifest bytes and a matching verified local
  runtime/template source without DNS, release lookup, or download. Validate
  every offline input before creating the target repository.
- Keep initialization atomic, source-free, one-commit, no-remote, and
  deterministic apart from existing generated identifiers.
- Make standalone `kb upgrade` target-aware without permitting it to mutate a
  setup-managed installation or cross-install another target.
- Include identical portable repository templates in every target archive and
  verify their hashes agree across release builders.
- Preserve the legacy `clamp-<version>-linux-x86_64.tar.gz` name and adjacent
  checksum asset for old standalone clients. Test the final assets with an
  immutable reviewed 0.1.4 executable, not only newly compiled updater tests.

### Tests and exit gate

- Unit tests cover exact/latest selection, target matching, unknown targets,
  manifest and archive checksum mismatches, malformed/oversized manifests,
  duplicate entries, redirected/non-HTTPS URLs, interrupted downloads, and
  atomic failure preservation.
- Initializer tests prove generated repositories contain no source and that v1
  Linux locks remain usable while v2 locks select every target accepted at the
  Phase 1 exit gate.
- Repeating release-manifest generation for the same target artifacts is
  byte-for-byte deterministic.

## Phase 3: Native macOS runtime and packages

### Deliverables

- Preserve the OCaml `Secure_fs` contract behind target-specific C backends.
  Implement and prove Darwin equivalents for no-follow traversal, retained
  entry identity, root descriptor locking, ownership/mode checks,
  descriptor-bound inspection and cleanup, atomic no-replace/exchange renames,
  nanosecond timestamps, and durable file and parent synchronization. Fail
  closed when a required primitive is unavailable; never fall back to ordinary
  overwrite or check-then-destruct behavior.
- Audit every direct `Unix.fsync` and other durability/process call in Local,
  Initializer, Upgrade, and adjacent modules, not only the secure-filesystem C
  stubs. Route required file-flush and parent-directory guarantees through the
  platform boundary with failure-injection seams and stable unsupported-
  operation handling. Qualify default case-insensitive APFS, the filesystem
  hosting the runtime installation, and rejection of unsupported/network
  filesystems on the selected minimum macOS version.
- Replace Linux `/proc` assumptions in executable discovery and descriptor
  tests with target-specific implementations that preserve identity and leak
  checks. Keep OS selection at the C/Dune boundary rather than scattering it
  through mutation logic.
- Make linker flags and runtime library discovery target-specific. Build a
  relocatable `macos-arm64` package with the executable, migrations, portable
  templates, version/revision markers, license, notices, and permitted
  non-system dynamic libraries. Validate dependencies with `otool -L` and
  package-relative install names.
- Choose and enforce the minimum macOS version. Treat code signing, hardened
  runtime, notarization, and their effect on reproducibility as explicit
  release gates.
- Keep local PostgreSQL bootstrap unsupported for macOS consumers in 0.2. Local
  users use the existing remote Neon URLs. Provide a native macOS integration
  harness backed by an explicitly identified disposable PostgreSQL/pgvector
  service, independent of Debian cluster discovery and `sudo`; reject ambient
  production URLs.

### Tests and exit gate

- Run the common unit suite on Linux and native Apple silicon.
- Add Darwin race/failure tests for every secure filesystem operation,
  including symlinks, hard links, concurrent replacement, lock contention,
  rollback, cleanup, mode/ownership checks, and directory durability.
- Exercise validation, every mutation/task transition, TODO regeneration,
  Git-object sync, retrieval, publication, and upgrade on a clean minimum-version
  macOS machine or dedicated runner.
- Run native sync, retrieval, database timeout/finalization, and publication
  integration tests through the macOS disposable database harness. Linux
  results and mocked database behavior cannot substitute for native client
  coverage.
- Verify the extracted package under an empty environment, resolve every
  dependency to the package or an allowed system library, and record signing
  and notarization evidence. Linux release reproducibility and behavior remain
  green.

## Phase 4: Portable private-repository scaffold and migration

### Deliverables

- Replace hard-coded repository paths in generated `AGENTS.md`, README, and the
  skill with a validated repository root established from the current Git
  checkout. Every command still passes an explicit `--repo`; no command trusts
  an arbitrary current directory after bootstrap.
- Teach the one tracked skill to distinguish capabilities rather than assume an
  Orb path:
  - verify the selected target/runtime lock and active `kb`;
  - explain that project secrets are Orb-only and check local inherited secret
    presence without printing values;
  - use indexed sync/search/get when credentials and authenticated Git are
    available, preserving current fallback classification;
  - retain full managed publication and conflict handling locally; and
  - never claim that local setup, a successful clone, or readable Markdown
    proves index freshness.
- Add `.agents/setup-local` as an idempotent, noninteractive-by-default script.
  It detects only supported targets, verifies and installs the pinned runtime
  outside the checkout, verifies `.agents/kb` selects it, validates the bundle,
  verifies a clean worktree and exact `origin`, checks the Amp CLI/helper and
  repository-local Git author, and reports secret presence. It performs no
  migration, embedding, synchronization, publication, package-manager mutation,
  shell-profile edit, or tracked-file edit.
- Keep `.agents/setup` and `.agents/resume` Orb-specific but share exact lock and
  archive verification. Orb setup continues to prepare only disposable local
  PostgreSQL and must remain idempotent and snapshot-safe.
- Add `kb scaffold upgrade` for existing assistants. Bootstrap migration in the
  existing assistant's Orb by downloading and verifying a separate standalone
  0.2 runtime outside the setup-managed installation and invoking that
  executable by absolute path. Do not first change the old runtime lock or
  self-upgrade its managed installation: the 0.1.4 setup archive allowlist does
  not recognize the new scaffold. The migration updates the portable scaffold
  and v2 runtime lock together. After review, commit and push only those
  scaffold changes using ordinary non-force Git, then run upgraded Orb setup
  before cloning locally.
- Automatic migration initially supports the exact verified 0.1.4 generated
  scaffold. Specify an explicit path for every other claimed 0.1.x source
  version. Owner-modified scaffold files receive a reviewable reconciliation
  procedure, never an overwrite switch or silent merge.
- Require a quiescent repository with no unrelated dirty state, active merge or
  rebase, or retained publication operation. Specify the multi-file install,
  reported-failure rollback, and abrupt-interruption recovery contract before
  coding. Never exchange the repository root or replace `.git`; preserve
  knowledge, configuration, history, and publication state. Do not claim crash-
  atomic replacement without a durable recovery protocol and tests.
- The upgrader replaces only files whose exact prior generated identity is
  known. Owner-modified files or foreign replacements produce a stable conflict
  with paths and no partial reported update; they are never overwritten.
- Record future scaffold identities in a tracked, non-secret manifest so later
  upgrades can distinguish generated bytes from owner changes. The command
  updates no knowledge concept and never publishes; the user reviews and
  commits scaffold changes through ordinary Git before cloning locally.
- Audit every generated instruction against the source-free consumer inventory.
  Remove source-development acceptance commands and historical/production-
  evidence claims that do not apply to generated assistants. Golden tests prove
  every referenced consumer script exists and no template claims rollout
  evidence.

### Tests and exit gate

- Golden tests cover portable skill commands from repository paths containing
  spaces and shell metacharacters without interpolating them unsafely.
- Setup-local tests run with empty/fake homes and hostile PATH, Git config,
  symlinks, locks, manifests, archives, and environment variables. They prove
  exact target selection, no secret output, no tracked mutation, idempotence,
  and preservation of a previous runtime after every injected failure.
- Start local Amp from the original parent shell with no pre-existing `kb` PATH
  entry. Alternate two repositories pinned to different runtime digests and
  prove each launcher remains stable; rerun setup after injected failure without
  changing either repository's selected runtime.
- Scaffold migration tests cover exact 0.1.4, current 0.2, modified owner files,
  interrupted updates, foreign replacements, reruns, and rollback equality.
- Run existing Orb setup twice and resume once after the refactor; verify the
  local PostgreSQL identity and that no production endpoint was contacted.

## Phase 5: Trusted local Amp Git authentication

### Design

Keep the current Orb credential path unchanged. Add a separate local path that
uses the authenticated Amp CLI installed on the user's machine, not arbitrary
Git credential configuration. Phase 1 determines whether separate non-secret
enrollment metadata is necessary; prefer invocation-time validation of a stable
official installation contract when sufficient. If needed, `setup-local`
records only non-secret helper identity metadata in an effective-UID-owned,
mode-0600 machine-local Clamp configuration outside tracked files. `kb`
revalidates the executable and every retained parent, the exact Amp HTTPS origin
and source identity, and any local configuration immediately before each
authenticated operation.

The local path invokes only the Amp `git-credential-helper` protocol with a
minimal allowlisted environment needed to read the user's Amp login. It resets
all other credential helpers, askpass, hooks, proxies, rewrites, includes, and
Git system/global behavior before exposing credentials. It never reads a token
itself, places credentials in argv or files, accepts `amp clone --no-git-setup`
without repair, or broadens publication to arbitrary Git hosts.

### Deliverables

- Define and implement strict local Amp executable discovery and identity
  validation for qualified official installation layouts. Specify accepted
  effective-user/root ownership, rejection of group/other-writable entries, and
  any explicitly approved official-layout indirections. Distinguish trusted
  same-user ownership from protection against hostile same-UID processes.
  Define how an ordinary Amp update invalidates or safely refreshes enrollment;
  never silently trust changed bytes or permanently strand an approved update.
- Validate the helper actually supports the exact Amp origin using a bounded,
  read-only remote operation during setup. Do not mutate repository/global Git
  configuration except through Amp's documented `amp clone`/credential setup.
- Extend sync fetch, remote conflict proof, non-force push, and post-push exact
  sync through the same authenticated boundary. Preserve every current timeout,
  output bound, process-group cleanup, redaction, and uncertain-operation
  classification.
- Keep repository-local dangerous Git configuration rejection. Recognize only
  the exact approved Amp helper source; do not trust a generic existing
  `credential.helper` merely because `git pull` succeeds.
- Add every new local-authentication error to Sync's authoritative fallback
  producer classification and its fixture/construction tests so an eligible
  outage degrades intentionally rather than becoming
  `sync_producer_contract_invalid`.

### Tests and exit gate

- Unit/integration tests use a fake official-layout Amp binary and loopback HTTPS
  Amp remote to cover helper success, missing login, timeout, oversized output,
  malformed protocol, path replacement, owner/mode changes, hostile Git config,
  redaction, and cleanup.
- Prove Orb and local authentication paths cannot be confused and that neither
  path leaks its credential environment to local/file/non-Amp remotes.
- Against a disposable private Amp-hosted fixture project, a real `amp clone`
  on each supported target can read `origin/main`, and `kb` can perform a
  reviewed no-force test publication and exact-tip sync. This is an explicit
  credentialed external gate, not an ordinary test.

## Phase 6: Local service configuration and end-to-end workflow

### Deliverables

- Document that Amp project secrets are not copied locally. Provide secure,
  shell-agnostic examples for launching `amp` with the three required variables
  supplied by the user's environment or secret manager. Do not recommend
  command-line secret arguments, tracked files, shell history, or an agent-
  readable `.env`.
- Verify whether the supported `amp clone` version writes repository-local
  `user.name` and `user.email`. If it does not, define explicit setup inputs or
  a documented user-owned `git config --local` prerequisite. Never infer an
  author from commit history or Clamp provenance and never fabricate an email.
- Add a body-free `kb doctor --local` (or an equivalently narrow setup check)
  that validates runtime/lock/target, repository identity, clean Git state,
  local Amp helper readiness, service-secret presence, database URL policy, and
  index compatibility. Network checks must be individually explicit; setup's
  default remains non-paid and read-only.
- Ensure a local Amp thread obtains its authenticated current thread ID/URL from
  Amp context exactly as the Orb skill does. Do not infer them from environment,
  branch names, files, or command output. Implement the notification decision
  frozen in Phase 1 without adding an external email provider or weakening
  conflict preservation.
- Update generated and public documentation for: create in Orb, upgrade an
  existing 0.1.x scaffold, commit/push the upgrade, `amp clone`, local setup,
  secure secret launch, local Amp use, degraded offline use, troubleshooting,
  and returning to an Orb without state divergence.
- Document the real bootstrap boundary: `kb init` creates a nonexistent separate
  directory; the user seeds an empty Amp remote with reviewed ordinary Git;
  only then does project-Orb setup and explicitly authorized service
  initialization occur. Never imply initialization can replace an existing
  `amp clone` checkout or its `.git` history.

### End-to-end acceptance

Use a disposable private Amp-hosted project, a disposable non-production Neon
branch, and a credit-limited OpenRouter key. Never use private user knowledge or
the production database.

On every target accepted at the Phase 1 exit gate:

1. Initialize a source-free assistant with the 0.2 runtime, push it, and complete
   the existing Orb setup, migration, initial sync, search, and get flow.
2. Run real `amp clone` into a path with spaces, invoke `.agents/setup-local`
   twice, and prove the worktree remains byte-for-byte clean.
3. Start a local Amp thread with securely inherited service variables. Verify
   skill discovery, validation, idempotent sync without re-embedding unchanged
   concepts, search without access telemetry, and get with exactly one access
   increment.
4. Record an explicit fact and task, regenerate TODO through the CLI, publish
   from the local thread without force, and verify exact Git durability and
   post-push index convergence from a fresh Orb.
5. Publish a concurrent nonconflicting Orb change and prove local fetch/rebase
   preservation. Exercise a genuine concept conflict, remote preservation,
   cleanup retry, and exactly one owner notification when the local capability
   exists.
6. Delay publication P's post-push synchronization while another executor
   publishes and indexes Q. P retains Git success, reports the existing target-
   mismatch/stale outcome, and never regresses Q's checkpoint to P. Exercise
   advisory-lock contention, stale local tracking refs, simultaneous independent
   gets, and surviving-path telemetry preservation during sync.
7. Remove one service credential at a time and prove unrelated operations still
   work, including the existing structured, non-semantic local fallback
   behavior, without secret leakage or false index freshness. With a fresh
   compatible index, unset both `OPENROUTER_API_KEY` and
   `KB_DATABASE_DIRECT_URL` and prove `get` still returns full indexed content
   and commits one access increment, while semantic search without the
   OpenRouter key returns its existing classified failure.
8. Upgrade an exact 0.1.4 assistant scaffold to 0.2, clone it locally, and repeat
   the core workflow. Prove an owner-modified 0.1.4 scaffold fails closed with
   no partial replacement.
9. Reopen the same project in a fresh Orb and confirm portable instructions did
   not regress Orb setup, retrieval, mutation, publication, or recovery.

### Exit gate

- All existing v1 acceptance remains green on Linux.
- Every target accepted at the Phase 1 exit gate and the release manifest pass
  clean-machine verification, including signing/notarization where required.
- The local workflow passes on real supported machines using `amp clone` and a
  local Amp executor; mocks alone are insufficient.
- Setup produces no tracked changes, stores no secrets, performs no paid or
  shared-state operation by default, and can be rerun safely.
- A local and an Orb agent can alternate writes without losing knowledge,
  bypassing confirmation, or treating Postgres as the source of truth. Preserve
  atomic increments for each successful get and the existing uncertain-COMMIT
  contract; do not promise exactly-once telemetry across connection loss or
  automatically retry an uncertain get.
- README, command help, generated templates, skill, architecture, operations,
  recovery, release documentation, and acceptance traceability describe the
  same supported target and failure boundaries.

## Release and rollout gate

1. Land the reviewed PRD and acceptance updates before behavior changes.
2. Complete Linux regression and native acceptance for every target accepted at
   the Phase 1 exit gate on exact clean source commits.
3. Build all target archives independently, then generate and verify the one
   deterministic release manifest and checksums. Prepare a draft release and
   upload every target archive/checksum and the manifest/checksum, but leave it
   unpublished. Verify the draft inventory and identities through an
   authenticated operator path. Interrupted uploads stay unpublished and
   retryable; preserve legacy Linux assets needed by old standalone clients.
4. Test exact 0.1.4 scaffold migration and rollback against the final bytes.
   Independently verify and safely extract the final legacy Linux archive, then
   invoke the immutable reviewed 0.1.4 executable's explicit offline initializer
   with the final version, revision, fixed public URL, archive SHA-256, and
   extracted runtime root. Require the exact expected source-free scaffold. The
   Phase 1 proxy/private-CA experiment proved that the immutable client uses the
   proxy but does not accept the process-local test CA, while the replacement
   offline mechanism succeeded against exact public 0.1.4 bytes. Do not use the
   failed proxy fixture as evidence. After the one public promotion, run the
   immutable client's discovery/download smoke test against the real fixed
   public URL before broad adoption.
5. Obtain explicit approval for, execute, and pass the disposable real-
   Amp/Neon/OpenRouter end-to-end gate using the final draft artifacts. Record
   only body-free evidence outside the public baseline.
6. Promote the draft to public exactly once only after every accepted target's
   artifact, manifest, checksum, signing/notarization result, and documentation
   link agrees with the exact source commit, and the local source commit,
   `origin/main`, and release tag agree. Never publish a partial multi-target
   release.
7. Upgrade one non-sensitive assistant in its Orb, commit and publish the
   scaffold/runtime-lock update, clone it to a clean local machine, and repeat
   the normal local workflow before recommending broad adoption.

Release creation, external test-project mutation, paid embedding requests, and
production-assistant upgrades require explicit operator approval. This plan
does not authorize them.
