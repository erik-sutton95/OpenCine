# Gyro capture

Phone gyro logging for Gyroflow, shared by every camera app. The phone, clamped to the camera,
records its rotation during each take; the user stabilizes the clip in Gyroflow afterwards. This
guide covers the engine and the Android bridge (plan 1 of the gyro series). The iOS runtime and
screens, the Android runtime and screens, and the first camera adapter follow in plans 2 to 4
(`docs/superpowers/plans/2026-10-25-gyro-*.md`); the UX is specified in
`docs/superpowers/specs/2026-10-25-gyro-capture-ux-design.md`.

Status: implemented, automated checks passed. No app links these modules yet.

## Modules

| Module | Layer | Depends on | Contents |
|---|---|---|---|
| `OpenCineGyro` (Swift) | core | nothing (Foundation only) | Engine and policy, below |
| `OpenCineGyroAndroid` (Swift) | vendor | `OpenCineGyro`, `OpenCineJNISupport` | Owner-keyed JSON wires and the `GyroNative` JNI exports |
| `:gyro` (Android, `com.opencapture.opencine.gyro`) | core | no project dependencies | `GyroNative` facade, `GyroNativeApi`, reply decoders, Kotlin twins of the adapter contract and take status |

`OpenCineGyro` names no app or manufacturer and holds no mutable static state
(`GyroSourceRulesTests`, Kotlin `GyroRulesTest`). App names, storage directories and preference
keys arrive as host values.

## Engine (`OpenCineGyro`)

| File | Responsibility |
|---|---|
| `GyroLog.swift` | Samples, descriptors (with the writing app's sanitized name), summaries, updates |
| `GyroTakeSession.swift` | Take segmentation over a monotonic sensor clock, 2 s pre and post roll, first mount-moved mark |
| `GyroGCSV.swift` | GCSV 1.3 encoder and crash recovery |
| `GyroMountCalibration.swift`, `GyroMountCalibrationSession.swift` | Three-pose mount solver and its still-window capture |
| `GyroCameraGravity.swift` | Camera roll and pitch to a down vector in Gyroflow's up/left/backward basis |
| `GyroMountPreset.swift` | Legacy manual presets, kept only so old logs decode and recover |
| `GyroRingCalibration.swift` | The automatic "fill the ring" calibration controller |
| `GyroDriftDetector.swift` | Mount-moved detection during steady moments |
| `GyroCameraAdapter.swift` | The camera adapter contract and its values |
| `GyroArming.swift` | Session-scoped arming and the exact stabilization save/restore machine |
| `GyroTakeStatus.swift` | The one badge a take shows |
| `GyroLogStore.swift` | File store actor: durable partial files, recovery, mount-moved sidecar, batch share |
| `GyroPreferences.swift` | Toggle, tip, per-camera calibrations, owed restores, legacy migration |

Everything runs on manual clocks; tests never sleep.

### Tolerances

- Solver acceptance (unchanged from the original app): pose separation 20 to 160 degrees, pose
  pair agreement 2 degrees, mixed component `sin(15 degrees)`, validation error at most 2 degrees,
  still window at least 1 s with every reading within 3 degrees of the mean, phone and camera
  timestamps within 0.25 s.
- Ring zones: level within 12 degrees of camera down `(-1, 0, 0)`; tilt up 25 to 150 degrees from
  the captured level pose; tilt and lean at least `sin(18 degrees)` along both the in-plane axis
  perpendicular to the level pose and the normal of the plane of the first two poses (the solver's
  mixed check). A pose captures after 2 s still in its zone. Zones are judged from the camera's
  down vector only, so any phone orientation on the mount works.
- Drift: steady when rotation rate is below 0.05 rad/s and acceleration within 0.03 g of 1 g;
  camera reading at most 0.25 s old; disagreement above 2.5 degrees sustained for 1 s confirms
  once. Nothing gyro-related ever stops a recording.

### Take status precedence

`recording` > `mountMoved` > `cutShort` > `smallGaps` > `notCalibrated` > `ready`. The shared
vectors in `Fixtures/gyro-take-status-vectors.tsv` drive both the Swift and the Kotlin test.

## Camera adapter

A camera integration enables gyro capture by implementing `GyroCameraAdapter` (Swift, main
actor, events through a `GyroCameraSink`) or the Kotlin `GyroCameraAdapter` (flows):

- a stable `GyroCameraIdentity` (per-body id for calibrations and owed restores, display name);
- recording state and video mode, `nil` when unknown;
- camera down readings with phone-clock timestamps, or none (`providesLevel == false` hides
  calibration and drift; logging still works);
- stabilization: the settings that matter with their off values, the current values (a missing
  key is unknown), whether the lens has its own switch, and a write that reports success.

## Arming

The saved toggle means "arm whenever possible". A session is armed while the toggle is on, a
camera is connected, the host is eligible (monitor showing, app in front, no multicam or relay)
and the camera is in video mode. At session start the host presents the setup steps the machine
returns (turn off stabilization when it is known to be on; calibration when the camera provides
level). Turning stabilization off persists the owed restore before writing. When the session ends
while connected, the machine restores exactly the saved values, but only for keys still at the
value the app wrote. After a link drop the restore stays owed and runs first on the next
connection; a failed restore is not retried in the same connection.

## Storage

The store root is a host directory. Each take lives in `<root>/<UUID>/`: `descriptor.json`,
`summary.json` once finished, `capture.gcsv.part` while recording, the finished
`<descriptor.filename>` and, after a mount move, `mount-moved.json` (`{"offsetSeconds": s}`,
merged into the summary on completion and recovery). This is the layout the original app used, so
its logs load in place; descriptors without a `writer` and legacy `mountPreset` values decode and
report "not calibrated".

Preferences are JSON payloads in a host key-value store under a host prefix (`enabled`,
`calibrations` keyed by camera id, `pendingRestores`, `tipDismissed`, `legacyCalibration`,
`migrated`). Migration runs once: the legacy enabled flag is kept, the legacy preset is dropped,
and a valid legacy global calibration is adopted by the first camera that asks for one.

## Android bridge

`GyroNative` exports (`Java_com_opencapture_opencine_gyro_GyroNative_<name>`): `loggingCreate`,
`loggingIngest`, `loggingObserve`, `loggingMountMoved`, `loggingPoll`, `loggingFinish`,
`loggingClose`, `recoveryCreate`, `recoveryAccept`, `recoveryFinish`, `ringCreate`, `ringStart`,
`ringUpdateCamera`, `ringObserve`, `ringInvalidate`, `ringCancel`, `ringClose`,
`calibrationValidate`, `driftCreate`, `driftObserveCamera`, `driftObservePhone`, `driftReset`,
`driftClose`, `armingCreate`, `armingUpdate`, `armingChooseTurnOff`, `armingChooseKeepOn`,
`armingWriteFinished`, `armingClose`, `cameraDown`. The class name, package and member names are
part of the native contract (`consumer-rules.pro` keeps them); change Swift and Kotlin in step.
Camera level crosses the wire as a down vector; a camera that reports roll and pitch converts with
`cameraDown` first. An app links `OpenCineGyroAndroid` into its Swift Android library and calls
`GyroNative.load` with that library's name. Coordinators take `GyroNativeApi` so tests can pass a
fake.
