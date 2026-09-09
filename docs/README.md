# Clamp documentation

Start with the [project README](../README.md) for the short overview.

## Use Clamp

- [Getting started](./getting-started.md) – install the release and create a
  private knowledge repository in Amp or on local Linux.
- [CLI guide](./cli.md) – commands, authority flags, JSON results, and common
  sequences.
- [Using Clamp with Amp](./amp.md) – agent prompts, the repository skill, and
  publication behavior.
- [Knowledge format and configuration](./knowledge-format.md) – repository
  layout, OKF concepts, provenance, tasks, and `clamp.yaml`.

## Understand and operate Clamp

- [Architecture](./architecture.md) – data ownership, synchronization,
  retrieval, and publication.
- [Operations](./operations.md) – Neon, OpenRouter, secrets, migration, sync,
  and rollout boundaries.
- [Failure recovery](./recovery.md) – degraded retrieval, TODO drift, stale
  indexes, publication races, and conflicts.
- [Releases and upgrades](./releases.md) – packaged runtime contents, pinned
  private repositories, self-upgrade, and release production.

## Work on Clamp itself

- [Building Clamp](./building.md) – source builds and the requirements for a
  new target such as macOS.
- [Development and acceptance](./development.md) – source checkout setup,
  tests, and the hermetic acceptance runner.
- [PRD](../PRD.md) – authoritative v1 product and behavior contract.
- [Plan](../PLAN.md) – implementation sequence and acceptance traceability.
- [Repository guidance](../AGENTS.md) – constraints for contributors and
  agents changing this source repository.

If a guide conflicts with the PRD, follow the PRD and report the stale guide.
