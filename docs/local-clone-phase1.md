# Local-clone Phase 1 qualification record

## Scope and status

This record supports the planned Clamp 0.2.0 contract in
[PRD.md](../PRD.md). It records sanitized, reproducible observations rather
than treating one Orb as proof of a local target. No local target is supported
until its native acceptance gates pass.

Status on 2026-09-12:

- Linux x86-64 on local ext4 is a candidate after native non-Orb testing.
  Filesystem primitives, source-free bootstrap, authenticated read-only Amp
  Git, local-runner thread/owner-email interfaces, and a private
  PostgreSQL/pgvector harness passed. An updater-correlated ordinary Amp update
  replaced the recorded prior inode and passed official-checksum and full
  helper/path regression checks.
- Apple-silicon macOS is now a candidate after native testing on macOS 26.5.2
  (build 25F84). Local writable case-insensitive APFS primitives and a private
  PostgreSQL/pgvector harness passed. The minimum is conservatively fixed to
  macOS 26.5.2, and the source-free consumer bootstrap and authenticated local-
  runner thread/owner-email interfaces are qualified. A user-attested ordinary
  Amp update produced an updater-correlated replacement that passed official-
  checksum and full helper/path regression checks. Runtime porting and packaging
  remain later-phase work.
- Phase 1 is complete and Oracle-approved after every contract and native
  feasibility gate passed; no target is supported yet.

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

Native Linux observations from runner `clamp-linux`:

| Observation | Result | Contract consequence |
| --- | --- | --- |
| Host | Arch Linux rolling, kernel 7.2.3-arch1-3, native x86-64, glibc 2.44, local ext4 | Provides a native example within the existing Linux x86-64/glibc ≥2.36/ext4 candidate range; it does not directly test the glibc 2.36 boundary or qualify another libc/filesystem. |
| ext4 primitives | File/directory `fsync`, descriptor `flock`, hard-link identity, `O_NOFOLLOW`, descriptor-relative operations, `renameat2` no-replace/exchange, rollback, and retained-parent replacement detection passed | Native filesystem implementation is feasible; application-level failure injection remains with implementation. |
| Amp installation | `$HOME/.local/bin/amp` symlink to regular x86-64 ELF `$HOME/.amp/bin/amp`; current observed version `0.0.1789171288-gd95a61`; public SHA-256 `f34fc8597be9b1b5e5658ab8ebb29a4f2597242cd1c998ab9b845ab424bc8cf4` matched the official checksum; retained chain was safe and unchanged | Qualified direct-install shape. Keep `0.0.1789113641-gcd8b8a` as the common minimum; revalidate the installed executable identity before every credential-helper use. |
| Ordinary-update evidence | Amp's updater changed the installation through four recorded transitions from `0.0.1789113641-gcd8b8a` to `0.0.1789171288-gd95a61`. The retained updater process still held the deleted prior inode, whose bytes exactly matched the recorded prior SHA-256; both endpoint digests matched official checksums. | Passed with direct updater-mediated inode-replacement evidence. Hourly same-process events strongly support background initiation, but logs contain no explicit automatic/manual trigger field, so no stronger trigger claim is made. |
| Post-update regression | Direct path and stable symlink retained; executable inode changed; ownership/modes and no-follow retained-parent validation passed; disposable clone, explicit-helper exact-main read-only Git, and runner identity/email interfaces all passed at the new identity and final boundary | The enrollment design can treat changed bytes as untrusted, requalify them, and safely refresh only after all checks pass. |
| Existing-project clone | Disposable `amp clone user-skills` succeeded. Repository-local helper, `useHttpPath`, author name, and author email were unset; effective helper was `!amp git-credential-helper` with default-false `useHttpPath`. | Publication requires repository-local author configuration. Reconstruct the validated absolute helper rather than trusting ambient configuration. |
| Isolated authenticated Git | Bounded read-only `ls-remote` succeeded with the absolute helper, explicit `useHttpPath=true`, disabled system/global config and prompts, and only `HOME`, `PATH`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`, and `GIT_TERMINAL_PROMPT` | Freeze this Linux allowlist and helper invocation for the observed direct-install shape. |
| Local Amp interfaces | Authenticated runner supplied exact thread ID/URL, current-user identity, and owner-bound `send_email`; no email was sent | Interface feasibility passed; preservation ordering, deduplication, and delivery remain later end-to-end gates. |
| Native tools | Bash 5.3.15; Git 2.55.0; curl 8.22.0/OpenSSL 3.6.4; strict-wrapper-tested Python 3.14.7; GNU tar 1.35; sha256sum 9.11; rg 15.2.0 | Bootstrap semantics passed with the observed versions, which exceed the retained Linux floors; this run did not test the exact minimum versions. Opam, OCaml, Dune, and PostgreSQL remain build/test inputs, not consumer prerequisites. |
| Disposable database | Private PostgreSQL 15.19 and pinned pgvector 0.8.1 on Unix socket with TCP disabled; both migrations, UTF-8, schema constraints, vector(1536), and actual HNSW scan passed | Native database feasibility passed without ambient or production credentials. |

Native Apple-silicon observations from runner `clamp-macos`:

| Observation | Result | Contract consequence |
| --- | --- | --- |
| Host | macOS 26.5.2 build 25F84, native arm64, local writable case-insensitive APFS | Fix 26.5.2 as the conservative minimum; do not claim support for an older macOS release from this evidence. |
| APFS primitives | Directory `fsync`, file `F_FULLFSYNC`, descriptor `flock`, hard-link identity, no-follow traversal, retained descriptors, descriptor-relative unlink, exclusive/exchange rename, and exchange rollback passed in a disposable directory | Native filesystem implementation is feasible; application-level failure injection and abrupt-interruption tests remain with implementation. |
| Amp installation | `$HOME/.local/bin/amp` symlink to regular arm64 Mach-O `$HOME/.amp/bin/amp`; current observed version `0.0.1789171288-gd95a61`; bytes matched the official checksum; retained chain was not group/other writable | Qualified direct-install shape. Keep `0.0.1789113641-gcd8b8a` as the common minimum; revalidate the installed executable identity before every credential-helper use. |
| Ordinary-update evidence | The owner reported that the runner had updated in response to instructions to wait for an ordinary natural update without forcing or reinstalling. Amp changed from `0.0.1789113641-gcd8b8a` / SHA-256 `3c9371af1bed55f8fec8f03fe72f0e06f9aec97f671ee2338e131d1fb938d37d` to `0.0.1789171288-gd95a61` / SHA-256 `9b3c6eb26ccaa94d3c0d016d0a82e48c6d79d117d0559854e4ae752d09b321eb`; both digests matched official checksums, and a sanitized updater-success event aligned with the replacement. | Passed by accepting this contextual owner attestation together with updater-correlated local evidence and successful post-update checks. The log alone does not distinguish automatic from manual invocation. |
| Post-update regression | Direct path retained; binary inode changed; ownership/modes and no-follow parent validation passed; stable symlink was unchanged; disposable clone, explicit-helper exact-main read-only Git, and runner identity/email interfaces all passed at the new identity and final boundary | The enrollment design can treat changed bytes as untrusted, requalify them, and safely refresh only after all checks pass. |
| Existing-project clone | A disposable `amp clone user-skills` succeeded with exact Amp HTTPS origin shape. Repository-local helper, `useHttpPath`, author name, and author email were unset; the effective helper was `!amp git-credential-helper` with default-false `useHttpPath`. | Mac behavior differs from the Orb observation and must have its own target contract. Publication requires the user to configure a repository-local author. |
| Isolated authenticated Git | Read-only `ls-remote` succeeded with the absolute Amp helper, system/global Git configuration disabled, and only `HOME`, `PATH`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`, and `GIT_TERMINAL_PROMPT` retained | Freeze this Mac allowlist for the observed direct-install/helper shape; revalidate executable identity immediately before use and expose it only to exact Amp HTTPS origins. |
| Local Amp interfaces | The authenticated runner context supplied exact current-thread ID/URL, current-user identity, and owner-bound `send_email`; no email was sent | The existing skill model is feasible: retain thread identity in memory, pass it to `kb`, and request email only after preservation. End-to-end behavior remains a later implementation gate. `amp tools list` is not authoritative for agent server-side tools. |
| Native tools | Bash 3.2.57 without `mapfile` or associative arrays; Apple Git 2.50.1; curl 8.7.1; strict-wrapper-tested Python 3.9.6; bsdtar 3.5.3/libarchive 3.7.4; `shasum` 6.02; authenticated disposable arm64 ripgrep 14.1.1 | Freeze these conservative consumer floors and capabilities. Opam, OCaml, Dune, and PostgreSQL are build/test inputs, not source-free consumer prerequisites. Portable code cannot assume GNU shell, tar, checksum, or Linux path behavior. |
| Ripgrep artifact | Publisher-adjacent SHA-256 `24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be`; native arm64 execution passed Unicode JSON output, literal hostile path names, no-match exit 1, invalid-regex exit 2, and system PCRE2 resolution | Require ripgrep 14.1.1 or newer and preflight its behavior; the artifact's Mach-O minimum does not broaden Clamp's supported macOS floor. |
| Disposable database | PostgreSQL 15.19 and pinned pgvector 0.8.1 built as arm64, ran on a private Unix socket with TCP disabled, applied both migrations, and passed vector/HNSW checks | Native database integration is feasible without an ambient production URL. |
| Existing Clamp source | Current filesystem C stubs, linker/RPATH, release builder, and setup paths are Linux-specific | Porting belongs to the later native-runtime phase; Phase 1 must not claim a Mac runtime exists. |

The Orb exposes `AMP_BIN_DIR`, `AMP_API_KEY`, and `AMP_URL`. That is the v1 Orb
authentication path and is specifically excluded as evidence for a local login
or local helper environment.

## Phase 1 feasibility resolution

Both retained targets have passed ordinary-update, local helper, filesystem,
database, consumer-bootstrap, and runner-interface feasibility. Their minimum
OS, filesystem, exact source-free consumer bootstrap tools and versions, exact
local Amp environment allowlists, and disposable PostgreSQL/pgvector harnesses
are frozen from native evidence. Opam, OCaml, and Dune remain build-runner
inputs, not consumer prerequisites.

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
   allowlisted environment. This successful native path and the ordinary-update
   observation qualify Phase 1. Missing-login, timeout, malformed-output, and
   path-replacement failure injection execute after the Phase 5 helper
   implementation and must not retain helper output.
3. Confirm whether clone writes repository-local `user.name` and `user.email`.
4. Start a local Amp thread in the clone and prove authenticated current-thread
   ID/URL and current-thread-owner email capability. Send at most one test
   request to the authenticated test owner after explicit approval; do not use
   an inferred identity or external email provider.
The successful native portions of the first four steps qualify Phase 1
environment and capability assumptions. Failure injection and end-to-end
effects execute after their owning implementation phase. The following steps
are also later gates:

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
