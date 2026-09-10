# Clamp

Clamp gives an Amp agent a durable personal knowledge base. Facts, decisions,
preferences, projects, and tasks live as readable Markdown in your own private
Git repository. A rebuildable Postgres index adds semantic search without
turning the database into the source of truth.

Clamp is useful when each agent thread starts in a fresh environment but still
needs to remember what you decided, what you prefer, and what remains to be
done.

> Current release: [v0.1.4](https://github.com/gvrooyen/clamp/releases/tag/v0.1.4).
> Requires x86_64 Linux with glibc 2.36 or newer.

## What Clamp keeps

- [OKF v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf)
  Markdown under `knowledge/`.
- One concept per task, with a generated `TODO.md`.
- Separate records of who stated a claim, who wrote the file, and who verified
  it.
- Confirmation before saving agent inferences.
- OpenAI embeddings through OpenRouter, indexed in Neon Postgres with pgvector.
- Validated pushes to `origin/main`, without force-pushing.
- Local text search when external services are unavailable.

Clamp v1 has no recurring tasks, reminders, or background indexer, although
Amp's scheduled agent tasks can be used to facilitate
these. Clamp v1 has no multi-user knowledge model.

## Get started

Choose a setup:

1. **[Amp-hosted private repository](./docs/getting-started.md#amp-hosted-private-repository)**
   – the complete workflow. Amp creates the private repository, installs the
   pinned runtime in each orb, and can use project secrets for indexed search,
   synchronization, and publication.
2. **[Private Git repository on local x86_64 Linux](./docs/getting-started.md#private-git-repository-on-local-linux)**
   – local authoring, tasks, and validation with Amp running on your machine.
   The current `kb publish` authentication path does not support arbitrary
   private GitHub HTTPS or SSH origins, so this is not yet the full hosted
   workflow.

Both paths start with the prebuilt release. It bundles the native executable,
its non-system shared libraries, SQL migrations, and private-repository
templates. OCaml, opam, libpq, and libcurl do not need to be installed.

```bash
version=0.1.4
archive="clamp-${version}-linux-x86_64.tar.gz"
base="https://github.com/gvrooyen/clamp/releases/download/v${version}"

curl -fLO "$base/$archive" && \
  curl -fLO "$base/$archive.sha256" && \
  sha256sum --check "$archive.sha256" && \
  tar -xzf "$archive" && \
  ./clamp-${version}-linux-x86_64/bin/kb --version
```

Continue with the [full setup guide](./docs/getting-started.md) to initialize a
knowledge repository that contains no Clamp application implementation source
and connect it to a private remote. Until the generated setup activates `kb`,
invoke it from the extracted release directory as shown in that guide.

## Using Clamp from Amp

An initialized repository includes the
`managing-clamp-knowledge` skill. Amp discovers it automatically and uses the
stable JSON interface rather than parsing command-line prose.

Ask Amp:

> Remember that I prefer review notes ordered by severity, then file path.

> What did we decide about the billing migration?

> Add a task to rotate the staging credentials next Tuesday.

> Mark the release checklist task complete; you performed and verified it.

The agent uses `kb` to validate, search, update, and publish:

```bash
kb validate --json
kb sync --json
kb search "billing migration" --json
kb get decisions/billing-migration --json
# The agent uses kb add/edit/task commands after classifying write authority.
kb publish --thread-id T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --json
```

The default `inferred_writes: confirm` policy makes the agent ask before saving
its own inference. Direct statements from you can be recorded without asking
the same question again. See [Using Clamp with Amp](./docs/amp.md) for the
agent workflow, verification rules, and failure handling.

## `kb` at a glance

| Goal | Command |
| --- | --- |
| Check the repository | `kb validate --json` |
| Search by meaning | `kb search "query" --json` |
| Read one concept | `kb get facts/example --json` |
| Add or edit knowledge | `kb add`, `kb edit` |
| Verify or retire knowledge | `kb verify`, `kb deprecate` |
| Manage tasks | `kb task add\|list\|start\|block\|done\|cancel` |
| Rebuild `TODO.md` | `kb todo --json` |
| Update the derived index | `kb sync --json` |
| Publish durable changes | `kb publish --thread-id <thread-id> --json` |
| Change inference policy | `kb config set inferred-writes <confirm\|auto_draft>` |
| Upgrade the packaged runtime | `kb upgrade --version X.Y.Z` or `kb upgrade --latest` |

Commands accept `--repo` (also `--repo-root`), `--json`, `--quiet`, and
`--diagnostic`. Exit classes are stable: `0` success, `2` user or validation
error, `3` conflict, `4` authentication, `5` transient external failure, `6`
stale index, and `70` internal failure. Agents should branch on JSON result
codes, not messages. The [CLI guide](./docs/cli.md) covers command inputs and
common sequences.

## Architecture

```text
┌────────────────┐     search / update   ┌──────────────────┐
│ Amp agent      │──────────────────────▶│ skill + `kb` CLI │
└────────────────┘                       └────────┬─────────┘
                                                  │
                         ┌────────────────────────┼──────────────────────┐
                         │ publish                │ sync                 │ embed
                         ▼                        ▼                      ▼
                ┌────────────────┐       ┌─────────────────┐   ┌────────────────┐
                │ Git main       │       │ Neon + pgvector │   │ OpenRouter     │
                │ durable truth  │       │ derived index   │   │ pinned OpenAI  │
                └────────────────┘       └─────────────────┘   └────────────────┘
```

Git `origin/main` is the source of truth. Postgres holds the derived search
index and lossy access statistics:

- Concept rows and embeddings can be rebuilt from Git.
- A successful Git publication is never reverted because indexing failed.

Read [Architecture](./docs/architecture.md) for synchronization, retrieval,
publication, and trust boundaries.

## Upgrade

A packaged v0.1.3 or newer installation can replace itself atomically:

```bash
kb upgrade --latest
kb upgrade --version 0.1.4
```

Exact versions may upgrade or downgrade. `--latest` selects the latest stable,
non-draft, non-prerelease GitHub release. Use this only for a standalone
installation. For a private repository managed by `.agents/setup`, review and
update all four runtime-lock fields, then rerun setup; self-upgrading that
installation can make its revision pin inconsistent. See
[Releases and upgrades](./docs/releases.md).

## Documentation

- [Documentation index](./docs/README.md)
- [Getting started](./docs/getting-started.md)
- [CLI guide](./docs/cli.md)
- [Using Clamp with Amp](./docs/amp.md)
- [Architecture](./docs/architecture.md)
- [Knowledge format and configuration](./docs/knowledge-format.md)
- [Operations](./docs/operations.md)
- [Failure recovery](./docs/recovery.md)
- [Building Clamp](./docs/building.md)
- [Development and acceptance](./docs/development.md)
- [Releases and upgrades](./docs/releases.md)

[PRD.md](./PRD.md) is the authoritative v1 product and behavior contract.
[PLAN.md](./PLAN.md) records implementation phases and acceptance evidence.
[AGENTS.md](./AGENTS.md) contains repository-development guidance.

Clamp is distributed under the [MIT License](./LICENSE).
