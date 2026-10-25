# Gyro Capture, Part 4: Nikon Adapter and OpenZCine Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the gyro camera adapter for Nikon in OpenCine (Swift and Kotlin), then make OpenZCine the first adopter: pin the Core change, wire the adapter and the shared screens on iOS and Android, delete OpenZCine's own gyro code, and carry saved logs, the Gyro toggle and the saved calibration across the update.

**Architecture:** Phase A (OpenCine): `OpenCineNikon` gains `NikonGyroCamera.swift` (pure mapping between `PTPCameraPropertySnapshot`, `PTPLevelAngles`, `NativeCameraIdentity` and Part 1's adapter values) and `NikonGyroCameraAdapter` (a `GyroCameraAdapter` whose writes go through a host closure, because on iOS the app's model owns the camera write queue). Android `:nikon` gains a Kotlin `NikonGyroCameraAdapter` over `CameraSession` (`applyControl`) and `SwiftCoreLiveFrameSource` levels. `OpenCineNikon -> OpenCineGyro` and `:nikon -> :gyro` are vendor -> core edges (allowed). Phase B (OpenZCine) moves its pin to OpenCine's merge commit and replaces `GyroCaptureCoordinator`, `GyroLogStore`, `GyroLogsView`, `GyroMountView`, `PhoneMotionDriver` and the Android `gyro/` package with the shared ones; storage locations stay where they are, so migration is a preference rewrite, not a file move.

**Tech Stack:** Swift 6, SwiftUI, Kotlin/Compose, SwiftPM (OpenZCine root package plus `ios/Runner.xcodeproj`), Gradle included build `opencine`, `just native-check`, `just android-check`.

**Spec:** `docs/superpowers/specs/2026-10-25-gyro-capture-ux-design.md` (sections "Camera adapter", "OpenZCine adoption", owner decisions 1 to 3).

**Depends on:** Parts 1, 2 and 3 merged into OpenCine `main` (Phase A can be developed on the same Core branch and merged with them; Phase B starts only after the Core merge).

**Why this boundary:** the Nikon adapter cannot be proven without its first consumer, and the adoption cannot start without the adapter; Phase A still lands in Core first (owner rule: Core lands before app pins), so the plan is split into two phases with a release gate between them rather than two plans.

## Global Constraints

- Never use the em dash character anywhere.
- OpenCine commits and OpenZCine commits as `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>`; Conventional Commits; no co-author trailers; explicit `git add <path>`.
- OpenZCine work happens in a task-owned worktree of OpenZCine on its own branch (`atlas task start` or `git worktree add` from the shared sibling checkout `../OpenZCine`); never modify that checkout itself, never reset, clean or force-push.
- Merge commits only (`gh pr merge --merge`); OpenZCine's pin points at OpenCine `main`'s merge commit. Every `gh` call uses `GH_TOKEN=$(gh auth token -u erik-sutton95)`.
- Capability, not brand: `OpenCineNikon` may name Nikon; shared gyro code may not. Camera settings change only on **Turn off IBIS** and on the session-end restore; never during a demo session; never touch card contents.
- Integrations never import UI. Nikon behavior changes need the consumer checks: OpenZCine `swift test`, iOS build-for-testing and Android with Swift core staging.
- External releases stay held for the owner's hardware pass; land this after the internal builds currently being cut.
- Heavy commands go through `~/Work/OpenCine-Parity-20261012/tools/heavy.sh`; every run has a timeout. OpenZCine Android builds may use `~/Work/OpenCine-Parity-20261012/tools/remote-gradle.sh` (it builds against the pushed pin, so push Core first).

## Review Focus

1. **First launch after the update** with OpenZCine logs on disk and the old keys (`gyroLoggingEnabled.v1`, `gyroMountPreset.v1`, `gyroMountCalibration.v1` on iOS; `gyro-logging` prefs `enabled`, `mountPreset`, `mountCalibration` on Android): every log is listed with a status, the toggle keeps its value, the preset is gone, a valid calibration is adopted by the first connected body. Tests: `upgradeKeepsLogsToggleAndCalibration` in Tasks 7 (iOS) and 8 (Android).
2. **Disconnect from the app while armed with IBIS turned off:** the restore lands before the PTP session closes. Test: `disconnectRestoresBeforeClosing` in Task 6 (iOS) and Task 8 (Android).
3. **Electronic VR restore refused** (the codec changed to one without e-VR while armed): the notice shows, the movie VR part still restores, nothing loops. Test: `partialRestoreFailureShowsNoticeOnce` in Task 2.
4. **Live view header without pitch** (`hasPitch == false`) or without roll: no camera down is sent (`.level(nil, ...)`), the ring shows "Waiting for the camera", drift stays quiet. Test: `levelWithoutPitchIsNoReading` in Task 1.
5. **Demo session** (`isDemoSession`): the adapter is not attached, nothing is written to a camera, logging still works for UI review. Test: `demoSessionNeverWrites` in Task 6.

---

## Phase A: OpenCine

### File Structure (Phase A)

| Path | Responsibility |
|---|---|
| `Sources/OpenCineNikon/NikonGyroCamera.swift` | `NikonGyroCamera`: settings, snapshot -> state, values -> writes, level -> down, identity |
| `Sources/OpenCineNikon/NikonGyroCameraAdapter.swift` | `@MainActor final class NikonGyroCameraAdapter: GyroCameraAdapter` |
| `Tests/OpenCineNikonTests/NikonGyroCameraTests.swift`, `NikonGyroCameraAdapterTests.swift` | Tests |
| `Android/nikon/src/main/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapter.kt` | Kotlin adapter |
| `Android/nikon/src/test/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapterTest.kt` | JVM test over `FakeCameraSession` |

Modified: `Package.swift` (`OpenCineNikon` and `OpenCineNikonTests` gain `"OpenCineGyro"`), `Android/nikon/build.gradle.kts` (`api(project(":gyro"))`), `AGENTS.md` (integrations' neutral dependencies list adds the gyro module), `atlas/api/swift/OpenCineNikon.txt`, `Android/nikon/api/nikon.api`.

---

### Task 1: Nikon gyro mapping

**Files:**

- Create: `Sources/OpenCineNikon/NikonGyroCamera.swift`
- Test: `Tests/OpenCineNikonTests/NikonGyroCameraTests.swift`
- Modify: `Package.swift`

**Interfaces:**

- Consumes: `PTPCameraPropertySnapshot.vibrationReduction` ("OFF"/"ON"/"SPORT"), `.electronicVR` ("OFF"/"ON" via `PTPCameraPropertyDecoders.onOffLabel`), `.captureSelector`, `PTPCameraPropertyWrite.vibrationReduction(label:)` (0xD1F9), `PTPCameraPropertyWrite.electronicVR(on:)` (0xD314), `PTPLevelAngles` (`roll`, `pitch`, `hasPitch`, `signedDegrees(_:)`), `NativeCameraSession.NativeCameraIdentity` (`serialNumber`, `model`, `displayName`), `GyroCameraGravity.down`.
- Produces:

```swift
public enum NikonGyroCamera {
    public static let movieVRKey = "movieVR"
    public static let electronicVRKey = "electronicVR"
    public static let settings: [GyroStabilizationSetting]   // [(movieVR, "IBIS", "OFF"), (electronicVR, "Electronic VR", "OFF")]
    /// nil when neither value is known. lensHasVRSwitch is nil: no PTP property reports a lens VR switch today.
    public static func stabilization(from snapshot: PTPCameraPropertySnapshot) -> GyroStabilizationState?
    /// Unknown keys and unwritable labels are dropped; order is movie VR then electronic VR.
    public static func writes(for values: [String: String]) -> [PTPCameraPropertyWrite]
    /// Requires measured roll and pitch; signed degrees, then GyroCameraGravity.down.
    public static func cameraDown(from level: PTPLevelAngles?) -> GyroVector3?
    public static func videoMode(from snapshot: PTPCameraPropertySnapshot) -> Bool?   // captureSelector == .video; nil when unread
    /// "nikon-<serial>" when the serial is non-empty, else "nikon-model-<model>"; name is displayName.
    public static func identity(_ identity: NativeCameraSession.NativeCameraIdentity) -> GyroCameraIdentity
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct NikonGyroCameraTests {
    @Test func stabilizationReadsBothValues() { /* snapshot VR "SPORT", e-VR "ON" -> values ["movieVR":"SPORT","electronicVR":"ON"]; isOff == false */ }
    @Test func unknownValuesAreNil() { /* empty snapshot -> nil */ }
    @Test func writesRestoreExactLabels() {
        let writes = NikonGyroCamera.writes(for: ["movieVR": "SPORT", "electronicVR": "ON"])
        #expect(writes == [PTPCameraPropertyWrite.vibrationReduction(label: "SPORT")!, PTPCameraPropertyWrite.electronicVR(on: true)])
    }
    @Test func unknownKeysAndLabelsAreDropped() { }
    @Test func levelWithoutPitchIsNoReading() { /* hasPitch false -> nil; nil level -> nil */ }
    @Test func levelMapsThroughGyroCameraGravity() { /* roll 0, pitch 0 -> (-1, 0, 0) */ }
    @Test func identityPrefersTheSerial() { }
    @Test func videoModeFollowsTheSelector() { }
}
```

- [ ] **Step 2: Run to verify failure**: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 swift test --scratch-path .build-gyro --filter NikonGyroCameraTests`.
- [ ] **Step 3: Add `"OpenCineGyro"` to the `OpenCineNikon` target and `OpenCineNikonTests` dependencies; implement.**
- [ ] **Step 4: Run to verify pass**, then `--filter OpenCineNikonTests` and `python3 atlas/tools/atlas.py check` (vendor -> core is allowed; expect exit 0).
- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/OpenCineNikon/NikonGyroCamera.swift Tests/OpenCineNikonTests/NikonGyroCameraTests.swift
git commit -m "feat(nikon): map Nikon VR, level and identity to gyro adapter values"
```

---

### Task 2: Swift Nikon gyro adapter

**Files:**

- Create: `Sources/OpenCineNikon/NikonGyroCameraAdapter.swift`
- Test: `Tests/OpenCineNikonTests/NikonGyroCameraAdapterTests.swift`

**Interfaces:**

- Consumes: Task 1; `GyroCameraAdapter`, `GyroCameraSink`, `GyroCameraEvent` (Part 1); `PTPLiveViewFrame` (`isRecording`, `level`).
- Produces:

```swift
@MainActor public final class NikonGyroCameraAdapter: GyroCameraAdapter {
    /// `write` performs the writes in order through the host's camera queue and returns true only
    /// when every write landed; it stops at the first refusal.
    public init(write: @escaping @MainActor ([PTPCameraPropertyWrite]) async -> Bool)
    public let providesLevel = true
    public var stabilizationSettings: [GyroStabilizationSetting] { NikonGyroCamera.settings }
    public func attach(_ sink: any GyroCameraSink); public func detach()
    public func writeStabilization(_ values: [String: String]) async -> Bool
    // Host feed:
    public func connected(_ identity: NativeCameraSession.NativeCameraIdentity)
    public func disconnected()
    public func receive(frame: PTPLiveViewFrame, at timestamp: Double)   // .recording(frame.isRecording, at:) on change, .level(cameraDown, at:) every frame
    public func receive(snapshot: PTPCameraPropertySnapshot)              // .stabilization and .videoMode on change only
}
```

- [ ] **Step 1: Write the failing tests** with a recording sink and a scripted write closure: `framesEmitRecordingOnChangeAndLevelEveryFrame`, `snapshotsEmitOnlyOnChange`, `writeStopsAtFirstRefusal` (closure receives both writes and returns false -> `writeStabilization` returns false), `partialRestoreFailureShowsNoticeOnce` (drive a `GyroArmingMachine` with this adapter's settings: restore of movie VR lands, e-VR refused -> exactly one `.notice(.restoreFailed)` and no second write in the same connection), `detachStopsEvents`.
- [ ] **Step 2: Run to verify failure** (`--filter NikonGyroCameraAdapterTests`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineNikon/NikonGyroCameraAdapter.swift Tests/OpenCineNikonTests/NikonGyroCameraAdapterTests.swift
git commit -m "feat(nikon): gyro camera adapter for Nikon bodies"
```

---

### Task 3: Kotlin Nikon gyro adapter

**Files:**

- Create: `Android/nikon/src/main/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapter.kt`
- Test: `Android/nikon/src/test/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapterTest.kt`
- Modify: `Android/nikon/build.gradle.kts` (`api(project(":gyro"))`; tests add `testImplementation(testFixtures(project(":gyro")))` for `FakeGyroNative`)

**Interfaces:**

- Consumes: `CameraSession` (`state`, `reportedRecording`, `cameraProperties`), `CameraSessionState.Connected(identity: CameraIdentity)`, `CameraPropertySnapshot.vibrationReduction`, `.electronicVr`, `.captureSelector`, `CameraSession.applyControl(CameraControl.VIBRATION_REDUCTION | CameraControl.ELECTRONIC_VR, label)` (throws `CameraControlException` on refusal), `SwiftCoreLiveFrameSource.currentStreamFrames.metadataOnly()` with `LiveCameraLevel` (`rollDegrees`, `pitchDegrees`, `hasPitch`, `isDebugFixture`), `GyroNativeApi.cameraDown(roll, pitch)` (Part 1).
- Produces: `class NikonGyroCameraAdapter(session: CameraSession, frames: SwiftCoreLiveFrameSource?, native: GyroNativeApi, scope: CoroutineScope, now: () -> Double) : GyroCameraAdapter` with the same keys, titles and off values as Task 1 (`movieVR`, `electronicVR`, `IBIS`, `Electronic VR`, `OFF`); identity id `nikon-<serialNumber>` or `nikon-model-<model>`; `level` emits `GyroCameraLevel(null, t)` for debug fixtures, missing pitch or a null native reply; `writeStabilization` applies movie VR then e-VR (label `ON`/`OFF`), returns false at the first `CameraControlException`.

- [ ] **Step 1: Write the failing tests** over `FakeCameraSession` (Android/nikon) and `FakeGyroNative`: `identityPrefersSerial`, `stabilizationMapsBothValues`, `writesInOrderAndStopAtRefusal`, `debugFixtureLevelIsNoReading`, `videoModeFollowsSelector`.
- [ ] **Step 2: Run to verify failure**: `heavy.sh gyro-p4 bash -c 'cd Android && ./gradlew :nikon:test --tests "*NikonGyroCameraAdapterTest*"'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/nikon/build.gradle.kts Android/nikon/src/main/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapter.kt Android/nikon/src/test/kotlin/com/opencapture/opencine/nikon/NikonGyroCameraAdapterTest.kt
git commit -m "feat(nikon): Android gyro camera adapter"
```

---

### Task 4: Core release gate

- [ ] **Step 1: Snapshots and full Core gates** (AGENTS.md "Verification")

```sh
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 python3 atlas/tools/atlas.py api --write --build
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 bash -c 'cd Android && ./gradlew updateKotlinAbi updateAndroidApi'
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 swift build --scratch-path .build-gyro --build-tests -Xswiftc -strict-concurrency=complete
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 swift test --scratch-path .build-gyro
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 xcodebuild -scheme OpenCineApple -destination 'generic/platform=iOS Simulator' build
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p4 bash -c 'cd Android && ./gradlew test lint assembleRelease && cd .. && scripts/android-vulkan-sync-test.sh'
python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check
```

Expected: all pass.

- [ ] **Step 2: Consumer index**: `python3 atlas/tools/atlas.py consumers --write`; commit `atlas/consumers` if it changed.
- [ ] **Step 3: Commit snapshots**

```bash
git add atlas/api/swift/OpenCineNikon.txt Android/nikon/api/nikon.api atlas/consumers AGENTS.md
git commit -m "chore(nikon): API snapshots for the Nikon gyro adapter"
```

- [ ] **Step 4: Review and merge (needs the owner's authorization):** push the branch, open the Core PR covering Parts 1 to 4 Phase A, handle every CodeRabbit thread (verify, fix with a test or reply), get the owner's go, `GH_TOKEN=$(gh auth token -u erik-sutton95) gh pr merge --merge`. Record the merge commit SHA for Phase B.

---

## Phase B: OpenZCine

### File Structure (Phase B, paths relative to the OpenZCine task worktree)

| Path | Change |
|---|---|
| `opencine-pins.txt` | Pin moves to the Phase A merge commit |
| `Package.swift` | `OpenZCineAndroidFacade` gains `.product(name: "OpenCineGyroAndroid", package: "OpenCine")` |
| `ios/Runner.xcodeproj/project.pbxproj` | Runner links `OpenCineGyro` and `OpenCineGyroApple`; gyro file references removed |
| `ios/Runner/NativeAppRoot.swift` | Coordinator, adapter, eligibility, frame and snapshot feed, write completion, disconnect |
| `ios/Runner/MonitorUnified.swift` | Pill slot uses `GyroPillView` |
| `ios/Runner/MonitorPanels.swift` | `MonitorSettingsGyroSource(... calibrate:)` |
| `ios/Runner/` level overlay call sites | `PhoneMotionDriver.shared` now comes from `OpenCineGyroApple` |
| `ios/RunnerTests/GyroAdoptionTests.swift` | New: wiring and upgrade tests |
| Deleted | `ios/Runner/{GyroCaptureCoordinator,GyroLogStore,GyroLogsView,PhoneMotionDriver}.swift`, `ios/RunnerTests/{GyroCaptureTests,GyroLogStoreTests}.swift`, `Sources/OpenZCineCore/Gyro*.swift`, `Tests/OpenZCineCoreTests/Gyro*.swift`, `Sources/OpenZCineAndroidFacade/Gyro*.swift`, `Tests/OpenZCineAndroidFacadeTests/Gyro*.swift` |
| `Apps/Android/app/build.gradle.kts` | `implementation("com.opencapture.opencine:gyro:0.1.0-SNAPSHOT")` |
| `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/MainActivity.kt` | Shared coordinator, adapter, feature host, pill, settings |
| `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/SwiftCore.kt` | The 15 `external fun gyro*` removed; `GyroNative.load("OpenZCineAndroid")` next to `NikonNative.load` |
| `Apps/Android/app/src/test/kotlin/com/opencapture/openzcine/GyroAdoptionTest.kt` | New: upgrade test |
| `Apps/Android/app/src/androidTest/kotlin/com/opencapture/openzcine/GyroLoggingJNITest.kt` | Retargeted to `com.opencapture.opencine.gyro.GyroNative` |
| Deleted | `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/gyro/`, `Apps/Android/app/src/test/kotlin/com/opencapture/openzcine/gyro/`, `Apps/Android/app/src/androidTest/kotlin/com/opencapture/openzcine/gyro/` |
| `docs/gyro-logging.md`, `handbook/src/content/docs/guides/gyro-logging.md` | Rewritten for the ring, no presets, Share log, Mount moved |

---

### Task 5: Pin and package wiring

**Files:** `opencine-pins.txt`, `Package.swift`, `ios/Runner.xcodeproj/project.pbxproj`, `Apps/Android/app/build.gradle.kts`

- [ ] **Step 1: Move the pin** to the Phase A merge commit (`OpenCine <sha>`), then `scripts/checkout-opencine.sh` so `../OpenCine` matches.
- [ ] **Step 2: Add the Swift product to the facade target and the two Apple products to the Runner** (copy the `XCSwiftPackageProductDependency` and `PBXBuildFile` pattern of `OpenCineFrameIOApple` at `project.pbxproj` around the `productName = OpenCineFrameIOApple;` entry), and the Gradle dependency.
- [ ] **Step 3: Verify both builds still pass before any code change**: `just native-check` and `just android-build` (through `heavy.sh`). Expected: PASS (OpenZCine's own gyro code still compiles; the new modules are linked but unused). If OpenZCine's `GyroSample`/`GyroVector3` names collide with `OpenCineGyro`'s in a file importing both, qualify with `OpenZCineCore.` for this commit only.
- [ ] **Step 4: Commit**

```bash
git add opencine-pins.txt Package.swift ios/Runner.xcodeproj/project.pbxproj Apps/Android/app/build.gradle.kts
git commit -m "build: pin OpenCine with the shared gyro modules"
```

---

### Task 6: iOS adoption

**Files:**

- Modify: `ios/Runner/NativeAppRoot.swift`, `ios/Runner/MonitorUnified.swift`, `ios/Runner/MonitorPanels.swift`, level overlay call sites of `PhoneMotionDriver.shared.startLevel`
- Create: `ios/RunnerTests/GyroAdoptionTests.swift`

**Interfaces:**

- Consumes: `GyroCaptureCoordinator(host:)`, `GyroHostConfiguration`, `GyroPreferenceKeys.namespaced(_:)`, `GyroLegacyPreferenceKeys`, `View.gyroFeature(_:)`, `GyroPillView(state:action:)`, `MonitorSettingsGyroSource(...calibrate:)` (Part 2), `NikonGyroCameraAdapter` (Task 2).
- Wiring decisions:
  - `let gyroCapture = GyroCaptureCoordinator(host: GyroHostConfiguration(appName: "OpenZCine", logDirectory: URL.applicationSupportDirectory.appendingPathComponent("GyroLogs", isDirectory: true), preferenceKeys: .namespaced("gyro.v2."), legacyKeys: GyroLegacyPreferenceKeys(enabled: "gyroLoggingEnabled.v1", mountPreset: "gyroMountPreset.v1", calibration: "gyroMountCalibration.v1")))`. The directory is OpenZCine's existing one, so logs stay in place.
  - `let nikonGyro = NikonGyroCameraAdapter(write: { [weak self] writes in await self?.writeGyroStabilization(writes) ?? false })`; attach on connect when `!isDemoSession`, call `nikonGyro.connected(identity)`; `disconnected()` and detach in `disconnectCameraSession`.
  - `consumeCameraFrame`: replace the calibration block with `nikonGyro.receive(frame: frame, at: ProcessInfo.processInfo.systemUptime)`. Every place that assigns `cameraPropertySnapshot` from a camera read also calls `nikonGyro.receive(snapshot:)` (one helper `publishGyroSnapshot()` called from `publishCameraDisplayState()`).
  - `reconcileGyroCapture` becomes `gyroCapture.setHostEligible(isConnected && cameraSession != nil && isMonitorPresented && UIApplication.shared.applicationState == .active && !isDemoSession && videoSource != .relay && !multicam.isPresented && multicam.lentMember == nil)`; the selector check moves into the adapter's `videoMode`. Backgrounding calls `gyroCapture.appDidEnterBackground()`.
  - `writeGyroStabilization(_ writes: [PTPCameraPropertyWrite]) async -> Bool`: enqueue each write as a `PendingCameraWrite` with a new optional `completion: ((Bool) -> Void)?` field, resolved in `performNextPendingCameraWrite` after the readback (true) or in its failure path (false); await them in order with `withCheckedContinuation`; stop at the first false. The connection message for these writes reads `Gyro: IBIS OFF` / `Gyro: IBIS restored` instead of the generic "Queued VR" text.
  - `disconnect()`: when `gyroCapture.isArmed`, run `Task { await gyroCapture.prepareForDisconnect(); <existing body> }`; otherwise the existing body runs synchronously.
  - Replace `GyroMonitorStatus(coordinator:)` in `MonitorUnified.swift` with `GyroPillView(state: model.gyroCapture.pill) { model.gyroCapture.logsPresented = true }` in the same `layout.appBadge` slot and visibility condition (`pill.kind == .error || pill.kind == .mountMoved || pill.kind == .gaps` replaces `statusIsFailure || hasGapWarning`).
  - Replace the two `.sheet` presentations at the logs and mount sheets with one `.gyroFeature(model.gyroCapture)` on the root view.
  - Settings: `MonitorSettingsGyroSource(enabled:, status: GyroCopy.pillA11y(model.gyroCapture.pill.kind, warning: false), available:, openLogs:, calibrate: model.gyroCapture.canCalibrate ? { model.gyroCapture.beginCalibration() } : nil)`; stop passing `mountName` and `configureMount`.

- [ ] **Step 1: Write the failing tests** in `GyroAdoptionTests` (Swift Testing, `@testable import Runner`, `@MainActor`): `hostConfigurationKeepsTheLogDirectory`, `frameFeedReachesTheCoordinator` (a frame with level and `isRecording` produces a take and a level reading), `ibisWritesGoThroughTheCameraQueue` (demo-free model with a stub `NativeCameraSession` transport, or the existing RunnerTests camera fake; turn off -> one VR write enqueued with completion), `disconnectRestoresBeforeClosing`, `demoSessionNeverWrites`.
- [ ] **Step 2: Run to verify failure**: `heavy.sh gyro-z-ios just native-check` (or the RunnerTests `xcodebuild test -only-testing:RunnerTests/GyroAdoptionTests` on a private simulator per OpenZCine's AGENTS).
- [ ] **Step 3: Implement the wiring.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add ios/Runner/NativeAppRoot.swift ios/Runner/MonitorUnified.swift ios/Runner/MonitorPanels.swift ios/RunnerTests/GyroAdoptionTests.swift
git commit -m "feat(gyro): adopt OpenCine's shared gyro feature on iOS"
```

---

### Task 7: iOS upgrade test and deletion of the OpenZCine copies

**Files:**

- Modify: `ios/RunnerTests/GyroAdoptionTests.swift`, `ios/Runner.xcodeproj/project.pbxproj`
- Delete: `ios/Runner/{GyroCaptureCoordinator,GyroLogStore,GyroLogsView,PhoneMotionDriver}.swift`, `ios/RunnerTests/{GyroCaptureTests,GyroLogStoreTests}.swift`, `Sources/OpenZCineCore/Gyro*.swift`, `Tests/OpenZCineCoreTests/Gyro*.swift`

- [ ] **Step 1: Write the failing upgrade test** `upgradeKeepsLogsToggleAndCalibration`: in a temporary `UserDefaults` suite set `gyroLoggingEnabled.v1 = true`, `gyroMountPreset.v1 = "rearDown"`, `gyroMountCalibration.v1 = <valid calibration JSON>`; in a temporary log directory write one finished and one interrupted take in the old layout (copy the byte layout from the deleted `GyroLogStoreTests` fixtures, including an `OpenZCine-...gcsv` filename); build the coordinator with the production `GyroHostConfiguration` pointed at those; connect a fake adapter with id `nikon-123`. Expect: `enabled == true`, both logs listed (the interrupted one recovered, status `.cutShort`), `gyroMountPreset.v1` removed, `hasSavedCalibration == true` for `nikon-123` and false for a second camera.
- [ ] **Step 2: Run to verify** it passes against the shared code (it should; if it fails, the defect is in Parts 1 and 2: fix there, re-pin).
- [ ] **Step 3: Delete the OpenZCine copies** and their project references; remove `GyroMountView` and any remaining `GyroMountPreset` UI references; keep `OpenZCineCore`'s re-exports compiling.
- [ ] **Step 4: Run** `heavy.sh gyro-z-ios just native-check`. Expected: PASS, no `Gyro` symbol left in `Sources/OpenZCineCore` (`git grep -n 'Gyro' -- Sources/OpenZCineCore` prints nothing).
- [ ] **Step 5: Commit**

```bash
git add -A ios/Runner ios/RunnerTests Sources/OpenZCineCore Tests/OpenZCineCoreTests ios/Runner.xcodeproj/project.pbxproj
git commit -m "refactor(gyro): delete OpenZCine's iOS gyro copies after adopting OpenCine"
```

(`git add -A` is limited to the listed paths so deletions are staged; nothing else is added.)

---

### Task 8: Android adoption

**Files:**

- Modify: `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/MainActivity.kt`, `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/SwiftCore.kt`, the settings composition that builds `MonitorSettingsGyroSource`
- Create: `Apps/Android/app/src/test/kotlin/com/opencapture/openzcine/GyroAdoptionTest.kt`

**Interfaces / decisions:**

- `GyroNative.load("OpenZCineAndroid")` beside `NikonNative.load("OpenZCineAndroid")` in `SwiftCore`.
- `private val gyroCapture by lazy { GyroCaptureCoordinator(applicationContext, GyroHostConfiguration(appName = "OpenZCine", logRoot = File(filesDir, "gyro-logs"), preferencesName = "gyro-logging", keys = GyroPreferenceKeys.namespaced("gyro.v2."), legacy = GyroLegacyPreferenceKeys(enabled = "enabled", mountPreset = "mountPreset", calibration = "mountCalibration"))) }` (the existing root and prefs file, so logs stay in place).
- Where `gyroCapture.bind(eligible)` is called today, bind `NikonGyroCameraAdapter(session, session.liveFrames as? SwiftCoreLiveFrameSource, GyroNative, lifecycleScope, now)` for a connected `SwiftCoreCameraSession`, `null` otherwise; call `setHostEligible` with today's eligibility minus the selector (now the adapter's `videoMode`); `setForeground` stays.
- Disconnect paths call `gyroCapture.prepareForDisconnect()` before the session's disconnect when `state.value.isArmed`.
- Wrap the activity content in `GyroFeatureHost(gyroCapture, ZMediaShare) { ... }`; replace `GyroStatusPill` with `GyroPillChip`; settings source passes `calibrate` and stops passing mount preset parameters.
- `SwiftCore.kt`: delete the 15 `external fun gyro*` declarations.

- [ ] **Step 1: Write the failing test** `GyroAdoptionTest.upgradeKeepsLogsToggleAndCalibration` (Robolectric is not used in this repo: build the coordinator's `GyroPreferences` and `GyroLogStore` directly over a temp dir and an in-memory `SharedPreferences` fake, with the production host values, and a `FakeGyroNative` that validates the calibration JSON); plus `disconnectRestoresBeforeClosing` at the coordinator level with `FakeGyroCameraAdapter`.
- [ ] **Step 2: Run to verify failure**: `heavy.sh gyro-z-android just android-check` (or `remote-gradle.sh gyro-z test lint :app:assembleDebug` after pushing the branch).
- [ ] **Step 3: Implement the wiring.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/MainActivity.kt Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/SwiftCore.kt Apps/Android/app/src/test/kotlin/com/opencapture/openzcine/GyroAdoptionTest.kt
git commit -m "feat(gyro): adopt OpenCine's shared gyro feature on Android"
```

---

### Task 9: Android deletion and JNI symbol check

**Files:**

- Modify: `Apps/Android/app/src/androidTest/kotlin/com/opencapture/openzcine/GyroLoggingJNITest.kt`, `Package.swift` (facade comment)
- Delete: `Apps/Android/app/src/{main,test,androidTest}/kotlin/com/opencapture/openzcine/gyro/`, `Sources/OpenZCineAndroidFacade/Gyro*.swift`, `Tests/OpenZCineAndroidFacadeTests/Gyro*.swift`

- [ ] **Step 1: Retarget `GyroLoggingJNITest`** to `GyroNative.loggingCreate("OpenZCine")`, `loggingIngest`, `loggingObserve`, `ringCreate`/`ringObserve` and `calibrationValidate`, asserting the same behaviors it asserts today against the real `.so`.
- [ ] **Step 2: Delete the copies** and run `heavy.sh gyro-z-android just android-check`. Expected: PASS.
- [ ] **Step 3: Symbol check** (AGENTS.md rule for JNI facades): `llvm-nm -D <app .so> | grep Java_com_opencapture_opencine_gyro_GyroNative_` lists every `external fun` in `GyroNative`, and `grep Java_com_opencapture_openzcine_bridge_SwiftCore_gyro` lists nothing.
- [ ] **Step 4: Instrumented test on a device or emulator**: `./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.opencapture.openzcine.GyroLoggingJNITest` through `heavy.sh`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add -A Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/gyro Apps/Android/app/src/test/kotlin/com/opencapture/openzcine/gyro Apps/Android/app/src/androidTest/kotlin/com/opencapture/openzcine/gyro Sources/OpenZCineAndroidFacade Tests/OpenZCineAndroidFacadeTests
git add Apps/Android/app/src/androidTest/kotlin/com/opencapture/openzcine/GyroLoggingJNITest.kt Package.swift
git commit -m "refactor(gyro): delete OpenZCine's Android gyro copies and facade wire"
```

---

### Task 10: Docs, screenshots and the hardware checklist

**Files:** `docs/gyro-logging.md`, `handbook/src/content/docs/guides/gyro-logging.md` (and its images if the old ones show presets)

- [ ] **Step 1: Rewrite both docs** for the new flow: turning Gyro on opens the setup (IBIS step, ring calibration with "Use last calibration"), logging without calibration is allowed and marked Not calibrated, the pill states including MOUNT MOVED, the post-take recalibration prompt, the logs list badges, Select, Share log to a computer, then Gyroflow with the clip and the lens. No angles, no presets, no em dashes.
- [ ] **Step 2: Deploy and screenshot every changed screen** on the iOS simulator and an Android phone in landscape and portrait (OpenZCine AGENTS.md "Deploy + screenshot-verify every UI change"), with the demo session for the pill and logs and a connected body for calibration when available.
- [ ] **Step 3: Owner hardware checklist** in the PR body (owner runs it on a Nikon ZR before any external release): arm with IBIS on and turn it off; calibrate with the phone mounted portrait and again landscape; record, bump the phone mid-take, see MOUNT MOVED and the post-take prompt; disarm and confirm VR returns to the exact prior mode (for example SPORT); pull the link while armed, reconnect and confirm the restore happens first; open a log in Gyroflow on a desktop.
- [ ] **Step 4: Issues**: update OpenZCine and OpenCine issue labels and links for the gyro work (owner rule: keep issues current); open a follow-up OpenCine issue "Remove MonitorSettingsGyroSource mount preset parameters" for the next minor release.
- [ ] **Step 5: Commit**

```bash
git add docs/gyro-logging.md handbook/src/content/docs/guides/gyro-logging.md
git commit -m "docs(gyro): guided calibration, mount moved and Share log"
```

- [ ] **Step 6: Review and merge (needs the owner's authorization):** push, open the OpenZCine PR, handle every CodeRabbit thread, wait for the owner's review and hardware pass decision, then merge with `--merge`.
