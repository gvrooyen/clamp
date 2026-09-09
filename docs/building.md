# Building Clamp

Clamp's only supported package is Linux x86-64 with glibc 2.36 or newer. macOS
requires a platform port. For ordinary use, install the
[published Linux release](./releases.md) instead of building from source.

## Linux source build

Clamp pins OCaml 5.5.0, Dune 3.24.2, and its transitive OCaml dependencies.
Native builds need a C toolchain, `pkg-config`, and libpq and libcurl
development files. The pinned YAML package builds its bundled libyaml sources.

Run these commands from the root of a fresh source checkout on Debian 12
x86-64. The opam download is architecture-specific.

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential ca-certificates curl git libcurl4-gnutls-dev \
  libffi-dev libpq-dev m4 pkg-config unzip

mkdir -p "$HOME/.local/bin"
(
  set -eu
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "$temp_dir"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    https://github.com/ocaml/opam/releases/download/2.5.2/opam-2.5.2-x86_64-linux \
    --output "$temp_dir/opam"
  printf '%s  %s\n' \
    edfca2630c373b44b7ee1c2f81cd8dcf67468d0db57d6c02158de553ac63dbd4 \
    "$temp_dir/opam" | sha256sum --check
  install -m 0755 "$temp_dir/opam" "$HOME/.local/bin/opam"
)
export PATH="$HOME/.local/bin:$PATH"

opam init --bare --no-setup --yes
opam switch create . ocaml-base-compiler.5.5.0 --no-install --yes
opam install . --deps-only --with-test --locked --yes
opam exec -- dune build @all
opam exec -- dune build @install
opam exec -- dune runtest test/unit
```

The executable is `_build/default/bin/kb.exe`. `dune build @install` builds the
install targets; it does not install them. The commands above run the unit
suite. Full `dune runtest` requires the disposable PostgreSQL 15 and pgvector
environment described in [Development and acceptance](./development.md).

Use the repository's `.agents/setup` in an Amp development orb. It additionally
prepares the exact local PostgreSQL and pgvector environment used by integration
tests. It is not a general installer for other operating systems.

`release/build-in-container` runs as root inside a disposable Debian 12 x86-64
container. It pins the Debian package snapshot, opam executable, opam
repository, compiler, and locked dependencies, then invokes `release/build`.
It does not launch the container or select its image. A production build must
run it inside a digest-pinned base image. Do not run it directly on your host.

## What makes a target supported

A supported target needs tested filesystem and process behavior, native
dependency linkage, packaging, installation, and upgrade support. Compilation
alone is not sufficient.

Do not replace a missing atomic primitive with a check followed by an ordinary
rename. Clamp's write contract requires atomic no-replace and exchange
operations and fails closed when they are unavailable.

## macOS port

### Current blockers

The C stubs in `lib/secure_fs_stubs.c` use Linux-only open, stat, and rename
interfaces:

- `O_PATH`, used to retain descriptor-based identity without following links;
- `renameat2` with `RENAME_NOREPLACE` and `RENAME_EXCHANGE`;
- Linux `struct stat` fields `st_mtim` and `st_ctim`;
- `/proc/self/fd`, used by the descriptor-bound mode-repair path;
- Linux-specific syscall declarations and error handling.

`bin/dune` also passes ELF-specific linker options unconditionally. The
self-upgrader hard-codes `linux-x86_64` asset and archive-root names, discovers
the executable through `/proc/self/exe`, invokes `/usr/bin/tar`, and parses GNU
tar output. The release scripts use further GNU/Linux conventions including
`ldd`, `readelf`, `$ORIGIN`, GNU `strip`, Debian package metadata, and GNU tar
flags.

The generated `.agents/setup` and `.agents/resume` scripts deliberately target
Amp's Debian orb layout. They expect Linux x86-64 release names,
`pg_conftool`, and Debian's PostgreSQL 15 paths. Several tests also inspect
`/proc/self/fd` or exercise that local PostgreSQL layout.

### 1. Add a Darwin filesystem backend

Keep the OCaml `Secure_fs` contract unchanged and provide Darwin C stubs for
the same operations. The port must preserve:

- no-follow component traversal and retained directory or entry identity;
- shared and exclusive advisory locks on the open repository root;
- effective-UID ownership and mode checks;
- descriptor-bound inspection and cleanup;
- atomic no-replace and exchange renames with no unsafe fallback;
- nanosecond modification and change timestamps;
- durable file and parent-directory synchronization.

File and directory synchronization also call `Unix.fsync` directly in the
local mutation and upgrade code. Audit those calls as part of the port.
Establish the required Darwin file-flush and parent-directory behavior,
including unsupported-operation handling; do not assume that ordinary `fsync`
or `F_FULLFSYNC` provides every required guarantee.

Darwin APIs such as `renameatx_np` with `RENAME_EXCL` and `RENAME_SWAP` are
possible implementation candidates, not assumed equivalents. Verify their
same-filesystem behavior, error mapping, durability, and race semantics against
the invariants in [PRD.md](../PRD.md) before using them. Likewise, choose a
Darwin replacement for `O_PATH` only after proving that it witnesses regular
files, directories, and symlinks without following or mutating them.

Select Linux and Darwin stubs in `lib/dune` using Dune configuration or small
platform-specific C translation units. Make the linker options in `bin/dune`
target-specific at the same boundary. The Darwin build needs Mach-O-compatible
linkage and package-relative library paths. Do not scatter operating-system
checks through the OCaml mutation logic.

### 2. Port executable and database handling

Replace `/proc/self/exe` in the upgrader with a Darwin executable-path
implementation, such as one based on `_NSGetExecutablePath`. Its result may
contain symlinks, so preserve the existing package-layout and identity checks
rather than treating the returned path as canonical.

The local database bootstrap is a separate boundary. Either provide and test a
macOS PostgreSQL/pgvector lifecycle implementation or clearly leave
`--local-database`, `.agents/setup`, `.agents/resume`, and the Linux acceptance
runner unsupported on macOS. Remote database commands still require native
libpq plus the same TLS and channel-binding policy.

### 3. Install the macOS toolchain

After the platform code exists, build natively on each architecture. A typical
Homebrew development environment starts with:

```bash
xcode-select --install
brew install opam pkg-config libpq curl

export PATH="$(brew --prefix libpq)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$(brew --prefix curl)/lib/pkgconfig"

opam init --bare --no-setup --yes
opam switch create . ocaml-base-compiler.5.5.0 --no-install --yes
opam install . --deps-only --with-test --locked --yes
opam exec -- dune build @all
opam exec -- dune build @install
```

Build Apple silicon on arm64 hardware and Intel macOS on x86-64 hardware. Do not
combine the binaries into a universal executable until every bundled native
library has matching slices and the combined result passes the full tests.

### 4. Adapt and run the tests

Keep portable unit tests common. Add Darwin-specific tests for every secure
filesystem operation and its failure modes, including concurrent replacement,
symlinks, ownership, hard links, lock contention, rollback, and directory
fsync. Tests that currently count `/proc/self/fd` entries need an equivalent
Darwin implementation rather than deletion.

Database, Git, sync, retrieval, and publication tests must run against isolated
resources. Never point a porting test at production Neon. If the Debian local
database harness remains Linux-only, record that gap and do not describe the
macOS target as fully supported.

At minimum, run:

```bash
opam exec -- dune build @all
opam exec -- dune build @install
opam exec -- dune runtest
opam lint clamp.opam
```

### 5. Build a macOS package

Do not reuse `release/build`; it intentionally rejects non-Linux hosts. Add a
target-specific builder or parameterize the existing builder without weakening
the Linux path. Choose the minimum macOS version before building the executable
and bundled libraries. A macOS package needs to:

- choose and document an architecture-specific asset name;
- copy `kb`, migrations, templates, version markers, license, and notices;
- inspect dependencies with `otool -L` rather than `ldd`;
- use relocatable Mach-O install names such as `@loader_path/../lib`;
- bundle permitted non-system `.dylib` dependencies and rewrite their install
  names where necessary;
- verify every dependency resolves inside the package or to an allowed macOS
  system library;
- preserve deterministic file ordering, timestamps, and modes in the unsigned
  staging tree and document how signing affects reproducibility;
- handle code signing, hardened runtime, and notarization as explicit release
  steps;
- test the extracted package under a clean environment on the minimum supported
  macOS version.

Choose target-specific asset and archive-root names before porting `kb upgrade`.
Port executable discovery and atomic installation, and validate the tar
commands and size-listing parser against the target's archive tool. Preserve
the archive-layout checks, extracted-size ceiling, and candidate-version check.

Self-upgrade is for standalone packages. Setup-managed installations must
continue to update their runtime lock and rerun setup. See
[Releases and upgrades](./releases.md).

Repository templates also need an explicit decision. Today they install the
pinned Linux orb runtime. A native macOS consumer template must encode its
target in the pinned runtime URL, runtime root, and setup logic, while an
Amp-hosted knowledge repository should continue using its Linux orb pin.

### 6. Verify on a clean machine

Test each architecture independently on a machine or VM with no third-party
toolchain or libraries installed. After verifying the candidate archive's
checksum, the extracted package must run at least:

```bash
env -i HOME="$PWD/clean-home" PATH=/usr/bin:/bin \
  ./clamp-X.Y.Z-macos-ARCH/bin/kb --version
env -i HOME="$PWD/clean-home" PATH=/usr/bin:/bin \
  ./clamp-X.Y.Z-macos-ARCH/bin/kb --json --help
```

Then exercise validation, local mutations, task/TODO updates, Git operations,
and every target-supported external workflow. Record the OS version,
architecture, package checksum, command output, and unsupported features. A
package is not a production release until this evidence is reviewed. Obtain
operator approval before publishing.

## Other targets

Use the same process for another POSIX target: identify native primitives,
preserve the security contract, build on each architecture, package native
libraries relocatably, and test on a clean minimum-version host. Windows needs a
larger filesystem, locking, process, path, and Git-boundary design; it should not
be treated as a routine cross-compilation target.
