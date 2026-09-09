# Knowledge format and configuration

## Repository layout

An initialized private repository contains:

```text
AGENTS.md
README.md
clamp.yaml
TODO.md
.agents/
├── clamp-runtime.lock
├── setup
├── resume
└── skills/managing-clamp-knowledge/SKILL.md
knowledge/
├── facts/
├── preferences/
├── people/
├── projects/
├── decisions/
├── journal/<year>/<date>.md
└── tasks/<ulid>-<initial-slug>.md
```

Only Markdown files under `knowledge/` are concepts. A concept ID is its path
relative to `knowledge/`, without `.md`. Keep that path stable when the title,
value, or task state changes. Deprecate and link to a replacement only when the
enduring subject genuinely changes.

Reserved `index.md` and `log.md` documents support OKF progressive disclosure
and logs but are not indexed concepts.

## Concepts and provenance

Concepts use OKF v0.2 YAML frontmatter plus Markdown content. Clamp-specific
metadata lives in the top-level `clamp` mapping.

Two fields answer different questions:

- `generated.by` says who produced the current document content, normally
  `amp/agent` for an agent-written file.
- `clamp.asserted_by` says who originated the claim, normally the configured
  human authority for an explicit user statement or `amp/agent` for an
  inference.

`verified` events record direct confirmation of exact content. Agent review is
not human verification. A semantic edit clears stale events; non-semantic
formatting or link edits preserve them.

Clamp preserves unknown semantic frontmatter keys when rewriting. It does not
promise byte-for-byte YAML formatting: comments, key order, quoting, and block
scalar style may change. Duplicate keys, aliases, anchors, application-specific
tags, and unsupported scalar semantics are rejected.

Unknown non-empty OKF types produce deterministic warnings. They require
`--allow-unknown-type` when supplied to a mutation but remain readable and
round-trippable.

A minimal fact input looks like:

```markdown
---
type: fact
title: Deployment window
description: Production changes happen on Tuesday mornings.
---

Production changes happen on Tuesday mornings.
```

A minimal task input looks like:

```markdown
---
type: task
title: Review the deployment checklist
---

Review the deployment checklist before the next release.
```

Pass these complete documents to `kb add` or `kb task add`; the CLI writes
canonical lifecycle, provenance, verification, and timestamp metadata.

## Tasks and journals

Tasks are ordinary `type: task` concepts. The root `TODO.md` is a deterministic
view of active `doing`, `blocked`, and `todo` tasks. Completed and cancelled
tasks remain in their concept files and appear with `kb task list --history`.
Never edit `TODO.md` directly.

Generated task ULIDs sort by timestamp across different milliseconds and use
random entropy. Same-millisecond monotonic order is not guaranteed.

An ID-less `kb add` with a `type: journal` input writes the journal concept for
the configured local date at `knowledge/journal/<year>/<YYYY-MM-DD>.md`.
Repeated writes on the same date update that stable concept.

## `clamp.yaml`

The repository configuration is versioned and non-secret. It contains:

```yaml
schema_version: 1
source_repository: example.com/owner/private-clamp
timezone: Africa/Johannesburg
inferred_writes: confirm
embedding:
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
  model: openai/text-embedding-3-small
  dimensions: 1536
  max_input_bytes: 8000
  provider_order: [openai]
  allow_fallbacks: false
  data_collection: deny
retrieval:
  candidate_limit: 100
  result_limit: 10
  semantic_weight: 0.70
  recency_weight: 0.20
  frequency_weight: 0.10
  recency_half_life_days: 30
  frequency_saturation_count: 100
```

An optional top-level `human_authority` chooses the repository's canonical
human assertion and verification identifier:

```yaml
human_authority: human:your-identifier
```

Defaults to `human:owner`. Set this to the identifier you want Clamp to record
for your assertions and verification events. Accepted values begin with
`human:` and have a nonempty, bounded ASCII suffix.

`source_repository` is an identity, not a clone URL. It has a lowercase DNS
host and slash-separated path, with no scheme, credentials, query, fragment,
trailing slash, or `.git` suffix. Clamp does not infer it from `origin`.

Embedding identity fields are fixed for v1. Changing the gateway, model,
dimensions, provider routing, fallback policy, or data-collection policy makes
an existing index incompatible.

## Validation limits

V1 fixes these ceilings rather than making them configurable:

- 8 MiB per configuration, concept, or reserved file;
- YAML depth 64 and 100,000 nodes per file;
- 10,000 Markdown files and 100,000 links per bundle;
- 1,000 returned diagnostics;
- 8,000 normalized UTF-8 bytes per embedding input.

More than 1,000 diagnostics produces `diagnostic_limit` plus the 999 smallest
diagnostics in stable order. Diagnostics do not include concept bodies.

Accepted YAML integers and decimal floats remain exact JSON numbers, not binary
floats or strings. Values outside PostgreSQL `numeric` limits, and non-finite
numbers, fail before embedding or index mutation. Paths must be portable,
UTF-8, URI-safe, case-fold-collision-free, and free of symlinked or non-regular
concept files.

The complete normative format and validation contract is in
[PRD.md](../PRD.md).
