# ADR 0002: Candidate package dependencies by relative path

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-01 run; revisit when the user returns.
Date: 2026-10-01

## Context

Shared packages have no remotes or versions yet (ADR 0001), but consumers must build against
them to validate extraction.

## Decision

On task branches only, apps reference shared packages by relative path to the sibling
checkout: SwiftPM `.package(path:)`, XcodeGen `path:`, Gradle `includeBuild`. Release
configurations never carry these overrides. When remotes exist, swap to canonical URL plus
an exact version (see [PUBLISH.md](../../PUBLISH.md)).

## Consequences

`tools/atlas.py deps` maps such a path to the registered repo by its `local_dir` and
reports it as a manifest-derived `library` edge on that branch's ref.
