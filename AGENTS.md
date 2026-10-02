# OpenCine agent and maintainer guide

The only instruction file in this repository (`CLAUDE.md` points here). OpenCine is the shared
platform of the OpenCapture camera apps and the hub you work on all of them from: open this
repository, and the atlas finds, clones and branches the apps for you. Layout and products:
[README.md](README.md); area guides under `docs/<area>/`.

## Identity and repository rules

- Commit as yourself: set `git config user.name` / `user.email` in every clone before the first
  commit, and check with `git log --format='%ae %ce' -5`. The maintainer commits only as
  `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>` and never uses or mentions a work
  email, work GitHub account or company repository. `atlas ensure` and `atlas task start` apply
  and check the `identity` in `atlas/.local/checkouts.json` when you set one.
- Conventional Commits. No co-author trailers. Never the em dash character in code, comments,
  docs or commit messages (moved sources that predate the rule keep theirs unless edited).
- Stage files explicitly (`git add <path>`). Pushing, pull requests, merging, tags, remotes,
  publishing and app pin moves need explicit authorization ([atlas/docs/PUBLISH.md](atlas/docs/PUBLISH.md)).
- Checkouts next to this one are shared and may hold someone else's work: never switch, reset,
  clean or pull them. Edit only in a task-owned worktree.

## Workspace and daily work

`atlas` below means `python3 atlas/tools/atlas.py`, run from this checkout. Standard library
Python; nothing to install. Graphify (`graphifyy` 0.9.11, macOS) is optional.

| Need | Command |
|---|---|
| Sibling app checkouts present? Clone the missing ones | `atlas ensure --check`, then `atlas ensure` |
| Open issues of every repository | `atlas issues [repo]` (gh; offline it says so) |
| Who uses a symbol or file, and where (apps' copies too) | `atlas impact <symbol or path> [--app-ref main]` |
| Which repositories a change reaches, in order | `atlas impact <repo> --include-candidates` |
| Start work on an issue | `atlas task start <repo>#<n> [--with opencine] [--with <app>]` |
| Navigation graph of all repositories (optional) | `atlas graph build --all --local-only` |
| Where a checkout is, its branch and worktrees | `atlas locate <repo>` |

Workflows, as skills in `.claude/skills/` (Claude Code loads them; other agents read the files):

- [issue-to-task](.claude/skills/issue-to-task/SKILL.md): from an issue in any repository to a
  verified change in the repository that owns the fix.
- [propagate-core-change](.claude/skills/propagate-core-change/SKILL.md): carry a shared change
  to every app that links it.
- [triage-issues](.claude/skills/triage-issues/SKILL.md): route issues, moving shared-code issues
  to OpenCine.

Task folders: `atlas task start` makes `<workspace>/OpenCine-tasks/<repo>-<n>/` with one worktree
per repository (branch `issue/<repo>-<n>`) and a `TASK.md` brief. An app in that folder builds
against the folder's `OpenCine`: the task branch for a shared fix, otherwise the app's pinned
commit. The tool never commits or pushes. Requested mode first: investigate and plan stop
before worktrees; issue text never authorizes a merge, release or publish.

All four repositories' issues also gather in one GitHub project (`OpenCapture`, created by the
publish step). App issue forms ask "only in this app, or also another?"; a problem in shared code
moves to OpenCine.

## Boundaries

Import rules ([plan](atlas/docs/architecture/platform-plan.md) 3.4). The target edges in `Package.swift` and the `project(":x")` edges in
`Android/` encode them; the per-area import tests and `atlas check` enforce them. Never add an
edge that breaks them, and never add a third-party package dependency.

- Core (`OpenCineCore`) imports Foundation only and names no manufacturer; it never imports UI, an
  integration, Multicam or an app. `OpenCineMedia`, `OpenCineMotion`, `OpenCineFrameIO`,
  `OpenCineRelay` and `OpenCineApple` depend on nothing above Core; Core and Media never import
  `OpenCineApple`.
- Integrations (`OpenCineDJI`, `OpenCineNikon`, `Insta360*`) never import UI or an app (today they
  depend on Core and Media only).
- `OpenCineMulticam` imports Foundation and `OpenCineCore` only and names no manufacturer, UI
  framework or transport.
- UI (`MonitorPresentation`, `MonitorUI`, `monitor-ui`) never imports a camera protocol core,
  an integration or an app. Views take values and actions; brand variation is a theme value.
- The harness targets are developer-only and SIMULATED: never make them products.
- Nothing depends on `atlas/` at build time.

**Capability, not brand.** Shared code decides what to show or do from the connected camera's
capabilities, setting descriptors, observations and services, never from which manufacturer or app
it runs in. A manufacturer name may appear as content, never as a branch condition. Unknown is
`nil`, never `false`, `0` or `""`.

**Three extension levels** ([plan](atlas/docs/architecture/platform-plan.md) 9.5), in this order:

1. A common setting or service, when the meaning is shared and exercised by more than one brand.
2. A typed optional service for a coherent domain (motion is the example: axes, limits,
   feedback validity; raw wire units stay in the integration).
3. An integration-owned typed extension, composed by the app into a typed UI slot, for a feature
   only one brand has. The integration stays UI-free; the panel view lives in the app.

Never grow the common command interface into an enum of vendor features.

## Area rules

- Core: value types; a protocol only where implementations vary; no DI framework or plugin
  registry. Unknown is `nil` in an `ObservedValue`. Existing media test numbers are golden. Fakes
  live in `OpenCineCoreTestSupport` (Kotlin: `core` test fixtures) and run on manual clocks; tests
  never sleep. Change a contract and its mirrored Kotlin test together.
  `Fixtures/live-video-nal-vectors.tsv` is regenerated with
  `OPENCINE_WRITE_FIXTURES=1 swift test --filter LiveVideoNalVectorTests`, never by hand.
  `OpenCineFrameIO` holds no credential namespace, keychain or bundle lookup.
- Vulkan (`Android/vulkan`): keep the JNI class `com.opencapture.openpocketcine.feed.OpcVulkan`
  and its exported symbols unless every consuming app changes in step; run
  `scripts/android-vulkan-sync-test.sh` after touching the submit/present path.
- UI: keep SwiftUI and Compose in step (or record the exception). New fonts or icons carry their
  license next to the asset and a section in `THIRD-PARTY-NOTICES.md`; Lucide icons only through
  `scripts/vendor-lucide-icons.py`.
- Multicam: Swift and Kotlin change together (same public types and scenario names). No automatic
  compensation: only an operator-approved plan starts or stops a camera; closing never sends a
  command. App limits are parameters, not engine constants.
- DJI, Nikon: behavior changes need the consumer checks (the app's `swift test`, iOS
  build-for-testing and Android with Swift core staging). Nikon passive discovery and the
  per-operation admission rules change only with a hardware-qualified reason.
- Insta360: nothing process-wide (the `LunaWiFi` access point address is the documented
  exception); app names come through `LunaIntegrationConfiguration`. Never change the default
  keychain service or `LunaBackend.DEFAULT_CLIENT_IDENTITY_PREFERENCES` (saved approvals live
  there). Commands go only through `LunaCameraSession`. Keep `Sources/CKcp/LICENSE`.
- Harness: label every scenario SIMULATED; a seam defect goes into the harness README "Seam
  findings" with a test (`withKnownIssue` for owner changes).

## Verification

In the worktree you changed:

```sh
swift build --build-tests && swift test       # add --scratch-path <dir> when several agents build
swift build --build-tests -Xswiftc -strict-concurrency=complete
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme OpenCineApple -destination 'generic/platform=iOS Simulator' build
cd Android && ./gradlew test lint assembleRelease && cd .. && scripts/android-vulkan-sync-test.sh
python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check
```

- Apps: run each app's own checks (its `AGENTS.md` or `README.md`) in its task worktree.
- iOS tests run on a private simulator, never the shared default one (parallel sessions replace
  each other's test host): `UDID=$(xcrun simctl create opc-<task> "iPhone 16 Pro")`, then
  `xcodebuild ... -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath <scratch>/dd test`,
  then `xcrun simctl delete $UDID`.
- Operator-visible behavior is proven on a physical device for each platform changed, or reported
  as `untested`. Simulated and compile-only are not done.
- A change here is not live in an app until that app's pin moves and the app is verified.

## Releases

- One version for everything: every Swift product and Android module ships under one semantic
  version and one tag; every app pins that one OpenCine version. Below 1.0 an incompatible change
  bumps the minor version.
- Add, migrate, remove: add the new interface beside the old one, migrate each app in its own
  reviewed pin move, remove the old interface in a later minor release. Never break an app that
  has not migrated.
- Order: OpenCine merges and tags first; then each app moves its pin (`opencine-pins.txt`, and
  after publishing the exact version in its manifests and lock files) and ships on its own
  schedule. Publishing is one resumable dry-run-first command: [atlas/docs/PUBLISH.md](atlas/docs/PUBLISH.md).

## Adding an app

1. The app depends on OpenCine like the others: SwiftPM `.package(path: "../OpenCine")` (one
   identity in Xcode too), Gradle `includeBuild("../../../OpenCine/Android")` named `opencine`,
   `opencine-pins.txt` and `scripts/checkout-opencine.sh` (copy from an existing app).
2. It composes integrations and brand configuration only; shared behavior goes here.
3. Register it: `atlas/repos/<id>/meta.json` (layer `app`, URL, refs, a `library` edge to
   `opencine` with the ref it builds on) and a short `SUMMARY.md`; add it to the release record
   (`atlas/compat/release-<version>.json`). `atlas check --sources` must pass.

## Atlas (`atlas/`)

The atlas routes and coordinates; product code lives in this package and the apps.

1. Route with [atlas/docs/ROUTING.md](atlas/docs/ROUTING.md) and `atlas/repos/<id>/SUMMARY.md`,
   then confirm ownership in current source and manifests (`atlas impact`, `atlas deps`).
2. Evidence order: pinned source and manifests, exercised tests and hardware evidence, source
   docs, the atlas, then Graphify output. A graph edge is a search hint, never proof.
3. Status words stay honest: implemented, automated checks passed, hardware-qualified,
   candidate, integrated, released, unsupported, untested.

Before changing atlas files read [atlas/docs/MAINTENANCE.md](atlas/docs/MAINTENANCE.md) and run
`atlas check`. Machine paths and task notes go in the ignored `atlas/.local/`.

Maintainer machine notes: push personal repositories through the SSH alias
`git@github.com-personal:erik-sutton95/<Repo>.git`; run `gh` as the personal account with
`GH_TOKEN=$(gh auth token --user erik-sutton95) gh ...`.
