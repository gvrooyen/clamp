# Releases and upgrades

## Packaged runtime

The current production release is
[v0.1.4](https://github.com/gvrooyen/clamp/releases/tag/v0.1.4). Its archive is
named `clamp-0.1.4-linux-x86_64.tar.gz` and has SHA-256:

```text
f4b9cfbb6736def71eb5c54acae955cfe19b1e03cf519aa4616cad5dd6a53841
```

The package contains:

- a stripped native `bin/kb`;
- its non-system shared-library closure;
- authoritative SQL migrations;
- source-free private-repository templates;
- version and exact source-revision markers;
- third-party notices and the MIT license.

It targets x86_64 Linux with glibc 2.36 or newer. A fresh compatible orb needs
no OCaml, opam, libpq, libcurl, or language package installation. Keep `bin/`
and `lib/` together because the executable uses an origin-relative runtime
library path.

Always download the adjacent `.sha256` file, run `sha256sum --check`, and check
`bin/kb --version` before using a package. See
[Getting started](./getting-started.md) for exact v0.1.4 commands.

## Runtime pin in a private repository

`kb init` writes `.agents/clamp-runtime.lock` with four reviewed fields:

1. release version;
2. exact 40-character public source revision;
3. credential-free HTTPS archive URL;
4. lowercase SHA-256 digest.

Release v0.1.4 and later can derive those fields with `kb init --release X.Y.Z`
or `kb init --latest`. The shortcut verifies the public archive and checksum,
checks its version, revision, layout, size, and executable, and copies templates
from that selected archive. The four explicit runtime-pin options remain
available for offline or controlled initialization.

Fresh-orb setup downloads and verifies exactly that archive, installs it under
`$HOME/.local/share/clamp/kb/<revision>`, and atomically activates
`$HOME/.local/bin/kb`. Change all four fields together after reviewing a new
release, then rerun setup and `kb validate`. Commit and push the lock change
with ordinary Git after review; `kb publish` does not publish `.agents/` files.

Do not run `kb upgrade` on this setup-managed installation. It replaces the
current release directory without editing the repository lock, which can make
the directory's revision marker disagree with the pin and cause resume to
fail. Use `kb upgrade` only for a separately managed standalone installation.

## Self-upgrade

Packaged releases starting at v0.1.3 support:

```bash
kb upgrade --version X.Y.Z
kb upgrade --latest
```

The options are mutually exclusive. An exact version may upgrade or downgrade;
selecting the installed version does nothing. `--latest` follows GitHub's
latest stable release and ignores drafts and prereleases.

The command supports only packaged Linux x86_64 installations. It rejects opam,
source-tree, and unknown layouts without mutation. It downloads the fixed
public archive and checksum over verified HTTPS, bounds metadata and archive
sizes, checks SHA-256, enforces a safe single-root archive layout and a 512 MiB
extracted-file ceiling, runs the candidate's `kb --version`, and atomically
exchanges the complete release directory under an installation lock.

The base system must provide `/usr/bin/tar`; no external curl executable or
OCaml package environment is needed. Releases through v0.1.2 predate
self-upgrade and need one manual replacement with v0.1.3 or newer.

## Building a release

`release/build` creates and validates the archive from the committed opam lock
and runs the unit suite with Dune's release profile. The
`release/build-in-container` helper pins the Debian package snapshot, opam
binary checksum, opam-repository commit, OCaml version, and transitive package
versions. It must be invoked inside a separately selected, digest-pinned Debian
12 x86-64 container; the helper does not launch or pin that container itself.

Publishing is an operator-controlled external action. Before running
`release/publish`, the operator must verify the archive's executable, version,
contents, and release evidence. The script then requires a clean checkout and
checks that:

- local `HEAD`, its `v<dune-project version>` tag, remote `main`, and the
  remote tag identify the same commit;
- the adjacent checksum matches the archive it will upload.

Only after those checks does it create the corresponding GitHub release and
upload the archive and checksum. Never force-push a release tag or branch.

The current release scripts are Linux x86-64-specific. See
[Building Clamp](./building.md) before adding another operating system or
architecture.
