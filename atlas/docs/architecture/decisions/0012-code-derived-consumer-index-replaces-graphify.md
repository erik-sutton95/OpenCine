# ADR 0012: A code-derived consumer index replaces Graphify

Status: **Accepted.** Owner decision, 2026-10-19.
Date: 2026-10-19
Supersedes: [ADR 0006](0006-graphify-is-local-navigation-only.md)

## Context

ADR 0006 added Graphify as optional, macOS-only navigation. In practice the snapshots went
stale (they were built by hand at old commits), the merged view was undirected and missed
cross-language calls, the tool needed a pinned third-party install, and agents working in
OpenCine still had to search every app to learn which Core types an app adopts. The question
agents actually ask is narrower: what of Core does each thin app use, through which files, and
what does the app own.

## Decision

- Graphify is removed everywhere: the adapter (`atlas graph`), its committed snapshots and
  labels, doctor and staleness checks, `impact` graph hints, ignore rules and docs, in OpenCine
  and in the app repositories.
- Its place is taken by two small committed, deterministic, code-derived outputs built with the
  standard library and Git only (no model, no network beyond git and gh). They land in the
  changes that follow this removal; until then source search and `atlas impact` are the
  navigation:
  - public API snapshots of the Core Swift products and Android modules the apps consume,
    checked in CI so a public change is always deliberate;
  - a per-app consumer index (compact Markdown plus JSON, size-budgeted) listing the Core
    modules, public types and views each app adopts, the adapter files that use them, app-owned
    surfaces, pins and drift, platform twins and capability declarations, refreshed when a pin
    moves and checked daily for staleness, and queried offline with `atlas consumers`.
- Both reuse what the atlas already has: the registry, manifest readers, `impact` source
  search and resolver provenance.

## Consequences

Nothing needs installing and every output is reproducible from a commit. There is no call
graph; source search stays the way to find a specific call site, and the index says where to
look first. Snapshot schema and validation for graph snapshots are gone with them.
