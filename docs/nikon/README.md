# OpenCineNikon

Nikon camera integration for OpenCine apps (Swift). Protocol, wire and session code moved from
OpenZCine `Sources/OpenZCineCore` without behavior change (plan work package VENDOR-02):

- PTP/IP packets, handshake, transactions and read buffer; PTP/USB containers and object
  transfer; operations, events, device info and the transport seam (`CameraTransport`).
- Nikon property codes, decoders, write encoders and snapshots (`PTPCameraProperties`), live-view
  object header, capability profiles, still capture, ISO and white-balance policy, raw crop,
  clock sync, busy hold, R3D clip index/header and Nikon media file naming.
- Discovery (passive listing, infrastructure scan plan), Wi-Fi SSID and screen parsing,
  credential handoff, camera paths, connect progress and diagnostics, saved camera records and
  path groups, per-setup stream settings (`LiveViewStreamPreset`, `LiveViewQualityBias`), session
  recovery, reconnect backoff, link health, throughput, signal bars, poll pacing and watchdog.
- `NikonCameraSession`: OpenCineCore's `CameraSession` for ISO, white balance and record over a
  `NikonControlDriver` the app's control service implements (OpenZCine: `NativeAppModel`).
  Settings need no picture; record keeps its live-view preflight.

Depends only on `OpenCineCore` (same package; root `Package.swift`). No UI
and no app types. OpenZCine re-exports this module from `OpenZCineCore`, so its iOS app and
Android JNI facade keep their imports.

```sh
swift build && swift test --filter OpenCineNikonTests   # from the repository root
```

Not here (yet): the generic monitor/assist/preferences stack, the contributed LUT table and
Frame.io (plan OPTIONAL-01) stay in OpenZCine; the iOS PTP transports (`PTPIPTransport`,
`USBCameraTransport`, `NativeCameraSession`) and the Android JNI facade
(`PTPIPClientSession`, `AndroidSessionOwnerRegistry`) stay in the app for now.
