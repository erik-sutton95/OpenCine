# Gyro capture: shared Core feature with a guided, visual UX

Status: design, 2026-10-25. Owner direction from the 2026-10-25 brainstorm; calls marked
"(coordinator's call)" were made on the owner's behalf while they were away and are open to
change.

## Why

OpenZCine ships phone-gyro logging for Gyroflow: the phone, clamped to the camera, records
its motion during each take, and the user stabilizes in Gyroflow afterwards. It works, but
the owner tried it once during PR review and found it "very programmer": text-only
calibration with numeric angles ("Tilt the lens up 25–35°"), paragraphs of explanation,
internal words ("independent mixed pose", "REC offset", "roll and pitch"), and generic
settings lists that do not look like the rest of the app.

The owner wants:

1. A guided, visual experience with the feel of Face ID enrollment, in the OpenCine design
   language.
2. The feature to live in OpenCine Core so future cameras get it, not only the Nikon ZR.

## Goals

- One shared gyro feature in Core (engine and UI, iOS and Android), with the camera-specific
  parts behind a small adapter. OpenZCine becomes the first adopter and deletes its own copy.
- Calibration that a non-technical user completes without reading: one visual, live
  feedback, automatic capture, plain language.
- The camera's stabilization handled for the user (IBIS off while armed, restored after).
- Detection of a mount that moves during a take, without interrupting recording.
- A logs screen that answers "is this take usable?" at a glance and makes Gyroflow the main
  action.
- Portrait and landscape layouts for every screen; the phone may be mounted either way.

## Non-goals

- Automatic re-solving of the mount after a bump (possible later; out of scope here).
- Linking a log to its camera clip by name (logs record start time only today).
- In-app stabilization or Gyroflow integration beyond sharing the file.
- Changing the Gyroflow file format (GCSV) or the solver's math, except where moving to
  Core forces API changes.

## Anti-goals (would make this a failure even if it technically works)

- Any angle in degrees, sample rate, or millisecond figure on a primary screen.
- A Capture, Verify, or Start again button in calibration.
- Two different-looking implementations on iOS and Android, or a Z-only fork of the shared
  screens (see the parity rule: one shared component per surface).
- Touching camera settings without telling the user, or failing to restore them.
- Interrupting or stopping a recording because of anything gyro-related.

## Experience

Visual language: the Monitor theme (`MonitorTheme`): background `0x111213`, surface
`0x1A1B1C`, the brand accent (`MonitorTheme.accent`; yellow `0xFFE100` on OpenZCine), large
SF/Roboto type, 12 pt radius, one primary accent-filled button per screen. Reference
mockups (owner approved direction A "Fill the ring" and the logs screen) are in
`docs/superpowers/specs/2026-10-25-gyro-capture-ux-mockups/`.

Orientation: every screen follows the phone. Portrait stacks the visual above the text and
button; landscape puts the visual on the left and text and button on the right.

### 1. Arming (turning Gyro on)

Arming is turning gyro capture on with a supported camera connected. It opens one setup
sheet with up to two steps, skipping any that do not apply:

1. **Stabilization.** If the camera reports in-body stabilization on (or electronic VR on),
   the sheet says "Turn off IBIS for Gyroflow" with one line of reason ("Gyroflow can't
   correct footage the camera already stabilized"). Buttons: **Turn off IBIS** (primary)
   and **Keep it on**. If the camera reports a lens with its own VR switch, add "Also
   switch off VR on the lens." If stabilization is already off, skip the step.
2. **Calibration.** The ring calibration (below). Because a mount drifts every time it is
   put on (owner), calibration is always offered on arming. A small **Use last
   calibration** link skips it when a saved calibration exists for this camera
   (coordinator's call: the owner asked whether arming should always force calibration and
   left before answering; offering with a skip link is the default).

"Keep it on" arms anyway; the gyro pill then carries a small warning mark until IBIS is off
(coordinator's call).

### 2. Calibration: "Fill the ring"

- **Start:** title "Calibrate your phone mount", one line "About 20 seconds. Keep the phone
  clamped to the camera.", a ring of dotted ticks around a camera glyph, **Get started**.
- **Three poses,** each one short instruction and three progress dots:
  1. "Hold the camera level"
  2. "Slowly tilt the lens up"
  3. "Tilt up and lean to one side" (the verification pose; it must combine pitch and roll,
     which is what today's third pose checks).
  The ring lights up as the camera enters the target zone and fills while the rig holds
  still; the pose captures itself after about 2 s of stillness, with a haptic tick and a
  brief checkmark. No numeric angles are shown; the target zones keep today's solver
  requirements internally.
- **Blocked states:** instead of fine print, the ring dims and one line says what to do:
  "Connect your camera to calibrate", "Stop recording to calibrate", "Hold steadier"
  (motion too high), "Waiting for the camera" (no fresh tilt reading).
- **Verification failure:** "That didn't line up. Let's try once more." and an automatic
  restart from pose 1.
- **Finish:** large accent checkmark, "Calibration complete", "Your gyro data now lines up
  with this camera.", **Done**.
- Calibration is invalidated, with a plain message, when the camera source changes,
  recording starts mid-calibration, or the connection ends (today's rules, new wording).

### 3. Manual presets are removed

Calibration is the only way to set up the mount (owner: a mount "can drift easily every
time you mount"). The "Screen toward you / Screen toward lens" preset lists go away.
Existing saved presets are migrated to "not calibrated" so the next arming offers
calibration (coordinator's call).

### 4. During a take

- The gyro pill keeps its place on the monitor. States, in plain words where they are
  read by users: armed, recording, saving, gaps, error, offline (coordinator's call to keep
  the compact uppercase pill style of the other monitor chips; wording reviewed so nothing
  reads as an internal state).
- **Drift detection.** During steady moments only (low rotation rate and acceleration
  close to 1 g), compare the phone's down vector, mapped through the saved calibration,
  with the camera's reported down vector. If they disagree by more than a threshold
  (start at 2.5°, tuned on hardware) for about 1 s, the mount has moved: the pill turns
  amber and reads **MOUNT MOVED**, with one light haptic. Recording is never interrupted.
  The moment is written into the log.
- After recording stops, a small sheet: "Your phone mount moved during that take.
  Recalibrate now?" with one tap into calibration.

### 5. Disarming (turning Gyro off)

Restore exactly the stabilization values captured before arming (for example SPORT, not
just ON), but only if the camera still shows the values the app set; if the user changed
them on the camera meanwhile, leave them alone (coordinator's call). If the connection is
lost while armed, the pending restore is remembered per camera and applied on the next
connection when Gyro is off.

### 6. Logs screen

- Takes grouped by day (Today, Yesterday, dates). Each row: start time, camera name,
  length, one status badge: **Ready** (complete), **Small gaps** (usable, some dropped
  samples), **Cut short** (interrupted, recovered or partial), **Mount moved at m:ss**,
  and a red **REC** while recording.
- Swipe to delete (with confirmation); no per-row buttons.
- One dismissible tip at the top: "Open a log in Gyroflow, then pick your lens."
- Tapping a take opens its page: a verdict first ("Ready for Gyroflow" with a status
  glyph), camera, length and "calibrated mount", a primary **Open in Gyroflow** (share
  sheet to Gyroflow when installed, otherwise the system share sheet), "Share another way",
  then a **Details** section with friendly labels ("Starts 0.12 s before REC", "Smoothness:
  No gaps", "Sample rate 200 Hz").
- Empty state: "No logs yet", "Turn on Gyro, then hit record. Each take saves a log you can
  open in Gyroflow.", **Turn on Gyro**.
- Landscape: list on the left, selected take on the right.

## Architecture (Core)

### Engine (platform-neutral Swift, shared by iOS and Android via JNI)

Move from `OpenZCineCore` into a new Core module (name the builder's call, for example
`OpenCineGyro`): take session, sample buffer, GCSV writer, log model and summaries, mount
calibration solver and session, camera-gravity conversion helpers, and the new drift
detector. Keep the existing tests and move them with the code. The Android bridge follows
the existing Core JNI pattern (`OpenCineJNI`), replacing `OpenZCineAndroidFacade`'s gyro
wire and JNI files.

### Camera adapter

A small protocol (Swift; Kotlin mirror where Android needs it) that a camera integration
implements to enable gyro capture:

- recording state changes;
- camera down vector readings with timestamps (from the camera's level sensor), or "not
  available";
- stabilization: read current values, list which settings matter (for example in-body VR,
  electronic VR), write "off", and restore given saved values; plus whether the mounted
  lens has its own VR switch, if knowable;
- a stable camera identity for per-camera calibration and pending restores.

A camera without level readings can still log gyro but cannot calibrate or detect drift;
the UI then hides those parts (coordinator's call). The Nikon implementation lives in
`OpenCineNikon` and uses the live-view header level angles and the movie VR (`0xD1F9`) and
electronic VR properties the DISP 3 stabilization tile already writes.

### Phone motion

The phone sensor drivers (CoreMotion on iOS, SensorManager on Android) move to Core's
platform layers.

### UI

Shared SwiftUI and Compose components in Core (placement among `OpenCineCameraControls`,
`MonitorUI` and the Android `camera-controls` / `monitor-ui` modules is the builder's call,
following where comparable monitor sheets live): arming sheet, calibration, logs list and
take page, gyro pill, post-take drift sheet. Strings are shared. Apps opt in by providing a
camera adapter and an entry point (Settings toggle and Logs row, as Z has today).

### OpenZCine adoption

Z pins the Core change, wires the Nikon adapter, replaces its gyro screens and coordinator
with the shared ones, and deletes `ios/Runner/Gyro*`, the Android `gyro/` package and the
gyro parts of `OpenZCineCore` and `OpenZCineAndroidFacade`. Saved logs and calibrations
must survive the move (migrate storage keys and file locations).

## Constraints

- Owner rules for this program apply: merge commits only, Core lands before app pins,
  shared component parity across iOS and Android, CodeRabbit threads handled before
  merge, heavy builds through `tools/heavy.sh`.
- External releases stay held for the hardware pass; this work must not block the internal
  builds currently being cut. Land it after those builds.
- Never change camera settings silently; never touch card contents.
- Accessibility: every visual state has a VoiceOver/TalkBack description; the ring progress
  is announced; haptics are paired with an accessible announcement.

## Verification

- Unit tests: solver and drift detector (including steady-moment gating and threshold),
  stabilization save/restore rules, log status mapping, storage migration.
- UI tests on simulator/emulator with a fake camera adapter for each screen state, in both
  orientations, iOS and Android.
- Hardware check (owner, Nikon ZR): arm with IBIS on, calibrate in portrait and landscape
  mounts, bump the phone mid-take, disarm and confirm VR restored, open a log in Gyroflow.

## Decisions confirmed by the owner (2026-10-25 evening)

1. **"Armed" lasts one connected session** (owner chose this). The saved Gyro toggle
   means "arm whenever possible"; a session is armed while the toggle is on and capture is
   eligible (connected, monitor showing, app in front, video mode, no multicam or relay).
   The arming sheet (IBIS step, calibration offer) appears at the start of each armed
   session. IBIS is restored when the armed session ends while the camera is still
   connected (toggle off, leaving the monitor, switching to photo, backgrounding,
   disconnecting cleanly). If the link drops before the restore can be written, the
   restore is owed and applied on the next connection before anything else.
2. **Logging without a calibration is allowed** (owner: yes). Backing out of calibration,
   or a camera without level readings, still arms and logs. The file carries the
   unverified default orientation, as uncalibrated takes do today, and the user aligns in
   Gyroflow. The logs screen adds a **Not calibrated** badge (amber) and the take page says
   so in place of "calibrated mount". No preset picker returns; any orientation model the
   engine needs stays internal.
3. **Gyroflow runs mostly on a desktop** (owner). The take page's primary action is
   **Share log** on both platforms (system share sheet: AirDrop, Files, Drive); there is no
   app-specific Gyroflow path, which keeps iOS and Android identical. The tip line becomes
   "Share a log to your computer, open it in Gyroflow with the clip, then pick your lens."
   The logs list gets a **Select** mode to share several takes at once (coordinator's
   call, for desktop batches). This replaces "Open in Gyroflow" and "Share another way"
   in section 6.

## Left to the builder

Module names and file layout, adapter method signatures, exact animation timings, the
stillness and target-zone tolerances (keep the solver's current acceptance), pill glyph,
and the storage migration mechanics.
