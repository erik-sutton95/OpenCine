# Gyro Capture, Part 3: Android Runtime and Compose Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Android twin of Part 2: SensorManager motion sensors, the log store and preferences moved from OpenZCine, a capture coordinator that drives the Swift policy through `GyroNative`, and Compose screens identical in look, copy and behavior to the SwiftUI ones, in both orientations with TalkBack support.

**Architecture:** Runtime goes into Part 1's `:gyro` module (layer `core`, no project dependencies): `GyroMotionSensors`, `GyroLogStore` (moved from OpenZCine `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/gyro/GyroLogStore.kt`), `GyroPreferences`, `GyroPillState` and `GyroCaptureCoordinator` (moved from the same package and rebuilt on the JNI wires). Kotlin owns no take, calibration, drift or arming policy: every decision is a `GyroNativeApi` call. Screens go into `:camera-controls` under package `com.opencapture.opencine.cameracontrols.gyro`, take values and lambdas, and `GyroFeatureHost` binds them to the coordinator.

**Tech Stack:** Kotlin, coroutines/StateFlow, Jetpack Compose (Material3 via `monitor-ui`), Android SensorManager, `org.json`, JUnit (JVM), AndroidX instrumentation with `ActivityScenario`.

**Spec:** `docs/superpowers/specs/2026-10-25-gyro-capture-ux-design.md` (owner decisions 1 to 3 apply) and mockups in `docs/superpowers/specs/2026-10-25-gyro-capture-ux-mockups/`.

**Depends on:** Part 1 (engine, wires, `:gyro` facade) and Part 2 Tasks 3 and 5 (`Fixtures/gyro-pill-vectors.tsv`, `GyroCopy` table). Every rule, string and threshold here must equal Part 2's; where this plan says "as Part 2 Task N", read that task.

**Why this boundary:** the parity rule demands identical behavior, not shared code across languages; Android needs its own runtime (SensorManager, files, SharedPreferences) and its own UI toolkit, verified on its own test hosts. Keeping it a separate plan lets it run in a parallel lane after the iOS copy and pill vectors exist.

## Global Constraints

- Never use the em dash character anywhere.
- Conventional Commits as `Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>`, no co-author trailers, explicit `git add <path>`.
- Same visual language as Part 2 through `MonitorPalette` (`com.opencapture.monitorui`): background `0xFF111213`, surface `0xFF1A1B1C`, the theme accent, 12 dp radius, one accent-filled primary button per screen.
- Same copy as Part 2's `GyroCopy` table, byte for byte (pinned by a parity test in Task 5).
- Same orientation rule, same accessibility rule (TalkBack labels on every state, ring progress announced, every haptic paired with an announcement through `View.announceForAccessibility`).
- `:gyro` keeps no project dependencies; `:camera-controls` may add `api(project(":gyro"))` (ui -> core). `CameraControlsRulesTest` still rejects manufacturer and app names.
- Kotlin never decides take boundaries, calibration acceptance, drift or restores: those come from `GyroNativeApi`.
- Fakes run on manual clocks; tests never sleep (use `kotlinx.coroutines.test` virtual time).
- Gradle runs through `~/Work/OpenCine-Parity-20261012/tools/heavy.sh <label> bash -c 'cd Android && ./gradlew <tasks>'` with a timeout; a stalled test is killed and rerun alone. `~/Work/OpenCine-Parity-20261012/tools/remote-gradle.sh <label> <tasks>` is an alternative for JVM tasks when local slots are full (it builds a pushed snapshot).
- Instrumented tests run on a private emulator (`~/Work/OpenCine-Parity-20261012/tools/avd-clone.sh` when available) with `./gradlew :camera-controls:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=<FQN>`.

## Review Focus

1. **Process death mid-take:** the next launch recovers the partial file, merges the mount-moved sidecar, and owes the IBIS restore from preferences. Test: `processDeathRecoversTakeAndOwesRestore` in Task 3.
2. **Rotation (activity recreation) during calibration or the arming sheet:** the coordinator outlives the activity, so the step and hold survive and the sheet reappears in the same step. Test: `recreationKeepsCalibrationStep` in Task 10.
3. **System back during calibration or the arming sheet:** back means Cancel (calibration closes, the session stays armed uncalibrated) and Keep it on for the IBIS step; it never leaves the sheet in a half state. Test: `backActsAsCancel` in Task 10.
4. **TalkBack user calibrates:** progress announcements at 25, 50 and 75 percent and per capture. Test: `ringAnnouncesProgressAndCaptures` in Task 7.
5. **Sensors missing** (no `TYPE_GYROSCOPE`, or no `TYPE_GRAVITY` and no accelerometer): logging reports `sensorUnavailable`; calibration and drift are hidden when no gravity source exists; nothing crashes. Test: `missingSensorsDegradeVisibly` in Task 1.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroMotionSensors.kt` | `interface GyroMotionSensors` and `AndroidGyroMotionSensors` (gyro 100 Hz batches, motion readings 30 Hz) |
| `.../gyro/GyroSampleBatch.kt` | Moved `AndroidGyroSample`, `encodeGyroBatch`, `replayGyroIngress`, `RecordingObservation` |
| `.../gyro/GyroLogStore.kt` | Moved file store plus mount-moved sidecar and multi-file share list |
| `.../gyro/GyroPreferences.kt` | SharedPreferences twin of Part 1's `GyroPreferences` |
| `.../gyro/GyroPill.kt` | Twin of Part 2's `GyroPillState.resolve` |
| `.../gyro/GyroCaptureCoordinator.kt` | Moved and rebuilt coordinator; `GyroCaptureState`, `GyroNotice`, `GyroHostConfiguration` |
| `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/*Test.kt` | JVM tests with `FakeGyroNative`, `FakeGyroCameraAdapter`, `FakeMotionSensors` |
| `Android/gyro/src/testFixtures/kotlin/com/opencapture/opencine/gyro/*.kt` | `FakeGyroNative`, `FakeGyroCameraAdapter`, `FakeMotionSensors`, shared with `:camera-controls` tests |
| `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroCopy.kt` | Copy twin |
| `.../cameracontrols/gyro/{GyroAdaptiveLayout,GyroPillChip,GyroSetupSheet,GyroRing,GyroRingCalibrationScreen,GyroLogSections,GyroLogsScreen,GyroTakeScreen,GyroDriftSheet,GyroFeatureHost}.kt` | Screens, one per SwiftUI twin |
| `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/*Test.kt` | JVM tests of pure UI models |
| `Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt` | Instrumented screens test |
| `Tests/OpenCineCameraControlsTests/GyroCopyParityTests.swift` | Swift test pinning the Kotlin copy |

Modified: `Android/gyro/build.gradle.kts` (test fixtures), `Android/camera-controls/build.gradle.kts` (`api(project(":gyro"))`), `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/CameraControlsRulesTest.kt` (allow `com.opencapture.opencine.gyro.`), `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorSettingsConfiguration.kt` (`MonitorSettingsGyroSource.calibrate`), `Android/gyro/api/gyro.api`, `Android/camera-controls/api/camera-controls.api`.

---

### Task 1: Motion sensors and moved batch helpers

**Files:**

- Create: `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/{GyroMotionSensors,GyroSampleBatch}.kt`
- Test: `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/{GyroSampleBatchTest,GyroMotionSensorsTest}.kt` (the first moved from OpenZCine `GyroNativeTest.kt` and `GyroIngressTest.kt`)

**Interfaces:**

- Produces:

```kotlin
data class AndroidGyroSample(val timestamp: Double, val x: Double, val y: Double, val z: Double)   // moved
fun encodeGyroBatch(samples: List<AndroidGyroSample>): ByteArray                                    // moved
data class RecordingObservation(val recording: Boolean?, val timestamp: Double, val date: Double,
    val interrupted: Boolean = false, val calibrationJSON: String = "")                            // mountPreset removed
fun replayGyroIngress(...)                                                                          // moved unchanged
data class GyroMotionReading(val timestamp: Double, val phoneDown: GyroVector3, val rotationRate: Double, val accelerationG: Double)
interface GyroMotionSensors {
    val hasGyroscope: Boolean
    val hasGravity: Boolean          // TYPE_GRAVITY or TYPE_ACCELEROMETER present
    fun startGyro(onSample: (AndroidGyroSample) -> Unit): Boolean   // 10_000 us, own HandlerThread
    fun stopGyro()
    fun startMotion(onReading: (GyroMotionReading) -> Unit): Boolean   // 33_333 us
    fun stopMotion()
}
class AndroidGyroMotionSensors(context: Context) : GyroMotionSensors
internal fun motionReading(gravity: FloatArray, linearAcceleration: FloatArray?, gyro: FloatArray?, timestampNanos: Long): GyroMotionReading
```

`motionReading` negates Android's support acceleration into physical down (as OpenZCine's calibration listener does), divides by `SensorManager.GRAVITY_EARTH` for `accelerationG` (gravity plus linear acceleration when `TYPE_LINEAR_ACCELERATION` exists, else the raw accelerometer magnitude), and uses the latest gyro vector magnitude for `rotationRate`. Timestamps are `event.timestamp / 1e9` (elapsedRealtime nanoseconds, the clock the coordinator's `now()` uses). Without `TYPE_GRAVITY`, low-pass the accelerometer with alpha 0.1 (a private helper; `:gyro` cannot use `monitor-ui`'s `MonitorDeviceTiltMath`).

- [ ] **Step 1: Write the failing tests**: moved batch and ingress cases; `motionReadingNegatesAndScales` (gravity `[0, 0, 9.80665]` -> phoneDown `(0, 0, -1)` scaled, accelerationG `1.0`); `missingSensorsDegradeVisibly` (a `GyroMotionSensors` built over a fake SensorManager lookup returning nulls: `hasGyroscope == false`, `startGyro` returns false, `hasGravity == false`).
- [ ] **Step 2: Run to verify failure**: `~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p3 bash -c 'cd Android && ./gradlew :gyro:test'`.
- [ ] **Step 3: Implement** (constructor takes `sensorLookup: (Int) -> Sensor?` and a `SensorManager?` for testability).
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroMotionSensors.kt Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroSampleBatch.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroSampleBatchTest.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroMotionSensorsTest.kt
git commit -m "feat(gyro): Android motion sensors for logging, calibration and drift"
```

---

### Task 2: Log store and preferences

**Files:**

- Create: `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/{GyroLogStore,GyroPreferences}.kt`
- Test: `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/{GyroLogStoreTest,GyroPreferencesTest}.kt` (the first moved from OpenZCine `GyroLogStoreTest.kt`; sharing staging tests from `GyroLogSharingTest.kt` are dropped because sharing now goes through `:appkit`'s `MediaShare` in Task 8)

**Interfaces:**

- Consumes: `GyroNativeApi` recovery calls, `resolveGyroTakeStatus` (Part 1 Task 11).
- Produces:
  - `data class GyroLogEntry(val descriptor: JSONObject, val summary: JSONObject?, val file: File, val active: Boolean = false)` with `id`, `cameraLabel`, `startDateMillis`, `durationSeconds: Double?`, `measuredRate: Double?`, `approximateStartOffset: Double?`, `isCalibrated: Boolean`, `status: GyroTakeStatus`, `canShare: Boolean`. The OpenZCine `health`, `mountPreset` and `mountDetail` members are deleted.
  - `class GyroLogStore(root: File, native: GyroNativeApi, writeBytes: ...)`: OpenZCine layout unchanged (`<ID>.json`, `<ID>.partial`, `<descriptor.filename>`, `<ID>.summary.json`) plus `<ID>.mount-moved.json` (`{"offsetSeconds": x}`) written atomically on a `MountMoved` update and merged into the summary on finish and on recovery (`recoveryFinish(owner, descriptor, mountMovedOffset)`); `entries()`, `delete(entry)` (refuses active), `shareFiles(ids: List<String>): List<File>` (throws if any is active or unfinished).
  - `class GyroPreferences(prefs: SharedPreferences, keys: GyroPreferenceKeys, legacy: GyroLegacyPreferenceKeys?)` with `enabled`, `tipDismissed`, `pendingRestoresJSON: String`, `calibrationJSON(cameraId): String?`, `saveCalibration(cameraId, json)`; `data class GyroPreferenceKeys(...)` with `companion fun namespaced(prefix: String)`; `data class GyroLegacyPreferenceKeys(enabled, mountPreset, calibration)`. Migration rules are Part 1 Task 9's, including validation of legacy calibrations through `GyroNativeApi.calibrationValidate`.

- [ ] **Step 1: Write the failing tests**: moved store cases; `mountMovedSidecarSurvivesRecovery`; `shareFilesRefusesActiveTakes`; `legacyLayoutLoadsInPlace` (files written in OpenZCine's names with an `OpenZCine-...gcsv` finished file); preferences: `calibrationsPerCamera`, `legacyEnabledKeptPresetDropped`, `legacyCalibrationAdoptedOnce`, `migrationRunsOnce`, `invalidLegacyCalibrationDropped` (use an in-memory `SharedPreferences` fake).
- [ ] **Step 2: Run to verify failure** (`:gyro:test`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroLogStore.kt Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroPreferences.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroLogStoreTest.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroPreferencesTest.kt
git commit -m "feat(gyro): Android log store and per-camera preferences"
```

---

### Task 3: Capture coordinator: logging, arming and the pill

**Files:**

- Create: `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/{GyroPill,GyroCaptureCoordinator}.kt`
- Create: `Android/gyro/src/testFixtures/kotlin/com/opencapture/opencine/gyro/{FakeGyroNative,FakeGyroCameraAdapter,FakeMotionSensors}.kt` (`:gyro` is an Android library, so enable `android { testFixtures { enable = true } }` in `Android/gyro/build.gradle.kts`; `:core` uses the JVM `java-test-fixtures` plugin, which does not apply here. If AGP rejects Kotlin sources in Android test fixtures, add `android.experimental.enableTestFixturesKotlinSupport=true` to `Android/gradle.properties`)
- Test: `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/{GyroPillTest,GyroCaptureLoggingTest,GyroCaptureArmingTest}.kt` (logging cases moved from OpenZCine `GyroEligibilityTest.kt` and the coordinator behaviors covered by OpenZCine's `GyroMountMainActivityTest`, minus presets)

**Interfaces:**

- Consumes: `GyroNativeApi` (logging and arming wires, `decodeLogReply`, `decodeArmingReply`, `encodeArmingInputs`), `GyroCameraAdapter`, Tasks 1 and 2.
- Produces:

```kotlin
data class GyroHostConfiguration(val appName: String, val logRoot: File, val preferencesName: String,
    val keys: GyroPreferenceKeys, val legacy: GyroLegacyPreferenceKeys? = null)
enum class GyroPillKind { HIDDEN, OFFLINE, ARMED, RECORDING, SAVING, GAPS, MOUNT_MOVED, ERROR }
data class GyroPillState(val kind: GyroPillKind, val stabilizationWarning: Boolean)
fun resolveGyroPill(enabled: Boolean, failed: Boolean, armed: Boolean, motionRunning: Boolean, hasFirstSample: Boolean,
    activeTake: Boolean, cameraRecording: Boolean?, gapWarning: Boolean, mountMoved: Boolean, stabilizationWarning: Boolean): GyroPillState
enum class GyroNotice { TURN_OFF_FAILED, RESTORE_FAILED, SENSOR_UNAVAILABLE, SENSOR_STALLED, SAMPLES_LOST,
    RECORDING_EVENTS_LOST, SAVE_FAILED, OPEN_FAILED, SHARE_FAILED, DELETE_FAILED, RECOVERY_INCOMPLETE }
data class GyroCaptureState(
    val enabled: Boolean = false, val available: Boolean = false, val pill: GyroPillState = GyroPillState(GyroPillKind.HIDDEN, false),
    val logs: List<GyroLogEntry> = emptyList(), val notice: GyroNotice? = null, val tipVisible: Boolean = true,
    val setupSteps: List<GyroArmingStep> = emptyList(), val ring: GyroRingState? = null,
    val canCalibrate: Boolean = false, val hasSavedCalibration: Boolean = false,
    val driftPromptPresented: Boolean = false, val driftHapticToken: Int = 0, val isArmed: Boolean = false)
class GyroCaptureCoordinator(context: Context, host: GyroHostConfiguration,
    native: GyroNativeApi = GyroNative, sensors: GyroMotionSensors = AndroidGyroMotionSensors(context),
    scope: CoroutineScope = gyroCaptureScope(), now: () -> Double = { SystemClock.elapsedRealtimeNanos() / 1e9 }) {
    val state: StateFlow<GyroCaptureState>
    fun setEnabled(enabled: Boolean)
    fun bind(adapter: GyroCameraAdapter?)
    fun setHostEligible(eligible: Boolean)          // monitor showing, foreground, no multicam or relay
    fun setForeground(active: Boolean)              // false = backgrounded termination and calibration invalidation
    suspend fun prepareForDisconnect()              // ends the session and awaits the restore, 3 s max
    fun setupTurnOffStabilization(); fun setupKeepStabilization(); fun setupSkipCalibration(); fun setupUseLastCalibration()
    fun beginCalibration(); fun startRing(); fun cancelCalibration(); fun finishCalibration()
    fun recalibrateAfterDrift(); fun dismissDriftPrompt()
    fun delete(entry: GyroLogEntry); fun shareFiles(ids: List<String>): List<File>; fun dismissTip(); fun clearNotice()
    fun close()
}
```

Rules: as Part 2 Tasks 2 and 3 (same effects order, same session start and end conditions, same pill fixture). The armed-session decision comes only from `armingUpdate` replies; Kotlin re-sends `encodeArmingInputs(...)` on every adapter flow emission, eligibility, foreground and toggle change. `PersistPendingRestores` writes `preferences.pendingRestoresJSON`; `WriteStabilization` calls `adapter.writeStabilization` on the coordinator scope then `armingWriteFinished`.

- [ ] **Step 1: Write the failing tests** (virtual time, `FakeGyroNative` scripted to return the JSON shapes from Part 1 Task 10, or a `RealishGyroNative` that delegates to JSON-producing Kotlin stubs where scripting is clumsy):
  - `GyroPillTest.everySharedVectorResolves` (reads `Fixtures/gyro-pill-vectors.tsv`).
  - `GyroCaptureLoggingTest`: `optInDefaultsOffAndPersists`, `onlyReportedRecOpensATake`, `photoModeAndUnknownSelectorWait`, `ineligibleSourcesNeverStartSensors`, `sensorLossIsVisible`, `writeFailureAbortsAndRecovers`.
  - `GyroCaptureArmingTest`: `ibisOnShowsStabilizationStepFirst`, `turnOffWritesOffAfterPersisting`, `keepOnShowsWarning`, `toggleOffRestoresExactValue`, `linkDropOwesRestoreAndNextConnectRestoresFirst`, `connectingDuringRecordingDefersSheet`, `prepareForDisconnectAwaitsRestore`, `processDeathRecoversTakeAndOwesRestore` (new coordinator over the same root and preferences).
- [ ] **Step 2: Run to verify failure** (`:gyro:test`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/gyro/build.gradle.kts Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroPill.kt Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroCaptureCoordinator.kt Android/gyro/src/testFixtures Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroPillTest.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroCaptureLoggingTest.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroCaptureArmingTest.kt
git commit -m "feat(gyro): Android capture coordinator with session arming"
```

---

### Task 4: Coordinator calibration and drift

**Files:**

- Modify: `Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroCaptureCoordinator.kt` (split calibration and drift into `GyroCaptureCalibration.kt` and `GyroCaptureDrift.kt` internal helpers if the file passes about 400 lines)
- Test: `Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/{GyroCaptureCalibrationTest,GyroCaptureDriftTest}.kt` (calibration cases adapted from OpenZCine `GyroCalibrationSessionTest.kt`)

**Interfaces:**

- Consumes: ring wire (`ringCreate`, `ringStart`, `ringUpdateCamera`, `ringObserve`, `ringInvalidate`, `ringCancel`, `ringClose`), drift wire, `loggingMountMoved`, `GyroMotionSensors.startMotion`, `GyroCameraAdapter.level`.
- Rules: as Part 2 Task 4. Ring owners are closed exactly once (the moved `GyroCalibrationSession` retire-once rule). A completed calibration is validated with `calibrationValidate` before `saveCalibration`. Drift runs only while armed, calibrated for this camera, `adapter.providesLevel`, and a take is recording; the confirmation calls `loggingMountMoved` and applies the returned updates through the store.

- [ ] **Step 1: Write the failing tests**: `threeHeldPosesSaveForThisCamera`, `invalidationMessagesFollowRecordingSourceAndDisconnect`, `useLastCalibrationSkipsRing`, `cancelInSetupArmsUncalibrated`, `noLevelHidesCalibration`, `ringOwnerClosedExactlyOnce`; drift: `steadyMismatchMarksTakeAndPill`, `promptAfterRecStopsAndNotNowSilences`, `uncalibratedNeverDetects`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroCaptureCalibrationTest.kt Android/gyro/src/test/kotlin/com/opencapture/opencine/gyro/GyroCaptureDriftTest.kt
git commit -m "feat(gyro): ring calibration and mount drift in the Android coordinator"
```

---

### Task 5: Copy twin, parity test, layout and pill chip

**Files:**

- Create: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/{GyroCopy,GyroAdaptiveLayout,GyroPillChip}.kt`
- Create: `Tests/OpenCineCameraControlsTests/GyroCopyParityTests.swift`
- Test: `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroCopyTest.kt`
- Modify: `Android/camera-controls/build.gradle.kts` (`api(project(":gyro"))`), `CameraControlsRulesTest.kt` (allow `com.opencapture.opencine.gyro.` imports)

**Interfaces:**

- Produces:
  - `object GyroCopy` with the same member names (Kotlin camelCase) and literal texts as Part 2 Task 5's table; functions take the Kotlin enums from `:gyro` (`GyroPillKind`, `GyroRingPhase` step index `Int`, `GyroCalibrationBlock`, `GyroCalibrationInvalidation`, `GyroTakeStatus`, `GyroNotice`). Each literal appears once as a plain string literal so the parity test can find it.
  - `@Composable fun GyroAdaptiveLayout(modifier: Modifier = Modifier, visual: @Composable () -> Unit, content: @Composable () -> Unit)` using `BoxWithConstraints`: portrait when `maxWidth < maxHeight`.
  - `@Composable fun GyroPillChip(state: GyroPillState, onClick: () -> Unit, modifier: Modifier = Modifier)`: same look as Part 2's pill (monospaced 11 sp semibold, black 0.65 capsule, amber for `MOUNT_MOVED` and `ERROR`, amber dot for the warning), `testTag("gyro.pill")`, `semantics { contentDescription = GyroCopy.pillA11y(kind, warning) }`.
- `GyroCopyParityTests.swift`: reads `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroCopy.kt` through `#filePath` and asserts it contains `"\"<text>\""` for every fixed `GyroCopy` string, and the fixed parts of every interpolated one (for example `"Step "` and `" of 3"`), modeled on `MonitorSettingsCopyParityTests`.

- [ ] **Step 1: Write the failing tests**: Swift parity test; Kotlin `GyroCopyTest` (`noEmDash`, `lengthAndOffsetFormatting` with the same expectations as Part 2's `GyroCopyTests`, `statusTexts`).
- [ ] **Step 2: Run to verify failure**: `heavy.sh gyro-p3 swift test --scratch-path .build-gyro --filter GyroCopyParityTests` and `heavy.sh gyro-p3 bash -c 'cd Android && ./gradlew :camera-controls:testDebugUnitTest --tests "*gyro*"'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass**, plus `CameraControlsRulesTest`.
- [ ] **Step 5: Commit**

```bash
git add Android/camera-controls/build.gradle.kts Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/CameraControlsRulesTest.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroCopyTest.kt Tests/OpenCineCameraControlsTests/GyroCopyParityTests.swift
git commit -m "feat(gyro): Android gyro copy twin, layout and pill chip"
```

---

### Task 6: Arming sheet

**Files:**

- Create: `.../cameracontrols/gyro/GyroSetupSheet.kt`
- Test: `Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt` (start the file)

**Interfaces:**

- Produces: `@Composable fun GyroSetupSheet(step: GyroArmingStep, ring: GyroRingState?, actions: GyroSetupActions)` and `class GyroSetupActions(val turnOff: () -> Unit, val keepOn: () -> Unit, val getStarted: () -> Unit, val useLast: () -> Unit, val cancel: () -> Unit, val done: () -> Unit)`. Same content and rules as Part 2 Task 6. Test tags `gyro.setup.turnOff`, `gyro.setup.keepOn`, `gyro.primary`, `gyro.visual`. `BackHandler` calls `keepOn` on the IBIS step and `cancel` on the calibration step.

- [ ] **Step 1: Write the failing instrumented tests** (`ActivityScenario.launch(GalleryOpeningTestActivity::class.java)` then `activity.setContent { ... }`, the pattern in `LadderSheetFieldHostTest.kt`; query the view tree's `AccessibilityNodeInfo` for test tags exposed with `Modifier.semantics { testTagsAsResourceId = true }`): `stabilizationStepShowsOnePrimaryButton`, `lensLineOnlyWithVRSwitch`, `useLastOnlyWithSavedCalibration`.
- [ ] **Step 2: Run to verify failure**: `heavy.sh gyro-p3 bash -c 'cd Android && ./gradlew :camera-controls:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.opencapture.opencine.cameracontrols.gyro.GyroScreensTest'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroSetupSheet.kt Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt
git commit -m "feat(gyro): Android arming sheet with the IBIS step"
```

---

### Task 7: Ring and calibration screens

**Files:**

- Create: `.../cameracontrols/gyro/{GyroRing,GyroRingCalibrationScreen}.kt`
- Test: `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroRingModelTest.kt`, `GyroScreensTest.kt` (add)

**Interfaces:**

- Produces: `data class GyroRingModel(val litFraction: Double, val dimmed: Boolean, val checkmark: Boolean)` with `fun gyroRingModel(state: GyroRingState): GyroRingModel` (same mapping as Part 2 Task 7), `@Composable fun GyroRing(model: GyroRingModel)` (60 ticks on a `Canvas`), `@Composable fun GyroRingCalibrationScreen(state: GyroRingState, canUseLast: Boolean, actions: GyroSetupActions, announcer: (String) -> Unit = LocalView.current::announceForAccessibility)`. Same screens, feedback thresholds and copy as Part 2 Task 7; haptic `HapticFeedbackType.LongPress` paired with the announcement.

- [ ] **Step 1: Write the failing tests**: JVM `GyroRingModelTest` (same four cases as Part 2); instrumented `introHasNoCaptureButton`, `blockedStateShowsOneLine`, `ringAnnouncesProgressAndCaptures` (recording announcer lambda).
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroRing.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroRingCalibrationScreen.kt Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroRingModelTest.kt Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt
git commit -m "feat(gyro): Android fill-the-ring calibration screens"
```

---

### Task 8: Logs list, select-and-share and take page

**Files:**

- Create: `.../cameracontrols/gyro/{GyroLogSections,GyroLogsScreen,GyroTakeScreen}.kt`
- Test: `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroLogSectionsTest.kt`, `GyroScreensTest.kt` (add)

**Interfaces:**

- Consumes: `GyroLogEntry`, `GyroCopy`, `com.opencapture.opencine.appkit.MediaShare` (host value).
- Produces: `data class GyroLogSection(val title: String, val entries: List<GyroLogEntry>)`, `fun groupGyroLogs(entries: List<GyroLogEntry>, nowMillis: Long, zone: ZoneId, locale: Locale): List<GyroLogSection>` (same titles and ordering as Part 2), `class GyroLogsActions(share: (List<String>) -> Unit, delete: (GyroLogEntry) -> Unit, dismissTip, turnOnGyro, close)`, `@Composable fun GyroLogsScreen(entries, tipVisible, gyroEnabled, nowMillis, actions)`, `@Composable fun GyroTakeScreen(entry, onShare)`. Swipe to delete uses Material3 `SwipeToDismissBox` with the `deleteTitle` confirmation dialog; disabled on active rows. Landscape split 40/60 as Part 2.

- [ ] **Step 1: Write the failing tests**: JVM `groupsTodayYesterdayAndDates`, `ordersNewestFirst`; instrumented `rowsShowOneBadgeEach`, `emptyStateShowsOneButton`, `takePageLeadsWithVerdictAndSharePrimary`, `activeTakeCannotBeSelectedOrDeleted`, `landscapeShowsListAndTakeSideBySide`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroLogSections.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroLogsScreen.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroTakeScreen.kt Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroLogSectionsTest.kt Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt
git commit -m "feat(gyro): Android logs list, select-and-share and take page"
```

---

### Task 9: Drift sheet, feature host and settings entry

**Files:**

- Create: `.../cameracontrols/gyro/{GyroDriftSheet,GyroFeatureHost}.kt`
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorSettingsConfiguration.kt` (`MonitorSettingsGyroSource` gains `calibrate: (() -> Unit)? = null`; `SettingsGyro` renders a `GyroCopy.settingsCalibrate` row when present), `Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/MonitorSettingsCompositionTest.kt` (add a case)
- Test: `GyroScreensTest.kt` (add)

**Interfaces:**

- Produces: `@Composable fun GyroDriftSheet(onRecalibrate: () -> Unit, onNotNow: () -> Unit)`, `@Composable fun GyroFeatureHost(coordinator: GyroCaptureCoordinator, share: MediaShare, content: @Composable () -> Unit)` that collects `coordinator.state` and presents, in Part 2 Task 9's priority order, the setup or calibration full-screen dialog, the logs screen, the drift sheet (`ModalBottomSheet`), notices (auto-cleared after 4 s), the drift haptic and announcement, and the share chooser (`share.chooserIntent(context, coordinator.shareFiles(ids), { "text/plain" })` off the main thread, started with `context.startActivity`). The existing `mountName` and `configureMount` parameters of `MonitorSettingsGyroSource` stay (deprecated with `@Deprecated("Mount presets are gone; pass calibrate")`) until a later minor release.

- [ ] **Step 1: Write the failing tests**: instrumented `driftSheetHasOnePrimaryButton`, `featureHostPresentsSetupForNewSession` (coordinator over `FakeGyroNative` and `FakeGyroCameraAdapter` from `:gyro` test fixtures, added to `androidTestImplementation(testFixtures(project(":gyro")))`); JVM `gyroCalibrateRowOnlyWhenProvided`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit**

```bash
git add Android/camera-controls/build.gradle.kts Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroDriftSheet.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroFeatureHost.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorSettingsConfiguration.kt Android/camera-controls/src/test/kotlin/com/opencapture/opencine/cameracontrols/MonitorSettingsCompositionTest.kt Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt
git commit -m "feat(gyro): Android drift sheet, feature host and calibrate setting"
```

---

### Task 10: Orientation, recreation, back and TalkBack sweep

**Files:**

- Test: `GyroScreensTest.kt` (add)

- [ ] **Step 1: Write the tests**
  - `everyScreenRendersInBothOrientations`: same state list as Part 2 Task 10; set `activity.requestedOrientation` to portrait and to landscape, assert `gyro.primary` bounds lie inside the window insets and do not intersect `gyro.visual`.
  - `recreationKeepsCalibrationStep`: coordinator held outside the activity; `scenario.recreate()` at `POSING step 1 hold 0.5`; assert the counter reads `Step 2 of 3` and the ring state is unchanged.
  - `backActsAsCancel`: press back on the IBIS step (expect `keepOn`) and on a calibration step (expect `cancelCalibration` and `isArmed == true`).
  - `everyStateHasATalkBackLabel`: every clickable or visible text node has a non-empty `contentDescription` or text; the pill's description equals `GyroCopy.pillA11y` for each kind.
- [ ] **Step 2: Run** the instrumented class; fix defects in the owning composables; rerun until green.
- [ ] **Step 3: Commit**

```bash
git add Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroScreensTest.kt Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro
git commit -m "test(gyro): Android orientations, recreation, back and TalkBack for gyro screens"
```

---

### Task 11: ABI snapshots, gates and app impact

- [ ] **Step 1: Run**

```sh
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p3 bash -c 'cd Android && ./gradlew updateKotlinAbi updateAndroidApi'
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p3 bash -c 'cd Android && ./gradlew :gyro:test :camera-controls:test :gyro:lint :camera-controls:lint assembleRelease'
~/Work/OpenCine-Parity-20261012/tools/heavy.sh gyro-p3 swift test --scratch-path .build-gyro --filter GyroCopyParityTests
python3 atlas/tools/atlas.py check
grep -rn "$(printf '\342\200\224')" Android/gyro Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro Android/camera-controls/src/androidTest/kotlin/com/opencapture/opencine/cameracontrols/gyro
```

Expected: all pass; ABI files updated (`Android/gyro/api/gyro.api`, `Android/camera-controls/api/camera-controls.api`); grep prints nothing.

- [ ] **Step 2: App impact**: `python3 atlas/tools/atlas.py consumers MonitorSettingsGyroSource`; record that OpenPocketCine and OpenInstaCine compile unchanged (additive default) and need no adoption, and that the `:camera-controls -> :gyro` edge adds the gyro classes to every app that links camera controls without any runtime effect until an app constructs a coordinator (no native load happens until `GyroNative.load`).

- [ ] **Step 3: Emulator screenshots** of each state in both orientations (env-guarded capture in `GyroScreensTest`, pulled with `adb pull`), attached to the PR next to Part 2's iOS ones for the side-by-side parity check.

- [ ] **Step 4: Commit**

```bash
git add Android/gyro/api/gyro.api Android/camera-controls/api/camera-controls.api
git commit -m "chore(gyro): Android ABI snapshots for the gyro feature"
```
