# Shared Multiview Plan 5: OpenInstaCine adopts the Pocket-standard Multiview

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Luna integration the three Multiview seams (`MultiviewCameraPolicy`,
`StationCommissioner`, `MultiviewMemberLink`) on Swift and Kotlin over the prep operations from
#349, and put OpenInstaCine (iOS and Android) on OpenCine's shared `MultiviewScreen` with an app
`MultiviewScreenHost`, so the operator finds Pocket's Multiview with only Luna's capability
differences. The earlier Z-style stage (OpenInstaCine `feat/multicam`, `feat/multicam-android`) is
read for its Luna member code and not shipped.

**Architecture:** Three layers.

1. Backend steps (Insta360Apple `LunaCameraBackend`, Kotlin `LunaBackend`): the Bluetooth station
   move is split into the two steps the commission seam asks for, `authorizeForStation` (Bluetooth
   reach, approval on the camera, encrypted credential read: returns the serial) and
   `moveOntoStation` (SET_WIFI_MODE station, `LunaStationJoin`, remember: returns the address the
   camera reported), plus `probeStation` (the LAN probe the search already uses, no session). Both
   backends conform to a new port, `LunaStationPort`, which also lists the prep operations the link
   uses (LAN-only `connect(to:at:on:)`, `returnToAccessPoint`, `restartLive`, the live clocks).
2. Integration seams (Insta360Apple, `insta360-luna`, twins with the same names and tests):
   `LunaMultiview.policy`, `LunaStationCommissioner`, `LunaMemberLink`, `LunaNearbyScanner`, all
   over `LunaStationPort` and tested against a scripted fake (`FakeLunaStationPort`, test support).
   The camera is Core's `NearbyCamera` (the Luna sighting); the identity is the serial's UTF-8
   bytes.
3. Apps: OpenInstaCine iOS `MultiviewSession` (tiles, coordinator, host) and `MultiviewView`
   (presents `MultiviewScreen`); Android `MultiviewSession` and a Compose host. Journal and network
   storage, the record confirmation preference, Auto LUT, the cameras-page entry, the N1 one-liner.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing, Observation, SwiftUI), Kotlin 2.4 (JVM 17,
coroutines, Compose), XCTest and XCUITest in OpenInstaCine iOS, kotlin.test in OpenInstaCine
Android.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` ("Per camera: what
identical means", step 6, step 8, "Settled calls", "Owner answers"); roadmap
`docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md` (every "Carried from Plan N" item
for Plan 5, N1); Luna prep plan `2026-11-13-luna-multiview-prep.md` and its reviews; Pocket's
handbook `guides/multiview-prototype.md`.

## Global Constraints

- OpenCine `AGENTS.md`: Swift and Kotlin twins with the same type and test names; capability, not
  brand, in AppKit (this plan changes no AppKit or Core code unless a task says so, and then in its
  own commit); no em dash character (Kotlin strings write `\u2014`); Conventional Commits, no
  co-author trailers, explicit `git add`; behavior tests at contract boundaries on manual clocks
  and gates, no sleeps.
- Never stop a recording: no link, repair, close or return sends a record command; Remove and
  close only disconnect; the return sends one SET_WIFI_MODE 147 over Bluetooth.
- `stationHostsInUse` is respected: every member backend is told the hosts the other members
  hold, so no search or LAN open reaches another member's camera.
- A LAN-only open is never followed by a Bluetooth move inside the backend (REREVIEW note 2): the
  member backend is never driven through `reconnectRoute` / app-shell recovery; Bluetooth runs
  only through the commissioner and the link's repair under the coordinator's `bluetoothTurn`.
- Public API changes update snapshots in the branch (`atlas api --write --build`,
  `./gradlew updateKotlinAbi updateAndroidApi`).
- OpenInstaCine: build against the sibling `../OpenCine`; never move `opencine-pins.txt`.
- Scratch only under `/Volumes/OCScratch/smv5/`; iOS tests on the private simulator `opc-smv5`,
  deleted at the end. Hardware untested: every hardware claim says so.

## Review Focus

- The commission split: `authorizeForStation` then `moveOntoStation` sends exactly what the prep's
  `moveOverBluetooth` sent, in the same order; a cancelled or failed commission leaves Bluetooth
  closed.
- `restoreAccessPoint` maps every `LunaAccessPointReturn` per the Plan 3 cleanup ruling: only
  `returned` is `restored`; deferred and permanent refusals are `deferred(copy)`; a cancelled or
  thrown return is `failed` and stays journaled.
- The link never reaches Bluetooth outside `bluetoothTurn`, never sends a record command, and its
  session is one per member lifetime.
- App hosts: Pocket iOS behavior (entry, wizard, Add, tiles, record, settings popup, Live View,
  LUT, close), with Luna's differences only from capabilities.

## Rulings taken while planning (recorded again in the report)

1. The commission's `join` moves the camera, then asks `verifyOnNetwork` until it finds the camera
   or 60 s pass (the prep's own search budget after a move), returning `.verified`; otherwise
   `.joined`, and the coordinator's own discovery runs once more. A Luna needs DHCP time after the
   move; the coordinator's two passes three seconds apart alone are too short.
2. `discoversByProbe` is true: the Luna answers a greeting probe on its control port without a
   session, exactly as the prep's serial-checked search does; the coordinator opens a candidate only
   with the serial check.
3. `open` is the prep's LAN-only connect, which opens control and starts live in one step on Luna;
   `startPreview` reports `controlling` and `awaitingPicture` for the address `open` reached.
4. Repair: Luna's `LunaFeedStall` ladder in place (keyframe, at most two live restarts) without
   spending budget; a stall it escalates, or a lost control link, becomes `.repair`: under
   `bluetoothTurn`, a camera that does not answer at its last address is moved onto the network
   again over Bluetooth (station move only), then `.rejoin`, so the coordinator finds and opens it
   LAN-only with the serial. The coordinator's rejoin spends the budget.
5. Auto LUT: the link reports the snapshot's color profile as the color mode and the app's
   conversion for it (an app-supplied lookup; the integration has no LUT files).
6. `asksApprovalOnCamera` true, `joinsExperimentally` false, `scansNetworks` false (Plan 4 carry).
7. Network passwords use the Luna backend's setup store (`stationPassword` / `saveStation`), the
   same store the Add setup wizard fills, so a setup's password prefills the Multiview wizard.

## File Structure

OpenCine:
- `Sources/Insta360Apple/LunaStationPort.swift` (new): the port protocol, `LunaCameraBackend`
  conformance.
- `Sources/Insta360Apple/LunaCameraBackend.swift`: `authorizeForStation`, `moveOntoStation`,
  `probeStation` (refactor of `moveOverBluetooth`).
- `Sources/Insta360Apple/LunaMultiview.swift` (new): `LunaMultiview` (policy, record, identity),
  `LunaStationCommissioner`, `LunaNearbyScanner`.
- `Sources/Insta360Apple/LunaMemberLink.swift` (new).
- `Sources/Insta360AppleTestSupport/FakeLunaStationPort.swift` (new).
- `Tests/Insta360AppleTests/LunaMultiviewTests.swift`, `LunaMemberLinkTests.swift` (new).
- Kotlin twins under `Android/insta360-luna/src/{main,test,testFixtures?}`: `LunaStationPort.kt`,
  `LunaMultiview.kt`, `LunaMemberLink.kt`, `LunaMultiviewTest.kt`, `LunaMemberLinkTest.kt`
  (the fake lives in the test source set, as `FakeLunaPort` does there).
- `docs/insta360/README.md`, `docs/appkit/README.md` capability table row, API snapshots.

OpenInstaCine:
- iOS: `ios/OpenInstaCine/MultiviewSession.swift`, `MultiviewView.swift`, `MultiviewStores.swift`
  (new); `CamerasExperience.swift` (entry), `AppRoot.swift` (presentation), `AddSetupView.swift`
  (N1), `AppModel+LiveChrome.swift` (`multiviewExit`); tests in `OpenInstaCineTests`.
- Android: `monitor/.../multiview/MultiviewSession.kt`, `MultiviewStores.kt`, `MultiviewHost.kt`
  (new); `MainActivity.kt` / `AppModel.kt` (entry); tests in `monitor/src/test`.
- Handbook: `handbook/src/content/docs/guides/multiview.md` (new) and the sidebar.

## Tasks

### Task 1: Swift backend station steps and `LunaStationPort`

**Files:** `LunaStationPort.swift`, `LunaCameraBackend.swift`, `FakeLunaStationPort.swift`.

**Interfaces:**

```swift
@MainActor public protocol LunaStationPort: AnyObject {
    var stationHostsInUse: (@MainActor () -> Set<String>)? { get set }
    func authorizeForStation(_ camera: MonitorCamera) async throws -> String
    func moveOntoStation(_ network: LunaStationNetwork) async throws -> String?
    func probeStation(_ host: String) async -> Bool
    func connect(to camera: MonitorCamera, at host: LunaStationHost, on network: LunaStationNetwork) async throws
    func returnToAccessPoint(cameraID: UUID) async throws -> LunaAccessPointReturn
    func openSession() -> LunaCameraSession
    var connectedSerial: String? { get }
    var isControlReady: Bool { get }
    var secondsSinceVideo: TimeInterval? { get }
    func requestKeyframe() async
    func restartLive() async throws
    func disconnect()
}
```

- [ ] Refactor `moveOverBluetooth` into `authorizeForStation` + `moveOntoStation` (same requests,
      same order); `connect(route: .station)` keeps calling both. Run the Luna suites: unchanged.
- [ ] `probeStation`: this phone's station address as local, `LunaStationPath.probe`.
- [ ] The fake: scripted serials, reported addresses, probe answers, connect outcomes held on a
      gate, recorded requests (authorize, move, connect host and serial, disconnects, returns).
- [ ] Commit `feat(insta360): station move steps behind LunaStationPort`.

### Task 2: Swift policy, commissioner and scanner (test first)

**Interfaces:** `LunaMultiview.policy: MultiviewCameraPolicy<NearbyCamera>`,
`LunaMultiview.record(_:) -> StationCameraRecord`, `LunaStationCommissioner(makePort:)`
(`StationCommissioner<NearbyCamera>`), `LunaNearbyScanner(integration:)`.

Tests (`LunaMultiviewTests`): qualification (an unavailable sighting is refused, an available one
qualifies, no experimental path); `aCommissionProvesTheSerialAndMovesTheCamera`
(identity is the serial bytes, join moves once and returns `.verified` once `verifyOnNetwork`
finds it); `aCameraNotFoundYetIsAskedAgainWithinTheBudget`; `aFinalVerificationEndsTheJoin`;
`closingACommissionClosesBluetooth`; `returnMapsEveryResult` (returned, deferred, permanent
refusal, cancellation); `theScannerReportsEverySighting`.

- [ ] Tests red, implement, green, commit `feat(insta360): Luna station commissioner and policy`.

### Task 3: Swift `LunaMemberLink` (test first)

**Interfaces:** `LunaMemberLink(port:clock:conversion:)`, `MultiviewMemberLink<NearbyCamera>`.

Tests (`LunaMemberLinkTests`): `openChecksTheSerialAtTheAddress` (expecting identity is passed as
the serial; returns the proven serial); `openWithoutAnIdentityIsRefused`;
`aSilentAddressFails`; `probeAsksThePortOnly`; `startPreviewReportsControllingThenLive`;
`theRecordReportFollowsTheCamera` (stamped on the link clock, fresh only while reports arrive);
`aStallRestartsLiveInPlace` (reconnecting, then live again); `aLostLinkMovesTheCameraUnderABluetoothTurn`;
`aLostLinkThatStillAnswersRejoinsWithoutBluetooth`; `closeSendsNoCameraCommand`;
`theSessionIsOnePerMember`; `autoLUTFollowsTheColorProfile`; `autoLUTFollowsWhatThePictureCarries`.

- [ ] Tests red, implement, green, commit `feat(insta360): Luna Multiview member link`.

### Task 4: Kotlin backend steps, port and fake (Task 1 twin)

- [ ] `LunaBackend.authorizeForStation(id)`, `moveOntoStation(network)`, `probeStation(host)`;
      `LunaStationPort` (same members, Kotlin types: `connect(id, at, on): ConnectionFailure?`,
      `phase`/`failureDetail` flows to await the LAN connect). Existing suites unchanged.
- [ ] Commit `feat(insta360-luna): station move steps behind LunaStationPort`.

### Task 5: Kotlin policy, commissioner, scanner and link (Tasks 2 and 3 twins)

- [ ] Same test names in `LunaMultiviewTest` and `LunaMemberLinkTest`; red, implement, green.
- [ ] Commits `feat(insta360-luna): Luna station commissioner and policy`,
      `feat(insta360-luna): Luna Multiview member link`.

### Task 6: OpenCine docs and snapshots

- [ ] `docs/insta360/README.md` (Multiview section), `docs/appkit/README.md` (Luna row), roadmap
      "Carried from Plan 5"; `atlas api --write --build`; `updateKotlinAbi updateAndroidApi`;
      `atlas check`. Commit `docs: Luna Multiview seams` and `chore: API snapshots for Luna Multiview`.

### Task 7: OpenInstaCine iOS

- [ ] N1: `AddSetupView` passes `complete: { done(nil) }` (one line).
- [ ] `MultiviewStores` (Keychain journal `com.opencapture.openinstacine.multiview-stage`,
      presentation preferences), unit test round trip.
- [ ] `MultiviewSession`: four tiles, each its own backend, app `CameraSession` (picture, status;
      no shell recovery) and `LunaMemberLink`; the coordinator with the Luna policy, commissioner,
      scanner, `SharedWiFiPath`, journal and network storage; `MultiviewHost` (Live View borrow,
      editors, foreground, stage stopped, record confirmation, Auto LUT apply).
- [ ] `MultiviewView`: `MultiviewScreen` with the host's views (tile picture, settings preview and
      controls, Live View, wizard brand and services, camera SSIDs); the cameras page grid entry
      (`ShellActions.multiview`) disconnects the monitor first, as Pocket.
- [ ] Unit tests: the session's host values (record confirmation, Auto LUT, admits controls),
      stage persistence. Existing app tests unchanged. Commits per piece.

### Task 8: OpenInstaCine Android

- [ ] `MultiviewStores` (SharedPreferences journal), `MultiviewSession` (tiles: own `LunaBackend`
      on the app's one `SharedWiFiPath`, decoder, `LunaMemberLink`), Compose host
      (`Picture`, `SettingsPreview`, `SettingsControls`, `LiveView`, `NetworkSetup`), entry.
- [ ] Unit tests for stores and host values; `testDebugUnitTest`, lint, androidTest compile.

### Task 9: Handbook and hardware pass list

- [ ] OpenInstaCine handbook page mirroring Pocket's with Luna capability notes, every hardware
      behavior untested. Report with the full Luna hardware pass list (iOS and Android).

## Verification

- OpenCine: `swift build --build-tests -Xswiftc -strict-concurrency=complete`, `swift test
  --filter 'Insta360|Luna|Multiview'`, `atlas api --write --build`, Kotlin `:core :multicam
  :platform :appkit :insta360-luna :insta360-shell` tests and `:insta360-luna:lint`, `atlas check`.
- OpenInstaCine: iOS unit tests (and UI tests touching the cameras page) on `opc-smv5`; Android
  `testDebugUnitTest`, `lintDebug`, `compileDebugAndroidTestKotlin` with `-x stageSwiftCore`.
