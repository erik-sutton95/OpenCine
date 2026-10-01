# BASE-01: frozen evidence and donor choice

Status: **implemented** (documentation deliverables). Recorded 2026-10-01 from Git objects
only; no shared checkout was switched, and no build, test, simulator or hardware run was
performed for this record. Machine paths are omitted; resolve repos with
`python3 tools/atlas.py locate <id>`.

## 1. Baseline manifest

| Atlas ID | Ref | Full SHA | Commit time | Subject |
|---|---|---|---|---|
| `openpocketcine` | `origin/main` = local `main` | `27b15028e86d93798c802ddb56c7c474a30bb4c7` | 2026-10-01T10:47:41+02:00 | build: bump gradle-wrapper from 9.7.1 to 9.8.0 (#486) |
| `openinstacine` | `main` = `origin/main` | `35b6f33b20cbd791a4c24b6380046f180f1ee454` | 2026-09-30T22:23:53+02:00 | chore: store gradlew.bat with the line endings .gitattributes asks for |
| `openzcine` | `origin/main` | `9ac413876ddc663e95edb6cf7913f2aa73ea03b3` | 2026-09-30T12:45:09-07:00 | build: bump astro from 7.3.2 to 7.3.5 (#389) |
| `openzcine` (candidate) | `feat/monitor-engine-port` | `ef38a2646e49c248c089d6bf5d7bfca1c836dd62` | 2026-09-29T09:23:16+02:00 | docs: call the Frame.io upload Frame.io delivery instead of Camera to Cloud |

Canonical remotes (verified from each checkout): `https://github.com/erik-sutton95/OpenPocketCine`,
`.../OpenInstaCine`, `.../OpenZCine`; default branch `main` for all three
(`refs/remotes/origin/HEAD`).

### Checkout and worktree state at recording time

| Repo | Primary checkout | Relevant worktrees |
|---|---|---|
| `openpocketcine` | On `main` at the baseline; one untracked folder (`public-site/`), no tracked changes. Used live by other sessions. | A review worktree on the baseline commit; a prunable detached scratch worktree. |
| `openinstacine` | Clean `main` at the baseline. | None. |
| `openzcine` | **Dirty**, on `spike/br6-bluetooth-remote` (`28bb1143`): 3 modified tracked files, 3 untracked paths. User spike work, preserved, not a source for extraction. | `feat/monitor-engine-port` at `ef38a264`, clean, in a worktree whose folder is named `main` (the name is not branch evidence). Several other task worktrees exist; none is a donor. |

### Reconciliations required by BASE-01 steps 3 and 4

- **Pocket vertical-raster fix.** The plan's separate donor `7ee6df1981aedd62df88681f5021faef6c8a2ac3`
  (`fix/android-vertical-feed-crop`) was squash-merged as `707e30e33a3db7caaf737bb52746e7d69583525d`
  (#482). `Apps/Android/app/src/main/cpp/opc_vulkan.cpp` is byte-identical between the branch
  tip and #482, and #482 is an ancestor of the baseline. It is no longer a separate donor.
- **Plan inspection SHA for Pocket.** The plan inspected `3cf8187c25c640e47ad799983a9537c7d505bbf0`;
  it is an ancestor of the new baseline.
- **Insta remote.** The plan saw a stale cached `origin/main` (`539a292`); the cache now equals
  local `main`, so locally committed work is published.
- **Nikon engine-port.** Not merged: 117 commits not on `origin/main`, while `origin/main`
  has 17 commits not on the branch (merge base `4b83ce28`, 2026-08-29). Decision:
  - **Already integrated on main:** Frame.io request planning (`Sources/OpenZCineCore/Frameio/`),
    PTP core, HDMI/UVC capture (`ios/Runner/UVCVideoSource.swift`). Donor for these is `main`.
  - **Candidate donors (engine-port only):** owner-keyed JNI registry
    (`Sources/OpenZCineAndroidFacade/AndroidSessionOwnerRegistry.swift` and tests), picture/control
    separation (`Sources/OpenZCineCore/VideoSource.swift`), multicam (`ios/Runner/MulticamCoordinator.swift`,
    `Sources/OpenZCineCore/GroupRecord.swift`), Nikon UI adapters, vendored shared UI.
  - **Require separate qualification** through the branch's own review before any of it is
    called integrated. It is never merged as an incidental extraction step.

## 2. Shared UI comparison (step 5)

Exact blob comparison by path, Pocket baseline against each copy:

| Path | Pocket files | Insta identical | Nikon engine-port identical | Nikon-only files |
|---|---:|---:|---:|---:|
| `Sources/MonitorPresentation` | 31 | 31 | 27 | 0 |
| `Sources/MonitorUI` (incl. resources) | 143 | 142 (`MonitorTheme.swift` differs) | 130 | 0 |
| `Tests/MonitorPresentationTests` | 25 | 25 | 20 | 0 |
| `Apps/Android/monitor-ui` | 273 | 272 (`MonitorTheme.kt` differs) | 262 | 2 |

Pocket made 9 commits between Insta's last sync (`9e306c91`) and the baseline; none touched
these four paths, so Insta's copy is current for them.

## 3. Build inventory (step 6)

| Repo@ref | Swift package products | Xcode project input | Android modules | Cross-repo manifest deps |
|---|---|---|---|---|
| Pocket@main | `MonitorPresentation`, `MonitorUI`, `OpenPocketViewCore`, `OpenPocketCineAndroid` (`Package.swift`) | XcodeGen `ios/project.yml` (generated project is untracked); app consumes the root package by `path: ..` | `:app`, `:core-api`, `:monitor-ui` | none |
| Insta@main | Root: same four plus `MonitorContracts`; `Adapters/Insta360Protocol/Package.swift`; `tools/LunaProbe/Package.swift` | XcodeGen `ios/project.yml`; `Insta360Apple` framework target compiles `Adapters/Insta360Apple` sources | `:app`, `:core-api`, `:monitor`, `:monitor-ui`, `:luna-adapter` | none |
| Nikon@main | `OpenZCineCore`, `OpenZCineAndroid` | Committed `ios/Runner.xcodeproj`; compiles `OpenZCineCore` sources directly (no local package reference) | `:app`, `:core-api`, `:wear-relay`, `:wear` | none |
| Nikon@engine-port | adds `MonitorPresentation`, `MonitorUI` | `Runner.xcodeproj` adds a local package reference to `..` | adds `:monitor-ui` | none |

Every manifest above parses with `tools/atlas.py deps <id>` (status `parsed`). External
dependencies (Sentry, swift-crypto, ZIPFoundation, AndroidX and others) are listed by that
command; their versions stay in each repo's lockfiles and catalogs.

### Current CI commands (from `.github/workflows/ci.yml` and `justfile` at the baseline)

| Repo | Native job | Android job | Other required jobs |
|---|---|---|---|
| Pocket | `just native-check` = `swift-test relay-test ios-test ios-build watch-build` (macOS) | `./gradlew assembleDebug test lint` | Meta checks (gitleaks, hygiene, Sentry config, connection-stress unit tests, release notes, typos, markdownlint, lychee, editorconfig, actionlint), handbook build, `CI gate` |
| Insta | `just core-test` (`swift test`, plus `Adapters/Insta360Protocol`) and `just ios-test -only-testing:OpenInstaCineTests` | `./gradlew :app:assembleDebug :monitor:testDebugUnitTest :luna-adapter:testDebugUnitTest :app:lintDebug :monitor:lintDebug :luna-adapter:lintDebug` | Meta checks, handbook, `CI gate` |
| Nikon | `just native-check` = `check-demo-isolation swift-check ios-test ios-build watch-build` | `./gradlew assembleDebug :app:assembleDebugAndroidTest :wear:assembleDebugAndroidTest test lint :app:verifyReleaseNativeLibraries :wear:verifyWearReleaseArtifact` | Meta checks, secret scan, bug relay worker, handbook, `CI gate` |

All three use `dorny/paths-filter` with a `CI gate` job that accepts deliberately skipped
jobs, and native/Android jobs skip on private repositories (Pocket, Insta). Insta's Android CI
does not test `:monitor-ui` or `:core-api` (plan 11.6). None of these jobs runs when a
shared package changes upstream; OPS-01 owns that gap.

## 4. Donor inventory (plan section 4 groups)

Owner today is where the code lives at the baseline; destination stays proposed.

| Group | Chosen donor revision | Donor paths | Owner today | Destination (proposed) |
|---|---|---|---|---|
| 4.1 LUT parse/index/exposure math | Pocket `27b15028` | `Sources/OpenPocketViewCore/CubeLUT.swift`, `CustomLUTIndex.swift`, `LUTExposureCompensation.swift` | Pocket | `OpenCineMedia` (`opencinecore`) |
| 4.1 Color science, log transforms | Pocket `27b15028` | `Sources/OpenPocketViewCore/LiveColorScience.swift`, `LogColorTransform.swift`; Android `feed/LiveColorScience.kt` | Pocket | `OpenCineMedia` plus DJI profile provider |
| 4.1 Frame taps, scopes, decoder, renderer | Pocket `27b15028` (renderer includes #482) | `ios/OpenPocketCine/LiveFrameSample.swift`, `Apps/Android/app/src/main/cpp/opc_vulkan.cpp` | Pocket | Core media runtime (MEDIA-02) |
| 4.1 Frame.io request planning | Nikon main `9ac41387` (compare Pocket `ios/OpenPocketCine/Frameio/`) | `Sources/OpenZCineCore/Frameio/` | Nikon | Optional `OpenCineFrameIO` |
| 4.1 Scope math (alternative) | Nikon engine-port `ef38a264` (candidate) | `Sources/OpenZCineCore/ScopeSampler.swift` | Nikon (branch) | Compare in MEDIA-01 |
| 4.2 UI 2.0 Swift | Pocket `27b15028` | `Sources/MonitorPresentation`, `Sources/MonitorUI`, `Tests/MonitorPresentationTests` | Pocket (copied to Insta, Nikon branch) | `opencineui` |
| 4.2 Theme | Insta `35b6f33b` (ADR 0004) | `Sources/MonitorUI/MonitorTheme.swift`, `Apps/Android/monitor-ui/.../MonitorTheme.kt` | Insta | `opencineui` |
| 4.2 UI 2.0 Compose | Pocket `27b15028` | `Apps/Android/monitor-ui` | Pocket | `opencineui` Android |
| 4.2 Nikon UI reconciliation input | Nikon engine-port `ef38a264` (candidate) | the 4 + 13 + 5 + 11 differing files and 2 Nikon-only files above | Nikon (branch) | resolved in UI-03 |
| 4.3 Multi View | Pocket `27b15028`; Nikon engine-port `ef38a264` (candidate) | `ios/OpenPocketCine/Multiview*.swift`; `ios/Runner/MulticamCoordinator.swift`, `Sources/OpenZCineCore/GroupRecord.swift` | Pocket; Nikon (branch) | `OpenCineMulticam` (not created) plus `opencineui` |
| 4.4 DJI | Pocket `27b15028` | `Sources/OpenPocketViewCore` (DUML, BLE, status) | Pocket | `OpenCineDJI` (not created) |
| 4.4 Nikon | Nikon main `9ac41387`; owner registry from engine-port `ef38a264` (candidate) | `Sources/OpenZCineCore` (PTP), `Sources/OpenZCineAndroidFacade` | Nikon | `OpenCineNikon` (not created) |
| 4.4 Insta360 | Insta `35b6f33b` | `Adapters/Insta360Protocol`, `Adapters/Insta360Apple`, `Apps/Android/luna-adapter` | Insta | `OpenCineInsta360` (not created) |
| 4.5 App shells | each baseline | entry points, branding, signing, store config | each app | stays in the app |

## 5. Source-copy relationships

Authored as typed `source-copy` edges in `repos/<id>/meta.json`:

| Consumer | Donor | Scope | Mechanism | Donor revision | Status |
|---|---|---|---|---|---|
| Insta | Pocket | shared Swift targets, tests, renamed iOS shell, tools subset | `scripts/sync-openpocketcine.sh` | `9e306c91` | live |
| Insta | Pocket | Android `monitor`, `monitor-ui`, `core-api` | manual copy | `9e306c91` (per `docs/DEVELOPMENT.md`) | live |
| Nikon engine-port | Pocket | `MonitorPresentation`, `MonitorUI`, tests, Android `monitor-ui` | hand-vendored | not recorded | candidate |
| Pocket | Nikon | `CubeLUT.swift` | one-time adaptation | not recorded | live (historical) |
| `opencineui` | Pocket (and Insta theme) | shared UI | UI-01/UI-02 extraction | `27b15028` / `35b6f33b` | candidate |

## 6. Asset and fixture provenance (step 7)

From each repo's `THIRD-PARTY-NOTICES.md` at the baseline:

| Asset | Where | License/permission | Shared redistribution |
|---|---|---|---|
| Sora font | `Sources/MonitorUI/Resources/Fonts` (all copies) | SIL OFL 1.1, text shipped beside it | Allowed; moves with `opencineui` with its license file |
| Lucide HUD icons | `Sources/MonitorUI/Resources/Icons`, Android `monitor-ui` assets | ISC/MIT texts in the notices | Allowed with notice |
| Field Monitor assist icons (Tabler-derived) | `Resources/Icons/assist`, Android assets | MIT, `LICENSE-Tabler.txt` beside the SVGs | Allowed with license file |
| CubeLUT parser | Pocket `Sources/OpenPocketViewCore/CubeLUT.swift` | Apache 2.0, adapted from OpenZCine | Allowed (same license) |
| Official DJI Rec.709 cubes | Pocket `ios/OpenPocketCine/Resources/`, Pocket and Insta Android `assets/luts/` | Redistributed for identification; not affiliated with DJI | **App-scoped.** Keep with the DJI app/integration; not in `opencineui` or Core |
| Insta360 Luna I-Log LUT | Insta `Resources/CameraLUTs/`, `ios/OpenInstaCine/Resources/` | Manufacturer-supplied, no license accompanied | **App-scoped.** Excluded from shared packages |
| "R3D NE Monitor" contributed LUT | Nikon `Sources/OpenZCineCore/MonitorLUTContributedTable.swift` (generated table) | Permission given in conversation for OpenZCine's built-in category only | **Excluded from shared redistribution** pending clarification; MEDIA-01 must leave this file in the Nikon app |
| Luna protocol reference (diamondfsd/luna-ai-cut) | Insta notices | MIT reference, not distributed code | Notice travels with the Insta integration |
| IBM Plex Sans | Pocket website only | SIL OFL 1.1 | Not part of the app UI |

Test fixtures: Pocket `Tests/OpenPocketViewCoreTests/Fixtures` (1 binary capture), Nikon
`Tests/OpenZCineCoreTests/Fixtures` (6 binary, 1 JSON). Both are excluded from their Swift test
targets' sources and stay with the vendor integration. Before any fixture moves to a shared
package or this atlas, review it for credentials, network names and identifying metadata
(plan 11.7). The atlas stores no fixtures.

## 7. Qualification ledger

Nothing below was re-run for this record. "Exists" means a dated document at the baseline
describes earlier results; it is not a fresh pass.

| Area | Evidence that exists at the baseline | Missing (untested in this run) |
|---|---|---|
| Pocket iOS feed reliability | `docs/audits/2026-09-14-feed-qualification.md` (iPhone 16 Pro Max, Pocket 4 Pro; full release qualification recorded as incomplete) | Fresh run at `27b15028` |
| Pocket performance | `docs/PERFORMANCE.md`, audits dated 2026-09-22/23/24 (iOS and Android A/B) | Pre-extraction baseline on selected devices for MEDIA-02 bounds |
| Pocket upright Android raster | #482 merged | Physical confirmation at the baseline |
| Insta Android | `docs/DEVELOPMENT.md`: builds, **not yet verified on a physical Luna** | Any physical Android Luna run |
| Insta iOS | `docs/implementation/luna-ios-status.md` | Fresh run at `35b6f33b` |
| Nikon engine-port multicam | `docs/design/specs/2026-09-03-multicam-design.md` lists physical tests as required before ship | Any recorded physical multicam result: **untested** |
| UI baseline screenshots (step 8) | none captured | All apps, both platforms: **untested** (needs simulator/devices; not performed) |
| Runtime measurements (step 8) | historical audits only | Not captured for this baseline |

## 8. First extraction PR scope (UI-01)

One reviewable change set, local only until publishing is decided ([PUBLISH.md](../PUBLISH.md)):

1. `OpenCineUI` package created from Pocket `27b15028`: `Sources/MonitorPresentation` (31),
   `Sources/MonitorUI` (143 incl. fonts and icons), `Tests/MonitorPresentationTests` (25),
   with `LICENSE`, `NOTICE` and the Sora, Lucide and Tabler notice sections. Module names
   unchanged. No DJI cube, Luna LUT or Nikon contributed LUT.
2. Theme: Insta's settable-accent `MonitorTheme` replaces Pocket's (default accent unchanged,
   so Pocket renders as before).
3. Pocket consumer change on a task worktree branch: drop the two targets and their test
   target from `Package.swift`, depend on the package by relative path, keep `ios/project.yml`
   product names. No behavior change.
4. Gate: Pocket builds from a clean worktree with the package, no duplicate compilation, moved
   tests pass. Screenshot comparison stays **untested** until devices or simulators are used.

Out of scope: Android extraction (UI-02), Insta and Nikon adoption (UI-03), renames, any
camera-protocol change.
