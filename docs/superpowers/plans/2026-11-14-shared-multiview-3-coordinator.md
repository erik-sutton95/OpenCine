# Shared Multiview Plan 3: the Multiview coordinator in AppKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift Pocket's Multiview session into OpenCine as `MultiviewCoordinator` (Swift
`OpenCineAppKit`, Kotlin `:appkit`, same names and behavior), driving cameras only through the
Core seams (`MultiviewCameraPolicy`, `StationCommissioner`, `StationHostPath`,
`MultiviewMemberLink`, and a new `NearbyCameraScanner`) plus a small app host (`MultiviewHost`).
Pocket's `MultiviewSession` on both platforms becomes a thin adapter. Pocket iOS shows no
operator-visible change; Pocket Android moves to the iOS behavior.

**Architecture:** The coordinator owns every rule that is not a camera protocol: lifecycle,
network choice, Bluetooth discovery demand and a Bluetooth queue, add, the LAN discovery loop,
identity and duplicate refusal, the record plan and per-member notes, the recovery budget, the
45 s path loss, Live View and editor ordering, close and cleanup, background and foreground,
Reconnect and Remove, the status copy and the journal. Each member is a `MultiviewMember` (its
state, observable) paired with the integration's or app's `MultiviewMemberLink` (its camera
protocol). What only the app has (Live View borrow, the settings editor, the record confirmation
preference, background time, whether a picture is mounted, logging) reaches it through the
`MultiviewHost` protocol, whose requirements all have defaults so Plan 4 can grow it into the
screen host without breaking an adopter. Seams an integration implements stay in Core (an
integration may not import AppKit).

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing, Observation), Kotlin 2.4 (JVM 17, explicit API,
coroutines, Compose runtime state in `:appkit`), XCTest and kotlin.test in Pocket.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` ("Lifted from Pocket",
"Seams", order of work steps 2 and 4, "Verification", "Settled calls", "Owner answers"); series:
`docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md` ("Carried from Plan 1" and
"Carried from Plan 2", Plan 3 items); Pocket handbook `guides/multiview-prototype.md`.

## Global Constraints

- OpenCine `AGENTS.md`: twins with the same type and test names; no manufacturer or app name in
  Core, AppKit or Multicam; no em dash character (Kotlin strings use `\u2014`); Conventional
  Commits, no co-author trailers, explicit `git add`; behavior tests at contract boundaries on
  manual clocks (Swift `ManualHostClock`, Kotlin `runTest` virtual time), no sleeps.
- Boundaries unchanged: AppKit imports Core, Media, Multicam, UI values, never an integration or
  `OpenCineApple`; integrations implement Core seams only.
- Pocket iOS: no operator-visible change. Pocket Android: changes only toward iOS (tile status and
  actions, discovery demand, recovery, journal content); keep what the handbook names on purpose
  (24 parallel probes, the early identity read with one Wi-Fi wake, rebuilding every tile's
  decoder after Live View, the phone hotspot and Local Wi-Fi wording, Keystore storage).
- Stored data keeps loading: Keychain `com.opencapture.openpocketcine.multiview-stage` /
  `stage`, Android prefs `openpocketcine.multiview-stage` / `stage`, JSON keys of
  `MultiviewStageJournal` unchanged; network stores unchanged.
- Public API changes update snapshots in the same branch (`atlas api --write --build`,
  `./gradlew updateKotlinAbi updateAndroidApi`).
- Scratch only under `/Volumes/OCScratch/smv3/`; iOS tests on the private simulator `opc-smv3`.

## Review Focus

- Pocket iOS parity of the lifted flows, line by line against `MultiviewSession.swift` on
  `feat/shared-multiview-2`: add order and copy, discovery (cached address, two passes with 3 s
  between, other members excluded, address reserved, 64 probes per batch, at most 8 candidates,
  0.8 s probe), `openPreview` guards, Reconnect then re-add, Remove, close and cleanup, the 1 s
  monitor (keepalive, 3 s record freshness, repair guards with the 3 s foreground grace).
- Recovery: the coordinator's `RecoveryBudget` (2 rejoins, reset after 30 s of a healthy transport
  as the link reports it through `observeHealth`) replaces the rejoin counter inside DJI's
  `MultiviewRecovery`; the DJI watchdog ladder stays in Pocket's link and is reset on every open.
- The duplicate refusal is final (N2) on both platforms, in add and in Reconnect.
- The Bluetooth queue: a repair's `bluetoothTurn` waits for adds in their commission, a network
  scan and an earlier turn, in order; `stop()` answers every waiter with nil.
- Pocket Android differences that remain, each with its reason (the report lists them).

## Rulings taken while planning (recorded again in the report)

1. Member state lives in `MultiviewMember` (coordinator-owned, observable). An app whose link
   objects present that state (Pocket's `Tile`) creates the members and passes them in; the
   coordinator otherwise creates them. Pocket's `Tile` forwards its old properties to its member,
   so its views and tests keep their shape.
2. `isPublishing` leaves `MultiviewMemberLink`: the coordinator owns `publishing` (true from a
   started preview until the next open, a failed Reconnect or Remove). `close()` therefore needs
   no publishing rule, and its doc says only that it never sends a record or access-point command
   and may finish asynchronously (N3a).
3. Record availability: the link reports the camera's last take report (`recordReport`, with its
   arrival time); the coordinator owns the 3 s freshness. Swift links also expose `snapshot`
   (Swift `CameraSession` has no synchronous current snapshot; Kotlin reads
   `session.snapshots.value`).
4. The 8 s confirmation window becomes a shared AppKit helper (`MultiviewRecordConfirmation`)
   that a link's record path runs; the record wire (DJI's reply frame) stays in the link.
5. `restoreAccessPoint` returns `StationRestoreResult` (`restored`, `deferred(message)`,
   `failed`) so Plan 5 can show Luna's "approve on the camera" copy; DJI maps its Bool.
6. Discovery: with `discoversByProbe` the coordinator enumerates the subnet (`StationSubnet`,
   moved from DJI's `MulticamDiscovery`) and probes through the link, `probeWidth` per batch
   (Swift and Kotlin default 64, Pocket Android passes 24 as its handbook names). Without it the
   coordinator opens only the member's known address (N3b): its last address or the address the
   integration's sighting carries (`sightingAddress`).
7. Hosts compare by `MultiviewCameraPolicy.hostKey` (identity by default) (N3c).
8. The network credential check is the iOS rule (name 1 to 32 bytes, password at most 63 bytes)
   with the copy "Check the network name and password." on both platforms.
9. `DjiAppleSharedWiFiPath` fold: Multiview stops using it (the coordinator's discovery and the
   DJI probe use the host path, `DjiAppleDatalink` takes the local address from the caller); the
   single-camera transport keeps it until its own move.
10. Pocket test `testLeavingBorrowedLiveViewCancelsProgrammedMove`: the 0.3 s pose freshness is
    read from the motion engine's wall clock deep in `CameraSession`, not a small injection, so it
    is quarantined with an issue (Pocket `docs/ci.md`).

---

### Task 1: Core seam changes (Swift and Kotlin)

**Files:**
- Modify: `Sources/OpenCineCore/MultiviewMemberLink.swift`, `MultiviewCameraPolicy.swift`,
  `StationCommissioner.swift`; Kotlin twins in `Android/core/src/main/kotlin/com/opencapture/opencine/core/`
- Create: `Sources/OpenCineCore/NearbyCameraScanner.swift`, `StationSubnet.swift`; Kotlin twins
- Modify: `Sources/OpenCineDJI/MulticamDiscovery.swift` (delegates to `StationSubnet`),
  `Sources/OpenCineDJIApple/DJIStationCommissioner.swift`, `DjiAppleDatalink.swift` (local
  address from the caller), `Android/dji/.../DjiStationCommissioner.kt`
- Tests: `Tests/OpenCineCoreTests/StationSubnetTests.swift`, `Android/core/src/test/.../StationSubnetTest.kt`;
  update `MultiviewSeamTests` / `MultiviewSeamTest`

**Interfaces:**
```swift
public struct MultiviewRecordReport: Equatable, Sendable { public var recording: Bool; public var receivedAt: Date }
// MultiviewMemberLink: + var recordReport: MultiviewRecordReport? { get }; + var snapshot: CameraSnapshot { get } (Swift only); - isPublishing
// MultiviewRepairContext: + observeHealth: @MainActor (Bool) -> Void
public enum StationRestoreResult: Equatable, Sendable { case restored, deferred(String), failed }
// StationCommissioner.restoreAccessPoint(_:) async -> StationRestoreResult
// MultiviewCameraPolicy: + hostKey(_ address: String) -> String (init parameter, identity by default)
@MainActor public protocol NearbyCameraScanner<Camera>: AnyObject {
    associatedtype Camera
    func waitUntilReady() async -> Bool
    func scan(_ found: @escaping @MainActor (Camera) -> Void) async
    func stop()
}
public enum StationSubnet { static func hosts(address:mask:excluding:) -> [String]?; static func validAddress(_:) -> Bool }
```
Kotlin: `MultiviewRecordReport(recording, receivedAtMillis)`, `StationRestoreResult` sealed,
`NearbyCameraScanner` interface (`suspend fun waitUntilReady()`, `suspend fun scan(found)`,
`fun stop()`), `object StationSubnet`.

- [ ] Write `StationSubnet` tests on both platforms (a /24 lists 253 hosts without self and the
      excluded ones; /22 is the largest; /31, /32, malformed and non-contiguous masks are nil;
      `validAddress` accepts unicast and refuses 0.x, 127.x, multicast and malformed). Run: fail.
- [ ] Add the seam changes and `StationSubnet`; `MulticamDiscovery.hosts` forwards to it.
- [ ] Update the DJI commissioners (`restoreAccessPoint` maps true to `.restored`, false to
      `.failed`) and the seam tests. Build Core, DJI and their tests on both platforms; run the
      subnet and seam tests: pass.
- [ ] Commit `feat(core): Multiview seams carry record reports, health and restore results`.

### Task 2: `RecoveryBudget.exhaust()` and the seam fakes

**Files:**
- Modify: `Sources/OpenCineMulticam/Recovery.swift`, `Android/multicam/.../Recovery.kt`; tests in
  `Tests/OpenCineMulticamTests/EngineTests.swift`, `Android/multicam/src/test/.../EngineTests.kt`
- Create: `Sources/OpenCineCoreTestSupport/FakeMultiview.swift`,
  `Android/core/src/testFixtures/kotlin/com/opencapture/opencine/core/testing/FakeMultiview.kt`

**Interfaces:** `RecoveryBudget.exhaust()` (the operator must act; `reset()` restores).
Fakes (twins): `FakeStationCamera` (id, name, modelId), `FakeStationHostPath` (address and
netmask per kind, scripted join), `FakeStationCommissioner` (scripted identity, join outcome or
error, progress lines, restore results per camera, network scan, call log),
`FakeStationCommission`, `FakeMemberLink` (probe answers and identities per address, opens and
closes counted, status reports, scripted repair step, record report, snapshot), `FakeNearbyScanner`.

- [ ] Test: an exhausted budget refuses `beginAttempt` until `reset` (both platforms). Fail, add
      `exhaust()`, pass.
- [ ] Write the fakes. Commit `feat(multicam): a recovery budget the coordinator can exhaust`
      and `test(core): Multiview seam fakes for coordinator tests`.

### Task 3: Swift `MultiviewCoordinator` (tests first)

**Files:**
- Create: `Sources/OpenCineAppKit/MultiviewCoordinator.swift` (coordinator, member, host,
  Bluetooth queue, copy), `Sources/OpenCineAppKit/MultiviewCoordinator+Record.swift` (record plan,
  confirmation window helper, tile values)
- Create: `Tests/OpenCineAppKitTests/MultiviewCoordinatorTests.swift`

**Interfaces:**
```swift
public enum MultiviewMemberChange: Sendable { case camera, control, removed }
@MainActor public protocol MultiviewHost: AnyObject {   // every requirement has a default
    var confirmsRecord: Bool { get }
    func openLiveView(slot: Int) -> Bool
    func closeLiveView()
    func closeEditors()
    func memberChanged(slot: Int, _ change: MultiviewMemberChange)
    func applicationActivityChanged(_ active: Bool)
    func stageStopped()
    func showsPicture(slot: Int) -> Bool
    func log(_ line: String)
}
@MainActor @Observable public final class MultiviewMember<Camera> { id, stream, entryID, camera,
    identity, address, status, failureMessage, connecting, recovering, networkVerified,
    experimental, publishing, controlHost, recordingBusy, recordingAvailable, recordingNote,
    lutEnabled, pathLostAt, budget }
@MainActor @Observable public final class MultiviewCoordinator<Link: MultiviewMemberLink>
    where Link.Camera: Sendable {
    init(links:members:policy:commissioner:scanner:hostPath:describe:journal:networks:budget:
         sightingAddress:failureMessage:probeWidth:clock:)
    // state: members, links, presentation, found, busy, ready, ssid, usePhoneHotspot, password,
    // hostAddress, networkConfigured, configuringNetwork, networkSetupError, error, closing,
    // groupRecordingBusy, groupRecordingNote, applicationActive, editorLeases
    // actions: start, stop, scanNetworks, recordStationChange, selectNetworkSource,
    // selectNetwork, configureNetwork, joinSharedNetwork, setApplicationActive, enqueueAdd, add,
    // reconnect, tryExperimentalNetwork, connectPreview, remove, persistStage, restoreStage,
    // closeStage, resetStationOnce, show, openLiveView, closeLiveView, controlsAvailable,
    // openEditorLease, closeEditors, multicamGroup, multicamSnapshot, recordPlan, record,
    // recordContext, tile(_:_:)
}
public struct MultiviewJournalStorage { load, save }; public struct MultiviewNetworkStorage { password, save }
public enum MultiviewRecordConfirmation { static func wait(...) async -> Outcome }
public struct MultiviewTileReadings { name, model, format, storage, timecode, readouts,
    recordingSeconds, power, hasPicture, accessibilityValue }
```

Tests (Swift Testing, `ManualHostClock`, fakes), each a behavior Pocket's session pins today:
- `restoredStagesKeepPresentationButNeverNetworkOrCameras`
- `credentialsLoadOnlyAfterAnExplicitNetworkChoice`
- `anAssignedCameraLocksTheNetworkUntilRemoved`
- `legacyAssignedCamerasBecomeCleanupOnly`
- `cancellingSetupKeepsPresentationPreferences`
- `cleanupOnlyRestoreDefersRadioWorkUntilClose`
- `closeRetriesUnfinishedCleanupOnTheNextClose` (failed, then restored; journal kept then deleted)
- `aDeferredReturnShowsTheIntegrationsCopy`
- `closeReusesAnUncancelledScanCleanup`
- `discoveryFollowsAddAndConnectDemand` (static rule, and the scanner starts and stops)
- `linkStatusShowsTheTileCopyAndTheCoordinatorOwnsTheControlHost`
- `addCommissionsJoinsAndFindsTheCameraByProbe` (status lines, identity, saved network and
  journal, control host, publishing)
- `discoveryTriesTheKnownAddressFirstThenTwoPassesWithoutOtherMembers`
- `anUnsupportedSubnetFailsTheAddWithItsCopy`
- `theDuplicateRefusalIsFinal` (add and Reconnect)
- `aCameraWithoutPreviewStopsAtTheVerifiedJoin`
- `reconnectTriesTheKnownCameraThenSetsItUpAgain`
- `repairsRejoinWithinTheBudgetThenWaitForTheOperator`
- `aHealthyTransportRestoresTheBudget`
- `sharedNetworkLossFailsTheMemberAfter45Seconds`
- `repairsWaitForTheForegroundGrace`
- `bluetoothTurnsWaitForAddsAndScansAndGoInOrder`
- `recordAvailabilityFollowsThreeSecondFreshness` (strict plan refused with a stale member)
- `recordWritesEachOutcomeOnItsMemberAndTheGroupSummary`
- `theConfirmationWindowConfirmsRefusesOrTimesOut`
- `liveViewNeedsAControlledMemberAndClosesTheEditorFirst`
- `removeClearsTheMemberWithoutACameraCommand`
- `tileValuesFollowPocketIOS` (status text, detail, spinner, actions, tile note keyed off RecordAll)
- `withoutACommissionerTheCameraOpensAtItsSightingAndKeepsItsProvenIdentity`
- `withoutProbeDiscoveryARejoinReopensTheKnownAddressOnly`
- `hostsCompareByTheirKey`

- [ ] Write the tests and the public shapes as stubs; build: the tests fail.
- [ ] Implement the coordinator from Pocket iOS `MultiviewSession` (feat/shared-multiview-2),
      replacing DJI calls with the seams, `Task.sleep` with `clock.sleep`, polling for Bluetooth
      with the queue. Run the suite: pass. Strict concurrency build: no new warnings.
- [ ] Commit `feat(appkit): Multiview coordinator lifted from Pocket` (tests and code).

### Task 4: Kotlin `MultiviewCoordinator` (twin)

**Files:**
- Create: `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewCoordinator.kt`,
  `MultiviewCoordinatorRecord.kt`; `Android/appkit/src/test/.../MultiviewCoordinatorTest.kt`

Same names, same tests (kotlin.test names identical to the Swift ones), `runTest` with the
coordinator on the test scheduler and `clock = { testScheduler.currentTime }`.

- [ ] Port the tests; run `:appkit:testDebugUnitTest --tests '*MultiviewCoordinatorTest'`: fail.
- [ ] Implement the twin. Pass. `:appkit:lintDebug`. Commit
      `feat(appkit): Kotlin Multiview coordinator, twin of the Swift one`.

### Task 5: DJI pieces that follow the lift

**Files:**
- Move `testRecoveryDoesNotResetHealthyVideoForStalePresentation`,
  `testFirstPictureFailureEscalatesBeyondBaseCooldown` (they test `MultiviewRecovery`, a DJI type)
  to `Tests/OpenCineDJITests/MultiviewRecoveryTests.swift` as Swift Testing.
- `DjiAppleDatalink` gains a `localAddress` provider (defaults to today's path) so Multiview's
  links take it from the host path.

- [ ] Port the two tests; run: pass (behavior unchanged). Commit `test(dji): Multiview recovery
      ladder tests live with the ladder`.
- [ ] Add the provider; build `OpenCineDJIApple` for the iOS Simulator. Commit
      `refactor(dji): station datalink takes its local address from the caller`.

### Task 6: OpenCine docs, roadmap and API snapshots

- Area guides (`docs/appkit/README.md`, `docs/core/README.md`): the coordinator, the member, the
  host, the scanner seam, the restore result, the deliberate twin differences.
- Roadmap: "Carried from Plan 3" (what Plan 4 grows into `MultiviewHost`; Plan 5 restore copy;
  N1: OpenInstaCine `AddSetupView.swift:46-56` must pass `complete: { done(nil) }` at its next pin
  move; what stays on `DjiAppleSharedWiFiPath`).
- [ ] `atlas api --write --build`, `./gradlew updateKotlinAbi updateAndroidApi`,
      `atlas check`. Commit `docs: Multiview coordinator in the area guides and roadmap` and
      `chore: API snapshots for the Multiview coordinator`.

### Task 7: Pocket iOS adapter

**Files:** `ios/OpenPocketCine/MultiviewSession.swift` (thin adapter: builds the coordinator with
the DJI seams, is its `MultiviewHost`, keeps Live View borrow, the editor model, the backdrop
renderer and the background task), `MultiviewTileLink.swift` (record report, snapshot, health,
watchdog reset on open, host-path probe), `MultiviewTileControl.swift` (shared confirmation
window), `MultiviewTileValues.swift` (readings into `coordinator.tile`), `MultiviewStageStore.swift`
(drop the typealiases and the `validated` overload), `MultiviewNetworkStore.swift`, tests.

- [ ] Tests that now live in OpenCine are deleted from Pocket in the same commit (listed in the
      report with their new names); Pocket keeps the tests of its own DJI link, editor, Live View
      and record port.
- [ ] Build for testing on `opc-smv3`; run the Multiview unit selection and `MultiviewUIFlowTests`.
- [ ] Commit `refactor(ios): Multiview session is an adapter over the shared coordinator`.

### Task 8: Pocket Android adapter, toward iOS

**Files:** `multiview/MultiviewSession.kt`, `MultiviewTileControl.kt`, `MultiviewTileValues.kt`
(drop the unused `recordingAvailable` parameter; tile status and actions from the coordinator),
`MultiviewStores.kt`, tests.

- [ ] Same adapter shape; discovery demand, recovery budget, journal content and tile values from
      the coordinator; the record port reports availability as iOS does. Keep and record: 24
      probes, early identity read, decoder rebuild after Live View, repair only while a surface is
      mounted.
- [ ] `:app:testDebugUnitTest --tests '*multiview*'`, `:app:lintDebug -x stageSwiftCore`.
- [ ] Commit `refactor(android): Multiview session is an adapter over the shared coordinator`.

### Task 9: Pocket flaky test, docs

- [ ] Quarantine `testLeavingBorrowedLiveViewCancelsProgrammedMove` with a `ci-quarantine` issue
      (row in `docs/ci.md`, skipped in the PR tier). Commit `test(ios): quarantine the borrowed
      Live View move test`.
- [ ] Pocket `docs/PARITY.md` and the handbook page where Android changed. Commit `docs: ...`.

### Task 10: Verification, PRs, report

- [ ] OpenCine gates (brief), Pocket iOS per-test comparison with the base branches, Pocket
      Android gates. Push both branches, open the two draft PRs, write the report.
