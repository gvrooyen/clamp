# Architecture

Clamp keeps durable knowledge separate from disposable compute and derived
search state.

```text
┌──────────────────────┐
│ Amp thread           │
│ skill + native `kb`  │
└───────┬──────────────┘
        │
        ├──── publish ─────▶ Git `origin/main`
        │                     authoritative Markdown
        │
        ├──── sync ─────────▶ Neon Postgres + pgvector
        │                     derived concepts and lossy access stats
        │
        └──── embed ────────▶ OpenRouter
                              pinned OpenAI embedding model
```

## Data ownership

Clamp has three data classes:

1. **Durable knowledge.** Concept Markdown, `clamp.yaml`, and generated
   `TODO.md` at the exact remote `origin/main` tip.
2. **Derived index data.** Parsed metadata, bodies, and embeddings in Postgres.
   These can be reconstructed from Git and the pinned embedding configuration.
3. **Operational telemetry.** Access counts and last-accessed timestamps in
   Postgres. These improve ranking but may be lost without losing knowledge.

An orb worktree, local commit, or local file is not durable until publication
reaches the remote. Conversely, Postgres is not the knowledge authority.

## Local writes

Concept and task writes are canonicalized by the CLI. It preserves unknown
frontmatter values while controlling provenance, verification, lifecycle, and
timestamps. Task changes and the generated TODO view are written as one
reported operation.

The implementation uses Linux no-follow traversal, a lock on the open
repository-root directory inode, fsynced temporary files, no-replace/exchange
renames, private transaction directories, and post-write identity checks. It
never falls back to an unsafe ordinary overwrite. A crash can still occur
between the task and TODO renames; this is detectable `todo_drift`, repaired by
`kb todo`.

The exact mutation and rollback invariants are normative in
[PRD.md](../PRD.md).

## Embeddings and synchronization

Embedding input is deterministic: type, title, description, sorted tags, and
the exact Markdown body are normalized to LF and hashed with SHA-256. Input over
8,000 UTF-8 bytes is rejected before an external request.

OpenRouter requests are fixed to `openai/text-embedding-3-small`, 1,536
dimensions, OpenAI-only routing, disabled fallbacks, and denied data
collection. A gateway, model, dimension, or routing-policy change is
index-incompatible.

`kb sync` fetches and verifies the exact `origin/main` commit, then reads
configuration and concepts from Git objects rather than mutable worktree files.
It compares Git tree/blob identities with Postgres, embeds required content,
and applies additions, changes, deletions, and the index checkpoint atomically.
Changes to verification or task state reuse embeddings when the embedding
input is unchanged; surviving paths preserve access telemetry. Explicit
mass-deletion approval is required when a nonempty index becomes empty, or when
at least ten rows and more than half the index would be deleted.

This object-based design works with shallow orb checkouts and does not depend
on local Git history.

## Retrieval

`kb search` checks the local remote-tracking commit and index checkpoint before
embedding the query. Postgres supplies pgvector cosine candidates; OCaml reranks
them with the configured semantic, recency, and frequency weights. Search does
not update access telemetry.

`kb get` returns the full indexed concept and updates access telemetry only
after content validation and final freshness checks. Retrieval configuration
comes from the captured remote commit, not uncommitted `clamp.yaml` bytes.

Candidate validation runs in bounded batches under one five-second deadline,
with fixed aggregate and per-row payload limits. Deterministic resource-limit
failure is not reported as semantic success. See the PRD's retrieval section
for the exact transaction dispatch and uncertain-acknowledgement boundary.

## Publication

`kb publish` accepts only managed changes under `knowledge/**`, `TODO.md`, and
`clamp.yaml`. It requires an attached local `main` tracking a matching
`origin/main`, repository-local author identity, and the current Amp thread ID.

The command regenerates TODO when necessary, validates and stages exact bytes,
commits, fetches, rebases, validates again, and pushes without force. A
successful push is never rolled back solely because exact-commit indexing
fails. Content conflicts and exhausted clean races are preserved differently;
see [Failure recovery](./recovery.md).

## Trust boundaries

- Git publication uses the validated Amp HTTPS credential helper only for an
  exact Amp origin. Ambient Git configuration is removed before credentials
  are exposed.
- Database URLs require encrypted transport and channel binding. Errors redact
  credentials.
- OpenRouter TLS certificate and hostname verification remain enabled.
- Knowledge sent for embeddings is processed by both OpenRouter and OpenAI.
- Other processes running as the same user must not modify `.clamp/`; its
  permissions do not isolate it from them.
