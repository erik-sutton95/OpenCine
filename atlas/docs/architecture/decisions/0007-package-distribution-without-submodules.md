# ADR 0007: Shared packages are versioned repositories, never submodules

Status: **Accepted, provisional.** Decided by the run coordinator in answer to the user's question about Amended by ADR 0010 (2026-10-02): the shared packages are one versioned repository, OpenCine; still no submodules.
sharing packages in an open-source multi-repo project; revisit when hosting is decided.
Date: 2026-10-01

## Context

Contributors usually clone one app. They must get every shared package automatically, without
extra checkouts, credentials or a superproject. Plan sections 10.3 and 15.2 already reject Git
submodules.

## Decision

- **No Git submodules.** Each shared package (`OpenCineUI`, `OpenCineCore`, later others) is
  its own public repository with semantic-version tags.
- **iOS and Apple:** apps consume packages by SwiftPM remote URL plus an exact version pin and
  commit `Package.resolved`. Cloning an app and building resolves everything.
- **Android:** apps consume a published artifact by Maven coordinate.
  - Recommended host: **Maven Central.** Its namespace must be verifiable: `opencapture.org`
    is owned, so `org.opencapture` is verifiable; `com.opencapture` is not unless
    `opencapture.com` is owned too.
  - Zero-setup fallback: **JitPack** (builds from public Git tags).
  - **Not recommended: GitHub Packages.** It requires authentication even for public
    packages, which blocks casual contributors.
- **Local multi-repo development is an opt-in override, never the committed default.**
  - Xcode: add the local package checkout to the workspace (or drag it in) to override the
    remote package while editing.
  - Gradle: `includeBuild` is enabled only when an untracked property (for example
    `opencine.ui.dir` in `local.properties`, or in `~/.gradle/gradle.properties`) points at a
    local checkout.
- **Contribution flow:** fix in the package repository by pull request, tag a release, then
  bump the pin in each app with its own pull request.

## Open decision

The Android coordinate group is currently `com.opencapture.opencine` on the candidate
branches; it may become `org.opencapture.opencine` to satisfy Maven Central verification.
Decide before the first publication; it is cheap to change before any release exists.

## Consequences

The candidate branches commit hard sibling paths (`path: ../../OpenCineUI` in XcodeGen,
`includeBuild("../../../OpenCineUI/Android")` in Gradle) only because no remotes exist yet
(ADR 0001, ADR 0002). Converting them is a required publishing step in
[PUBLISH.md](../../PUBLISH.md).
