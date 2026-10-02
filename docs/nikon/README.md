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

- Swift `OpenCineNikonAndroid` (over `OpenCineNikon` and `OpenCineJNISupport`): `PTPIPClientSession`
  (PTP-IP and USB PTP session layer, live-view pump, property readback, media browse and
  transfer), the USB transaction transport, the owner-keyed `AndroidSessionOwnerRegistry`, link
  health, session recovery, camera Wi-Fi parsing wires, and `NikonNativeJNI.swift`, the JNI exports
  of the Kotlin class `NikonNative`. Everything but the JNI exports builds and tests on Darwin
  against scripted fake cameras (`OpenCineNikonAndroidTests`).
  Its JNI exports and USB transport use the same `OpenCineJNISupport` string, buffer
  and method lookup helpers as the other integration and app facades.
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

## iOS transports (SHELL-04)

`PTPIPTransport` (two BSD TCP sockets, the PTP-IP Init handshake and framing, port probes for
discovery) and the USB-C transport (`USBCameraDeviceBrowser`, `USBCameraTransport` over
ImageCaptureCore, `DeviceUSBConnector`), both `CameraTransport`s, and `NativeCameraSessionError`
moved here from OpenZCine `ios/Runner` without behavior change. They sit behind a file-wide
`#if canImport(Darwin)` / `#if os(iOS)`, so the Android build (and, for USB, `swift test` on
macOS) compiles them out; the import rule test allows Darwin, os and ImageCaptureCore only that
way. The app sets two hooks at launch: `PTPIPTransport.connectionLog` and
`USBCameraDeviceBrowser.shared.onEvent` (authorization, attach, detach). Logs use subsystem
`OpenCineNikon`.

Not here (yet): the generic monitor/assist/preferences stack, the contributed LUT table and
Frame.io (plan OPTIONAL-01) stay in OpenZCine; the iOS session orchestration
(`NativeCameraSession`, with its saved-camera store) stays in the app for now.

## Discovery behind a dialer (SHELL-02)

`NikonDiscovery` (Swift, moved from OpenZCine's `NativeCameraDiscoveryService`; Kotlin `:nikon`,
from `RelayPresenceScanner` and `InfrastructureCameraFinder`) runs every network dial through a
`NikonDialer` (presence port: presence reads and liveness; PTP/IP control port: mute port scan and,
on iOS, the PTP Init that names a camera). Bonjour/NSD and USB are listening sources the app
supplies.

- `.passive` (the cameras list): Bonjour, USB, the presence sweep (at most every 30 s) and
  liveness dials of saved hosts. Never a control-port dial, never a PTP byte: the pass has no probe
  step and its dialer (`PassiveDialer`) refuses camera-control dials.
- `.active` (pairing or a setup watch): also Init of trusted hosts Bonjour did not report, then a
  two-pass sweep (mute scan, Init only the hosts that answered; Android stops at the first open
  host and names it at connect). Hosts another device serves (the presence shield) and excluded
  hosts are never dialled.
- `PosixNikonDialer` (iOS) is the production dialer over POSIX sockets and `PTPIPTransport`; the
  app decodes its own presence line. Tests: `NikonDiscoveryTests` / `NikonDiscoveryTest`, same
  method names (zero camera-control dials and zero PTP bytes in `.passive`).

## Integration and saved setups (SHELL-02)

`NikonIntegration` (Swift and Kotlin) is the Nikon `CameraIntegration` over a `NikonConnectPort`
the app implements with its own pipeline: the discovery loop (passive for the cameras list,
active only while a pairing listener asks), the connect funnel, its phases and its forget. The app
keeps its save rules: it writes its saved setups as before and the integration reads them back for
the connected camera. Before connecting to a camera another device holds, the integration asks
with a `NikonTakeOverPrompt` (the app's prompt slot renders it). Pairing and the access point's
restart are approve-on-camera prompts; the access point join is the common network-join prompt.
Tests: `NikonIntegrationTests` / `NikonIntegrationTest`, same method names
(`theCamerasListNeverAsksForActiveDiscovery` pins the passive rule at the integration).

`NikonSavedRecordsV0` reads and mirrors the app's saved setups for the shared saved-camera
document: on iOS the `PTPIPSavedCameraRecord` array (grouped by serial, camera id `serial:<n>`),
on Android the `openzcine.saved-cameras` JSON (grouped by assigned camera name, id
`name:<name>`). One route per setup, most recently seen first; a patch only renames, retitles and
removes, and appends a setup the document has that the records do not. Golden fixtures written by
the app's own encoders: `Fixtures/saved-cameras/nikon-records-v0-ios.json` (regenerate with
`OPENCINE_WRITE_FIXTURES=1 swift test --filter NikonSavedRecords`) and
`nikon-records-v0-android.json` (OpenZCine `SavedCameraRecordsFixtureTest`).


## Monitor lifetime and wire runtime (SHELL-03 Z-1a)

On iOS, `NativeCameraSession` is the integration's real PTP session, including establishment,
transport ownership, property/descriptor/storage operations and live-view parsing. The app keeps
its GUID and paired-host store, saved setups, credentials, OS joining and permissions. An optional
per-session live-view-object callback supplies debug capture without a process-wide app hook.

`NikonMonitorRuntime` owns common ISO/WB/record queues, selector-first `NikonPropertyBootstrap`,
the sole `NikonLiveViewPump`, bounded restart escalation, idle keepalive and pushed events. The
app supplies preview demand and consumes frame/header and bootstrap values; its decoder, effects,
scopes, UVC picture, relay/watch projection and typed Nikon focus/still actions stay outside this
wire runtime. Interactive work still precedes maintenance at the existing safe point. A clock
correction waits for an authoritative idle frame header, never an optimistic app record target.

The common session keeps its ID during replacement, holds reports while recovering and advances
its control epoch on readiness. A retired reader drains before a multicam member gets its kept
link back, without CloseSession or stop-record. Routine covers and display changes drain their
pending fetch rather than cancelling a kept transaction socket. Short covers keep live view warm;
a cover lasting 30 seconds stops live view, and resume uses the first-frame deadline. HDMI retains
its independently owned picture while Nikon's header/control carrier recovers.

Both app shells own the common monitor lifetime and `MonitorControlModel` owns pending edits,
obsolete editors and command receipts. Kotlin reuses the root's `NikonOpenCineSession` instead of
creating a second screen-owned adapter; `setHoldsControl` supplies relay control surrender without
changing camera reports. Optional close hooks remain additive for existing consumers. The native
single-camera monitor, settings and media composition are later shell slices. Scripted tests cover
queues, bootstrap order, held recovery, cover/header transitions and late-reader retirement;
physical Nikon behavior remains untested.
