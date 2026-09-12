# Phase 3 native macOS verification

This is repository implementation evidence, not release authorization. The
candidate was verified in the development orb and dedicated `clamp-macos`
runner from an uncommitted snapshot based on
[`8c065b2`](https://github.com/gvrooyen/clamp/commit/8c065b2ff01902d606df1a6f5c4872efada13e26).
The verification archive carries version 0.1.4 and that base REVISION; it
contains uncommitted implementation changes and must not be published.

Phase 3's native Apple-silicon and Linux repository matrices passed. Phase 3 is
implementation-complete; the release/operator qualifications listed below
remain mandatory before macOS is advertised or a 0.2 release is published.

## Host and isolated inputs

- Observed host: macOS **26.5.2**, build **25F84**, **arm64**.
- Filesystem: local, default case-insensitive APFS. The working checkout and
  private build/database prefix both passed file and directory fsync followed
  by `F_FULLFSYNC`. This establishes syscall acceptance, not power-loss testing.
- Private prefix: `/private/tmp/clamp-phase3-toolchain`; isolated OPAMROOT:
  `/private/tmp/clamp-phase3-toolchain/opam`; switch: checkout `_opam`.
- OCaml 5.5.0, Dune 3.24.2, opam 2.5.2; locked OCaml libraries. Upstream's
  `compiler-cloning.disabled` is required on Darwin; the lock allows either
  upstream-selected cloning mode without changing library versions.
- PostgreSQL 15.19 and pgvector 0.8.1 built from source into the private `pg`
  prefix. PostgreSQL configured with shared OpenSSL 3.5.5, without readline,
  zlib, or ICU. Apple SDK/system libcurl 8.7.1 supplies HTTPS transport.
- pkgconf 2.5.1 built into the private prefix. No Homebrew, sudo, shell-profile
  changes, or shared/system package installation was used.
- Apple clang is 21.0.0 (`clang-2100.1.1.101`). Builds set
  `MACOSX_DEPLOYMENT_TARGET=26.5.2`. The SDK reports 26.5; the
  executable explicitly encodes minos 26.5.2. All three bundled dylibs also
  encode minos 26.5.2 and contain only arm64.

Inputs were downloaded over certificate-verified HTTPS. SHA-256 values:

| Input | SHA-256 | Verification source |
| --- | --- | --- |
| opam 2.5.2 arm64 executable | `407e53416cfb49b41ce80e6d3c67a3df08df7f5028f407311f457f4e2a19004b` | GitHub upstream release asset digest |
| PostgreSQL 15.19 tar.bz2 | `e1a64a87a46b825b88c082e4518161a47aab53c45694964f8ba1df28f7859f89` | Upstream matching `.sha256` |
| pgvector 0.8.1 source archive | `a9094dfb85ccdde3cbb295f1086d4c71a20db1d26bf1d6c39f07a7d164033eb4` | Existing repository source pin |
| OpenSSL 3.5.5 tar.gz | `b28c91532a8b65a1f983b4c28b7488174e4a01008e29ce8e69bd789f28bc2a89` | GitHub upstream release asset digest |
| pkgconf 2.5.1 tar.xz | `cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243` | Locally recorded digest; upstream directory publishes no checksum/signature for this file |

Sources: [opam](https://github.com/ocaml/opam/releases/tag/2.5.2),
[PostgreSQL](https://ftp.postgresql.org/pub/source/v15.19/),
[pgvector](https://github.com/pgvector/pgvector/releases/tag/v0.8.1),
[OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.5.5),
[pkgconf upstream directory](https://distfiles.ariadne.space/pkgconf/).
The pkgconf digest is not represented as an independently verified upstream
checksum. Downloaded metadata and build logs are retained in the private prefix.

## Commands and results

Build/test commands use this explicit environment, not ambient service secrets:

```bash
env -i \
  HOME=/private/tmp/clamp-phase3-toolchain \
  PATH=/private/tmp/clamp-phase3-toolchain/bin:/private/tmp/clamp-phase3-toolchain/pg/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  OPAMROOT=/private/tmp/clamp-phase3-toolchain/opam \
  MACOSX_DEPLOYMENT_TARGET=26.5.2 \
  /bin/sh -c '
    opam exec -- dune build @all &&
    opam exec -- dune build @install &&
    opam lint clamp.opam &&
    opam exec -- dune runtest --force test/unit &&
    opam exec -- dune exec test/unit/secure_fs_test.exe
  '
```

- Native `@all`, `@install`, common unit tests (151 Alcotest cases plus the
  runtime-metadata and macOS-builder Python tests), and `opam lint` passed.
  Lint output: `clamp.opam: Passed.` No diagnostics were suppressed.
- Mutation tests: all 49 passed, including mode/ownership races, bounded
  descriptors, preinstall witnesses, private namespace cleanup, paired task/TODO
  rollback, fault-injected file/directory durability, and final completion proof.
- Upgrade tests: all twelve passed under both umask `022` and `077`, including
  atomic installation, portable tar listing, verified manifest archives,
  parent-flush restoration, and preservation of a foreign replacement with an
  honest uncertain-state result.
- All nine focused Secure_fs cases passed. They cover symlink inode witnessing, no-follow traversal,
  hard links, atomic no-replace/exchange and unavailable-operation mapping,
  descriptor chmod, flock contention, APFS directory durability, kqueue
  deletion/rename/replacement distinctions, descriptor reuse, failed rmdir,
  repeated observation and exact descriptor cleanup, a known fractional
  timestamp, live descriptor-count changes, and fail-closed devfs rejection.
- Disposable PostgreSQL suite: all 21 passed, including migrations, catalog and
  ledger validation, hostile environments, connection failover, deadlines, and
  finalization.

The resumed integration commands ran sequentially with
`env -i HOME=/private/tmp/clamp-phase3-toolchain PATH=/usr/bin:/bin:/usr/sbin:/sbin`:

| Command (from the checkout root) | Final result |
| --- | --- |
| `test/run-macos-integration /private/tmp/clamp-phase3-toolchain/pg phase7_publication_test` | 19 passed in 427.915s; one historical-binary case explicitly skipped |
| `test/run-macos-integration /private/tmp/clamp-phase3-toolchain/pg phase8_workflow_test` | 3 passed in 22.622s |
| `test/run-macos-integration /private/tmp/clamp-phase3-toolchain/pg phase3_database_test` | 21 passed in 5.375s |
| `test/run-macos-integration /private/tmp/clamp-phase3-toolchain/pg phase5_sync_test` | 26 passed in 716.911s with command-scoped idle-sleep inhibition |

The harness's five invalid-invocation checks (missing arguments, loopback URL,
non-loopback URL, nonexistent prefix, and non-allowlisted suite) returned 2
with no output or cluster creation. A disposable fake PostgreSQL prefix proved
that deliberately supplied PG/KB/old-sanitization-marker variables were removed;
an unsupported version was rejected before cluster creation. No ambient secret
values were inspected. The fake prefix was removed after verification.

`git diff --check`, shell/Python syntax checks, and changed Markdown LF/local-link
checks passed. Final status inspection found only the intended paths listed
below, no staged changes, and no accidental generated/toolchain files. Disposable
clusters and the interrupted publication fixture were removed; the isolated
toolchain, logs, and ignored verification packages remain available for reuse.

Latest requalification logs under `/private/tmp/clamp-phase3-toolchain/` are
`oracle-green-unit.log`, `oracle-green-database.log`,
`oracle-green-package.log`, and `oracle-green-extraction.log`. Earlier full
integration logs are retained separately; one historical database/sync log
retains the diagnosed sleep-affected failure described below and is not a green
run.

Do not rebuild with Dune while the integration executables run from
`_build/default/test/integration`: Dune can remove their untracked Alcotest log
directory. One intermediate run exposed this harness usage error; final runs
are sequential.

## Native failures diagnosed before changing expectations

- APFS may keep a deleted directory's old nlink while an O_RDONLY descriptor is
  open. No link count was synthesized. Darwin registers a descriptor-bound
  kqueue immediately before final validated rmdir and latches `NOTE_DELETE`;
  Linux still checks real zero links. Watches are not reused across exchange.
- `/tmp` inherits the wheel group, and unprivileged chmod can strip setgid.
  Permission fixtures now give their temporary root the process's effective
  group. Every original unsafe-mode assertion remains.
- APFS rejects invalid UTF-8 names at mkdir (`EILSEQ`, surfaced as OCaml
  `EUNKNOWNERR 92`) and aliases case-equivalent paths. Impossible worktree
  fixtures now assert filesystem behavior or inject a distinct sibling. Git
  collision fixtures directly stage both names, preserving hostile-tree tests.
- Publication returned `publish_validation_materialization_failed`, not
  `publish_validation_failed`: exclusive materialization cannot represent
  both case spellings on APFS. The test expects the observed capability-specific
  fail-closed stage and still proves the invalid candidate was not pushed.
- Amp helper validation rejected a `/tmp`-aliased test HOME as noncanonical.
  The fixture now uses `Unix.realpath`; authentication validation is unchanged.
- Native stderr exposed absent `/bin/true` and `/usr/bin/rg` fixture assumptions.
  Tests use `/usr/bin/true` and grep when ripgrep is unavailable. No production
  Git/authentication behavior was changed to accommodate a fixture.
- The 1,001-document CLI output test exceeded its 60-second capture watchdog.
  Its fixture watchdog is now 240 seconds; production Git/database/retrieval
  deadlines and exact diagnostic/body-free assertions are unchanged.
- One resumed run returned `git_timeout` in the production diagnostic adapter.
  `pmset -g log` recorded sleep from 21:47:48 to 21:52:26 +0200 on 2026-09-12
  (278 seconds), with the failure recorded at 21:52:28. This exceeds the
  unchanged 30-second per-Git-process deadline. The harness now uses
  `caffeinate -i` only for its command lifetime; no persistent power setting
  changes. The complete awake rerun passed, and its assertion disappeared
  when the command ended. Manual sleep or power loss can still interrupt tests.

## Deterministic unsigned archive

Run twice from an empty environment (fixed HOME/PATH only):

```bash
release/build-macos \
  --library-license libpq.5.dylib=/private/tmp/clamp-phase3-toolchain/postgresql-15.19/COPYRIGHT \
  --library-license libssl.3.dylib=/private/tmp/clamp-phase3-toolchain/openssl-3.5.5/LICENSE.txt \
  --library-license libcrypto.3.dylib=/private/tmp/clamp-phase3-toolchain/openssl-3.5.5/LICENSE.txt
```

Both archives compare byte-for-byte equal using `cmp`, including final builds
under different umasks (`077` and `022`). The builder explicitly normalizes the
archive root's mode as well as its descendants:

```text
b05be61ea0ba46c36cfffaa377f59632b624f6e20e3d0642dce4a5c8fa687d31  clamp-0.1.4-macos-arm64.tar.gz
```

Only the executable, permitted dylibs, migrations, portable templates, markers,
license/notices, and runtime README are included. Archive entries use
deterministic timestamps, order, owner/group and modes; no implementation source
or toolchain is included.

`otool -L` resolves the executable's libpq to
`@loader_path/../lib/libpq.5.dylib`; libpq resolves OpenSSL using
`@loader_path/libssl.3.dylib` and `@loader_path/libcrypto.3.dylib`. Bundled
library IDs use `@rpath/NAME`; all dependency loads resolve locally. The only
unbundled loads are `/usr/lib/libcurl.4.dylib` and `/usr/lib/libSystem.B.dylib`.
The only `LC_RPATH` is `@executable_path/../lib`.

Each builder run extracts and checks version/help with a sanitized environment.
A separate extraction also passed literally `env -i /absolute/path/bin/kb
--version` (output `0.1.4`) and `env -i /absolute/path/bin/kb --json --help`.
Help remains ordinary Cmdliner text even with `--json`; this is existing CLI
behavior, not JSON-formatted help. No developer signing/notarization ran.

The manifest generator also validated private copies of the native archives,
including required files, markers, size limits, and checksums. No manifest or
archive was published.

## Linux regression and reproducibility

The exact final implementation snapshot passed `dune build @all @install`,
`opam lint`, the full unit suite, and all Linux integration suites: database
21/21, sync 26/26, publication 19 passed with the separately controlled
historical-binary case skipped, and workflow 3/3. Two clean-snapshot
`release/build` runs were byte-identical:

```text
e4397f07fe5b515b3cdf4e028bfdafe009f95910411c3ff13d2314d006a90cd7  clamp-0.1.4-linux-x86_64.tar.gz
```

The temporary verification checkout and archives were removed after recording
the result.

## Changed source paths

```text
ACCEPTANCE.md
ARCHITECTURE.md
PLAN.md
README.md
bin/dune
bin/linker-flags
clamp.opam.locked
docs/building.md
docs/macos-phase3.md
lib/database.ml
lib/database.mli
lib/initializer.ml
lib/local.ml
lib/secure_fs.ml
lib/secure_fs.mli
lib/secure_fs_stubs.c
lib/upgrade.ml
lib/upgrade.mli
release/build
release/build-macos
release/manifest
test/golden/command_contract.t
test/integration/disposable_database.ml
test/integration/dune
test/integration/phase3_database_test.ml
test/integration/phase5_sync_test.ml
test/integration/phase7_publication_test.ml
test/integration/phase8_workflow_test.ml
test/run-macos-integration
test/unit/dune
test/unit/build_macos_test.py
test/unit/initializer_test.ml
test/unit/phase1_test.ml
test/unit/phase2_test.ml
test/unit/phase3_test.ml
test/unit/secure_fs_test.ml
test/unit/upgrade_test.ml
```

## Release/operator gates and intentionally unsupported operations

- Developer signing, hardened runtime, notarization, Gatekeeper acceptance,
  separate clean-machine installation/upgrade, and physical power-loss/storage
  qualification remain unverified and require separate authorization.
- A clean, committed release candidate and final release reproducibility and
  acceptance evidence are still required. The dirty 0.1.4 verification archive
  does not establish these, regardless of its stable packaging checksum.
- The immutable reviewed Phase 7 cross-version executable is not present in the
  public source tree; ordinary tests cannot substitute for that controlled gate.
- Network filesystems and non-APFS volumes are rejected by native filesystem
  checks. No mounted network-volume qualification was performed.
- No production Neon, OpenRouter, authenticated Amp remote, release publishing,
  email, or external Git push was attempted. Integration uses disposable local
  Git remotes, mock embedding adapters and the private database only.
- Orb lifecycle scripts and consumer `--local-database` remain Linux-only.
  These restrictions are intentional for 0.2 and do not prevent repository
  completion of PLAN.md Phase 3.
