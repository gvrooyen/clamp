# Failure recovery

Clamp returns stable JSON codes so an agent or operator can distinguish a safe
retry from a conflict, stale index, or uncertain transaction. Do not collapse
these cases into a generic failure.

## Local fallback

Use Markdown or `rg` only when a structured sync or retrieval failure includes:

```json
{"fallback":"local_markdown_or_rg","semantic_equivalent":false}
```

Report that the result has no semantic ranking and made no access update.
Deterministic validation or internal failures are not fallback-eligible merely
because local files are readable.

## TODO drift

A crash between a task concept rename and the generated TODO rename may leave
the two out of sync. Diagnose and repair it with:

```bash
kb validate --json
kb todo --json
kb validate --json
```

Do not edit `TODO.md` directly. Clamp intentionally has no local write-ahead
marker for this v1 crash window.

## Ordinary stale index

Run `kb sync --json`. A result such as `publish_complete_index_stale` means the
Git push succeeded and remains durable even though exact-commit indexing did
not. It is not a publication rollback.

If publication also reports local state cleanup pending, rerun the same
`kb publish --thread-id ...` command after repairing the local Git problem. A
standalone sync can repair the index but cannot clear retained publication
state.

## Missing index state with surviving rows

`index_state_missing` with rows still in `concepts` is not adopted
automatically: those rows lack an authenticated repository identity. Recovery
destroys the derived index and lossy telemetry, then rebuilds from Git.

This is a destructive database operation that discards access telemetry.
Obtain explicit approval for the exact target, connect using the direct URL
without printing it, and substitute the exact configured `source_repository`
below:

```sql
BEGIN;
SELECT pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('example.com/owner/private-clamp', 0)
);
TRUNCATE TABLE public.access_stats, public.concepts;
DELETE FROM public.index_state;
COMMIT;
```

Then rebuild from Git:

```bash
kb sync --json
```

Do not run this procedure against production without separate approval.

## Publication conflicts

A genuine managed-content conflict returns `publish_conflict` and leaves the
rebase available for semantic resolution. Resolve the concepts without losing
facts, stage only the approved resolution paths, and rerun the same publish
command.

If a safe resolution is not possible, run publication with
`--preserve-conflict`. Clamp aborts without a hard reset and preserves the
original commit on `conflicts/<thread-id>/<UTC timestamp>`. Only
`publish_conflict_preserved` or
`publish_conflict_preserved_cleanup_pending` with `preserved: true` proves the
remote branch and permits the Amp skill's single owner notification.

If remote preservation succeeded but local cleanup failed, repeating the same
preserve command verifies the branch and removes only retained local state. It
does not repush. If the first push outcome was uncertain, Clamp checks the exact
recorded branch before deciding whether an ordinary non-force retry is safe.

## Exhausted clean races

Three completed, conflict-free rebase losses return `publish_race_exhausted`
and preserve the latest rebased commit on
`recovery/<thread-id>/<UTC timestamp>`. This is a transient race result, not a
content conflict. Keep the recovery ref and do not send conflict email.

## Uncertain retrieval commit

`kb get` records lossy access telemetry. If the database connection is lost
after COMMIT dispatch, the concept response may fail while the access increment
has already committed. The JSON result warns about this uncertainty. Do not
blindly retry when an exact count matters; reading again may double-count.

Search writes no access telemetry, but a post-dispatch failure can still leave
transaction acknowledgement uncertain. The PRD defines the exact dispatch,
deadline, and acknowledgement boundary.

## Integrity failures

Results such as `rollback_state_uncertain` or `repository_changed` mean Clamp
could not prove that the managed path still has the identity it operated on.
It preserves foreign replacements instead of deleting or overwriting them.
Stop, inspect the repository and `.clamp/transactions/`, and do not claim a
rollback until exact state and cleanup are verified.
