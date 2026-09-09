# Operations

Local validation and editing need no external services. Indexed retrieval uses
Neon and OpenRouter; publication also writes to the Git remote. Obtain approval
before paid requests or shared-state changes.

## Required secrets

Keep secrets in Amp project settings or an equivalent secure environment, not
in Git, issues, thread messages, command arguments, or artifacts.

| Variable | Use |
| --- | --- |
| `KB_DATABASE_URL` | Pooled Neon connection for search and get |
| `KB_DATABASE_DIRECT_URL` | Direct Neon connection for migrations, locks, and sync writes |
| `OPENROUTER_API_KEY` | Embedding requests through OpenRouter credits |

No Neon account key, OpenAI key, OpenRouter BYOK key, or notification email
address belongs in the repository.

## Neon

Create a Neon Free project in `aws-eu-west-2` (London) for the v1 deployment.
Keep pooled and direct connection strings separate. Migration 0001 enables and
validates pgvector 0.8.1. Both remote URLs must use the literal
lowercase `postgres://` or `postgresql://` form, require TLS
(`sslmode=require` or stronger), require `channel_binding=require`, and contain
no URI fragment. Direct URLs with libpq `options` are rejected.

Apply ordered SQL migrations only after explicit approval:

```bash
kb database migrate --json
```

SQL files in the public source repository's `db/migrations/` are authoritative;
the packaged runtime carries them under `share/clamp/migrations/` for private
repositories. The command validates the checksum ledger as an exact positional
prefix, obtains transaction and relation locks, verifies the migration bytes
and expected pgvector catalog ownership, and applies only the remaining suffix.
Changed, missing, inserted, reordered, renamed, malformed, or rogue history
fails atomically.

Never run development migrations or destructive integration tests against a
production Neon branch.

## OpenRouter

Create a credit-limited key and fund it with OpenRouter credits. Clamp sends
knowledge through OpenRouter to OpenAI using this fixed contract:

```yaml
base_url: https://openrouter.ai/api/v1
model: openai/text-embedding-3-small
dimensions: 1536
provider_order: [openai]
allow_fallbacks: false
data_collection: deny
```

Provider pinning prevents fallback to a different vector space. Certificate and
hostname verification stay enabled, and input over the fixed 8,000-byte ceiling
is rejected before the request.

## Synchronization

```bash
kb sync --json
```

Sync uses the direct database URL. It fetches and verifies the configured
`origin/main`, reads the selected tree from Git objects, performs all required
embeddings, then changes concept rows and the checkpoint in one transaction.
It preserves access telemetry for surviving paths and reuses an embedding when
verification or task state changes leave the embedding input unchanged.

Useful controlled variants are:

```bash
commit_sha="0123456789abcdef0123456789abcdef01234567"
kb sync --commit "$commit_sha" --json
kb sync --reembed --json
kb sync --allow-mass-deletion --json
```

`--commit` verifies an exact publication-supplied SHA. `--reembed` regenerates
every vector. `--allow-mass-deletion` is the explicit approval required when a
nonempty index would become empty, or when deletion affects at least ten rows
and more than half the index. There is no automatic sync daemon or hook.

## Publication

Publication validates and pushes knowledge directly to `origin/main`:

```bash
thread_id="T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
kb publish --thread-id "$thread_id" --json
```

The command refuses unrelated staged, tracked, or untracked work. It also
refuses pre-existing local commits ahead of or diverged from the known tracking
ref, unsafe Git transformation configuration, a mismatched repository identity,
or a missing repository-local Git author. It never force-pushes.

For Amp-hosted private repositories, Git subprocesses use only the validated
Amp credential helper and a minimal environment. Arbitrary private GitHub
HTTPS/SSH origins are not a supported `kb publish` path in v1.

After a successful push, Clamp synchronizes the exact commit. An indexing
failure returns a stale-index result but does not undo durable Git publication.
See [Failure recovery](./recovery.md) before handling a conflict or retrying an
uncertain operation.

## Production rollout boundary

This public repository contains no private rollout history or production
credentials. Repository tests and `.agents/phase9-acceptance` provide local
evidence only; they grant no production authority.

Before first production use:

1. Review the local acceptance result and the matrix in
   [PLAN.md](../PLAN.md#acceptance-criteria-traceability).
2. Verify the private repository identity and the exact runtime pin.
3. Configure secrets without exposing their values.
4. Obtain approval before migration or other shared-state changes.
5. Inspect the migration ledger and run an exact-tip idempotent sync.
6. Exercise search/get and confirm telemetry behavior.
7. Test publication and conflict preservation in the target environment.
