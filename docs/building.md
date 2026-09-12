# Building Clamp

The published supported package remains Linux x86-64 with glibc 2.36 or newer.
The native macOS arm64 backend and verification-package builder are development
work toward the gated 0.2 target, not a supported production release.

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
install targets; it does not install them. Full `dune runtest` requires the
disposable database described in [Development and acceptance](./development.md).

Use `.agents/setup` in an Amp development orb. `.agents/setup`, `.agents/resume`,
and `.agents/phase9-acceptance` remain Debian/Linux-only; they are not host
installers. Their Linux-only acceptance test is excluded on macOS, not ported
by weakening the environment or production-isolation checks.

`release/build-in-container` runs as root inside a disposable Debian 12 x86-64
container. It pins the Debian package snapshot, opam executable, opam
repository, compiler, and locked dependencies, then invokes `release/build`.
It does not launch the container or select its image. A production build must
run it inside a digest-pinned base image. Do not run it directly on your host.

## Native macOS build and disposable integration

The candidate floor is **Apple silicon, macOS 26.5.2, local APFS**. Older OSes,
other architectures and filesystems are not inferred to work. No Homebrew,
profile changes, shared package installation, or production credentials are
needed for an isolated source build. Xcode Command Line Tools must already be
available. Use a private prefix, isolated `OPAMROOT`, and repo-local `_opam`.

Required native inputs are opam 2.5.2 arm64, pkgconf/pkg-config, PostgreSQL
15.19 with TLS-enabled libpq, pgvector 0.8.1, and the pinned OCaml dependencies.
The Apple SDK's libcurl 8.7.1 is sufficient; expose a private `libcurl.pc`
matching `/usr/bin/curl-config` if the SDK has no pkg-config metadata.
OpenSSL 3.5.5 shared libraries can supply libpq's TLS implementation. Check
downloaded release checksums against authoritative upstream release metadata.
Do not override HTTPS verification or disable libpq TLS/channel binding.

Set `MACOSX_DEPLOYMENT_TARGET=26.5.2` for the compiler, dependencies, and every
build invocation. The executable's linker flags also encode this floor.
Upstream OCaml 5.5.0 requires `compiler-cloning.disabled` on macOS; the lock
permits that upstream-selected build mode while retaining all library pins.
Use `OPAMDEPEXT=false` to prevent system package-manager operations.

With the private toolchain on PATH and private pkg-config paths:

```bash
opam init --bare --no-setup --disable-sandboxing --yes
opam switch create . ocaml-base-compiler.5.5.0 --no-install --yes
opam install . --deps-only --with-test --locked --yes
opam exec -- dune build @all
opam exec -- dune build @install
opam exec -- dune runtest test/unit
opam lint clamp.opam
opam exec -- dune exec test/unit/secure_fs_test.exe
test/run-macos-integration /absolute/private/postgresql-prefix
```

For a focused rerun, append exactly one suite name: `phase3_database_test`,
`phase5_sync_test`, `phase7_publication_test`, or `phase8_workflow_test`.
Omitting it runs all four. Finish builds before starting the harness so Dune
does not remove live Alcotest logs from its build directory.

The integration harness accepts a PostgreSQL installation prefix, **never a
database URL**. It replaces the environment, creates a mode-0700 temporary
cluster, binds only `127.0.0.1` and a private Unix socket, checks PostgreSQL
15.19/pgvector 0.8.1 and exact data-directory identity, and removes the cluster
after the selected suites. Command-scoped `caffeinate -i` inhibits idle sleep
without changing persistent power settings; manual sleep can still interrupt
tests. Runtime `--local-database` remains Debian-only. The
integration-only scoped target seam cannot be selected by CLI or environment.
The test helper uses only explicitly identified private sockets; production
Neon/OpenRouter services are not part of this harness.

## Darwin filesystem guarantees

`Secure_fs` keeps platform selection in C. Linux retains `O_PATH`, `renameat2`,
real link counts, and fsync. Darwin uses `O_EVTONLY`/`O_SYMLINK`, descriptor-bound
fchmod, nanosecond stat fields, flock, and `renameatx_np` with `RENAME_EXCL` and
`RENAME_SWAP`. There is no ordinary-rename or check-then-overwrite fallback.
Directory traversal rejects unqualified filesystems before mutation.

Darwin still checks entry access permissions. Private directories are created
with their final 0700 mode while temporarily restoring a restrictive umask;
this C operation has no runtime callbacks and assumes Clamp's synchronous,
single-threaded execution. Foreign inaccessible entries fail closed.

APFS can retain a deleted directory's old link count while a read descriptor
is open. Directory removal therefore uses a freshly registered descriptor-bound
kqueue `NOTE_DELETE` witness immediately before the final validated rmdir.
The event is polled without waiting, latched through durability retries, and
explicitly closed. Rename alone and deletion of a replacement are not proof.
Do not reuse a watch across exchange: Darwin may report DELETE for an exchange
destination. Linux continues to require a real zero link count. File hard-link
identity and count assertions are unchanged.

Local, Initializer, and Upgrade route durability through `Secure_fs.fsync`.
On Darwin it requires local APFS, calls fsync then `F_FULLFSYNC`, including on
parent directories, and never silently reduces the guarantee. Successful native
tests establish syscall behavior, not simulated power-loss or storage-hardware
qualification. Linux retains its existing fsync behavior and fault seams.

APFS rejects invalid UTF-8 names and aliases case-equivalent names. Tests assert
these filesystem outcomes rather than expecting impossible Linux directory
fixtures. Malformed content tests still run. Git-object collision tests construct
both paths directly in the index, so native synchronization still validates
hostile case-colliding trees independently of worktree capabilities.

## Native macOS verification packages

After building, run `release/build-macos` with explicit license files for every
bundled non-system dylib. For a private PostgreSQL/OpenSSL build:

```bash
release/build-macos \
  --library-license libpq.5.dylib=/private/source/postgresql-15.19/COPYRIGHT \
  --library-license libssl.3.dylib=/private/source/openssl-3.5.5/LICENSE.txt \
  --library-license libcrypto.3.dylib=/private/source/openssl-3.5.5/LICENSE.txt
```

The builder copies only the executable, allowed dependencies, migrations,
portable templates, markers, licenses, and notices. It discovers dylibs with
`otool`, rewrites package-relative names with `install_name_tool`, rejects
unresolved dependencies, checks arm64 and the deployment floor, normalizes
archive order/modes/timestamps, and checks extracted `--version` and JSON help
with an empty environment. Build twice and compare the archive SHA-256.

No developer signing, hardened-runtime configuration, notarization, or release
publication is performed. Native linker/tool-generated ad-hoc metadata is not
developer identity or Gatekeeper approval. These remain separately authorized
release gates, together with clean-machine installation/upgrade, power-loss
qualification, Linux regression, and the later real-service end-to-end gates
in [PLAN.md](../PLAN.md). A dirty-checkout verification archive is not an
artifact suitable for publication, even though its REVISION names its base.

## Other targets

Use the same process for another POSIX target: identify native primitives,
preserve the security contract, build on each architecture, package native
libraries relocatably, and test on a clean minimum-version host. Windows needs a
larger filesystem, locking, process, path, and Git-boundary design; it should not
be treated as a routine cross-compilation target.
