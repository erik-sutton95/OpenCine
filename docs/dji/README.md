# OpenCineDJI

DJI camera integration for OpenCine apps (Swift). Protocol, wire and session code moved from
OpenPocketCine `Sources/OpenPocketViewCore` without behavior change (plan work package VENDOR-01):

- DUML framing, transport and notification assembly; datalink handshake admission; HEVC
  depacketizer; setting mailbox; command builders (`Commands`).
- Camera model, control, capability and status decode (`CameraModel`, `CameraControl`, `CamCap`,
  `CameraStatus`, `CamAudioStatus`); feed watchdog, link diagnosis and recovery ladders.
- BLE adverts, SoftAP, station join, multicam discovery and Wi-Fi scan.
- Media endpoints and live resume; AE/AWB lock, face-priority exposure, tracking box; native gimbal
  target stream, native program zoom, gimbal reach.
- DJI colour data: log curves, monitor LUT catalogue, clip colour profiles.

Depends only on `OpenCineCore`, `OpenCineMedia` and `OpenCineMotion` (same package; root
`Package.swift`). No UI and no app types. OpenPocketCine re-exports this module from
`OpenPocketViewCore`, so its app and Android JNI facade import nothing new.

```sh
swift build && swift test --filter OpenCineDJITests   # from the repository root
```

`DJICameraSessionAdapter` is OpenCineCore's `CameraSession` for common capture controls
over a `DJIControlPort` the app's DJI session implements (Pocket: `CameraSession+DJIControlPort`).
`DJICameraSessionAdapterPortTests` drive it with a fake port, without any app. The adapter reads
time from OpenCineCore's shared `MonotonicInstant.now()` (injectable), lists what the connected
body cannot do (`CameraModel` flags: aperture, focus, zoom) as unsupported, and leaves everything
else unknown. It publishes timecode (`timecode_info`; Nano: unsupported) and live audio levels
(`cam_audio_status_v2` in dBFS; every known body), each unknown until the camera reports
(`CameraStatus.audioMeters` is `nil` until then). `CameraModel.motion` is what a body declares to
OpenCineMotion (`MotionCapabilities.pocketGimbal` with camera-reported pose; `nil` without a gimbal),
and `layout(base:)` projects the snapshot and that motion for a monitor. DJI's official
Rec.709 look curves live in `DJILook`, not on the neutral `LiveColorScience`.

The additive `DJICaptureControlState` supplies actual decoded reports separately from pending
presentation pins. It enables shutter durations, exposure compensation, AF-S/AF-C and zoom,
with mirrored Kotlin ports. Shutter choices come from the camera's capability report and require
reported Manual exposure; a common duration request never switches exposure mode implicitly.
Zoom bounds follow the reported format and mode. ACK and legacy optimistic settlement never
manufacture an observation; an actual matching report can confirm a sent command before its ACK.
Measured iris is a read-only f-number. Auto/Starburst aperture strategy remains a typed DJI panel.
Older ports retain their original controls until they provide this optional state and writes.

## Android (`Android/dji`, `com.opencapture.opencine:dji`)

The Kotlin DJI layer, moved from the OpenPocketCine app without behavior change (SHELL-04): BLE
link and initialization, the Wi-Fi datalink driver, DUML command and status models
(`CameraCommands`, `CameraStatus`, `CameraModel`, `VideoFormat`, `CamFov`), gimbal programs and
the native program runner, connection and live-view policies (`LiveViewEnablePolicy`,
`SessionRecovery`), Multiview `StationJoin`, `ConnectionPhase`, and `DjiCameraSessionAdapter`
(OpenCineCore `CameraSession` over a `PocketControlPort`). Depends on `core`, `media`, `decoder` and `platform`; Android framework adapters stay outside portable policy.
The adapter mirrors the Swift one for SHELL-01: timecode and audio level support and values
(`CameraStatus.audioMetersReported` keeps "not reported" apart from silence across the facade),
`pocketGimbal` and `CameraModel.motion`, and `layout(base)` with the same capture descriptor rules.
`DjiControlSessionBinding` caches one control seam per native connection, retires it before a
replacement, and fences late close callbacks from the successor. Borrowed Multiview settings
come from the tile's actual decoded aggregate; editor pins remain in the borrowed presentation.

Wire bytes come through `DjiNative`, a JNI facade whose class name is part of the native symbols
(`Java_com_opencapture_opencine_dji_DjiNative_<name>`). The Swift side is the product
`OpenCineDJIAndroid` (`Sources/OpenCineDJIAndroid`: the `@_cdecl` exports, `#if os(Android)`, and
the Darwin-testable `DjiNativeWire` helpers over OpenCineDJI). `OpenCineJNISupport`
owns JNI string, buffer and method lookup helpers over the `OpenCineJNI` header shim;
integration and app facades use that one implementation.
An app adds the product to the target that builds its Swift Android library and the 30 exports
ship in that `.so`; `consumer-rules.pro` keeps the Kotlin class in minified apps. The app calls `DjiNative.load(<its library>)` once at startup and points `DjiLog.sink`
at its diagnostics. Swift and Kotlin `CamFov` share `Fixtures/camfov-vectors.tsv`.

The session itself is here too: `DjiCameraSession` (BLE to pairing to camera Wi-Fi to datalink to
live picture, recovery, operator commands, Multiview station join), with the Wi-Fi joining and saved
credential stores, feed incident models, capture value lists and gamepad actions it uses. What
stays with the app comes in through `DjiSessionHost`: operator preferences, the feed incident
recorder and reliability reporting, build identity, and the face detector (`FaceDetectorPort`; the
app keeps ML Kit). The app keeps all UI.

## Integration contract (SHELL-02)

`DJIIntegration` (Swift, over a `DJIConnectPort` the app's DJI connect pipeline implements in
step 7) and `DjiIntegration` (Kotlin `:dji`, over a `DjiConnectPort` that `DjiCameraSession`
implements) are DJI's Core `CameraIntegration`:

- Discovery is `.passive` only (Bluetooth adverts). Profiles: the verified bodies; those that list
  in Multiview add Wi-Fi and hotspot setups (`MulticamSupport.appears`).
- One connection at a time over camera Wi-Fi or a Wi-Fi or hotspot setup that moves the camera.
  Steps are the connect card's ("Connecting over Bluetooth", "Joining camera Wi-Fi" or "Moving the
  camera to <network>", "Opening the video link" or "Finding the camera", "Starting the
  picture"); the approval prompt is `approveOnCamera("Approve on the camera")`. A camera whose
  preferred or last setup moved it connects with `restoreAccessPoint`.
- Adding a setup (`ConnectTarget.addRoute`) hands the network and password to the pipeline
  (Kotlin: saved to the shared network store first).
- Failures keep the session's copy, typed (Kotlin `DjiFailures.classify` where the session catches
  a connect error, published as `PocketCameraSession.failureDetail` beside the unchanged
  `failure`); a failed moving setup offers Edit setup, Try again and the camera's own Wi-Fi.
- The record after a connect: the used route preferred, the joined camera network, the advertised
  model id (`extras["modelId"]`), the time. `forget` drops the camera's saved Wi-Fi only.
- Tests: `DJIIntegrationTests` / `DjiIntegrationTest` against fake ports, same method names.

## Neutral Android utility ownership (SHELL-04)

`:media` owns incident classification, recovery-effect values/logging, diagnostic redaction,
shutter-angle math and EV display/parse math. DJI retains its existing incident DTO JVM paths
and methods as compatibility adapters through private Media value projections; they keep the
same schema, enum wire strings and export shape. New consumers use the neutral Media values.
The DJI EV `0x10` wire offset and supported +/-3 EV range remain integration-owned.

`:platform` owns Android Keystore sealing and configured Wi-Fi credential storage. It imports
no integration, UI or app and adds no third-party packages. Existing DJI and app wrapper classes
supply the unchanged `openpocketcine.camera-wifi` preferences namespace and key alias, camera
`.ssid`/`.password` keys and trimmed `ssid:` index. The envelope remains Base64 IV, colon,
Base64 AES/GCM payload, 128-bit tag and no AAD; unreadable ciphertext stays unknown and legacy
plaintext migrates idempotently. Multiview network storage keeps its existing separate alias.

Media's redactor defaults to redacting all SSIDs. The compatibility wrappers supply the
existing safe-network policy so neither app's exported diagnostic behavior changes. Neutral
shutter observations return `null` for unknown shutter/rate, matching Swift Media; legacy
Android capture wrappers keep their existing 180-degree/24-fps display fallback until their
callers migrate explicitly.

## Session names and compatibility

Android apps compose `DjiCameraSession` with a `DjiSessionHost`. These preferred
integration-level names are source aliases of the existing JVM types
`PocketCameraSession` and `PocketSessionHost`. The same class, constructor,
private fields and runtime owner remain in use. Legacy callers and compiled
entry points remain compatible; retirement of the old names belongs to a later
minor release after all consumers migrate. JNI class/member names are unchanged.
