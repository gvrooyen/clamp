# Private Clamp knowledge repository

This repository contains a private Clamp OKF knowledge bundle. Durable
knowledge lives under `knowledge/`; `TODO.md` is a generated task view.

The native `kb` executable and SQL migrations are installed from the exact
target record in the release manifest pinned by `.agents/clamp-runtime.lock`.
This repository intentionally contains no Clamp implementation source.

Fresh Amp Orbs run `.agents/setup` once and `.agents/resume` after every wake.
Neither hook performs production synchronization, publication, migration, or
paid embedding requests.

`kb init` records the durable bootstrap files in a generic initial commit but
does not configure a remote. Setup recreates empty taxonomy directories because
Git does not track empty directories.

Validate locally with:

```bash
kb validate --repo /home/user/workspace/repo --json
```
