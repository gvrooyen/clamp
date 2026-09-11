# Local-clone Phase 1 qualification record

## Scope and status

This record supports the planned Clamp 0.2.0 contract in
[PRD.md](../PRD.md). It records sanitized, reproducible observations rather
than treating one Orb as proof of a local target. No local target is supported
until its native acceptance gates pass.

Status on 2026-09-11:

- Linux x86-64 on local ext4 is a candidate. Repository and current Orb
  observations are captured; a clean non-Orb local runner is still needed.
- Apple-silicon macOS is now a candidate after native testing on macOS 26.5.2
  (build 25F84). Local writable case-insensitive APFS primitives and a private
  PostgreSQL/pgvector harness passed, but the minimum OS and bootstrap closure
  remain unset because `rg` and a native Clamp toolchain were absent. Exact Amp
  standalone thread/owner-email interfaces, runtime porting, packaging, and
  update requalification remain pending. A real existing-project clone and
  isolated authenticated read-only Git operation passed.
- Phase 1 is therefore in progress and must not be marked complete.

## Authoritative Amp documentation

The current Amp documentation establishes only these product facts:

- [Getting started with the CLI](https://ampcode.com/docs/cli) states that the
  CLI supports macOS, Linux, and Windows through WSL, starts a local thread by
  default, installs through Amp's documented installer, and updates
  automatically.
- [Projects](https://ampcode.com/docs/projects) specifies
  `amp clone owner/project-name` for an Amp-hosted repository, project matching
  from Git remotes, and Orb-only project secret/environment injection.
- [Handling secrets](https://ampcode.com/docs/orbs/handling-secrets) describes
  project values as Orb environment variables; it does not promise that they
  are copied into local CLI processes.
- `amp clone --help` documents automatic Git credential-helper setup and the
  opt-out `--no-git-setup` flag.

These documents do not guarantee a minimum CLI version, executable inode/path,
credential-store environment, repository-local commit author, Clamp-compatible
filesystem primitive, current-thread identity interface, or owner-email tool in
a local executor. Those remain Clamp qualification responsibilities.

## Sanitized observations

The following observations were collected in the Linux x86-64 Clamp source Orb.
No credential value, helper response, private repository name, or knowledge
body was retained.

| Observation | Result | Contract consequence |
| --- | --- | --- |
| `amp --version` | `0.0.1789099241-gef9fd5` | Candidate minimum; native local qualification may raise it. |
| Amp executable | regular ELF x86-64 file at `$HOME/.amp/bin/amp`; effective-user-owned; parents mode `0700`; executable mode `0755` | Qualify this direct-install shape only on Linux; reject substitutions and other layouts. |
| `amp clone` of an Amp-hosted personal repository | exact `https://ampcode.com/...` origin and successful read-only `ls-remote` | Preserve exact-host/path validation; this Orb observation is not local-login proof. |
| effective Amp-host helper | `credential.https://ampcode.com.helper=!amp git-credential-helper`, with `useHttpPath=true` | Reconstruct an explicit absolute validated helper; do not trust ambient global helpers. |
| repository-local Git author after clone | both `user.name` and `user.email` absent | Require the user to configure both locally before publication. |
| Amp update documentation | automatic background replacement after restart | Store no permanent trust assumption; rerun setup to requalify changed bytes. |
| source Orb filesystem | local ext4 with Linux no-replace/exchange primitives covered by v1 tests | Candidate baseline only; reject unqualified filesystems. |
| source Orb bootstrap tools | Bash 5.2, Git 2.55, curl 7.88.1, Python 3.11, GNU tar 1.34, coreutils 9.1, ripgrep 14.1 | Contract floors do not exceed the lowest observed required versions; native local tests remain required. |
| immutable 0.1.4 HTTPS proxy/private-CA experiment | The reviewed release executable honored `HTTPS_PROXY` and opened only `CONNECT github.com:443`, but rejected the private CA when supplied process-locally through `CURL_CA_BUNDLE` and `SSL_CERT_FILE`; it sent no HTTP request and returned `init_release_network_error` (5). | The proposed proxy fixture is not viable and must not be used as release evidence. |
| immutable 0.1.4 offline compatibility mechanism | After independent SHA-256 verification and extraction of the public 0.1.4 archive, the same immutable executable accepted its exact version, revision, public URL, archive digest, and extracted runtime root through the explicit offline initializer; it returned `repository_initialized`, produced one commit and no remote, and reproduced the recorded runtime-lock digest. | Use this qualified offline mechanism with independently validated final legacy-archive bytes before publication; test public download discovery separately after publication. |

Native Apple-silicon observations from runner `clamp-macos`:

| Observation | Result | Contract consequence |
| --- | --- | --- |
| Host | macOS 26.5.2 build 25F84, native arm64, local writable case-insensitive APFS | Candidate evidence for only this exact environment; no broader minimum macOS version is inferred. |
| APFS primitives | Directory `fsync`, file `F_FULLFSYNC`, descriptor `flock`, hard-link identity, no-follow traversal, retained descriptors, descriptor-relative unlink, exclusive/exchange rename, and exchange rollback passed in a disposable directory | Native filesystem implementation is feasible; application-level failure injection and abrupt-interruption tests remain with implementation. |
| Amp installation | `$HOME/.local/bin/amp` symlink to regular arm64 Mach-O `$HOME/.amp/bin/amp`; observed version `0.0.1789113641-gcd8b8a`; bytes matched the official checksum; retained chain was not group/other writable | Candidate direct-install shape. Requalification after an ordinary update and exact installer provenance remain required. |
| Existing-project clone | A disposable `amp clone user-skills` succeeded with exact Amp HTTPS origin shape. Repository-local helper, `useHttpPath`, author name, and author email were unset; the effective helper was `!amp git-credential-helper` with default-false `useHttpPath`. | Mac behavior differs from the Orb observation and must have its own target contract. Publication requires the user to configure a repository-local author. |
| Isolated authenticated Git | Read-only `ls-remote` succeeded with the absolute Amp helper, system/global Git configuration disabled, and only `HOME`, `PATH`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`, and `GIT_TERMINAL_PROMPT` retained | Freeze this Mac allowlist for the observed direct-install/helper shape; revalidate executable identity immediately before use and expose it only to exact Amp HTTPS origins. |
| Local Amp interfaces | `amp tools list` did not advertise current-user identity, thread read/status, or owner-email tools | The runner thread's authenticated tools do not prove that standalone local Clamp can obtain the required capabilities. |
| Native tools | Bash 3.2.57 without `mapfile`; Apple Git 2.50.1; curl 8.7.1; Python 3.9.6 requiring explicit duplicate-key/non-finite JSON rejection; bsdtar 3.5.3; `shasum` 6.02; no `rg`, Opam, OCaml, or Dune | These are observations, not frozen minimums. Portable code cannot assume GNU shell, tar, checksum, or Linux path behavior. |
| Disposable database | PostgreSQL 15.19 and pinned pgvector 0.8.1 built as arm64, ran on a private Unix socket with TCP disabled, applied both migrations, and passed vector/HNSW checks | Native database integration is feasible without an ambient production URL. |
| Existing Clamp source | Current filesystem C stubs, linker/RPATH, release builder, and setup paths are Linux-specific | Porting belongs to the later native-runtime phase; Phase 1 must not claim a Mac runtime exists. |

The Orb exposes `AMP_BIN_DIR`, `AMP_API_KEY`, and `AMP_URL`. That is the v1 Orb
authentication path and is specifically excluded as evidence for a local login
or local helper environment.

## Remaining Phase 1 feasibility gates

Before implementation begins, Phase 1 must:

1. Run the local Amp helper/layout/update/thread-identity/email checks below on
   a clean non-Orb Linux runner. On Mac, complete the ordinary-update,
   local-executor thread/owner-notification capability decision, and consumer
   bootstrap qualification left pending by the native passes.
2. Freeze each retained target's minimum OS, filesystem, exact source-free
   consumer bootstrap tools and versions, exact local Amp environment
   allowlist, and disposable PostgreSQL/pgvector feasibility harness from
   native evidence. Opam, OCaml, and Dune are build-runner inputs, not consumer
   prerequisites.

The immutable-client compatibility feasibility gate is resolved. The attempted
proxy/private-CA mechanism failed closed, and the explicit offline initializer
mechanism above was proved against exact public 0.1.4 bytes. The final 0.2.0
legacy asset must repeat that protocol with final independently verified bytes;
that is a release gate, not Phase 1 evidence already claimed for a nonexistent
artifact.

These are feasibility decisions needed before implementing Phases 2–6. The
complete workflow tests described next are later implementation/release gates,
not circular prerequisites for starting their implementation.

The Darwin filesystem/process port, native Clamp build, relocatable package
closure, empty-environment package checks, signing/notarization,
application-level failure injection, setup/migration behavior, and complete
cross-executor workflows remain owned by their later implementation and release
phases. Their absence does not undo the Phase 1 APFS/database feasibility
evidence or become a circular prerequisite for beginning those phases.

## Native qualification and later acceptance protocol

Run this protocol separately on each proposed target with a disposable
Amp-hosted repository and disposable non-production database. Capture only
versions, path shapes, booleans, stable result codes, and digests of public test
artifacts.

1. Install Amp through the proposed official layout, authenticate normally,
   restart once after an ordinary automatic update, and record version/path,
   ownership, mode, symlink/indirection, and changed-identity behavior.
2. Run real `amp clone` without Orb authentication variables. Record the exact
   origin shape and scoped helper configuration, then prove bounded
   noninteractive `get` and read-only `ls-remote` under Clamp's proposed
   allowlisted environment. Repeat missing-login, timeout, malformed-output,
   update, and path-replacement cases without retaining helper output.
3. Confirm whether clone writes repository-local `user.name` and `user.email`.
4. Start a local Amp thread in the clone and prove authenticated current-thread
   ID/URL and current-thread-owner email capability. Send at most one test
   request to the authenticated test owner after explicit approval; do not use
   an inferred identity or external email provider.
The first four steps qualify Phase 1 behavior and environment assumptions. The
following steps execute after their owning implementation phase:

5. Exercise every required secure-filesystem primitive and durability failure
   on the target filesystem, including parent-directory sync, locks, hard
   links, no-follow traversal, no-replace/exchange rename, rollback, concurrent
   replacement, and abrupt interruption recovery.
6. Verify the source-free package and all dependencies in an empty environment.
   Run database timeout/finalization, sync, retrieval, publication, and upgrade
   integration tests against an identified disposable PostgreSQL/pgvector
   service without accepting an ambient production URL.
7. Run the complete 0.2 end-to-end workflow twice from the original parent
   shell, alternate two differently pinned repositories, and prove both
   worktrees and runtimes remain independent.

Any failed or unavailable step leaves that target candidate/pending. Evidence
from Linux, an Orb, mocks, or Amp's general platform-support statement cannot
substitute for another target's native result.

## Fixture provenance

- `test/fixtures/v0_2_phase1/scaffolds.json` was derived from the immutable
  public v0.1.4 tag commit and published adjacent checksum. It separates the
  six replaceable static templates from the validated runtime lock and
  preserved owner configuration, TODO, and knowledge. The sanitized initial
  example uses `local.test/clamp-fixture`; no private identity is present.
- `test/fixtures/v0_2_phase1/environments.json` stores only state names,
  version/path shapes, prerequisite names, expected stable codes, and body-free
  compatibility observations.
- `test/fixtures/v0_2_phase1/contracts.json` is the machine-readable code,
  envelope, exit-class, and body-free payload-key contract.

Fixture changes require PRD and acceptance review. They are not evidence that a
future command is already implemented.
