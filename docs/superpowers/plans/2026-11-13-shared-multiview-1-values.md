# Shared Multiview Plan 1: shared values and prep

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Pocket's self-contained Multiview values (record-all policy and copy, saved shared
networks, the locked Shared Wi-Fi page, the saved-stage journal) into OpenCine on both platforms,
and move Pocket onto them: no visible change on Pocket iOS, Pocket Android aligned to iOS for
toolbar order, tally and format line.

**Architecture:** Pure values and small stores land in OpenCine (`OpenCineMulticam`,
`OpenCineApple`, `OpenCineAppKit`, `OpenCineAppKitApple`, Android `:multicam`, `:appkit`) as Swift
and Kotlin twins. Pocket keeps its storage names and JSON keys so saved data from older builds
still loads. The coordinator, seams and screen stay in Pocket until Plans 2 to 4.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing / XCTest as each target already uses), SwiftUI,
Kotlin 2.4 (JVM 17, explicit API mode), Compose, org.json on Android.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md`; series:
`docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md`.

## Global Constraints

- Follow OpenCine `AGENTS.md`: Swift and Kotlin twins change together with the same type and test
  names; no manufacturer or app names in shared code; no em dash character anywhere; Conventional
  Commits; no co-author trailers; stage files explicitly; tests are behavior at contract
  boundaries, no sleeps.
- Shared behavior follows Pocket iOS where Pocket iOS and Android differ (owner, 2026-11-13).
- Pocket iOS shows no operator-visible change in this plan.
- Existing stored data keeps loading: Keychain service `com.opencapture.openpocketcine.multiview-network`
  (accounts `last-network`, `saved-networks`) and `com.opencapture.openpocketcine.multiview-stage`
  (account `stage`); Android prefs `openpocketcine.multiview-stage` key `stage`; every existing
  JSON key unchanged.
- Public API changes update snapshots in the same commit: `python3 atlas/tools/atlas.py api --write --build`
  and `cd Android && ./gradlew updateKotlinAbi updateAndroidApi`.
- Work in a task folder `OpenCine-tasks/shared-multiview/` with worktrees `OpenCine` (branch
  `feat/shared-multiview-1` from `origin/main`) and `OpenPocketCine` (branch
  `feat/shared-multiview-1` from `origin/main`); first cherry-pick the spec and roadmap commits
  from `feat/insta360-multicam` onto the OpenCine branch. Gradle needs `--project-cache-dir /tmp/...`
  on the network volume; Swift builds use `--scratch-path /tmp/...`.

## Review Focus

- A stage saved by today's Pocket iOS (no `bleAddress` key) and by today's Pocket Android (with
  `bleAddress`, hex `identity`) must decode unchanged on its own platform: golden tests in Task 4.
- A Keychain holding only the old `last-network` account (no `saved-networks`) must still list
  that network: test in Task 2.
- Saving a network that already exists with the other hotspot flag must keep both entries; same
  name and flag replaces: test in Task 2.
- A stage whose cleanup list is non-empty but has no cameras and an empty SSID is valid (cameras
  still to return after a closed session); any other empty SSID is not: test in Task 4.
- Record all with any camera unable to record commands no camera at all on iOS, as on Android:
  test in Task 1.

---

### Task 1: Swift `RecordAll`

**Files:**
- Create: `Sources/OpenCineMulticam/RecordAll.swift`
- Test: `Tests/OpenCineMulticamTests/RecordAllTests.swift` (reuse `Harness.swift`)
- Modify: `docs/multicam/README.md` (Public types table: `RecordAll`, both platforms),
  `atlas/api/swift/OpenCineMulticam.txt` (regenerated)

**Interfaces:**
- Consumes: `RecordPlan.make(_:policy:entries:in:at:)`, `RecordPlan.submit(in:at:sessions:)`,
  `RecordSubmission.finished(sessions:)`, `TargetOutcome`, `RecordResult` (existing).
- Produces (twin of Kotlin `RecordAll`, `Android/multicam/.../RecordAll.kt`):
  ```swift
  public enum RecordAll {
      public static let policy: TargetPolicy                       // .strict
      public static func plan(_ requested: [MonitorEntryID], recording: (MonitorEntryID) -> Bool,
          in group: MulticamGroup, at state: MulticamSnapshot) -> RecordPlan
      public static func run(_ plan: RecordPlan, in group: MulticamGroup, at state: MulticamSnapshot,
          sessions: [CameraSessionID: any CameraSession]) async -> RecordResult?   // nil: stale or refused, nothing sent
      public static func progress(_ direction: RecordDirection) -> String
      public static let waiting: String       // "Waiting for camera confirmation"
      public static let changed: String       // "Cameras changed · try again"
      public static func note(_ outcome: TargetOutcome, direction: RecordDirection) -> String?
      public static func summary(_ result: RecordResult, allMatch: Bool) -> String
  }
  ```
  Copy is exactly Kotlin's (`progress`: "Starting cameras…" / "Stopping cameras…"; `note`:
  "Recording" / "Recording stopped", "Recording command rejected · check camera" for
  `.rejected(.cameraRefused)`, "Not sent · check camera" for other rejections and failures,
  `nil` for `.superseded`, "No confirmation · check camera" otherwise; `summary`: "Recording on N
  cameras" / "Recording stopped" when every target confirmed and `allMatch`, else "C of T
  confirmed · check camera tiles").

- [ ] **Step 1: Write the failing tests**, same names as the Kotlin twin:
  `oneCameraThatCannotRecordCommandsNone` (a DJI-like reported camera plus a Nikon-like camera
  with no live view: `plan.policy == .strict`, direction `.start`, `plan.isRefused`, `run` returns
  `nil`, neither fake's wire has a command), `anyCameraRecordingMakesThePressAStop`,
  `everyCameraConfirmsAndTheSummarySaysSo`, `theOperatorsWordsForEachOutcome` (every
  `TargetOutcome` case maps to the copy above). Port the bodies from
  `Android/multicam/src/test/kotlin/com/opencapture/opencine/multicam/RecordAllTests.kt`.
- [ ] **Step 2: Run** `swift test --scratch-path /tmp/smv1 --filter RecordAllTests`. Expected: FAIL, `RecordAll` not found.
- [ ] **Step 3: Implement** `RecordAll` in `Sources/OpenCineMulticam/RecordAll.swift` (submission
  failure, `RecordSubmissionError`, maps to `nil`).
- [ ] **Step 4: Run** the same filter. Expected: PASS, 4 tests.
- [ ] **Step 5: Regenerate** the Swift API snapshot, update the README table, commit
  `feat(multicam): Swift RecordAll, the twin of Kotlin's`.

### Task 2: Swift `SharedNetworkStore`

**Files:**
- Create: `Sources/OpenCineApple/SharedNetworkStore.swift`
- Test: `Tests/OpenCineAppleTests/SharedNetworkStoreTests.swift` (create the folder and test
  target in `Package.swift` if `OpenCineApple` has none; follow the existing test target pattern)
- Modify: `atlas/api/swift/OpenCineApple.txt`

**Interfaces:**
- Produces (iOS twin of Android `platform/SharedNetworkStore`):
  ```swift
  public struct SharedNetwork: Codable, Hashable, Sendable {
      public var ssid: String; public var password: String; public var hotspot: Bool?   // JSON keys ssid, password, hotspot
  }
  public protocol SharedNetworkStorage: Sendable {          // one Keychain generic password per account
      func read(account: String) -> Data?
      func write(_ data: Data, account: String)              // device-only, after first unlock
      func delete(account: String)
  }
  public struct KeychainSharedNetworkStorage: SharedNetworkStorage { public init(service: String) }
  public struct SharedNetworkStore: Sendable {
      public init(storage: any SharedNetworkStorage)
      public func savedNetworks() -> [SharedNetwork]          // "saved-networks", else ["last-network"], else []
      public func load(ssid: String, hotspot: Bool) -> SharedNetwork?
      public func save(ssid: String, password: String, hotspot: Bool)   // writes "last-network" and the list
  }
  ```
  Behavior is exactly Pocket's `ios/OpenPocketCine/MultiviewNetworkStore.swift`: a missing
  `hotspot` reads as `false`; save replaces the entry with the same SSID and hotspot flag and
  appends; `last-network` always holds the newest save.

- [ ] **Step 1: Write the failing tests** against an in-memory `SharedNetworkStorage`:
  `aLegacyLastNetworkIsListedWhenNoListExists`, `savingTheSameNetworkAndKindReplacesIt`,
  `aWiFiAndAHotspotWithOneNameAreKeptApart`, `aMissingHotspotFlagReadsAsWiFi` (decode
  `{"ssid":"Set","password":"pw"}`), `loadFindsByNameAndKind`.
- [ ] **Step 2: Run** `swift test --scratch-path /tmp/smv1 --filter SharedNetworkStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the store and the Keychain storage (`kSecClassGenericPassword`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, delete then add, as Pocket does).
- [ ] **Step 4: Run** the filter. Expected: PASS, 5 tests.
- [ ] **Step 5: Snapshot and commit** `feat(apple): shared Wi-Fi network store for Multiview`.

### Task 3: iOS locked Shared Wi-Fi page in the wizard

**Files:**
- Modify: `Sources/OpenCineAppKitApple/StationNetworkSetupView.swift` (init ~:64 and body)
- Test: `Tests/OpenCineAppKitAppleTests/` (extend the existing StationNetworkSetup test file if
  there is one, else follow that folder's hosted-view pattern)
- Modify: `docs/appkit/README.md` (wizard section: `lockedNetwork` on both platforms)

**Interfaces:**
- Produces: a new trailing init parameter `lockedNetwork: StationNetwork? = nil` on
  `StationNetworkSetupView`, mirroring Kotlin `StationNetworkSetup(lockedNetwork:)`. When set the
  view shows only the locked page: navigation title "Shared Wi-Fi", a Wi-Fi icon with
  `lockedNetwork.ssid`, the text "Cameras are using this network. Remove them before changing it.",
  and a "Done" confirmation action that calls `close`; no scan starts. Accessibility identifier
  stays `multiview.networkSetup`.

- [ ] **Step 1: Write the failing test** `lockedNetworkShowsTheSharedWiFiPageAndNeverScans`: with
  `lockedNetwork` set and a `scan` closure that records calls, the rendered page has the title,
  SSID and copy above, "Done" calls `close`, and `scan` was never called.
- [ ] **Step 2: Run** the AppKitApple test filter on a private iOS simulator
  (`xcrun simctl create opc-smv1 "iPhone 16 Pro"`, `-derivedDataPath /tmp/smv1-dd`). Expected: FAIL.
- [ ] **Step 3: Implement** the parameter and the page (styling from Pocket's
  `ios/OpenPocketCine/MultiviewNetworkSetup.swift:14-34`).
- [ ] **Step 4: Run** the test. Expected: PASS. Delete the simulator.
- [ ] **Step 5: Commit** `feat(appkit): locked Shared Wi-Fi page on iOS`.

### Task 4: shared `MultiviewStageJournal`

**Files:**
- Create: `Sources/OpenCineAppKit/MultiviewStageJournal.swift`,
  `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewStageJournal.kt`
- Test: `Tests/OpenCineAppKitTests/MultiviewStageJournalTests.swift`,
  `Android/appkit/src/test/kotlin/com/opencapture/opencine/appkit/MultiviewStageJournalTest.kt`
- Modify: `docs/appkit/README.md` (Multiview stage section), Swift and Kotlin API snapshots

**Interfaces:**
- Produces, Swift (Codable, keys as Pocket iOS writes them):
  ```swift
  public enum MultiviewStageJournal {
      public struct Camera: Codable, Equatable, Sendable {
          public var slot: Int; public var id: UUID; public var name: String
          public var modelId: Int?            // integration's model code
          public var identity: [UInt8]?       // integration's identity proof
          public var deviceAddress: String?   // JSON key "bleAddress"; absent in iOS stages
          public var address: String; public var experimental: Bool; public var lutEnabled: Bool
      }
      public struct Stage: Codable, Equatable, Sendable {
          public var version: Int             // 1
          public var ssid: String; public var hotspot: Bool; public var layout: String
          public var focusedIndex: Int; public var cameras: [Camera]
          public var pendingReset: [Camera]?; public var returnedToCameraWiFi: Bool?; public var fill: Bool?
          public func validated(tileCount: Int) -> Stage?
      }
      public static func cleanupTargets(_ pending: [Camera], including cameras: [Camera]) -> [Camera]
  }
  ```
  Kotlin: same names; `Camera.id: String`, `identity: ByteArray?` (hex in JSON),
  `deviceAddress: String?` (key `bleAddress`, written only when non-null), equality by `id` as
  Pocket Android does; plus `fun encode(stage: Stage): String` and `fun decode(raw: String): Stage?`
  (org.json, keys exactly as `PocketCine multiview/MultiviewStores.kt:89-148`).
  `validated(tileCount)` is Pocket's rule (`ios/OpenPocketCine/MultiviewStageStore.swift:36-55`)
  with the app's tile count passed in. Storage stays in the app (load/save closures).

- [ ] **Step 1: Write the failing tests** (same names both sides):
  `aStageSavedByPocketIOSDecodes` and `aStageSavedByPocketAndroidDecodes` (golden JSON strings
  copied from Pocket's current encoders: iOS without `bleAddress`, Android with `bleAddress` and
  hex `identity`; Kotlin runs both, Swift runs the iOS one plus one with `bleAddress`),
  `encodeThenDecodeKeepsEveryField`, `moreCamerasThanTilesIsInvalid`,
  `duplicateSlotsOrIdsAreInvalid`, `emptyNamesAreInvalid`, `focusOutsideTheTilesIsInvalid`,
  `anEmptyNetworkIsValidOnlyForCleanupWithoutCameras`,
  `cleanupTargetsReplaceByIdAndAppendNewCameras`. Port further cases from Pocket's
  `MultiviewStagePersistenceTests` (iOS) and `MultiviewStageStoreTest` (Android) that test the
  value rules rather than storage.
- [ ] **Step 2: Run** `swift test --scratch-path /tmp/smv1 --filter MultiviewStageJournalTests`
  and `cd Android && ./gradlew --project-cache-dir /tmp/smv1-gradle :appkit:testDebugUnitTest --tests '*MultiviewStageJournalTest'`.
  Expected: FAIL.
- [ ] **Step 3: Implement** both twins.
- [ ] **Step 4: Run** both. Expected: PASS on both.
- [ ] **Step 5: Snapshots, README, commit** `feat(appkit): shared Multiview stage journal`.

### Task 5: Pocket iOS adopts (no visible change)

**Files (OpenPocketCine worktree):**
- Delete: `ios/OpenPocketCine/MultiviewWiFiControl.swift` (no callers) and its Xcode project entries
- Modify: `ios/OpenPocketCine/MultiviewTileControl.swift:150-234` (record through `RecordAll`)
- Modify: `ios/OpenPocketCine/MultiviewNetworkStore.swift` (becomes a thin wrapper over
  `SharedNetworkStore(storage: KeychainSharedNetworkStorage(service: "com.opencapture.openpocketcine.multiview-network"))`, or callers use the store directly; delete the file if nothing is left)
- Modify: `ios/OpenPocketCine/MultiviewNetworkSetup.swift` (locked branch becomes
  `StationNetworkSetupView(..., lockedNetwork:)`)
- Modify: `ios/OpenPocketCine/MultiviewStageStore.swift` (types become `MultiviewStageJournal`;
  the Keychain load/save and `MultiviewQualificationPolicy` stay; `load()` returns
  `.validated(tileCount: MultiviewQualificationPolicy.tileCount)`)

**Interfaces:**
- Consumes: Tasks 1 to 4.

- [ ] **Step 1: Run Pocket's Multiview unit tests first** to record the baseline
  (`MultiviewStagePersistenceTests`, `MultiviewStageTests`, `MultiviewControlsTests`,
  `MultiviewEngineTests`) on a private simulator; note any pre-existing failure.
- [ ] **Step 2: Make the changes above.** `record(_:together:)` keeps its signature and its tile
  notes and group note, now from `RecordAll.note`, `RecordAll.summary`, `RecordAll.progress`,
  `RecordAll.changed`; `recordPlan(for:)` uses `RecordAll.plan`; `Self.recordPolicy` callers use
  `RecordAll.policy`.
- [ ] **Step 3: Run** the same unit tests plus `MultiviewUIFlowTests`. Expected: same results as
  the baseline.
- [ ] **Step 4: Commit** `refactor(ios): Multiview record, networks, wizard and saved stage from OpenCine`.

### Task 6: Pocket Android adopts and aligns to iOS

**Files (OpenPocketCine worktree, `Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/multiview/`):**
- Modify: `MultiviewStores.kt:18-164` (types and codec from `MultiviewStageJournal`; prefs
  `openpocketcine.multiview-stage` / `stage` and `MultiviewQualificationPolicy` stay)
- Modify: `MultiviewTileValues.kt:34-68` (tally and format line)
- Modify: `MultiviewScreen.kt:282` (toolbar order)
- Modify: `MultiviewTileControl.kt` only if it duplicates `RecordAll` copy
- Test: `Apps/Android/app/src/test/kotlin/com/opencapture/openpocketcine/multiview/MultiviewTileReadoutsTest.kt`,
  `MultiviewStageStoreTest.kt`
- Modify: Pocket handbook `guides/multiview-prototype.md` "Android differences" if it names any
  of these three differences

**Interfaces:**
- Consumes: Task 4, Kotlin `MultiviewTally.text(recording, seconds, waiting, holding, failed)`.
- Produces, matching iOS exactly:
  - toolbar `listOf(MultiviewTool.LAYOUT, MultiviewTool.CAMERA, MultiviewTool.FIT, MultiviewTool.LUT)`
  - tally `MultiviewTally.text(recording = observation when available else null, seconds =
    recordElapsedSec, waiting = recordingBusy, holding = recovering, failed = failure != null)`:
    "REC 01:05", "STBY", "\u2014" (unavailable), "WAIT", "HOLD", "CHECK" (no "REC m:ss", "REC \u2014" or "REC ?")
  - format line `"$resolution $rate · $color"` (for example "4K 25p · D-Log M")

- [ ] **Step 1: Update the tests first:** in `MultiviewTileReadoutsTest` assert the six tally
  strings above and the format "4K 25p · D-Log M"; add `toolbarMatchesIOSOrder` where the tools
  list is built (extract it to a small `internal val multiviewTools` if needed to test it).
- [ ] **Step 2: Run** `cd Apps/Android && ./gradlew --project-cache-dir /tmp/smv1-pocket :app:testDebugUnitTest --tests '*multiview*'`. Expected: FAIL on the changed strings.
- [ ] **Step 3: Make the changes above.**
- [ ] **Step 4: Run** the same command, then `:app:lintDebug`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(android): Multiview tally, format and toolbar as on iOS, saved stage from OpenCine`.

### Task 7: verify the slice

- [ ] **Step 1: OpenCine** checks from `AGENTS.md` that this plan touches: Swift build and test
  (`--scratch-path /tmp/smv1`, strict concurrency), `xcodebuild` MonitorUI and OpenCineApple for
  the iOS simulator, `cd Android && ./gradlew --project-cache-dir /tmp/smv1-gradle :multicam:test :appkit:testDebugUnitTest :appkit:lintDebug`,
  `python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check`. Expected:
  pass except the known space-in-path `RelayImportRules` failure.
- [ ] **Step 2: Pocket** iOS build-for-testing and the Multiview unit and UI tests on a private
  simulator; Android unit tests and lint. Expected: pass.
- [ ] **Step 3: Report** per AGENTS.md (OpenCine, Pocket, why InstaCine and ZCine are
  unaffected: they use none of the moved types yet). No push, PR or pin move.
