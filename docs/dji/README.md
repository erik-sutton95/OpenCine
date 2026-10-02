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

`DJICameraSessionAdapter` is OpenCineCore's `CameraSession` for ISO, white balance and record
over a `DJIControlPort` the app's DJI session implements (Pocket: `CameraSession+DJIControlPort`).
`DJICameraSessionAdapterPortTests` drive it with a fake port, without any app. The adapter reads
time from OpenCineCore's shared `MonotonicInstant.now()` (injectable), lists what the connected
body cannot do (`CameraModel` flags: aperture, focus, zoom) as unsupported, and leaves everything
else unknown. It publishes timecode (`timecode_info`; Nano: unsupported) and live audio levels
(`cam_audio_status_v2` in dBFS; every known body), each unknown until the camera reports
(`CameraStatus.audioMeters` is `nil` until then). `CameraModel.motion` is what a body declares to
OpenCineMotion (`MotionCapabilities.pocketGimbal` with camera-reported pose; `nil` without a gimbal),
and `layout(base:)` projects the snapshot and that motion for a monitor; zoom, focus and aperture
still come from the body flags there because the app drives them outside the seam. DJI's official
Rec.709 look curves live in `DJILook`, not on the neutral `LiveColorScience`.

## Android (`Android/dji`, `com.opencapture.opencine:dji`)

The Kotlin DJI layer, moved from the OpenPocketCine app without behavior change (SHELL-04): BLE
link and initialization, the Wi-Fi datalink driver, DUML command and status models
(`CameraCommands`, `CameraStatus`, `CameraModel`, `VideoFormat`, `CamFov`), gimbal programs and
the native program runner, connection and live-view policies (`LiveViewEnablePolicy`,
`SessionRecovery`), Multiview `StationJoin`, `ConnectionPhase`, and `DjiCameraSessionAdapter`
(OpenCineCore `CameraSession` over a `PocketControlPort`). Depends on `core` and `media` only.
The adapter mirrors the Swift one for SHELL-01: timecode and audio level support and values
(`CameraStatus.audioMetersReported` keeps "not reported" apart from silence across the facade),
`pocketGimbal` and `CameraModel.motion`, and `layout(base)` with the same body-flag rule for zoom,
focus and aperture.

Wire bytes come through `DjiNative`, a JNI facade whose class name is part of the native symbols
(`Java_com_opencapture_opencine_dji_DjiNative_<name>`). The Swift side is the product
`OpenCineDJIAndroid` (`Sources/OpenCineDJIAndroid`: the `@_cdecl` exports, `#if os(Android)`, and
the Darwin-testable `DjiNativeWire` helpers over OpenCineDJI). `OpenCineJNISupport`
owns JNI string, buffer and method lookup helpers over the `OpenCineJNI` header shim;
integration and app facades use that one implementation.
An app adds the product to the target that builds its Swift Android library and the 30 exports
ship in that `.so`; `consumer-rules.pro` keeps the Kotlin class in minified apps. The app calls `DjiNative.load(<its library>)` once at startup and points `DjiLog.sink`
at its diagnostics. Swift and Kotlin `CamFov` share `Fixtures/camfov-vectors.tsv`.

The session itself is here too: `PocketCameraSession` (BLE to pairing to camera Wi-Fi to datalink to
live picture, recovery, operator commands, Multiview station join), with the Wi-Fi joining and saved
credential stores, feed incident models, capture value lists and gamepad actions it uses. What
stays with the app comes in through `PocketSessionHost`: operator preferences, the feed incident
recorder and reliability reporting, build identity, and the face detector (`FaceDetectorPort`; the
app keeps ML Kit). The app keeps all UI.

## Integration contract (SHELL-02)

`DJIIntegration` (Swift, over a `DJIConnectPort` the app's DJI connect pipeline implements in
step 7) and `DjiIntegration` (Kotlin `:dji`, over a `DjiConnectPort` that `PocketCameraSession`
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
