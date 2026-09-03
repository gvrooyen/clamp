---
type: fact
title: Alpha
generated: {by: amp/agent, at: 2026-08-06T10:00:00Z}
verified: {by: human:owner, at: 2026-08-06T10:01:00Z}
status: stable
sources:
  - id: source-a
    resource: https://example.test/source
    usage_count: 9007199254740993
    usage_window: {from: 2026-01-01, to: 2026-08-06}
clamp:
  asserted_by: human:owner
unknown_nested:
  number: 900719925474099312345
  multiline: |
    first
    second
---

Alpha links to [Beta](<../projects/beta.md#details> "project") and the
[bundle index](../index.md).

The same project is available through [a reference][beta].

[beta]: ../projects/beta.md "Beta project"
