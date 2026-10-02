# ADR 0009: Publish with library ranges, app exact pins, in one resumable command

Status: **Accepted, provisional.** Made autonomously during the unattended 2026-10-02 run (RELEASE-01); revisit at the first publish. Partly superseded by ADR 0010 (2026-10-02): one platform repository, one tag; the library ranges no longer apply because the platform depends on no other package.
Date: 2026-10-02

## Context

ADR 0001 kept everything local until hosting is decided; ADR 0002 left sibling paths on the
candidate branches; ADR 0007 chose versioned repositories without submodules. The harness found
(MULTI-03 finding F2) that exact library-to-library pins cannot resolve together in a
cross-brand app. The publish touches seven package repositories, the atlas and three app
branches, so it must be repeatable, reviewable before it acts, and resumable.

## Decision

- `tools/publish.py`, driven by `compat/release-<version>.json`, is a dry run by default and acts
  only with `--execute`. Each step is recorded in `.local/publish-state.json`; a rerun resumes.
- Packages are published one at a time in tag order (Core first, Harness last): remote, URL
  dependencies, clean-clone verification, annotated tag, push. No pushed `main` ever carries a
  sibling path.
- Libraries depend on each other with `.upToNextMinor(from: "<version>")`. In 0.x an incompatible
  change bumps the minor version (compat/VERSIONS.md), so `from:` (up to the next major) would
  admit incompatible versions.
- Apps pin `exact` versions in `Package.swift`, XcodeGen `exactVersion`, or an Xcode
  `exactVersion` requirement, and commit every `Package.resolved`.
- Android keeps sibling checkouts pinned to the tag commits until a Maven namespace is chosen.
  The sibling checkout leaves every CI job that does not run Gradle, and Xcode Cloud.
- Local multi-repo work uses `swift package edit` or an Xcode local package override; manifests
  never read environment variables.
- Commit emails are a recorded decision. `publish.py rewrite-authors` rewrites unpublished package
  branches to the chosen address (tree-identical) before the first push.

## Consequences

`atlas compat run` substitutes candidates by sibling path, which Apple builds stop reading once an
app takes packages by URL; it needs an override step before the next package candidate is
validated on iOS. Package docs that describe sibling checkouts must be updated by hand (the dry
run lists them).
