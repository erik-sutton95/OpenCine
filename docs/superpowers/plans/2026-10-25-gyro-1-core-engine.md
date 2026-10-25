# Gyro Capture, Part 1: Core Engine and Android Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move OpenZCine's portable gyro engine into a new OpenCine module, add the camera adapter contract, the drift detector, the ring calibration controller, the session-scoped stabilization save/restore machine, take status mapping and storage, and expose all of it to Android through a Core JNI facade.

**Architecture:** `OpenCineGyro` is a Foundation-only Swift module in the `core` layer (like `OpenCineFrameIO`, it depends on nothing). All gyro policy lives there as value types that run on manual clocks. `OpenCineGyroAndroid` (layer `vendor`, beside `OpenCineFrameIOAndroid`) wraps that policy in owner-keyed JSON wires and exports `Java_com_opencapture_opencine_gyro_GyroNative_*`. A new Android library `:gyro` (layer `core`, package `com.opencapture.opencine.gyro`) holds the Kotlin JNI facade, the reply decoders, the Kotlin twin of the camera adapter contract and the Kotlin twin of take status mapping.

**Tech Stack:** Swift 6 (Swift Testing), SwiftPM, Swift SDK for Android JNI via `OpenCineJNISupport`, Kotlin, Gradle Android library, `org.json`.

**Spec:** `docs/superpowers/specs/2026-10-25-gyro-capture-ux-design.md` (read the "Decisions confirmed by the owner" section first; it overrides section 6 and refines sections 1, 3 and 5).

**Plan series (landing order):** 1 Core engine and Android bridge (this plan) -> 2 iOS runtime and SwiftUI screens -> 3 Android runtime and Compose screens -> 4 Nikon adapter and OpenZCine adoption. Plans 2 and 3 depend only on this plan and may run in parallel lanes.

**Why this boundary (deviation from the suggested split):** the suggested part 1 also held the platform sensor drivers and coordinators. They are moved into parts 2 and 3 instead because each one needs its platform's test host (iOS simulator, Android JVM/emulator), while everything in this plan runs under `swift test` on macOS plus JVM unit tests. That keeps this plan landable and reviewable as pure, deterministic policy, and lets each platform plan ship a working feature (runtime plus screens) against a fake adapter.

## Global Constraints

- Never use the em dash character in code, comments, docs, copy or commit messages.
- Conventional Commits; commit as `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>`; no co-author trailers; stage files explicitly with `git add <path>`.
- `OpenCineGyro` imports Foundation only, names no manufacturer and no app, holds no mutable static state (`static var`, `nonisolated(unsafe)`), never imports UI, an integration, Multicam or an app.
- App names, storage directories and preference keys arrive as host values. Unknown is `nil`, never `false`, `0` or `""`.
- GCSV stays version 1.3 with the same columns; solver math and acceptance stay as today: pose separation 20 to 160 degrees, pose pair agreement 2 degrees, mixed component `sin(15 degrees)`, validation error at most 2 degrees, still window at least 1 s with all readings within 3 degrees of the mean, phone/camera timestamps within 0.25 s.
- Drift: steady moments only, threshold starts at 2.5 degrees, sustained about 1 s. Recording is never interrupted by anything gyro-related.
- Arming is session-scoped (owner decision 1): the toggle means "arm whenever possible"; restore happens when the armed session ends while connected; a restore owed after a link drop is applied on the next connection before anything else.
- Logging without calibration is allowed (owner decision 2); no preset picker returns; legacy preset logs must still load and recover.
- Fakes run on manual clocks; tests never sleep.
- Change a contract and its mirrored Kotlin test together.
- Heavy commands go through `~/Work/OpenCine-Parity-20261012/tools/heavy.sh <label> <command...>`; every run gets a timeout (the Bash tool timeout or `timeout`), and a stalled test is killed and rerun alone.
- Use `--scratch-path .build-gyro` for SwiftPM so parallel lanes do not share a build directory.

## Review Focus

1. **Stale camera level during a take** (the camera's level header stalls while phone samples continue): drift must not fire on a camera reading older than 0.25 s. Test: `staleCameraReadingNeverConfirmsDrift` in Task 3.
2. **Phone clamped in landscape** (phone axes rotated 90 degrees relative to the camera): the ring's target zones are judged from the camera's down vector only, so calibration completes for any phone orientation. Test: `ringCompletesWithPhoneMountedSideways` in Task 4.
3. **User changed VR on the body while the app was disconnected:** an owed restore must not overwrite a value the app did not set. Test: `owedRestoreSkipsKeysTheUserChanged` in Task 6.
4. **App killed mid-take after a mount-moved mark:** the recovered log still reports "Mount moved at m:ss". Test: `recoveryMergesTheMountMovedSidecar` in Task 8.
5. **Legacy OpenZCine logs** (old filenames, manual `mountPreset`, no `writer`, no `mountMovedOffset`): they decode, recover and map to a status without throwing. Tests: `legacyDescriptorWithoutWriterDecodes` in Task 1, `legacyPresetLogMapsToNotCalibrated` in Task 7.

---

## File Structure

Created in OpenCine (paths relative to the Core worktree root):

| Path | Responsibility |
|---|---|
| `Sources/OpenCineGyro/GyroLog.swift` | Moved: `GyroSample`, `GyroLogTermination`, `GyroLogDescriptor`, `GyroLogSummary`, `GyroLogUpdate`, `GyroStatistics` |
| `Sources/OpenCineGyro/GyroTakeSession.swift` | Moved: take segmentation; gains `appName` and `observeMountMoved` |
| `Sources/OpenCineGyro/GyroGCSV.swift` | Moved: encoder and recovery; header `id` from the descriptor's writer |
| `Sources/OpenCineGyro/GyroMountCalibration.swift` | Moved: `GyroVector3`, `GyroCalibrationPose`, errors, solver; gains `mapping(_:)` |
| `Sources/OpenCineGyro/GyroMountCalibrationSession.swift` | Moved unchanged |
| `Sources/OpenCineGyro/GyroCameraGravity.swift` | Moved unchanged |
| `Sources/OpenCineGyro/GyroMountPreset.swift` | Moved; kept only to decode and recover legacy logs (labels removed) |
| `Sources/OpenCineGyro/GyroDriftDetector.swift` | New: steady-moment drift detection |
| `Sources/OpenCineGyro/GyroRingCalibration.swift` | New: automatic three-pose ring calibration controller |
| `Sources/OpenCineGyro/GyroCameraAdapter.swift` | New: camera adapter protocol, identity, stabilization values, camera events |
| `Sources/OpenCineGyro/GyroArming.swift` | New: session arming and stabilization save/restore machine |
| `Sources/OpenCineGyro/GyroTakeStatus.swift` | New: take status mapping |
| `Sources/OpenCineGyro/GyroLogStore.swift` | Moved from OpenZCine `ios/Runner/GyroLogStore.swift`: file store actor, plus mount-moved sidecar and multi-share |
| `Sources/OpenCineGyro/GyroPreferences.swift` | New: preferences over a host key-value store, per-camera calibrations, pending restores, legacy migration |
| `Tests/OpenCineGyroTests/*.swift` | Moved OpenZCine tests plus new suites named per task |
| `Fixtures/gyro-take-status-vectors.tsv` | Shared status vectors read by Swift and Kotlin tests |
| `Sources/OpenCineGyroAndroid/GyroLoggingWire.swift` | Moved from `Sources/OpenZCineAndroidFacade/GyroLoggingWire.swift` |
| `Sources/OpenCineGyroAndroid/GyroRingCalibrationWire.swift` | New: replaces OpenZCine's `GyroCalibrationWire` |
| `Sources/OpenCineGyroAndroid/GyroDriftWire.swift` | New |
| `Sources/OpenCineGyroAndroid/GyroArmingWire.swift` | New |
| `Sources/OpenCineGyroAndroid/GyroNativeJNI.swift` | New: every `Java_com_opencapture_opencine_gyro_GyroNative_*` export |
| `Tests/OpenCineGyroAndroidTests/*.swift` | Wire tests |
| `Android/gyro/build.gradle.kts`, `consumer-rules.pro`, `src/main/AndroidManifest.xml` | New library module |
| `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroNative.kt` | JNI facade object |
| `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroWire.kt` | Reply decoders and Kotlin value types |
| `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroCameraAdapter.kt` | Kotlin twin of the adapter contract |
| `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroTakeStatus.kt` | Kotlin twin of status mapping |
| `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/*.kt` | JVM tests |
| `Android/gyro/api/gyro.api` | ABI snapshot |
| `docs/gyro/README.md` | Area guide (module map, boundaries, JNI contract) |

Modified: `Package.swift`, `Android/settings.gradle.kts`, `atlas/repos/opencine/meta.json`, `AGENTS.md` (Boundaries and Area rules bullets), `atlas/api/swift/OpenCineGyro.txt`, `atlas/api/swift/OpenCineGyroAndroid.txt` (generated).

Source of moved files: `git -C ../OpenZCine show origin/main:<path>` (read-only; never modify that checkout). Moved code keeps its doc comments; edit only what the task names.

---

### Task 1: OpenCineGyro module with the moved engine

**Files:**

- Create: `Sources/OpenCineGyro/{GyroLog,GyroTakeSession,GyroGCSV,GyroMountCalibration,GyroMountCalibrationSession,GyroCameraGravity,GyroMountPreset}.swift` (moved from OpenZCine `Sources/OpenZCineCore/`)
- Create: `Tests/OpenCineGyroTests/{GyroLogTests,GyroMountCalibrationTests,GyroCameraGravityTests,GyroCalibrationExportTests,GyroMountTests}.swift` (moved from OpenZCine `Tests/OpenZCineCoreTests/`)
- Create: `Tests/OpenCineGyroTests/GyroSourceRulesTests.swift`
- Create: `Tests/OpenCineGyroTests/GyroTestRig.swift`: the private `rotate(_:axis:degrees:)` and `pose(_:axis:)` helpers of the moved `GyroMountCalibrationTests`, lifted into `enum GyroTestRig` (internal) with `static func rotate(_ v: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroVector3`, `static func pose(camera: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroCalibrationPose` (phone down = camera down rotated by the mount), and `static func solvedCalibration(axis: GyroVector3 = GyroVector3(x: 0.3, y: -0.5, z: 0.8), degrees: Double = 37) throws -> GyroMountCalibration` (solves level, 35 degree tilt-up and 30 degree tilt plus 25 degree lean poses). Tasks 3, 4 and 10 reuse it.
- Modify: `Package.swift` (product `OpenCineGyro`, target, test target), `atlas/repos/opencine/meta.json` (`products`, `layers.core` gains `OpenCineGyro`, `OpenCineGyroTests`)

**Interfaces:**

- Produces (all `public`):
  - `GyroLogDescriptor.init(id: UUID = UUID(), appName: String, cameraLabel: String, startDate: Date, approximateStartOffset: Double, isPartial: Bool, mountPreset: GyroMountPreset = .unconfigured, mountCalibration: GyroMountCalibration? = nil)`; new stored `writer: String?` (nil in legacy logs); `filename` becomes `"\(sanitizedAppName)-yyyyMMdd'T'HHmmss'Z'-\(UUID).gcsv"` where `sanitizedAppName` keeps `[A-Za-z0-9]` and falls back to `"Gyro"` when empty.
  - `GyroTakeSession.init(appName: String)`; `observeRecording(_ recording: Bool, at timestamp: Double, date: Date, cameraLabel: String, mountCalibration: GyroMountCalibration?) -> [GyroLogUpdate]` (the `mountPreset` parameter is removed; new takes are calibrated or `.unconfigured`).
  - `GyroGCSVEncoder.header(descriptor:)` writes `id,\(descriptor.writer ?? "OpenCine")`.
  - `GyroMountCalibration.mapping(_ vector: GyroVector3) -> GyroVector3` (the same rows `applying(to:)` uses).
  - `GyroVector3.angle(to:) -> Double` and `normalized() throws -> GyroVector3` become `public` (Tasks 3 and 4 and the Android wire use them).
  - `GyroMountPreset` keeps `rawValue`, `orientation`, `allCases`, Codable; `title`, `shortLabel`, `group`, `detail` are deleted (no preset UI remains). `GyroLogDescriptor.alignmentDetail` is deleted (UI copy owns this now).

- [ ] **Step 1: Copy the seven engine files and five test files from OpenZCine, change `@testable import OpenZCineCore` to `@testable import OpenCineGyro`, add the product and targets to `Package.swift`**

```swift
// products, Core area:
.library(name: "OpenCineGyro", targets: ["OpenCineGyro"]),
// targets, MARK: Core:
// Phone gyro capture for Gyroflow: take segmentation, GCSV, mount calibration, drift,
// stabilization save/restore and log storage. Foundation only; names no app or manufacturer.
.target(name: "OpenCineGyro"),
.testTarget(name: "OpenCineGyroTests", dependencies: ["OpenCineGyro"]),
```

Tests read repository files (the Task 7 fixture) through `#filePath`, like `MonitorSettingsCopyParityTests`.

- [ ] **Step 2: Write the failing tests for the host-value changes in `Tests/OpenCineGyroTests/GyroLogTests.swift`**

```swift
@Test func descriptorFilenameAndHeaderUseTheHostAppName() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let descriptor = GyroLogDescriptor(id: id, appName: "Example App!", cameraLabel: "Cam",
        startDate: date, approximateStartOffset: 2, isPartial: false)
    #expect(descriptor.filename == "ExampleApp-20231114T221320Z-00000000-0000-0000-0000-000000000001.gcsv")
    let header = String(decoding: GyroGCSVEncoder.header(descriptor: descriptor), as: UTF8.self)
    #expect(header.contains("\nid,ExampleApp\n"))
    #expect(header.contains("\norientation,XYZ\norientation_status,unverified\n"))
}

@Test func legacyDescriptorWithoutWriterDecodes() throws {
    // JSON written by OpenZCine before the move: no "writer" key, a manual preset, OpenZCine filename.
    let json = #"{"id":"00000000-0000-0000-0000-000000000002","cameraLabel":"Nikon ZR","startDate":720000000,"filename":"OpenZCine-20240101T000000Z-00000000-0000-0000-0000-000000000002.gcsv","approximateStartOffset":2,"isPartial":false,"mountPreset":"rearDown"}"#
    let descriptor = try JSONDecoder().decode(GyroLogDescriptor.self, from: Data(json.utf8))
    #expect(descriptor.writer == nil)
    #expect(descriptor.filename.hasPrefix("OpenZCine-"))
    #expect(descriptor.orientation == "YxZ")
}

@Test func calibrationMappingMatchesSampleRotation() throws {
    let calibration = try GyroTestRig.solvedCalibration()
    let sample = GyroSample(timestamp: 1, x: 0.1, y: -0.2, z: 0.3)
    let rotated = calibration.applying(to: sample)
    let mapped = calibration.mapping(GyroVector3(x: 0.1, y: -0.2, z: 0.3))
    #expect(abs(mapped.x - rotated.x) < 1e-12 && abs(mapped.y - rotated.y) < 1e-12 && abs(mapped.z - rotated.z) < 1e-12)
}
```

The legacy JSON test string names OpenZCine as stored content only (allowed: it is data, not a branch). Update the moved golden tests (`gyroEncoderDeclaresUnverifiedAxesAndUsesRadiansAndMicroseconds`, `gyroMetadataRoundTripsAndSanitizesTheCSVLabel`, the export tests) to construct `GyroTakeSession(appName: "ExampleApp")` and expect `id,ExampleApp`; delete assertions on preset labels and on `alignmentDetail`. Keep every other expected byte unchanged.

- [ ] **Step 3: Write `GyroSourceRulesTests` (imports, no app/manufacturer names, no mutable statics)**

Model it on `Tests/OpenCineFrameIOTests/FrameIOSourceRulesTests.swift`: every `import` line in `Sources/OpenCineGyro` is `import Foundation`; no file contains `static var`, `nonisolated(unsafe)`, `UserDefaults`, `Bundle.main`, `OpenZCine`, `OpenPocketCine`, `OpenInstaCine`, `Nikon`, `DJI`, `Insta360`; `Sources/OpenCineCore` and `Sources/OpenCineMedia` never mention `OpenCineGyro`.

- [ ] **Step 4: Run to verify the new tests fail**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter OpenCineGyroTests`
Expected: compile errors for `appName:`, `writer`, `mapping(_:)`.

- [ ] **Step 5: Implement the host-value changes listed under Interfaces**

`writer` is set from the sanitized app name in `GyroLogDescriptor.init`; `GyroTakeSession` stores `appName` and passes it to every descriptor. Remove `mountPreset` from `observeRecording` and from the take session's descriptor construction (`mountPreset: .unconfigured`). Make `angle(to:)` and `normalized()` public. Delete the preset label properties.

- [ ] **Step 6: Run the suite to verify it passes**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter OpenCineGyroTests`
Expected: PASS (all moved tests plus the three new ones and the rules suite).

- [ ] **Step 7: Register the module in the atlas and check**

Add `{"name": "OpenCineGyro", "kind": "swift-library", "manifest": "Package.swift"}` to `products` and `OpenCineGyro`, `OpenCineGyroTests` to `layers.core` in `atlas/repos/opencine/meta.json`.
Run: `python3 atlas/tools/atlas.py check`
Expected: no FORBIDDEN lines, exit 0.

- [ ] **Step 8: Commit**

```bash
git add Package.swift atlas/repos/opencine/meta.json Sources/OpenCineGyro Tests/OpenCineGyroTests
git commit -m "feat(gyro): move the gyro engine from OpenZCine into OpenCineGyro"
```

---

### Task 2: Mount-moved marks in takes and summaries

**Files:**

- Modify: `Sources/OpenCineGyro/GyroLog.swift`, `Sources/OpenCineGyro/GyroTakeSession.swift`, `Sources/OpenCineGyro/GyroGCSV.swift`
- Test: `Tests/OpenCineGyroTests/GyroMountMovedTests.swift`

**Interfaces:**

- Consumes: `GyroTakeSession` from Task 1.
- Produces:
  - `GyroLogUpdate.mountMoved(id: UUID, offsetSeconds: Double)` (new case; stores persist it immediately, see Task 8).
  - `GyroLogSummary.mountMovedOffset: Double?` (seconds after observed REC start; synthesized Codable decodes nil from legacy JSON).
  - `GyroTakeSession.observeMountMoved(at timestamp: Double) -> [GyroLogUpdate]`
  - `GyroGCSVRecovery.finish(descriptor: GyroLogDescriptor, mountMovedOffset: Double? = nil) throws -> GyroLogSummary`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GyroMountMovedTests {
    @Test func markIsRelativeToObservedRecStartAndOnlyFirstCounts() throws {
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.ingest((0..<500).map { GyroSample(timestamp: Double($0) / 100, x: 0, y: 0, z: 0) })
        let opened = session.observeRecording(true, at: 3, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        let id = try #require(opened.compactMap { if case .opened(let d) = $0 { d.id } else { nil } }.first)
        #expect(session.observeMountMoved(at: 4.25) == [.mountMoved(id: id, offsetSeconds: 1.25)])
        #expect(session.observeMountMoved(at: 4.5).isEmpty)
        _ = session.observeRecording(false, at: 5, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        let finished = session.finish(reason: .disabled)
        let summary = try #require(finished.compactMap { if case .finished(let s) = $0 { s } else { nil } }.first)
        #expect(summary.mountMovedOffset == 1.25)
    }

    @Test func noOpenRecordingTakeMeansNoMark() {
        var session = GyroTakeSession(appName: "ExampleApp")
        #expect(session.observeMountMoved(at: 1).isEmpty)
    }

    @Test func postrollTakeDoesNotTakeAMark() throws {
        // After REC stops the take is in postroll (endTimestamp set): a later mark is ignored.
        var session = GyroTakeSession(appName: "ExampleApp")
        _ = session.ingest((0..<300).map { GyroSample(timestamp: Double($0) / 100, x: 0, y: 0, z: 0) })
        _ = session.observeRecording(true, at: 1, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        _ = session.observeRecording(false, at: 2, date: .now, cameraLabel: "Cam", mountCalibration: nil)
        #expect(session.observeMountMoved(at: 2.5).isEmpty)
    }

    @Test func legacySummaryJSONDecodesWithoutTheMark() throws {
        // Encode a summary, strip "mountMovedOffset", decode again: nil, no throw.
    }

    @Test func recoveryCarriesAnExternallySuppliedMark() throws {
        // Feed a valid header plus two rows to GyroGCSVRecovery, finish(descriptor:mountMovedOffset: 0.5).
        // Expect summary.termination == .recovered and summary.mountMovedOffset == 0.5.
    }
}
```

Write the bodies of the last two tests with the same fixtures `GyroLogTests` already uses for recovery and summaries.

- [ ] **Step 2: Run to verify failure**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter GyroMountMovedTests`
Expected: compile failure on `observeMountMoved` and `.mountMoved`.

- [ ] **Step 3: Implement**

`Take` gains `var mountMovedOffset: Double?`. `observeMountMoved(at:)` returns updates for takes with `endTimestamp == nil` and `mountMovedOffset == nil`; offset is `max(0, timestamp - (origin + descriptor.approximateStartOffset))` rounded to milliseconds. `GyroStatistics.summary(...)` gains a `mountMovedOffset: Double? = nil` parameter forwarded into `GyroLogSummary`. Ignore non-finite timestamps and finished sessions.

- [ ] **Step 4: Run to verify pass**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter OpenCineGyroTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro Tests/OpenCineGyroTests/GyroMountMovedTests.swift
git commit -m "feat(gyro): record the first mount-moved moment of a take"
```

---

### Task 3: Drift detector

**Files:**

- Create: `Sources/OpenCineGyro/GyroDriftDetector.swift`
- Test: `Tests/OpenCineGyroTests/GyroDriftDetectorTests.swift`

**Interfaces:**

- Consumes: `GyroMountCalibration.mapping(_:)`, `GyroVector3.angle(to:)`.
- Produces:

```swift
public struct GyroDriftReading: Equatable, Sendable {
    public let timestamp: Double          // phone monotonic seconds
    public let phoneDown: GyroVector3     // physical down in phone axes (gravity direction)
    public let rotationRate: Double       // |angular velocity|, rad/s
    public let accelerationG: Double      // |specific force| in g (gravity plus user acceleration)
    public init(timestamp: Double, phoneDown: GyroVector3, rotationRate: Double, accelerationG: Double)
}
public struct GyroDriftDetector: Sendable {
    public static let thresholdDegrees = 2.5
    public static let holdSeconds = 1.0
    public static let steadyRotationRate = 0.05        // rad/s
    public static let steadyAccelerationToleranceG = 0.03
    public static let cameraFreshness = 0.25           // s
    public static let maximumSteadyGap = 0.25          // s between steady readings
    public init(calibration: GyroMountCalibration, thresholdDegrees: Double = Self.thresholdDegrees)
    public private(set) var hasDrifted: Bool
    public mutating func observeCamera(down: GyroVector3?, at timestamp: Double)
    /// True exactly once: on the reading that completes `holdSeconds` of steady disagreement.
    public mutating func observePhone(_ reading: GyroDriftReading) -> Bool
    public mutating func reset()
}
```

Rule (the spec leaves tolerances to the builder; these are this plan's values): a reading is steady when `rotationRate < steadyRotationRate` and `abs(accelerationG - 1) <= steadyAccelerationToleranceG`; it is comparable when the newest camera down is non-nil and `0 <= reading.timestamp - cameraTimestamp <= cameraFreshness`. A steady comparable reading disagrees when `calibration.mapping(phoneDown).angle(to: cameraDown) > threshold`. The disagreement run starts at the first disagreeing reading, resets on an agreeing steady comparable reading, on a camera reading of nil, or when two steady comparable readings are more than `maximumSteadyGap` apart; non-steady readings neither extend nor reset it. Drift is confirmed when the run spans at least `holdSeconds`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GyroDriftDetectorTests {
    // Helpers: `GyroTestRig.solvedCalibration()` with its mount rotation; `aligned(t)` feeds a camera
    // down of (-1, 0, 0) and the phone down that the mount rotation maps onto it; `tilted(t, degrees:)`
    // rotates only the phone down by `degrees` about the camera's left axis (0, 1, 0).
    @Test func sustainedSteadyDisagreementConfirmsOnceAfterOneSecond() { /* 3 degrees, readings every 0.02 s:
        returns false until t - t0 >= 1.0, then true once, then false; hasDrifted == true */ }
    @Test func belowThresholdNeverConfirms() { /* 2.4 degrees for 5 s -> never true */ }
    @Test func movingReadingsAreIgnored() { /* 10 degrees but rotationRate 0.2 -> never true */ }
    @Test func accelerationAwayFromOneGIsNotSteady() { /* accelerationG 1.1 -> never true */ }
    @Test func agreementResetsTheRun() { /* 0.8 s disagree, one agreeing steady reading, 0.8 s disagree -> false */ }
    @Test func staleCameraReadingNeverConfirmsDrift() { /* camera observed once at t=0, phone disagreeing t=0...3 -> false */ }
    @Test func gapBetweenSteadyReadingsRestartsTheRun() { /* readings at 0...0.6, then 0.9...1.4 -> false at 1.4 */ }
    @Test func resetClearsDriftedState() { }
}
```

Fill in each body with explicit loops and `#expect` on the returned Bool and `hasDrifted`, using the stated numbers.

- [ ] **Step 2: Run to verify failure**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter GyroDriftDetectorTests`
Expected: compile failure, `GyroDriftDetector` not found.

- [ ] **Step 3: Implement `GyroDriftDetector` per the rule above**

- [ ] **Step 4: Run to verify pass**

Same command. Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroDriftDetector.swift Tests/OpenCineGyroTests/GyroDriftDetectorTests.swift
git commit -m "feat(gyro): detect a mount that moved during steady moments"
```

---

### Task 4: Ring calibration controller

**Files:**

- Create: `Sources/OpenCineGyro/GyroRingCalibration.swift`
- Test: `Tests/OpenCineGyroTests/GyroRingCalibrationTests.swift`

**Interfaces:**

- Consumes: `GyroMountCalibrationSession`, `GyroMountCalibration.validatePair` (internal, same module), `GyroMountCalibrationError`.
- Produces:

```swift
public enum GyroRingStep: Int, CaseIterable, Sendable { case level = 0, tiltUp, tiltAndLean }
public enum GyroCalibrationBlock: String, Sendable { case cameraDisconnected, recording, moving, waitingForCamera }
public enum GyroCalibrationInvalidation: String, Sendable { case cameraChanged, recordingStarted, connectionEnded }
public enum GyroRingPhase: Equatable, Sendable {
    case intro
    case posing(step: GyroRingStep, inZone: Bool, hold: Double)   // hold 0...1, fills over holdSeconds
    case blocked(step: GyroRingStep, reason: GyroCalibrationBlock)
    case retrying                                                   // verification failed; restarted at .level
    case invalidated(GyroCalibrationInvalidation)
    case complete(GyroMountCalibration)
}
public enum GyroRingEvent: Equatable, Sendable { case stepCaptured(GyroRingStep), verificationFailed, completed(GyroMountCalibration) }
public struct GyroRingCalibration: Sendable {
    public static let holdSeconds = 2.0
    public init()
    public private(set) var phase: GyroRingPhase          // starts .intro
    public var completedSteps: Int { get }                // 0...3, drives the three progress dots
    public mutating func start(cameraConnected: Bool, recording: Bool?)
    public mutating func updateCamera(connected: Bool, recording: Bool?)
    public mutating func observe(phoneDown: GyroVector3, phoneTimestamp: Double,
                                 cameraDown: GyroVector3?, cameraTimestamp: Double?) -> GyroRingEvent?
    public mutating func invalidate(_ reason: GyroCalibrationInvalidation)
    public mutating func cancel()                          // back to .intro, session reset
}
```

Behavior (target zones and stillness are the builder's call; these keep the solver's acceptance with margin):

- Camera basis is up/left/backward, so a level camera's down is `(-1, 0, 0)`.
- `level` zone: camera down within 12 degrees of `(-1, 0, 0)`.
- `tiltUp` zone: angle between camera down and the captured level pose's camera down in `25...150` degrees.
- `tiltAndLean` zone: camera down has a component of at least `sin(18 degrees)` along both the second and third basis vectors of the first two camera poses (the solver's mixed check needs 15 degrees).
- Hold: while in zone, `hold = (phoneTimestamp - holdStart) / holdSeconds`, where `holdStart` is the first in-zone reading since the window became still (all phone downs in the last 1.5 s within 3 degrees of their mean). Leaving the zone resets `hold` to 0. In zone but not still shows `.blocked(step, .moving)` ("Hold steadier").
- At `hold >= 1` call `session.capture(at: phoneTimestamp)`: success -> `.stepCaptured(step)` and the next step at `hold 0` (or `.completed` and `.complete` after step 3). `.moving` -> blocked moving, hold reset. `.staleReadings` or `.insufficientReadings` -> stay at `hold 1` and retry on the next reading. `.insufficientSeparation` or `.inconsistentPoses` on step 2 -> hold reset, stay on step 2. `.validationMismatch`, `.unmixedValidation` or `.inconsistentPoses` on step 3 -> event `.verificationFailed`, session reset, phase `.retrying`; the next `observe` moves to `.posing(.level, ...)`.
- Blocks, checked first on every call: not connected -> `.cameraDisconnected`; `recording == true` -> `.recording`; `cameraDown == nil` or `phoneTimestamp - cameraTimestamp > 0.25` -> `.waitingForCamera` (and `session.invalidateReadings()`).
- `invalidate(_:)` resets the session and sets `.invalidated(reason)`; `start` from any phase resets and begins at `.posing(.level, inZone: false, hold: 0)` unless blocked.
- Every reading is forwarded to `session.add(...)` when not blocked.

- [ ] **Step 1: Write the failing tests**

Build a `RingRig` test helper on top of `GyroTestRig`: a fixed mount rotation (default `GyroTestRig`'s axis and angle), a manual clock stepping 1/30 s, and `hold(cameraDown:seconds:)` that feeds matching phone and camera downs (`GyroTestRig.rotate`) and collects returned events. Tests:

```swift
@Suite struct GyroRingCalibrationTests {
    @Test func threeHeldPosesCompleteWithAVerifiedCalibration() { /* level, tilt 35 deg, tilt 30 + lean 25:
        events == [.stepCaptured(.level), .stepCaptured(.tiltUp), .completed(_)], completedSteps == 3 */ }
    @Test func holdFillsOverTwoSecondsAndResetsWhenLeavingTheZone() { /* hold ~0.5 at 1 s; leave zone -> 0 */ }
    @Test func notInZoneNeverCaptures() { /* camera pitched 40 deg at step 1 for 5 s -> phase posing(.level, inZone: false, hold: 0) */ }
    @Test func shakingInZoneShowsHoldSteadier() { /* alternate +-5 deg phone noise -> .blocked(.level, .moving) */ }
    @Test func missingOrStaleCameraShowsWaitingForCamera() { }
    @Test func recordingAndDisconnectBlock() { }
    @Test func verificationFailureRestartsFromLevel() { /* third pose without lean -> .verificationFailed, then .posing(.level, ...) and completedSteps == 0 */ }
    @Test func invalidationStopsAndStartRestarts() { }
    @Test func ringCompletesWithPhoneMountedSideways() { /* true rotation includes a 90 deg turn about the lens axis */ }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter GyroRingCalibrationTests`
Expected: compile failure.

- [ ] **Step 3: Implement `GyroRingCalibration` per the behavior list**

- [ ] **Step 4: Run to verify pass**

Same command. Expected: 9 tests PASS. Then the full `OpenCineGyroTests` filter still passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroRingCalibration.swift Tests/OpenCineGyroTests/GyroRingCalibrationTests.swift
git commit -m "feat(gyro): automatic three-pose ring calibration"
```

---

### Task 5: Camera adapter contract and stabilization values

**Files:**

- Create: `Sources/OpenCineGyro/GyroCameraAdapter.swift`
- Test: `Tests/OpenCineGyroTests/GyroCameraAdapterTests.swift`

**Interfaces:**

- Produces:

```swift
public struct GyroCameraIdentity: Hashable, Codable, Sendable {
    public let id: String      // stable per body: used for calibrations and pending restores
    public let name: String    // shown on log rows
    public init(id: String, name: String)
}
public struct GyroStabilizationSetting: Hashable, Codable, Sendable {
    public let key: String     // adapter-owned, e.g. an in-body VR or electronic VR key
    public let title: String
    public let offValue: String
    public init(key: String, title: String, offValue: String)
}
public struct GyroStabilizationState: Equatable, Codable, Sendable {
    public let values: [String: String]   // key -> current value; a missing key is unknown
    public let lensHasVRSwitch: Bool?     // nil when not knowable
    public init(values: [String: String], lensHasVRSwitch: Bool?)
    /// nil when no setting's value is known; true when every known value equals its offValue.
    public func isOff(_ settings: [GyroStabilizationSetting]) -> Bool?
}
public enum GyroCameraEvent: Equatable, Sendable {
    case connected(GyroCameraIdentity)
    case disconnected
    case recording(Bool?, at: Double)          // phone monotonic seconds
    case level(GyroVector3?, at: Double)       // camera down in up/left/backward axes; nil = no reading
    case stabilization(GyroStabilizationState?)
    case videoMode(Bool?)                      // camera in movie mode; nil = unknown
}
@MainActor public protocol GyroCameraSink: AnyObject { func receive(_ event: GyroCameraEvent) }
@MainActor public protocol GyroCameraAdapter: AnyObject {
    /// False when the camera has no level sensor: logging works, calibration and drift are hidden.
    var providesLevel: Bool { get }
    /// Empty when the camera exposes no stabilization control.
    var stabilizationSettings: [GyroStabilizationSetting] { get }
    func attach(_ sink: any GyroCameraSink)
    func detach()
    /// Writes the given key -> value pairs; true only when the camera accepted every write.
    func writeStabilization(_ values: [String: String]) async -> Bool
}
```

The Kotlin twin (Task 11) uses flows instead of a sink; the value types keep the same names and fields.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GyroCameraAdapterTests {
    let settings = [GyroStabilizationSetting(key: "ibis", title: "IBIS", offValue: "OFF"),
                    GyroStabilizationSetting(key: "evr", title: "Electronic VR", offValue: "OFF")]
    @Test func isOffIsNilWhenNothingIsKnown() { #expect(GyroStabilizationState(values: [:], lensHasVRSwitch: nil).isOff(settings) == nil) }
    @Test func isOffIsTrueOnlyWhenEveryKnownValueIsOff() {
        #expect(GyroStabilizationState(values: ["ibis": "OFF"], lensHasVRSwitch: nil).isOff(settings) == true)
        #expect(GyroStabilizationState(values: ["ibis": "OFF", "evr": "ON"], lensHasVRSwitch: nil).isOff(settings) == false)
        #expect(GyroStabilizationState(values: ["ibis": "SPORT"], lensHasVRSwitch: nil).isOff(settings) == false)
    }
    @Test func unknownKeysAreIgnored() { #expect(GyroStabilizationState(values: ["other": "ON"], lensHasVRSwitch: nil).isOff(settings) == nil) }
    @Test func valuesRoundTripThroughJSON() throws { /* encode/decode identity and state */ }
}
```

- [ ] **Step 2: Run to verify failure**, `--filter GyroCameraAdapterTests`; expected compile failure.
- [ ] **Step 3: Implement the types.**
- [ ] **Step 4: Run to verify pass**; expected 4 tests PASS.
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroCameraAdapter.swift Tests/OpenCineGyroTests/GyroCameraAdapterTests.swift
git commit -m "feat(gyro): camera adapter contract for gyro capture"
```

---

### Task 6: Session arming and stabilization save/restore machine

**Files:**

- Create: `Sources/OpenCineGyro/GyroArming.swift`
- Test: `Tests/OpenCineGyroTests/GyroArmingMachineTests.swift`

**Interfaces:**

- Consumes: Task 5 types.
- Produces:

```swift
public struct GyroPendingRestore: Codable, Equatable, Sendable {
    public let cameraID: String
    public let saved: [String: String]     // values before the app turned stabilization off
    public let applied: [String: String]   // values the app wrote (each setting's offValue)
}
public enum GyroArmingStep: Equatable, Sendable {
    case stabilization(lensHasVRSwitch: Bool?)
    case calibration(hasSavedCalibration: Bool)
}
public enum GyroWritePurpose: String, Codable, Sendable { case turnOff, restore }
public enum GyroArmingNotice: String, Codable, Sendable { case turnOffFailed, restoreFailed }
public enum GyroArmingEffect: Equatable, Sendable {
    case writeStabilization([String: String], purpose: GyroWritePurpose)
    case presentSetup([GyroArmingStep])
    case persistPendingRestores([GyroPendingRestore])
    case sessionStarted
    case sessionEnded
    case notice(GyroArmingNotice)
}
public struct GyroArmingInputs: Equatable, Sendable {
    public var toggleOn: Bool
    public var camera: GyroCameraIdentity?        // nil = not connected
    public var hostEligible: Bool                 // monitor showing, app in front, no multicam or relay
    public var videoMode: Bool?
    public var recording: Bool?
    public var stabilization: GyroStabilizationState?
    public var settings: [GyroStabilizationSetting]
    public var providesLevel: Bool
    public var hasSavedCalibration: Bool
    public init(...)                              // memberwise, all parameters
}
public struct GyroArmingMachine: Sendable {
    public init(pendingRestores: [GyroPendingRestore])
    public private(set) var isArmed: Bool
    public private(set) var stabilizationWarning: Bool
    public private(set) var pendingRestores: [GyroPendingRestore]
    public mutating func update(_ inputs: GyroArmingInputs) -> [GyroArmingEffect]
    public mutating func chooseTurnOff() -> [GyroArmingEffect]
    public mutating func chooseKeepOn() -> [GyroArmingEffect]
    public mutating func writeFinished(_ purpose: GyroWritePurpose, succeeded: Bool) -> [GyroArmingEffect]
}
```

Rules (owner decision 1 plus the coordinator's calls in spec sections 1 and 5):

1. `eligible = toggleOn && camera != nil && hostEligible && videoMode == true`.
2. **Owed restore first.** When a camera connects and a pending restore exists for its id, nothing else happens (no session start) until it resolves. Wait for a non-nil `stabilization` and `recording != true`, then emit `.writeStabilization(r, .restore)` with `r = saved[key]` for every key whose current value equals `applied[key]`. Keys whose current value differs, or is missing, are dropped (the user changed them; leave them alone). If `r` is empty, drop the pending restore and emit `.persistPendingRestores`. On `writeFinished(.restore, true)`: remove it, persist. On failure: keep it, emit `.notice(.restoreFailed)`, and do not retry until the next connection.
3. **Session start** when eligible and no restore is in flight: `isArmed = true`, `.sessionStarted`, then `.presentSetup(steps)` where steps are `.stabilization(lensHasVRSwitch:)` if `settings` is non-empty and `stabilization?.isOff(settings) == false`, followed by `.calibration(hasSavedCalibration:)` if `providesLevel`. Omit `.presentSetup` when steps are empty. If `recording == true` at start, defer `.presentSetup` until the first update with `recording == false` in the same session.
4. `chooseTurnOff()`: build a pending restore for keys whose current value is known and not already off (`saved` = current, `applied` = offValue), add it, emit `.persistPendingRestores` before `.writeStabilization(applied, .turnOff)` so a crash still owes the restore. `writeFinished(.turnOff, true)` clears `stabilizationWarning`; failure sets it and emits `.notice(.turnOffFailed)` (the pending restore stays; rule 2 only restores keys still at the applied value, so it is safe).
5. `chooseKeepOn()`: `stabilizationWarning = true`. Any later update where `isOff(settings) == true` clears it.
6. **Session end while connected** (eligible becomes false and `camera` is still the same id): `isArmed = false`, `.sessionEnded`, then the restore per rule 2 for that camera (deferred while recording).
7. **Link drop** (`camera` becomes nil while armed): `.sessionEnded`, pending restore stays (already persisted).
8. A different camera id connecting is a new connection: rule 2 runs for that id.

- [ ] **Step 1: Write the failing tests** (each asserts the exact effect array)

```swift
@Suite struct GyroArmingMachineTests {
    @Test func armingWithIbisOnOffersTheStabilizationStepThenCalibration() { }
    @Test func stabilizationAlreadyOffSkipsTheStep() { }
    @Test func unknownStabilizationSkipsTheStep() { }
    @Test func cameraWithoutLevelSkipsCalibration() { }
    @Test func turnOffPersistsTheRestoreBeforeWriting() { /* effects == [.persistPendingRestores([r]), .writeStabilization(["ibis":"OFF"], purpose: .turnOff)] */ }
    @Test func keepOnSetsTheWarningUntilTheCameraReportsOff() { }
    @Test func sessionEndRestoresExactSavedValues() { /* saved SPORT -> writes ["ibis":"SPORT"], not ON */ }
    @Test func owedRestoreSkipsKeysTheUserChanged() { /* applied OFF, camera now ON -> no write for that key */ }
    @Test func linkDropKeepsTheRestoreOwedAndNextConnectionRestoresFirst() { /* toggle still on: restore effect precedes .sessionStarted */ }
    @Test func failedRestoreIsNotRetriedInTheSameConnection() { }
    @Test func recordingAtStartDefersTheSetupSheet() { }
    @Test func restoreWaitsForRecordingToStop() { }
    @Test func photoModeEndsTheSessionAndRestores() { }
}
```

- [ ] **Step 2: Run to verify failure**, `--filter GyroArmingMachineTests`; expected compile failure.
- [ ] **Step 3: Implement `GyroArmingMachine` per the rules.**
- [ ] **Step 4: Run to verify pass**; expected 13 tests PASS.
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroArming.swift Tests/OpenCineGyroTests/GyroArmingMachineTests.swift
git commit -m "feat(gyro): session arming with exact stabilization restore"
```

---

### Task 7: Take status mapping and shared vectors

**Files:**

- Create: `Sources/OpenCineGyro/GyroTakeStatus.swift`, `Fixtures/gyro-take-status-vectors.tsv`
- Test: `Tests/OpenCineGyroTests/GyroTakeStatusTests.swift`

**Interfaces:**

- Produces:

```swift
public enum GyroTakeStatus: Equatable, Sendable {
    case recording, mountMoved(offsetSeconds: Double), cutShort, smallGaps, notCalibrated, ready
    public static func resolve(descriptor: GyroLogDescriptor, summary: GyroLogSummary?, active: Bool) -> GyroTakeStatus
}
```

Precedence (this plan's call; the spec lists the badges but not their order, and decision 2 adds Not calibrated): `recording` (active) > `mountMoved` (summary has `mountMovedOffset`) > `cutShort` (no summary while inactive, `termination != .normal`, or `descriptor.isPartial`) > `smallGaps` (`summary.isPartial`, `hasGapWarning` or `rejectedSampleCount > 0`) > `notCalibrated` (`descriptor.mountCalibration == nil`, which includes legacy manual-preset logs) > `ready`.

Fixture columns (tab-separated, header row): `active hasSummary termination descriptorPartial summaryPartial largestGapMs rejected calibrated mountMovedOffset expected`, with `expected` one of `recording, mountMoved:<s>, cutShort, smallGaps, notCalibrated, ready`. Include at least 14 rows covering every precedence pair, a recovered take, an incomplete file, a 50 ms gap (not a gap) and a 51 ms gap.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GyroTakeStatusTests {
    @Test func everySharedVectorResolves() throws { /* parse the TSV, build descriptor/summary through JSON, compare */ }
    @Test func legacyPresetLogMapsToNotCalibrated() throws { /* legacy JSON from Task 1 plus a complete summary -> .notCalibrated */ }
}
```

Build descriptors and summaries by decoding JSON (the summary has no public init) so the Kotlin twin can use the same construction.

- [ ] **Step 2: Run to verify failure**, `--filter GyroTakeStatusTests`.
- [ ] **Step 3: Implement `resolve`.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroTakeStatus.swift Fixtures/gyro-take-status-vectors.tsv Tests/OpenCineGyroTests/GyroTakeStatusTests.swift
git commit -m "feat(gyro): plain take status with shared vectors"
```

---

### Task 8: Log file store

**Files:**

- Create: `Sources/OpenCineGyro/GyroLogStore.swift` (moved from OpenZCine `ios/Runner/GyroLogStore.swift`)
- Test: `Tests/OpenCineGyroTests/GyroLogStoreTests.swift` (the storage cases of OpenZCine `ios/RunnerTests/GyroLogStoreTests.swift`, rewritten against a temporary directory; the share-bridge UTType case moves to Plan 2)

**Interfaces:**

- Consumes: `GyroLogUpdate` (with `.mountMoved`), `GyroGCSVRecovery.finish(descriptor:mountMovedOffset:)`, `GyroTakeStatus`.
- Produces (now `public`): `GyroLogEntry` (adds `public var status: GyroTakeStatus` and `public var canShare: Bool` = summary present and not active), `GyroLogRecoveryResult`, `protocol GyroLogStoring: Sendable` with `load()`, `apply(_:at:)`, `abort()`, `share(_ ids: [UUID]) async throws -> [URL]`, `delete(_ id: UUID)`, `GyroStoreError`, `actor GyroLogStore(directory: URL)` (directory is required; no default path).
- On-disk layout is unchanged from OpenZCine iOS so existing logs load in place: `<directory>/<UUID>/descriptor.json`, `summary.json`, `capture.gcsv.part`, `<descriptor.filename>`. New: `mount-moved.json` (`{"offsetSeconds": Double}`) written atomically on `.mountMoved`; `complete(_:)` and recovery merge it into the summary when the summary lacks `mountMovedOffset`.
- `share(_ ids:)` copies each finished file into `temporaryDirectory/GyroShare/<UUID>/` as today and throws `GyroStoreError.active` or `.missing` if any id cannot be shared (no partial share).

- [ ] **Step 1: Write the failing tests** (moved cases plus)

```swift
@Test func mountMovedIsPersistedImmediatelyAndMergedOnFinish() async throws { }
@Test func recoveryMergesTheMountMovedSidecar() async throws { /* open, append rows, mountMoved, abort without finish; new store load -> entry.summary?.mountMovedOffset == 1.25, status == .mountMoved(offsetSeconds: 1.25) */ }
@Test func sharingSeveralTakesReturnsOneURLPerTake() async throws { }
@Test func sharingRefusesWhenAnyTakeIsActive() async throws { }
@Test func legacyLayoutLoadsInPlace() async throws { /* write an OpenZCine-shaped folder by hand: descriptor without writer, finished file named OpenZCine-...gcsv, summary.json -> load returns it */ }
```

- [ ] **Step 2: Run to verify failure**, `--filter GyroLogStoreTests`.
- [ ] **Step 3: Move the actor, make the listed members public, add the sidecar and multi-share.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroLogStore.swift Tests/OpenCineGyroTests/GyroLogStoreTests.swift
git commit -m "feat(gyro): durable log store with mount-moved marks and batch share"
```

---

### Task 9: Preferences, per-camera calibrations and legacy migration

**Files:**

- Create: `Sources/OpenCineGyro/GyroPreferences.swift`
- Test: `Tests/OpenCineGyroTests/GyroPreferencesTests.swift`

**Interfaces:**

- Produces:

```swift
public protocol GyroKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}
public struct GyroPreferenceKeys: Equatable, Sendable {
    public let enabled, calibrations, pendingRestores, tipDismissed, legacyCalibration, migrated: String
    public static func namespaced(_ prefix: String) -> GyroPreferenceKeys   // prefix + "enabled", ...
}
public struct GyroLegacyPreferenceKeys: Equatable, Sendable {
    public let enabled: String; public let mountPreset: String; public let calibration: String
    public init(enabled: String, mountPreset: String, calibration: String)
}
public final class GyroPreferences {
    public init(store: any GyroKeyValueStore, keys: GyroPreferenceKeys, legacy: GyroLegacyPreferenceKeys?)
    public var enabled: Bool
    public var tipDismissed: Bool
    public var pendingRestores: [GyroPendingRestore]
    public func calibration(for cameraID: String) -> GyroMountCalibration?
    public func saveCalibration(_ calibration: GyroMountCalibration, for cameraID: String)
}
```

All values are stored as JSON `Data` (Bool as `true`/`false` JSON) so the Android twin (Plan 3) can store the same payloads as strings. Migration (the spec leaves mechanics to the builder; this plan's calls, mirroring section 3's "migrated to not calibrated"):

- Runs once in `init` when `legacy != nil` and `keys.migrated` is absent. Legacy `enabled` (stored by the host as a Bool) is read through `store.data`; the host's `GyroKeyValueStore` conformance must return legacy Bool keys as JSON `true`/`false` (Plan 2 and 3 adapters do this).
- `legacy.mountPreset` is deleted (presets become "not calibrated").
- A valid legacy calibration moves to `keys.legacyCalibration`; `calibration(for:)` adopts it for the first camera id that asks while it has none saved, then deletes the legacy slot (the old calibration was global; OpenZCine users have one body).
- Invalid stored calibrations decode to nil and are removed.

- [ ] **Step 1: Write the failing tests** with an in-memory `GyroKeyValueStore`

```swift
@Suite struct GyroPreferencesTests {
    @Test func calibrationsAreStoredPerCamera() { }
    @Test func pendingRestoresRoundTrip() { }
    @Test func legacyEnabledIsKeptAndPresetIsDropped() { }
    @Test func legacyCalibrationIsAdoptedByTheFirstCameraOnly() { }
    @Test func migrationRunsOnce() { }
    @Test func corruptCalibrationReadsAsNotCalibrated() { }
}
```

- [ ] **Step 2: Run to verify failure**, `--filter GyroPreferencesTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineGyro/GyroPreferences.swift Tests/OpenCineGyroTests/GyroPreferencesTests.swift
git commit -m "feat(gyro): per-camera calibration preferences with legacy migration"
```

---

### Task 10: OpenCineGyroAndroid wires and JNI exports

**Files:**

- Create: `Sources/OpenCineGyroAndroid/GyroLoggingWire.swift` (moved from OpenZCine `Sources/OpenZCineAndroidFacade/GyroLoggingWire.swift`), `GyroRingCalibrationWire.swift`, `GyroDriftWire.swift`, `GyroArmingWire.swift`, `GyroNativeJNI.swift`
- Create: `Tests/OpenCineGyroAndroidTests/{GyroLoggingWireTests,GyroRingCalibrationWireTests,GyroDriftWireTests,GyroArmingWireTests}.swift` (the first moved from OpenZCine `Tests/OpenZCineAndroidFacadeTests/GyroLoggingWireTests.swift`)
- Modify: `Package.swift` (product `OpenCineGyroAndroid`, target depending on `OpenCineGyro`, `OpenCineJNISupport`; test target), `atlas/repos/opencine/meta.json` (`OpenCineGyroAndroid`, `OpenCineGyroAndroidTests` in `layers.vendor`; product)

**Interfaces:**

- Consumes: everything in Tasks 1 to 7.
- Produces (each wire is `public final class ... : @unchecked Sendable` with `static let shared`, an `NSLock` and an owner-keyed dictionary, like the moved logging wire; owners are UUID strings; a retired owner returns nil):
  - `GyroLoggingWire`: `create(appName:) -> String`, `ingest(owner:bytes:) -> String?` (32-byte little-endian `t,x,y,z` doubles, at most 512 samples), `observe(owner:recording:timestamp:dateSeconds:cameraLabel:calibrationJSON:) -> String?`, `mountMoved(owner:timestamp:) -> String?`, `poll`, `finish(owner:reason:)`, `close`, `recoveryCreate`, `recoveryAccept`, `recoveryFinish(owner:descriptorJSON:mountMovedOffset:)` (`Double.nan` = none). Reply JSON keeps OpenZCine's shape plus update kind `"mountMoved"` with `id` and `offsetSeconds`. `mountPresets` is deleted.
  - `GyroRingCalibrationWire`: `create() -> String`, `start(owner:cameraConnected:recording:)` (`recording` as `Int`: -1 unknown, 0, 1), `updateCamera(owner:connected:recording:)`, `observe(owner:phoneX:phoneY:phoneZ:phoneTimestamp:hasCameraLevel:rollDegrees:pitchDegrees:cameraTimestamp:) -> String?` (camera down computed with `GyroCameraGravity.down`), `invalidate(owner:reason:)`, `cancel(owner:)`, `close(owner:)`, `validate(calibrationJSON:) -> Bool`. Reply: `{"phase":"intro|posing|blocked|retrying|invalidated|complete","step":0..2|null,"inZone":Bool|null,"hold":Double|null,"block":String|null,"invalidation":String|null,"completedSteps":Int,"event":"stepCaptured|verificationFailed|completed"|null,"calibration":{...}|null}`.
  - `GyroDriftWire`: `create(calibrationJSON:) -> String?`, `observeCamera(owner:hasLevel:rollDegrees:pitchDegrees:timestamp:)`, `observePhone(owner:x:y:z:timestamp:rotationRate:accelerationG:) -> Bool`, `reset(owner:)`, `close(owner:)`.
  - `GyroArmingWire`: `create(pendingRestoresJSON:) -> String`, `update(owner:inputsJSON:) -> String?`, `chooseTurnOff(owner:)`, `chooseKeepOn(owner:)`, `writeFinished(owner:purpose:succeeded:) -> String?`, `close(owner:)`. Inputs JSON mirrors `GyroArmingInputs` field names. Reply: `{"effects":[...],"isArmed":Bool,"stabilizationWarning":Bool}` with effect objects `{"kind":"writeStabilization","purpose":"turnOff|restore","values":{...}}`, `{"kind":"presentSetup","steps":[{"kind":"stabilization","lensHasVRSwitch":Bool|null},{"kind":"calibration","hasSavedCalibration":Bool}]}`, `{"kind":"persistPendingRestores","restores":[...]}`, `{"kind":"sessionStarted"}`, `{"kind":"sessionEnded"}`, `{"kind":"notice","notice":"turnOffFailed|restoreFailed"}`.
  - `GyroNativeJNI.swift` (inside `#if os(Android)`): one `@_cdecl("Java_com_opencapture_opencine_gyro_GyroNative_<name>")` per wire method above, names `loggingCreate`, `loggingIngest`, `loggingObserve`, `loggingMountMoved`, `loggingPoll`, `loggingFinish`, `loggingClose`, `recoveryCreate`, `recoveryAccept`, `recoveryFinish`, `ringCreate`, `ringStart`, `ringUpdateCamera`, `ringObserve`, `ringInvalidate`, `ringCancel`, `ringClose`, `calibrationValidate`, `driftCreate`, `driftObserveCamera`, `driftObservePhone`, `driftReset`, `driftClose`, `armingCreate`, `armingUpdate`, `armingChooseTurnOff`, `armingChooseKeepOn`, `armingWriteFinished`, `armingClose`, plus `cameraDown(roll, pitch) -> String?` (JSON vector or null) for Kotlin adapters. Use `javaString`, `swiftString`, `swiftBytes` from `OpenCineJNISupport` exactly as the moved `GyroLoggingJNI.swift` does.

- [ ] **Step 1: Move the logging wire and its tests; update for `appName`, removed presets and `mountMoved`; write failing tests for the three new wires**

```swift
@Suite struct GyroRingCalibrationWireTests {
    @Test func observeRepliesWithPhaseAndCompletes() throws { /* drive the same RingRig poses as Task 4 through observe(...) and decode replies with JSONSerialization */ }
    @Test func missingCameraLevelRepliesWaitingForCamera() throws { }
    @Test func retiredOwnerReturnsNil() { }
}
@Suite struct GyroDriftWireTests {
    @Test func invalidCalibrationJSONReturnsNil() { }
    @Test func driftConfirmsThroughTheWire() { }
}
@Suite struct GyroArmingWireTests {
    @Test func effectsEncodeInOrder() throws { /* IBIS ON connect -> sessionStarted, presentSetup; turnOff -> persist, write */ }
    @Test func pendingRestoresSurviveAWireRoundTrip() throws { }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro --filter OpenCineGyroAndroidTests`
Expected: compile failure.

- [ ] **Step 3: Implement the wires and `GyroNativeJNI.swift`.**

- [ ] **Step 4: Run to verify pass**; same command, expected PASS. Then confirm the exports compile for Android if the Swift Android SDK is installed (`swift build --swift-sdk aarch64-unknown-linux-android28 --target OpenCineGyroAndroid` or the SDK name CI uses in `.github/workflows/ci.yml`); otherwise record "Android compile deferred to Plan 4's app build".

- [ ] **Step 5: Atlas and commit**

Run: `python3 atlas/tools/atlas.py check`. Expected: exit 0.

```bash
git add Package.swift atlas/repos/opencine/meta.json Sources/OpenCineGyroAndroid Tests/OpenCineGyroAndroidTests
git commit -m "feat(gyro): Android JNI wires for logging, calibration, drift and arming"
```

---

### Task 11: Android `:gyro` module (JNI facade, decoders, contract and status twins)

**Files:**

- Create: `Android/gyro/build.gradle.kts`, `Android/gyro/consumer-rules.pro`, `Android/gyro/src/main/AndroidManifest.xml`
- Create: `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/{GyroNative,GyroWire,GyroCameraAdapter,GyroTakeStatus}.kt`
- Create: `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/{GyroWireTest,GyroTakeStatusTest,GyroRulesTest}.kt`
- Create: `Android/gyro/api/gyro.api` (generated)
- Modify: `Android/settings.gradle.kts` (`":gyro"`), `atlas/repos/opencine/meta.json` (`":gyro"` in `layers.core`)

**Interfaces:**

- Consumes: the JNI names and JSON shapes from Task 10; the TSV from Task 7.
- Produces:
  - `object GyroNative { var isAvailable: Boolean; fun load(library: String): Boolean; external fun <every Task 10 export> }` mirroring `com.opencapture.opencine.frameio.FrameioNative` (load guarded by `UnsatisfiedLinkError`, `Log` wrapped in `runCatching`). `recording` parameters are `Int` (-1, 0, 1).
  - `interface GyroNativeApi` with the same members, implemented by `GyroNative` and by test fakes (Plan 3 coordinators take `GyroNativeApi`).
  - `GyroWire.kt`: `data class GyroLogUpdate` (sealed: `Opened(descriptor: JSONObject)`, `Appended(id: String, bytes: ByteArray)`, `Finished(summary: JSONObject)`, `MountMoved(id: String, offsetSeconds: Double)`), `fun decodeLogReply(json: String): GyroLogReply`; `data class GyroRingState(phase: GyroRingPhase, step: Int?, inZone: Boolean?, hold: Double?, block: GyroCalibrationBlock?, invalidation: GyroCalibrationInvalidation?, completedSteps: Int, event: GyroRingEvent?, calibrationJSON: String?)` with Kotlin enums named like Swift (`GyroRingPhase.INTRO, POSING, BLOCKED, RETRYING, INVALIDATED, COMPLETE`); `fun decodeRingReply(json: String): GyroRingState`; `sealed interface GyroArmingEffect` (`WriteStabilization(values: Map<String, String>, purpose: GyroWritePurpose)`, `PresentSetup(steps: List<GyroArmingStep>)`, `PersistPendingRestores(json: String)`, `SessionStarted`, `SessionEnded`, `Notice(notice: GyroArmingNotice)`), `data class GyroArmingReply(effects, isArmed, stabilizationWarning)`, `fun decodeArmingReply(json: String): GyroArmingReply`; `fun encodeArmingInputs(inputs: GyroArmingInputs): String`.
  - `GyroCameraAdapter.kt`:

```kotlin
data class GyroCameraIdentity(val id: String, val name: String)
data class GyroStabilizationSetting(val key: String, val title: String, val offValue: String)
data class GyroStabilizationState(val values: Map<String, String>, val lensHasVRSwitch: Boolean?)
data class GyroCameraLevel(val down: GyroVector3?, val timestampSeconds: Double)   // elapsedRealtime seconds
data class GyroVector3(val x: Double, val y: Double, val z: Double)
data class GyroArmingInputs(val toggleOn: Boolean, val camera: GyroCameraIdentity?, val hostEligible: Boolean,
    val videoMode: Boolean?, val recording: Boolean?, val stabilization: GyroStabilizationState?,
    val settings: List<GyroStabilizationSetting>, val providesLevel: Boolean, val hasSavedCalibration: Boolean)
interface GyroCameraAdapter {
    val identity: StateFlow<GyroCameraIdentity?>          // null = not connected
    val recording: StateFlow<Boolean?>
    val videoMode: StateFlow<Boolean?>
    val stabilization: StateFlow<GyroStabilizationState?>
    val level: Flow<GyroCameraLevel>
    val providesLevel: Boolean
    val stabilizationSettings: List<GyroStabilizationSetting>
    suspend fun writeStabilization(values: Map<String, String>): Boolean
}
```

- `GyroTakeStatus.kt`: `sealed interface GyroTakeStatus { Recording, MountMoved(offsetSeconds: Double), CutShort, SmallGaps, NotCalibrated, Ready }` and `fun resolveGyroTakeStatus(descriptor: JSONObject, summary: JSONObject?, active: Boolean): GyroTakeStatus` with Task 7's precedence (gap limit: `round(largestGap * 1_000_000) > 50_000`).
- `build.gradle.kts`: Android library, namespace `com.opencapture.opencine.gyro`, minSdk 29, JVM 17, `api(libs.kotlinx.coroutines.core)`, `testImplementation(libs.kotlin.test.junit)`, `testImplementation(libs.kotlinx.coroutines.test)`, `testImplementation(libs.json)`, and the `opencine.fixtures` system property block copied from `Android/camera-controls/build.gradle.kts`. No project dependencies (layer `core`).
- `consumer-rules.pro`: `-keep class com.opencapture.opencine.gyro.GyroNative { *; }`.

- [ ] **Step 1: Write the failing JVM tests**

```kotlin
class GyroTakeStatusTest {
    @Test fun everySharedVectorResolves() { /* read System.getProperty("opencine.fixtures") + "/gyro-take-status-vectors.tsv"; same JSON construction as the Swift test */ }
}
class GyroWireTest {
    @Test fun ringReplyDecodes() { /* literal JSON copied from GyroRingCalibrationWireTests' expected reply */ }
    @Test fun armingEffectsDecodeInOrder() { }
    @Test fun armingInputsEncodeTheSwiftFieldNames() { }
    @Test fun logReplyDecodesMountMoved() { }
}
class GyroRulesTest {
    @Test fun importsStayPlatformAndNameNoAppOrManufacturer() { /* imports start with android., kotlin., kotlinx., java., org.json.; no "openzcine", "Nikon", "DJI", "Insta360" */ }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1-android bash -c 'cd Android && ./gradlew :gyro:test'`
Expected: FAIL (unresolved references).

- [ ] **Step 3: Implement the module.**

- [ ] **Step 4: Run to verify pass**; same command. Expected: BUILD SUCCESSFUL, tests pass.

- [ ] **Step 5: ABI snapshot, lint, atlas**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1-android bash -c 'cd Android && ./gradlew updateKotlinAbi updateAndroidApi :gyro:lint'`
Then: `python3 atlas/tools/atlas.py check`. Expected: `Android/gyro/api/gyro.api` written; lint clean; atlas exit 0.

- [ ] **Step 6: Commit**

```bash
git add Android/settings.gradle.kts Android/gyro atlas/repos/opencine/meta.json
git commit -m "feat(gyro): Android gyro module with JNI facade and contract twins"
```

---

### Task 12: Boundaries, API snapshots and full verification

**Files:**

- Modify: `AGENTS.md` (Boundaries: one bullet for `OpenCineGyro` and `:gyro`, one for `OpenCineGyroAndroid` beside the Frame.io and Nikon Android bullets; Area rules: "Gyro Android: keep the JNI class `com.opencapture.opencine.gyro.GyroNative` and its member names ..."), `Package.swift` header comment (dependency rule line for `OpenCineGyro`)
- Create: `docs/gyro/README.md` (module map, layer placement, the adapter contract, JNI export list, storage layout, migration rules), `atlas/api/swift/OpenCineGyro.txt`, `atlas/api/swift/OpenCineGyroAndroid.txt` (generated)

- [ ] **Step 1: Write the boundary text and area guide** (no em dashes; state that `OpenCineGyro` imports Foundation only and depends on nothing, that `OpenCineGyroAndroid` depends on `OpenCineGyro` and `OpenCineJNISupport` only, and that `:gyro` has no project dependencies).

- [ ] **Step 2: Generate the Swift API snapshots**

Run: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 python3 atlas/tools/atlas.py api --write --build`
Expected: two new files under `atlas/api/swift/`, no unrelated diffs.

- [ ] **Step 3: Run the repository gates touched by this plan**

```sh
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift build --scratch-path .build-gyro --build-tests -Xswiftc -strict-concurrency=complete
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1 swift test --scratch-path .build-gyro
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p1-android bash -c 'cd Android && ./gradlew :gyro:test :gyro:lint'
python3 -m unittest discover -s atlas/tests && python3 atlas/tools/atlas.py check
grep -rn "$(printf '\342\200\224')" Sources/OpenCineGyro Sources/OpenCineGyroAndroid Android/gyro docs/gyro Tests/OpenCineGyroTests Tests/OpenCineGyroAndroidTests Fixtures/gyro-take-status-vectors.tsv
```

Expected: all pass; the grep prints nothing.

- [ ] **Step 4: App impact note (propagate-core-change)**

Run: `python3 atlas/tools/atlas.py consumers OpenCineGyro` and `python3 atlas/tools/atlas.py impact opencine --include-candidates`. Record in the task handoff: no app links the new modules yet; OpenPocketCine and OpenInstaCine are unaffected (they do not depend on the new products); OpenZCine adopts in Plan 4.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md Package.swift docs/gyro/README.md atlas/api/swift/OpenCineGyro.txt atlas/api/swift/OpenCineGyroAndroid.txt
git commit -m "docs(gyro): boundaries, area guide and API snapshots for the gyro modules"
```
