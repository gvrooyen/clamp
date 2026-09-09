# Using Clamp with Amp

An initialized private repository contains
`.agents/skills/managing-clamp-knowledge/SKILL.md`. Amp loads this skill when a
request involves knowledge, tasks, retrieval, publication, or conflict
recovery. No MCP server, plugin, daemon, hook, or companion process is needed.

## What to ask

- “Remember that deployment notes should include the rollback command.”
- “What do I know about the supplier contract?”
- “Record the decision to keep invoices for seven years.”
- “Add a task to check the renewal quote by Friday.”
- “Show my blocked tasks.”
- “I reviewed this concept and confirm it is correct.”

Use these prompts in a thread for your Clamp project or from its local
repository. The generated skill is repository-local; unrelated projects do not
automatically have access to it or your knowledge repository.

## Hosted-orb agent flow

At the start of indexed work, the skill validates the local repository and
synchronizes the exact remote `main` state:

```bash
kb validate --repo /home/user/workspace/repo --json
kb sync --repo /home/user/workspace/repo --json
kb search "the user's question" --repo /home/user/workspace/repo --json
kb get facts/relevant-concept --repo /home/user/workspace/repo --json
```

The skill branches only on stable JSON fields. It does not infer success from
exit text. A successful search candidate is not treated as an access; only
returning full content with `kb get` records access telemetry.

After a mutation, the agent publishes with the exact authenticated Amp thread
ID:

```bash
kb publish \
  --repo /home/user/workspace/repo \
  --thread-id T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  --json
```

Until that push reaches `origin/main`, the knowledge is not durable.

## Explicit statements and inferences

Clamp distinguishes a user's statement from an agent's conclusion:

- An explicit user statement may be recorded immediately with
  `--claim explicit`.
- An inferred fact or task requires confirmation under the default
  `inferred_writes: confirm` policy.
- The user may directly switch the repository to `auto_draft`; unconfirmed
  inferred creations then remain drafts without verification.
- An agent must not treat prior confirmations as blanket permission to change
  the policy or save future inferences.

This distinction is reflected in provenance. `generated.by` identifies who
produced the current document. `clamp.asserted_by` identifies the source of the
claim. An agent can therefore transcribe a human claim without pretending that
the human wrote the Markdown.

## Verification

Verification means that the authenticated current user confirmed the exact
current content. It is stronger than an agent deciding that a statement looks
correct.

The agent may invoke:

```bash
concept_id="facts/example"
kb verify "$concept_id" --verification-authority user-explicit --json
```

only after the user directly requests verification or confirms the content.
The resulting `verified.by` value comes from the repository's
`human_authority` setting, defaulting to `human:owner`. A semantic edit clears
stale verification; formatting-only or link-only edits preserve it.

## Task closure

The agent uses the task commands, never direct edits to `TODO.md`. It may close
a task without asking again only when it directly performed and verified the
work (`--closure-authority performed-and-verified`) or when the user explicitly
marked it complete. Other inferred closure requires confirmation.

## Service outages

When a structured retrieval result recommends
`local_markdown_or_rg`, the skill may search local Markdown and report that the
fallback is not semantically equivalent. It must not claim semantic ranking or
an access update. Validation and deterministic internal failures do not gain a
fallback merely because local files exist.

## Publication conflicts

The skill first tries to resolve a genuine concept conflict without losing
facts. If it cannot do so confidently, it asks `kb publish` to preserve the
original commit. It sends one owner notification only after the CLI proves a
remote conflict branch with `publish_conflict_preserved` or
`publish_conflict_preserved_cleanup_pending` and `preserved: true`.

Authentication, network, provider, database, stale-index, clean race, and
ordinary cleanup failures do not trigger that conflict email. The CLI itself
does not send email. See [Failure recovery](./recovery.md) for the exact
distinctions.
