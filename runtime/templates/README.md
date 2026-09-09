# Private Clamp knowledge repository

This repository contains a private Clamp OKF knowledge bundle. Durable
knowledge lives under `knowledge/`; `TODO.md` is a generated task view.

The native `kb` executable and SQL migrations are installed from the exact
x86-64 public runtime release pinned in `.agents/clamp-runtime.lock`. This
repository intentionally contains no Clamp implementation source.

Fresh Amp Orbs run `.agents/setup` once and `.agents/resume` after every wake.
Neither hook performs production synchronization, publication, migration, or
paid embedding requests.

Validate locally with:

```bash
kb validate --repo /home/user/workspace/repo --json
```
