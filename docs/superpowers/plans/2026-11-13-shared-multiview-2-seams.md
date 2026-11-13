# Shared Multiview Plan 2: integration seams and the DJI implementations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the three seams the shared Multiview coordinator (Plan 3) will drive
(`StationCommissioner`, `StationHostPath`, `MultiviewMemberLink`) as Swift and Kotlin twins,
implement them for DJI by wrapping Pocket's existing code, and have Pocket's `MultiviewSession`
call through them on both platforms with no operator-visible change.

**Architecture:** The seams are Core contracts (`OpenCineCore` / `:core`): the coordinator will
live in AppKit, which may not import an integration or `OpenCineApple`, and the DJI implementations
live in integrations, which may import only Core and the neutral modules. So the seams, and the
`StationNetwork` value they carry, sit in Core. The phone side of the network is a platform
adapter (`OpenCineApple.SharedWiFiPath` on iOS, `:platform` `SharedWiFiPath` on Android). The DJI
commissioner wraps the moved provisioner in `OpenCineDJIApple` / `:dji`. The DJI member link is
supplied by Pocket (its `Tile`), per the spec's settled call.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), SwiftUI, Kotlin 2.4 (JVM 17, explicit API in
`:core` and `:appkit`), Compose, org.json.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md`; series:
`docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md` (Plan 2 and the Plan 1
carry-overs).

## Global Constraints

- OpenCine `AGENTS.md`: Swift and Kotlin twins with the same type and test names; no manufacturer
  or app name in Core, AppKit or `OpenCineApple`/`:platform`; no em dash character; Conventional
  Commits, no co-author trailers, explicit `git add`; behavior tests at contract boundaries, no
  sleeps.
- Boundaries: Core imports Foundation only; integrations add nothing above Core, Media, Motion,
  the vocabulary; `OpenCineDJIApple` never imports `OpenCineApple`; AppKit never imports an
  integration or `OpenCineApple`. One new edge: Android `:platform` -> `:core` (same atlas layer,
  mirrors Swift `OpenCineApple` -> `OpenCineCore`).
- Pocket iOS: no operator-visible change. Pocket Android: no change in this plan (it may only
  move toward iOS, and nothing here needs it to).
- Stored data keeps loading: Keychain service `com.opencapture.openpocketcine.multiview-network`
  (accounts `last-network`, `saved-networks`, JSON keys `ssid`, `password`, `hotspot` with a
  missing `hotspot` reading as Wi-Fi); Android prefs and Keystore alias
  `openpocketcine.multiview-network`.
- Public API changes update snapshots in the same branch: `python3 atlas/tools/atlas.py api --write --build`
  and `cd Android && ./gradlew updateKotlinAbi updateAndroidApi`.
- Worktrees: `OpenCine-tasks/shared-multiview-2/OpenCine` and `.../OpenPocketCine`, both on
  `feat/shared-multiview-2` stacked on `feat/shared-multiview-1`. Build scratch under
  `/Volumes/OCScratch/smv2/` (Swift `--scratch-path`, xcodebuild `-derivedDataPath`, Gradle
  `--project-cache-dir`); iOS tests on the private simulator `opc-smv2`.

## Review Focus

- The provisioner moved byte for byte: pairing, the `00 06` deferral, the scan's AP return in its
  own task, close-and-wait before the next connect (Task 4 diff against Pocket's file).
- Close still retries a deferred pairing at most three times, with the wait injected by the app,
  and a cancelled restore never reports success (Task 3 tests, Pocket's persistence tests).
- Pocket's add flow keeps its order and copy: host join, Bluetooth pairing, Nano wake, identity,
  station join with `verifyOnNetwork`, LAN discovery; the same tile status strings (Task 9, 10).
- The member link split: what the coordinator keeps (guards, address reservation, other tiles
  excluded, `running`, the 45 s path loss, the rejoin budget) and what the link does (datalink
  open, identity check, live view start, watchdog actions). The repair step must not run a
  rejoin itself; it hands the coordinator a closure whose `true` means "rejoin".
- `StationNetwork` moved to Core: Pocket's three users compile; no app other than Pocket uses it
  (`atlas consumers StationNetwork`).
- `SharedNetworkStore.Network.hotspot` is no longer optional; a stored entry without `hotspot`
  still decodes as Wi-Fi (golden JSON in the test).

---

### Task 1: `StationNetwork` in Core

**Files:**
- Create: `Sources/OpenCineCore/StationNetwork.swift`, `Android/core/src/main/kotlin/com/opencapture/opencine/core/StationNetwork.kt`
- Modify: `Sources/OpenCineAppKit/StationNetworkSetup.swift` (remove the struct),
  `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/StationNetworkSetup.kt` (remove
  the class, import it from core)

**Interfaces:**
```swift
public struct StationNetwork: Equatable, Sendable { public var ssid, password: String; public var hotspot: Bool }
```
```kotlin
public data class StationNetwork(public val ssid: String, public val password: String, public val hotspot: Boolean)
```
Kotlin keeps the `toString` redaction if the appkit class had one.

- [ ] **Step 1:** Move both; `swift build` and `:appkit:compileDebugKotlin` pass (pure move, the
  existing wizard tests cover it).
- [ ] **Step 2:** Commit `refactor(core): StationNetwork moves to Core for the Multiview seams`.

### Task 2: the seams in Core

**Files:**
- Create: `Sources/OpenCineCore/StationHostPath.swift`, `Sources/OpenCineCore/StationCommissioner.swift`,
  `Sources/OpenCineCore/MultiviewMemberLink.swift` and the Kotlin twins in
  `Android/core/src/main/kotlin/com/opencapture/opencine/core/`
- Test: `Tests/OpenCineCoreTests/MultiviewAutoLUTTests.swift`,
  `Android/core/src/test/kotlin/com/opencapture/opencine/core/MultiviewAutoLUTTest.kt`
- Modify: `docs/core/README.md` (a "Multiview seams" section)

**Interfaces (Swift; Kotlin twins have the same names, `suspend` where Swift is `async`, `String`
camera ids, `ByteArray` identity):**
```swift
@MainActor public protocol StationHostPath: AnyObject {
    func address(hotspot: Bool) -> String?
    func netmask(hotspot: Bool) -> String?
    /// Router Wi-Fi: joins and returns this phone's address there, nil when it did not join.
    /// Hotspot: nothing to join, returns the hotspot address (nil until a client associates).
    func join(_ network: StationNetwork) async throws -> String?
}

public struct StationCameraRecord: Hashable, Sendable { id: UUID; name: String; modelId: Int?; deviceAddress: String? }
public enum StationCommissionOutcome: Equatable, Sendable { case joined, verified }

@MainActor public protocol StationCommission: AnyObject {      // one nearby camera's setup link
    func identity() async throws -> [UInt8]
    func join(_ network: StationNetwork, identity: [UInt8], experimental: Bool,
        progress: @escaping @MainActor (String) -> Void,
        verifyOnNetwork: @escaping @MainActor () async throws -> Bool) async throws -> StationCommissionOutcome
    func close()
}

@MainActor public protocol StationCommissioner<Camera>: AnyObject {
    associatedtype Camera: Sendable
    func qualification(_ camera: Camera, experimental: Bool) -> MulticamQualification
    func hasPreview(_ camera: Camera) -> Bool
    func record(_ camera: Camera) -> StationCameraRecord
    func connect(_ camera: Camera, progress: @escaping @MainActor (String) -> Void) async throws -> any StationCommission
    /// Includes the integration's own bounded retry; false when the camera did not confirm.
    func restoreAccessPoint(_ record: StationCameraRecord) async -> Bool
    var scansNetworks: Bool { get }                                   // default false
    func scanNetworks(through camera: Camera,
        beforeStationChange: @escaping @MainActor () throws -> Void,
        onRestored: @escaping @MainActor (Bool) -> Void,
        onFound: @escaping @MainActor (String) -> Void) async throws  // default throws CancellationError
}

public struct MultiviewAutoLUT: Equatable, Sendable {
    public var colorMode: String?     // the reported color mode's name; nil until reported
    public var conversion: String?    // the look profile's conversion for it; nil: none needed
    public func caption(enabled: Bool, conversionLoaded: Bool) -> String
}

public enum MultiviewRepairStep {
    case healthy                                   // nothing to repair: the coordinator checks path loss
    case handled                                   // repaired in place, or declined this tick
    case repair(@MainActor () async -> Bool)       // run as the member's recovery; true: rejoin
}

public struct MultiviewRepairContext {             // what the repair may read of the coordinator
    public var pathReady: Bool
    public var running: @MainActor () -> Bool
    public var applicationActive: @MainActor () -> Bool
    public var foregroundUnchanged: @MainActor () -> Bool
    public var pathAvailable: @MainActor () -> Bool
}

@MainActor public protocol MultiviewMemberLink<Camera>: AnyObject {
    associatedtype Camera
    var session: any CameraSession { get }
    var pictureHealth: PictureHealth { get }
    func probe(_ address: String, hotspot: Bool) async -> Bool
    /// Opens `camera` at `address` and checks `identity`; throws when another camera or none answers.
    func open(_ camera: Camera, at address: String, identity: [UInt8], hotspot: Bool) async throws
    func startPreview(_ camera: Camera) async throws
    func keepalive()
    func close()
    func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep
    var autoLUT: MultiviewAutoLUT { get }
}
```
`caption` is Pocket's rule, identical on both platforms today: no color mode: "Waiting for camera
color"; no conversion: "Auto · no conversion needed"; enabled and the conversion did not load:
"LUT unavailable"; else "Auto · <conversion>".

- [ ] **Step 1: Failing test** `captionFollowsTheReportedColorAndTheLookProfile` (both platforms):
  every branch above, including "disabled still names the conversion".
- [ ] **Step 2: Run** `swift test --scratch-path /Volumes/OCScratch/smv2/swift --filter MultiviewAutoLUTTests`
  and `:core:test --tests '*MultiviewAutoLUTTest'`. Expected: FAIL (type missing).
- [ ] **Step 3: Implement** the files above. Protocol defaults: `scansNetworks` false,
  `scanNetworks` throws `CancellationError` (Kotlin: `CancellationException`).
- [ ] **Step 4: Run** both. Expected: PASS.
- [ ] **Step 5:** README section; commit `feat(core): Multiview seams for commissioning, the host path and member links`.

### Task 3: DJI Multiview failure, pairing reply and Wi-Fi return retry (Swift twin)

**Files:**
- Create: `Sources/OpenCineDJI/MultiviewExit.swift`
- Test: `Tests/OpenCineDJITests/MultiviewExitTests.swift` (names of Kotlin `MultiviewExitTest`)

**Interfaces:**
```swift
public enum MultiviewFailure: LocalizedError, Equatable { case timeout, unavailable, rejected, network, pairingDeferred; case message(String) }
public enum MultiviewPairing { public static func acceptsReply(_ response: Duml.Frame, sequence: UInt16) throws -> Bool }
public func restoreCameraWiFiWithRetry(waitBetween: () async -> Void, attempt: () async throws -> Bool) async -> Bool
```
Copy is Pocket's `MultiviewSession.Failure` (same as Kotlin `MultiviewFailure`). Retry: three
attempts; only `pairingDeferred` waits and retries; any other error, cancellation included,
returns false (Pocket iOS behavior).

- [ ] **Step 1: Failing tests** `firstExitRetriesCapturedReplyAfterClosingTheAttempt`,
  `repeatedDeferralStopsAtThreeAttempts`, `otherRejectionsAndFailedAPCommandsDoNotRetry`,
  `approvalRequiresMatchingOpcodeSequenceAndExactReply`, `cancellationDoesNotBecomeAReportedSuccess`.
- [ ] **Step 2: Run** `--filter MultiviewExitTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS, 5 tests.
- [ ] **Step 5: Commit** `feat(dji): Swift Multiview exit retry, the twin of Kotlin's`.

### Task 4: provisioner and `DJIStationCommissioner` in `OpenCineDJIApple`

**Files:**
- Create: `Sources/OpenCineDJIApple/DjiAppleMultiviewProvisioner.swift` (moved from Pocket
  `ios/OpenPocketCine/MultiviewProvisioner.swift`), `Sources/OpenCineDJIApple/DJIStationCommissioner.swift`
- Modify: `Sources/OpenCineDJIApple/DjiAppleNetworkDiscovery.swift` (public `probe(_:hotspot:)`
  over the existing private probe), `docs/dji/README.md`

**Interfaces:**
- `DjiAppleMultiviewProvisioner(host: DjiAppleTransportHost)`: Pocket's class unchanged apart from
  its logger (`host.journal` in place of `ControlLiveLog`), `MultiviewFailure` in place of
  `MultiviewSession.Failure`, and `MultiviewPairing.acceptsReply`.
- `DJIStationCommissioner: StationCommissioner` with `Camera == DjiAppleSighting`,
  `init(host:retryDelay:)`; `connect` = Pocket's Bluetooth pairing plus the Nano Wi-Fi wake;
  `StationCommission.identity()` = `07/07`; `join` = `StationJoin.run` with Pocket's arguments;
  `restoreAccessPoint` = Pocket's `resetStation` under `restoreCameraWiFiWithRetry`;
  `scanNetworks` = the provisioner's scan. `cancelCommissions()` closes every open commission
  link (Pocket's `stop()`), never a scan's link.

- [ ] **Step 1:** Move the file and build: `swift build` (macOS) and
  `xcodebuild -scheme OpenCineDJIApple -destination 'generic/platform=iOS Simulator' build`
  (CoreBluetooth parts are iOS only). The behavior tests are Pocket's persistence and UI suites
  (Task 9) and Task 3; Bluetooth is hardware.
- [ ] **Step 2:** Commit `feat(dji): Multiview provisioner and station commissioner in OpenCineDJIApple`.

### Task 5: `StationHostPath` on both platforms

**Files:**
- Create: `Sources/OpenCineApple/SharedWiFiPath.swift` (iOS; `DjiAppleSharedWiFiPath`'s reader
  and join, generalised, conforming to `StationHostPath`)
- Modify: `Android/platform/src/main/kotlin/com/opencapture/opencine/platform/SharedWiFiPath.kt`
  (implements `StationHostPath`; `address()`/`netmask()` keep their no-argument forms),
  `Android/platform/build.gradle.kts` (`api(project(":core"))`),
  `Android/platform/src/test/.../PlatformImportRuleTest.kt` (allows Core values), `docs/platform/README.md`

- [ ] **Step 1:** Build both (`swift build`, `xcodebuild -scheme OpenCineApple ... build`,
  `:platform:testDebugUnitTest`). No behavior test: interface addresses and joins are OS I/O; the
  import rule test guards the new edge.
- [ ] **Step 2:** Commit `feat(platform): shared Wi-Fi path is the station host path on both platforms`.

### Task 6: Kotlin `DjiStationCommissioner`

**Files:**
- Create: `Android/dji/src/main/kotlin/com/opencapture/opencine/dji/DjiStationCommissioner.kt`

**Interfaces:** `class DjiStationCommissioner(context: Context, log: (String) -> Unit) :
StationCommissioner<FoundCamera>`; `connect` = Pocket Android's pairing plus Nano wake;
`identity()` = Pocket Android's `readIdentity` (one Wi-Fi wake and retry) and its
`size <= 2 || first != 0` rejection; `join` = `StationJoin.run` with Pocket Android's arguments;
`restoreAccessPoint` = Pocket Android's `resetStation` under `restoreCameraWiFiWithRetry` (false
without a Bluetooth address); `scanNetworks` = `MultiviewProvisioner.scanNetworks`.

- [ ] **Step 1:** `:dji:testDebugUnitTest` and `:dji:lintDebug` pass.
- [ ] **Step 2:** Commit `feat(dji): Android station commissioner over the Multiview provisioner`.

### Task 7: reconcile the saved shared networks

**Files:**
- Modify: `Sources/OpenCineApple/SharedNetworkStore.swift` (`SharedNetwork` becomes
  `SharedNetworkStore.Network`, `hotspot: Bool`, missing key decodes as `false`),
  `Tests/OpenCineAppleTests/SharedNetworkStoreTests.swift`,
  `Android/platform/src/main/kotlin/com/opencapture/opencine/platform/SharedNetworkStore.kt`
  (an internal storage seam for tests)
- Create: `Android/platform/src/test/kotlin/com/opencapture/opencine/platform/SharedNetworkStoreTest.kt`

- [ ] **Step 1: Failing tests** (Kotlin, same names as Swift where the behavior exists on Android):
  `savingTheSameNetworkAndKindReplacesIt`, `aWiFiAndAHotspotWithOneNameAreKeptApart`,
  `aMissingHotspotFlagReadsAsWiFi`, `loadFindsByNameAndKind`. Swift tests updated to the new type
  (`aMissingHotspotFlagReadsAsWiFi` decodes `{"ssid":"Set","password":"pw"}` to `hotspot == false`).
- [ ] **Step 2: Run** both filters. Expected: FAIL (Swift type, Kotlin seam missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `refactor(platform): one saved shared network shape on both platforms`.

### Task 8: locked Shared Wi-Fi page completes and names itself from the context

**Files:**
- Modify: `Sources/OpenCineAppKit/StationNetworkSetup.swift` (`StationNetworkSetupContext.identifier`),
  `Sources/OpenCineAppKitApple/StationNetworkSetupView.swift` (`complete` parameter; the locked
  page's Done calls it, else `close`; its identifier is `context.identifier`),
  `Tests/OpenCineAppKitAppleTests/StationNetworkSetupLockedPageTests.swift`, `Package.swift`
  (AppKitApple tests use `OpenCineHostedAccessibility`, `OpenCineHostedTestSupport`)

`identifier` matches Kotlin's test tag: `.multiview` "multiview.networkSetup", `.camera` "addSetup".

- [ ] **Step 1: Failing rendered test** `lockedPageDoneCompletesAndTheSheetIsNamedByItsContext`:
  host the locked view in a window; the hosted accessibility tree shows "Shared Wi-Fi", the SSID,
  the copy and a "Done" button; activating Done calls `complete` once and never `close` or
  `scan`; the sheet's identifier is `multiview.networkSetup`.
- [ ] **Step 2: Run** on `opc-smv2`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `fix(appkit): locked Shared Wi-Fi Done completes, named by its wizard context`.

### Task 9: Pocket iOS calls through the seams

**Files (OpenPocketCine):**
- Delete: `ios/OpenPocketCine/MultiviewProvisioner.swift`
- Create: `ios/OpenPocketCine/MultiviewTileLink.swift` (`MultiviewSession.Tile: MultiviewMemberLink`)
- Modify: `ios/OpenPocketCine/MultiviewSession.swift`, `MultiviewNetworkSetup.swift` (`complete:`),
  `MultiviewNetworkStore.swift`, `AddSetupView.swift`, `CameraSession.swift` (network type),
  `ios/OpenPocketCineTests/MultiviewStagePersistenceTests.swift` (pairing test moved to OpenCine)

The session keeps everything the Plan 3 coordinator will own (lifecycle, guards, address
reservations, exclusion, the two-pass discovery, the rejoin budget, the 45 s path loss, the
journal) and calls: `commissioner.qualification/hasPreview/record/connect/restoreAccessPoint/scanNetworks`,
`hostPath.address/join`, and per tile `open/startPreview/keepalive/close/repair/autoLUT`.
`resetCamera` stays as the test hook, run under `restoreCameraWiFiWithRetry` as today.

- [ ] **Step 1:** Baseline already recorded (Multiview unit suites and `MultiviewUIFlowTests` on
  the unchanged branch).
- [ ] **Step 2:** Make the changes.
- [ ] **Step 3:** Run the same suites. Expected: same results as the baseline.
- [ ] **Step 4:** Commit `refactor(ios): Multiview calls through the shared seams`.

### Task 10: Pocket Android calls through the seams

**Files (OpenPocketCine):**
- Modify: `Apps/Android/app/src/main/kotlin/com/opencapture/openpocketcine/multiview/MultiviewSession.kt`
  (Tile implements `MultiviewMemberLink<FoundCamera>`; the session uses `DjiStationCommissioner`
  and the path as `StationHostPath`), `MultiviewScreen.kt`, `pairing/PairingCallouts.kt` (Core
  `StationNetwork`)

- [ ] **Step 1:** Baseline recorded (`:app:testDebugUnitTest --tests '*multiview*'`, `:app:lintDebug`).
- [ ] **Step 2:** Make the changes.
- [ ] **Step 3:** Run the same. Expected: same results.
- [ ] **Step 4:** Commit `refactor(android): Multiview calls through the shared seams`.

### Task 11: snapshots, docs and the full gates

- [ ] Swift and Kotlin API snapshots; `atlas consumers --write` if CI asks.
- [ ] OpenCine: `swift build --build-tests` and `swift test --skip-build` (strict concurrency),
  `xcodebuild` builds of `OpenCineApple`, `OpenCineDJIApple`, `OpenCineAppKitApple`; Gradle
  `:core:test :platform:testDebugUnitTest :platform:lintDebug :dji:testDebugUnitTest :dji:lintDebug
  :appkit:testDebugUnitTest :appkit:lintDebug`; `python3 -m unittest discover -s atlas/tests`;
  `atlas check`.
- [ ] Commit `chore: API snapshots for the Multiview seams`.

## Left for Plan 3

- The coordinator itself (AppKit, both platforms) over these seams, with fakes of
  `StationCommissioner`, `StationHostPath` and `MultiviewMemberLink` in `OpenCineCoreTestSupport`
  and Kotlin `core` test fixtures, written with the first tests that use them.
- Discovery through `MultiviewMemberLink.probe` (Pocket still uses DJI's batched discovery).
- The iOS/Android differences the seams preserve (Android's early identity and Wi-Fi-wake retry,
  foreground repair, probe width).
