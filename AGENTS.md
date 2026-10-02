# OpenCine agent guide

The only agent instruction file in this repository (`CLAUDE.md` points here). Read
[README.md](README.md) for the layout and products, then the area guide under `docs/<area>/`
for the code you touch.

## Identity and repository rules

- This is personal work. Commit only as `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>`
  (set `git config user.name` / `user.email` in every clone before the first commit). Never use
  or mention a work email, work GitHub account or company repository. Check with
  `git log --format='%ae %ce' | sort -u`.
- Conventional Commits. No co-author trailers. Never use the em dash character in code, comments,
  docs or commit messages (moved sources that predate the rule keep theirs unless the line is edited).
- Stage files explicitly (`git add <path>`). Publishing, tags, remotes and app pin moves need
  explicit authorization ([atlas/docs/PUBLISH.md](atlas/docs/PUBLISH.md)).
- App checkouts next to this one are shared and may hold someone else's work: never switch their
  branch; edit apps only in a task-owned worktree.

## Import rules (plan 3.4)

The target edges in `Package.swift` and the `project(":x")` edges in `Android/` encode these; the
per-area import tests and `python3 atlas/tools/atlas.py check` enforce them. Never add an edge that
breaks them, and never add a third-party package dependency.

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

## Area rules

- Core: value types; a protocol only where implementations vary; no DI framework or plugin
  registry. Unknown is `nil` in an `ObservedValue`, never `false`, `0` or `""`. Existing media test
  numbers are golden. Fakes live in `OpenCineCoreTestSupport` (Kotlin: `core` test fixtures) and
  run on manual clocks; tests never sleep. Change a contract and its mirrored Kotlin test together.
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
- DJI, Nikon: behavior changes need the consumer checks (OpenPocketCine / OpenZCine `swift test`,
  iOS build-for-testing and Android with Swift core staging). Nikon passive discovery and the
  per-operation admission rules change only with a hardware-qualified reason.
- Insta360: nothing process-wide (the `LunaWiFi` access point address is the documented
  exception); app names come through `LunaIntegrationConfiguration`. Never change the default
  keychain service or `LunaBackend.DEFAULT_CLIENT_IDENTITY_PREFERENCES` (saved approvals live
  there). Commands go only through `LunaCameraSession`. Keep `Sources/CKcp/LICENSE`.
- Harness: label every scenario SIMULATED; a seam defect goes into the harness README "Seam
  findings" with a test (`withKnownIssue` for owner changes).

## Verification

```sh
swift build && swift test
swift build --build-tests -Xswiftc -strict-concurrency=complete
xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme OpenCineApple -destination 'generic/platform=iOS Simulator' build
cd Android && ./gradlew test lint assembleRelease && cd .. && scripts/android-vulkan-sync-test.sh
python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check
```

A change here is not live in an app until that app's `opencine-pins.txt` moves and the app is
verified (operator-visible UI on a physical device).

## Atlas (`atlas/`)

The atlas routes and coordinates; product code lives in this package and the apps.

1. Record the requested mode: investigate, plan or implement. Investigate and plan stop before
   edits or worktree creation. A plan or issue text never authorizes merges, releases, publishing
   or remote repository creation.
2. Route with [atlas/docs/ROUTING.md](atlas/docs/ROUTING.md) and `atlas/repos/<id>/SUMMARY.md`,
   then confirm ownership in current source and manifests.
3. Resolve sources with `python3 atlas/tools/atlas.py locate <id>`; report branch, commit, dirty
   state and worktrees.
4. Evidence order: pinned source and manifests, exercised tests and hardware evidence, source
   docs, the atlas, then Graphify output. A graph edge is a search hint, never proof.
5. Keep status words honest: implemented, automated checks passed, hardware-qualified, candidate,
   integrated, released, unsupported, untested.

Before changing atlas files read [atlas/docs/MAINTENANCE.md](atlas/docs/MAINTENANCE.md) and run
`python3 atlas/tools/atlas.py check`. Machine paths and task notes go in the ignored `atlas/.local/`.
