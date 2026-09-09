# CLI guide

`kb` has human-readable output for interactive use and stable JSON output for
agents. Run it inside a Clamp knowledge repository or pass
`--repo /path/to/repository` (`--repo-root` is an alias).

## Common options and results

All executable commands accept `--json`, `--quiet`, and `--diagnostic`.
Automations should use `--json` and branch on `code`, `data`, and `details`, not
on the English `message`.

```json
{"ok":false,"code":"validation_failed","message":"Bundle validation failed.","details":{"diagnostics":[]}}
```

Exit classes are:

| Exit | Meaning |
| ---: | --- |
| 0 | Success |
| 2 | Invalid input or validation failure |
| 3 | Publication conflict |
| 4 | Authentication failure |
| 5 | Transient external failure |
| 6 | Stale index after otherwise valid work |
| 70 | Internal or local integrity failure |

Use `kb --json --help` for the current command tree and `kb COMMAND --help`
for exact options.

## Repository and validation

```bash
kb init --release X.Y.Z \
  --source-repository HOST/PATH --repo /new/path --json
kb init --latest \
  --source-repository HOST/PATH --repo /new/path --json
kb validate --json
kb todo --json
```

`kb init` is a bootstrap command for a path that does not exist. It creates a
source-free private repository and one initial commit, but no remote or external
service state. The release shortcuts download and verify the selected public
package, derive its exact revision, URL, and SHA-256, and use its own templates.
Use all four `--runtime-version`, `--runtime-revision`, `--runtime-url`, and
`--runtime-sha256` options instead for offline or controlled initialization.

`kb validate` checks configuration, concept files, paths, links, and generated
documents. Warnings such as an unknown non-empty OKF type do not fail the
command; errors do. `kb todo` regenerates the root task view from task concepts.

## Search and retrieval

```bash
kb sync --json
kb search "release decision" --json
kb search "release decision" --include-deprecated --verbose
kb get decisions/release-process --json
```

`search` uses semantic similarity, recency, and access frequency. It normally
excludes deprecated or stale concepts and closed tasks. Use
`--include-deprecated`, `--include-stale`, or `--include-closed-tasks` when those
records are relevant. Search does not increment access telemetry.

`get` returns the complete indexed concept and records an access only after the
response and freshness checks succeed. Retrieval never fetches or synchronizes
implicitly.

For eligible external or stale failures, JSON reports
`"fallback":"local_markdown_or_rg"` and
`"semantic_equivalent":false`. A local text search is useful degraded behavior,
but it is not semantic retrieval and does not update access telemetry.

## Knowledge mutations

Mutation input is one complete UTF-8 Markdown document supplied through exactly
one of `--input PATH` and `--stdin`:

```bash
kb add facts/example --input /tmp/example.md --claim explicit --json
cat /tmp/revised.md | \
  kb edit facts/example --stdin --claim inferred --confirmed --json
kb verify facts/example --verification-authority user-explicit --json
kb deprecate facts/example \
  --superseded-by facts/replacement --claim explicit --json
```

Use `--claim explicit` when the user directly supplied the claim. Use
`--claim inferred` for an agent inference; under the default policy it requires
`--confirmed`. `kb` ignores caller-supplied provenance fields and writes the
canonical producer, assertion, verification, status, and timestamps itself.

Direct verification requires `--verification-authority user-explicit` and is
valid only when the authenticated current user requested verification or
confirmed the exact current content. Agent review alone is not verification.

## Tasks

```bash
kb task add --input /tmp/task.md --claim explicit --json
kb task list --json
task_id="tasks/01H...-description"
kb task start "$task_id" --json
kb task block "$task_id" --json
kb task done "$task_id" \
  --closure-authority performed-and-verified --json
kb task cancel "$task_id" --json
kb task list --history --json
```

Task completion authority for `kb task done` is one of
`performed-and-verified`, `user-explicit`, or `confirmed`. An agent may complete
work without another confirmation only when it performed and verified that work
itself or the user directly marked it done.
Never edit `TODO.md`; run `kb todo` after repairing drift.

## Configuration

```bash
kb config set inferred-writes confirm --direct-user-intent --json
kb config set inferred-writes auto_draft --direct-user-intent --json
```

Changing inference policy requires a direct user request. Under `auto_draft`,
an unconfirmed inferred creation is saved as an unverified draft. The setting
does not turn inferred edits into verified claims.

The repository-specific human authority is a normal top-level `clamp.yaml`
value rather than a `config set` subcommand. See
[Knowledge format and configuration](./knowledge-format.md).

## Database, synchronization, and publication

```bash
kb database migrate --json
kb sync --json
commit_sha="0123456789abcdef0123456789abcdef01234567"
kb sync --commit "$commit_sha" --json
kb sync --reembed --json
kb sync --allow-mass-deletion --json
kb publish --thread-id T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --json
```

Migrations and sync use `KB_DATABASE_DIRECT_URL`; search and get use the pooled
`KB_DATABASE_URL`; embeddings use `OPENROUTER_API_KEY`. Publication requires an
attached local `main`, a matching configured `origin`, repository-local Git
author identity, and only managed changes. It validates, commits, rebases,
pushes without force, and then synchronizes the exact pushed commit.

These commands can mutate shared external state. Run them only with the
appropriate authorization and after reading [Operations](./operations.md) and
[Failure recovery](./recovery.md).

## Runtime upgrade

```bash
kb upgrade --version X.Y.Z --json
kb upgrade --latest --json
```

The options are mutually exclusive. Exact selection can upgrade or downgrade;
selecting the installed release is a no-op. Only a packaged Linux x86_64
installation can self-upgrade. See [Releases and upgrades](./releases.md).
