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
- Multicam (NIKON-01, `NikonMulticam.swift`): `NikonMulticamPolicy` (which saved paths may join:
  USB-C, router and hotspot yes; camera access point, HDMI capture, photography mode and offline
  no; a member is its body serial, never its host or path) and `NikonMemberControl`, the command
  side of one member's own control pump: per-member coalescing write queue with readback into
  that member's `NikonCameraSession`, record requests, and `lend`/`reclaim` for a full Live View
  that borrows the link without CloseSession. The member limit is the app's
  `ResourceBudget(qualifiedEntries:)`. `NikonMulticamTests` run 2, 3 and 4 bodies through
  OpenCineMulticam (test-only dependency).

Depends only on `OpenCineCore` (same package; root `Package.swift`). No UI
and no app types. OpenZCine re-exports this module from `OpenZCineCore`, so its iOS app and
Android JNI facade keep their imports.

```sh
swift build && swift test --filter OpenCineNikonTests   # from the repository root
```

## Android (`OpenCineNikonAndroid`, `Android/nikon`, `com.opencapture.opencine:nikon`)

Moved from OpenZCine's Android facade and Kotlin bridge without behavior change (SHELL-04):

- Swift `OpenCineNikonAndroid` (over `OpenCineNikon` and `OpenCineJNI`): `PTPIPClientSession`
  (PTP-IP and USB PTP session layer, live-view pump, property readback, media browse and
  transfer), the USB transaction transport, the owner-keyed `AndroidSessionOwnerRegistry`, link
  health, session recovery, camera Wi-Fi parsing wires, and `NikonNativeJNI.swift`, the JNI exports
  of the Kotlin class `NikonNative`. Everything but the JNI exports builds and tests on Darwin
  against scripted fake cameras (`OpenCineNikonAndroidTests`).
- Kotlin `:nikon` (package `com.opencapture.opencine.nikon`): the Nikon session contract
  (`CameraSession`, `LiveFrameSource`, `FakeCameraSession`), `SwiftCoreCameraSession` and
  `SwiftCoreLiveFrameSource` over `NikonNative`, the property and metadata wires, ISO and
  white-balance picker policy, the PTP-IP initiator identity (same bytes as Swift's
  `PTPIPInitiator.appGUID`), the `UsbPtpTransport` seam, and `NikonOpenCineSession`, OpenCineCore's
  Kotlin `CameraSession` over the Nikon session.

The app links `OpenCineNikonAndroid` into its Swift Android library (which therefore exports
`Java_com_opencapture_opencine_nikon_NikonNative_*`), loads that library once through
`NikonNative.load(<its library>)` before any session exists, and supplies the Android USB host
(`UsbPtpTransport` implementation), discovery, pairing, preferences and UI. `consumer-rules.pro`
keeps the package and every `UsbPtpTransport` and listener implementation in minified apps.

```sh
swift test --filter OpenCineNikonAndroidTests          # from the repository root
(cd Android && ./gradlew :nikon:test)
```

Not here (yet): the generic monitor/assist/preferences stack, the contributed LUT table and
Frame.io (plan OPTIONAL-01) stay in OpenZCine; the iOS PTP transports (`PTPIPTransport`,
`USBCameraTransport`, `NativeCameraSession`) stay in the app for now.
