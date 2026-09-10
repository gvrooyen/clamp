# Development and acceptance

This guide is for work on the public Clamp implementation. A source-free
private knowledge repository does not need this toolchain.

For source-build prerequisites and non-Linux porting requirements, see
[Building Clamp](./building.md).

## Orb setup

The source repository's `.agents/setup` installs checksum-pinned opam, creates
the repo-local switch from the locked dependency set, installs PostgreSQL 15
development prerequisites, builds pgvector 0.8.1 when needed, and prepares a
disposable local `clamp_test` database. It reports whether project secrets are
present without printing them and never contacts or changes Neon or OpenRouter.

The switch is retained in orb snapshots. `.agents/resume` performs a fast,
authenticated local PostgreSQL readiness check after an orb wakes.

When changing lifecycle behavior, run:

```bash
.agents/setup
.agents/setup
.agents/resume
```

The second setup invocation checks idempotence. Local setup accepts only the
Debian-managed PostgreSQL 15 `main` cluster at its canonical Unix socket and
data directory; it does not fall back to TCP or ambient libpq service settings.

## Build and test

Use the repository-local opam switch:

```bash
opam exec -- dune build @all
opam exec -- dune build @install
opam exec -- dune runtest
opam lint clamp.opam
```

Tests use Alcotest, Dune cram tests, and disposable local PostgreSQL databases.
Never aim destructive integration tests at the production Neon branch.

## Phase 9 acceptance

Stage the exact source candidate, then run:

```bash
.agents/phase9-acceptance
```

The runner rejects unstaged tracked changes and non-ignored untracked files. It
re-executes itself with an empty private `HOME`, fixed tool paths, allowlisted
variables, and disabled shell, psql, Git, cloud, and credential configuration.
It creates and migrates a random disposable local database, builds install and
all targets, validates the bundle, forces the repository-owned test suites,
runs `opam lint`, audits staged regular blobs for bounded leakage, and attempts
database cleanup after every creation attempt.

The runner contains no Neon, OpenRouter, Amp Git publication, or email command
and receives no production credentials. This constrains its environment and
command plan; it is not a network namespace proving that arbitrary future test
code cannot make an unauthenticated request.

The reviewed Phase 7 cross-version migration case is not run by the ordinary
acceptance command because the public source tree contains no immutable old
binary. Its separately controlled historical evidence is recorded in the
acceptance matrix. An ambient `CLAMP_REVIEWED_PHASE7_KB` is rejected rather than
executed.

The criterion-to-evidence map is in
[ACCEPTANCE.md](../ACCEPTANCE.md#acceptance-criteria-traceability).

## Review rules

1. Follow [AGENTS.md](../AGENTS.md).
2. Treat [PRD.md](../PRD.md) as the definition of v1 behavior.
3. Keep user documentation aligned with the implemented release.
4. Keep credentials and private knowledge out of the public repository.
5. Treat local acceptance as evidence, not authority for production actions.
