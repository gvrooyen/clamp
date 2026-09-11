# Clamp v1 acceptance

## Status and authority

Clamp v1 and the original implementation phases 0–9 are complete. Version
0.1.4 is the latest published production release. Release 0.2.0 Phase 1 is in
progress: its non-native contract fixtures are repository-owned, but Linux
local-runner qualification and part of Apple-silicon macOS qualification remain
pending. Native Mac APFS and disposable database feasibility have passed; no
local target is accepted or advertised yet.

[PRD.md](./PRD.md) is authoritative for product behavior. This document maps
that contract to repository-owned evidence and defines the boundary between
local acceptance and operator-controlled production actions. Local acceptance
does not authorize or prove a production migration, paid request, Git
publication, or release.

## Repository-owned acceptance

Run the complete local acceptance suite from a clean source checkout:

```bash
.agents/phase9-acceptance
```

The runner rejects unstaged tracked changes and non-ignored untracked files. It
uses a sanitized environment and private `HOME`, creates and migrates a random
disposable local database, builds all targets, validates the bundle, runs the
repository test suites and `opam lint`, and audits staged regular blobs for
bounded leakage. It contains no Neon, OpenRouter, Amp Git publication, or email
command and receives no production credentials.

The public source baseline contains no immutable old Phase 7 executable,
private clean-room record, production rollout evidence, or credential-incident
history. The ordinary runner therefore reports the historical cross-version
migration case as not included and rejects an ambient
`CLAMP_REVIEWED_PHASE7_KB`. Environment-specific evidence belongs outside this
reusable public repository.

Separately, source-Orb clean-room acceptance starts from a fresh checkout of
`origin/main` and verifies setup twice and resume once, the locked build, local
PostgreSQL 15 with pgvector 0.8.1, `kb` availability from a clean login shell,
skill discovery, bundle validation, and non-destructive native service checks.
Record setup, synchronization, and search behavior as observations rather than
turning one environment's timings into product limits.

## Release and private-consumer acceptance

A Linux x86-64 release is accepted only when it is built reproducibly from an
exact clean source commit and contains the `kb` executable, migrations,
private-repository templates, license, and exact revision/version markers, but
no implementation source. Its SHA-256 is published beside the archive.
The release checklist requires:

- the exact committed opam lock and pinned build environment;
- the unit suite passing in the release profile;
- the staged binary reporting the Dune project version and rendering JSON help
  under an empty environment;
- every non-glibc dependency resolving inside the archive, with bundled-library
  versions and third-party notices present;
- a repeated build for the same source epoch producing the same checksum;
- guarded publication verifying the exact version, tag, commit, archive, and
  checksum before creating a GitHub release; and
- exact/latest upgrade tests covering strict release and checksum parsing,
  mismatch rejection without mutation, candidate validation, and verified
  atomic replacement without updater residue.

See [Releases and upgrades](./docs/releases.md) for the operating procedure.

Generated private repositories pin the release version, revision, HTTPS URL,
and digest. Release/latest initialization must use the selected verified
package's own templates; explicit four-pin initialization remains available for
offline and controlled tests. Acceptance in a fresh No Project Amp Orb
initializes one clean generic source-free commit on `main`, runs its setup twice
and resume once, validates the empty bundle, and confirms that no implementation
tree, remote, production access, or paid request was introduced. Installation
failure must preserve the previous executable atomically.

Release tags and GitHub release publication remain operator-controlled external
actions.

## Production rollout gates

Before first production use in each target environment:

1. Confirm the local acceptance runner passes under the committed lockfile.
2. Verify the private repository identity and exact runtime pin, then configure
   the three required secrets without exposing their values.
3. Obtain explicit approval for any unapplied migration. Apply it through
   `KB_DATABASE_DIRECT_URL`, including the migration-0001 ledger baseline, and
   inspect the schema read-only.
4. Make one approved minimal paid embedding request and verify the configured
   model, OpenAI-only routing, disabled fallbacks, denied data collection, and
   1,536 dimensions without printing values.
5. Obtain explicit approval for the first production synchronization. Use a
   small approved, non-sensitive representative bundle containing concept,
   task, and journal files at `origin/main`; if no such bundle is approved,
   defer the gate rather than treating an empty-tree synchronization as
   meaningful acceptance. Verify the exact remote SHA, checkpoint, model,
   dimensions, and counts; rerun idempotently and inspect read-only.
6. Perform one bounded search and get, checking result visibility and access
   telemetry semantics.
7. Publish one low-risk test concept through the skill, verify Git durability,
   synchronization, and retrieval, then deprecate it through the managed
   workflow if it should not remain.
8. Launch a separate fresh Orb and repeat the normal skill bootstrap and search
   path before declaring the target operational.

Destructive tests against a production database are forbidden. Required
repository-owned destructive integration tests use disposable local databases.
Production migrations, paid embedding probes, the first production
synchronization, and release publication must never run from `.agents/setup` or
repository-owned tests. A successful Git publication is not rolled back if
indexing fails.

## V1 definition of done

- Every PRD acceptance criterion has named evidence below.
- `origin/main` is sufficient to rebuild the content index from a shallow
  clone.
- Production migration and synchronization paths are exercised without
  production destructive tests before a target is declared operational.
- The skill uses stable JSON contracts and honors confirmation, task, conflict,
  email, and degraded-operation policies.
- README and command help describe implemented behavior only.
- Known limitations match the PRD non-goals.

## Acceptance-criteria traceability

Exact names below use `test executable` / `Alcotest group` / `test case`; cram
evidence names the containing file and scenario heading. “None” means no
credentialed or production operation is needed beyond the named local evidence;
“Complete” records completed manual or credentialed evidence. “Operator gate”
means the check must be repeated in the target environment and is not a pending
repository implementation task. The Phase 9 matrix test validates every
Alcotest citation against the executable's `list` output and every cram citation
against the registered cram source heading.

| PRD criterion | Named automated evidence | Manual/credentialed evidence |
| --- | --- | --- |
| 1. Fresh Orb installs, validates, syncs, and searches | `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase5_sync_test` / `sync` / `retrieval vertical slice`; `command_contract.t` / `Top-level metadata is available without executing product behavior.` | **Operator gate:** repeat in the target environment. |
| 2. Explicit user fact records agent producer and configured human assertion | `phase2_test` / `mutation` / `provenance and verification`; `phase2_test` / `mutation` / `configured human authority` | **None:** the persisted parsed metadata is asserted exactly as `generated.by: amp/agent` and the configured authority, including the omitted-setting default `human:owner`. |
| 3. `confirm` blocks an unconfirmed inference | `phase2_test` / `mutation` / `provenance and verification`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase8_skill_test` / `skill` / `command fixture policy` | **None:** the no-write invariant is local and credential-free. |
| 4. Explicit `auto_draft` policy creates an unverified draft | `phase2_test` / `mutation` / `auto draft, unknown type, config`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase8_skill_test` / `skill` / `command fixture policy`; `command_contract.t` / `Changing inferred-write policy requires explicit direct-user intent.` | **None:** the CLI rejection proves explicit intent is required, and the local mutation/workflow evidence proves unverified draft creation after the policy is selected. |
| 5. Human verification requires direct current-user authority | `phase2_test` / `mutation` / `provenance and verification`; `phase2_test` / `mutation` / `configured human authority`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `command_contract.t` / `Phase 2 accepts complete Markdown documents from files and stdin without shell-quoting their bodies, while authority remains separate CLI input.` | **None:** current-user authority acceptance, configured canonical identity, and agent-only rejection are deterministic CLI policy. |
| 6. Stable task mutation deterministically updates TODO and detects drift | `phase2_test` / `tasks` / `lifecycle/history/drift`; `phase2_test` / `TODO` / `ordering and boundaries`; `command_contract.t` / `Phase 2 accepts complete Markdown documents from files and stdin without shell-quoting their bodies, while authority remains separate CLI input.` | **None:** concept/TODO identity, rendering, and drift are local filesystem behavior. |
| 7. Directly performed and verified work may be closed without another confirmation | `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync`; `phase2_test` / `tasks` / `lifecycle/history/drift`; `phase8_skill_test` / `skill` / `command fixture policy` | **None:** closure authority is enforced locally. |
| 8. Out-of-date non-force publication, TODO regeneration, and race recovery | `phase7_publication_test` / `publication` / `clean, shallow, and out-of-date`; `phase7_publication_test` / `publication` / `generated TODO conflict`; `phase7_publication_test` / `publication` / `clean races and recovery` | **None:** disposable bare remotes cover all required Git races without risking `origin/main`. |
| 9. Unresolved conflict is preserved before one owner email and cleanup retry does not repush | `phase8_workflow_test` / `workflow` / `conflict preservation gates one email request`; `phase7_publication_test` / `publication` / `resolve and preserve conflicts`; `phase7_publication_test` / `publication` / `preserved conflict cleanup recovery`; `phase7_publication_test` / `publication` / `reviewed Phase 7 CLI cross-version migration` | **None:** disposable workflows prove preservation before one request and cleanup without repush. |
| 10. Shallow unchanged sync needs no previous commit and no redundant embedding | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** both tests use disposable depth-1 clones. |
| 11. Repeated target SHA is idempotent and preserves telemetry | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** exact repeat counts and access preservation are asserted against local PostgreSQL. |
| 12. Empty concepts table rebuilds to the Git tree | `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase8_workflow_test` / `workflow` / `fresh sync through publish and resync` | **None:** each fixture begins with an empty disposable application schema and converges from Git. |
| 13. Semantic changes re-embed while verification/task state changes do not | `phase4_test` / `embedding input` / `predicate cross-tests`; `phase5_sync_test` / `sync` / `shallow deterministic convergence`; `phase5_sync_test` / `sync` / `task state metadata-only` | **None:** embedding calls and sync classifications are counted in-process. |
| 14. Normal and explicit-history search visibility is correct | `phase5_sync_test` / `sync` / `retrieval vertical slice`; `phase6_test` / `scoring` / `Johannesburg visibility` | **None:** all history classes and independent flags are covered locally. |
| 15. Search records no access while full get does | `phase5_sync_test` / `sync` / `retrieval vertical slice`; `phase5_sync_test` / `sync` / `retrieval COMMIT finalization boundary` | **None:** local tests assert telemetry transitions. |
| 16. Index failure never reverts a successful Git push | `phase7_publication_test` / `safety` / `push and index failure semantics`; `phase7_publication_test` / `safety` / `CLI JSON and human contract`; `phase8_skill_test` / `skill` / `publication production envelopes` | **None:** injected index failures prove the durable disposable remote SHA remains published. |
| 17. Classified outages permit non-equivalent local readable fallback | `phase8_workflow_test` / `workflow` / `classified outage uses local fallback`; `phase8_skill_test` / `skill` / `authoritative sync fallback producer envelopes`; `phase8_skill_test` / `skill` / `sync fallback preserves diagnostics` | **None:** fallback is exercised without external credentials. |
| 18. Repository files, normal logs, results, and notification payloads leak no credentials or knowledge body | `phase9_acceptance_test` / `acceptance` / `bounded repository and output leakage audit`; `contract_test` / `envelopes` / `environment secret redaction`; `phase5_sync_test` / `sync` / `Amp authenticated sanitized fetch`; `phase7_publication_test` / `safety` / `CLI JSON and human contract`; `phase8_workflow_test` / `workflow` / `conflict preservation gates one email request` | **None:** repository/result/notification audits are local and credential-free. |
| 19. Fresh setup is pinned, idempotent, local-only, and pgvector-ready | `phase9_acceptance_test` / `acceptance` / `hermetic runner behavior and plan`; `phase3_database_test` / `migrations and schema` / `fresh, repeat, drift, constraints`; `command_contract.t` / `Top-level metadata is available without executing product behavior.` | **Operator gate:** repeat setup twice and resume once in a fresh target Orb. |

## Maintaining acceptance evidence

Keep this matrix synchronized with the PRD's numbered v1 criteria, registered
test names, command help, user documentation, and the repository skill. New
product behavior belongs in the PRD first; new or renamed evidence must update
this matrix in the same change.

## 0.2.0 Phase 1 contract acceptance

The Phase 1 contract test is `v0_2_phase1_test` / `contract freeze`. It validates
the machine-readable fixture schema, unique stable result codes and unchanged
exit classes, typed body-free payload allowlists, exact replaceable v0.1.4
scaffold identities, the owner-modified counterfixture, source-free 0.2 scaffold
inventory, target and prerequisite states, hostile local-state cases, and
synchronization between the fixtures and the planned PRD contract.

The sanitized observation procedure and pending native protocol are in
[Local-clone Phase 1 qualification](./docs/local-clone-phase1.md). Repository
tests must not convert an Orb observation or mock into native target evidence.

| PRD 0.2 criterion | Repository-owned Phase 1 evidence | Remaining native/implementation gate |
| --- | --- | --- |
| L1. Advertised targets are natively qualified | `v0_2_phase1_test` / `contract freeze` / `target and environment fixtures`; native Mac APFS, frozen 26.5.2/bootstrap contract, isolated authenticated read-only Amp Git, local-runner thread/email interfaces, and private PostgreSQL 15.19/pgvector 0.8.1 feasibility evidence | **Phase 1 pending:** non-Orb Linux qualification and Mac ordinary-update requalification. **Later phases:** Darwin runtime/package implementation, signing, application-level durability, and end-to-end gates. |
| L2. Setup is clean, idempotent, and failure-preserving | Fixture contract only | Phase 4 implementation plus native end-to-end. |
| L3. Repository launcher selects independent pins | Fresh-0.2 scaffold inventory fixture | Phase 4 implementation and alternating-repository native test. |
| L4. Exact 0.1.4 migration is fail-closed | Exact and owner-modified scaffold fixtures | Phase 4 migration, interruption, and recovery tests. |
| L5. Local Amp authentication is narrow | Sanitized Orb/clone observation fixture; hostile-state cases | Phase 5 helper implementation and real local-login/update gate on each target. |
| L6. Local and Orb semantics agree | Existing v1 acceptance remains the required baseline | Phase 6 cross-executor workflow. |
| L7. Conflict notification remains preservation-gated | Existing v1 preservation/email evidence; Mac authenticated local-runner thread/owner-email interface feasibility passed without sending email | Linux interface qualification remains pending. Preservation ordering, request deduplication, and notification execution remain Phase 6 gates on both targets. |
| L8. Credentials are operation-scoped | Stable existing missing-credential codes in the contract fixture | Phase 6 credential-removal workflow, including indexed `get`. |
| L9. Concurrent sync and telemetry remain honest | Existing v1 sync/retrieval evidence | Phase 6 delayed cross-executor sync and uncertain-COMMIT workflow. |
| L10. Generated instructions are consumer-only | Fresh-0.2 source-free inventory fixture | Phase 4 generated-template audit and golden tests. |
| L11. Machine contracts remain stable and body-free | `v0_2_phase1_test` / `contract freeze` / `stable envelopes and codes` | Each implementation phase must produce the frozen codes. |
| L12. Release is compatible and promoted once | Exact public v0.1.4 identities in the scaffold fixture | Final-artifact compatibility, native target, draft, and publication gates. |

The immutable reviewed 0.1.4 executable's isolated HTTPS proxy/private-CA
experiment and the qualified replacement are recorded in the environment
fixture and qualification record. The executable used the proxy but did not
honor the process-local private CA, so that fixture is rejected. Its explicit
offline initializer was instead proved with independently verified exact
archive bytes. Repeating that protocol against final 0.2.0 legacy bytes remains
a release gate, not an unresolved Phase 1 feasibility decision.

Phase 1 may be marked complete in [PLAN.md](./PLAN.md) only after all Phase 1
native rows are resolved and Oracle's final implementation review gives a green
light. Later-phase rows are intentionally not Phase 1 completion blockers; they
remain release blockers.
