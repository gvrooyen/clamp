# Private Clamp knowledge repository

This repository contains a private Clamp OKF knowledge bundle. Durable
knowledge lives under `knowledge/`; `TODO.md` is a generated task view.

The native `kb` executable and SQL migrations are installed from the exact
target record in the release manifest pinned by `.agents/clamp-runtime.lock`.
This repository intentionally contains no Clamp implementation source.

Fresh Amp Orbs run `.agents/setup` once and `.agents/resume` after every wake.
Neither hook performs production synchronization, publication, migration, or
paid embedding requests.

After `amp clone` on a qualified local machine, run `.agents/setup-local` from
the checkout. It installs the checksum-pinned runtime outside the repository,
validates the bundle, and reports only whether required service values are
present. It does not copy Orb project secrets, edit tracked files, synchronize,
publish, or run a production database migration. Supply service credentials to
the local Amp process from your own secret manager.

`kb init` records the durable bootstrap files in a generic initial commit but
does not configure a remote. Setup recreates empty taxonomy directories because
Git does not track empty directories.

Validate locally with:

```bash
.agents/kb validate --json
```
