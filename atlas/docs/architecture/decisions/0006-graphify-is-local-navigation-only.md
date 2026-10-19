# ADR 0006: Graphify is local, code-only navigation

Status: **Superseded** by [ADR 0012](0012-code-derived-consumer-index-replaces-graphify.md) on 2026-10-19.
Originally accepted provisionally during the unattended 2026-10-01 run.
Date: 2026-10-01

## Context

Plan section 12 lists defects in the donor atlas's Graphify workflow: date-only provenance,
scanning dirty working trees, model calls during a default refresh, and an undirected merge
mistaken for a dependency graph.

## Decision

- Graphify is pinned to the inspected `graphifyy` 0.9.11. Its `update` command runs AST
  extraction and names communities by their hub node, with no model client.
- `atlas graph build --local-only` exports one registered commit with `git archive`, drops
  credential, build-output, capture and vendor-reference files, and runs Graphify under
  `sandbox-exec` with network denied and writes confined to a temporary folder. If the pinned
  version or the sandbox is unavailable, the build refuses to run.
- Snapshots are keyed by full commit SHA, so branch snapshots cannot replace each other.
  Compact reports, labels and provenance are committed; full graphs are ignored.
- The merged view lists its inputs and is navigation only. Dependency facts come from
  `atlas deps`/`impact`, which read manifests and authored evidence.
- Labeling with a model is not implemented. Labels are edited by hand and survive rebuilds.

## Consequences

Builds work on macOS only. On other platforms `graph plan` reports the refusal and the
rest of the atlas works unchanged.
