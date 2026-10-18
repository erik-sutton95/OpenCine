# OpenCineCore

Portable common contracts for the OpenCine camera monitor apps: identity, observations with
provenance, capability descriptors, camera state, the command lifecycle, monitoring-entry
composition and a small camera-session seam. Manufacturer integrations translate their
protocols into these values; shared UI and multicam read them without knowing which camera is
behind them.

Status: pre-release (plan work package CORE-01). No production app depends on it yet. Expect
interface changes driven by the first real adapter slices (CORE-02).

## Products

| Product | Contents | Use from |
|---|---|---|
| `OpenCineCore` | Value types and the `CameraSession` protocol, plus `CameraValuePin` (a requested setting held against older reports until the camera confirms it or the settle window ends) and `LocalVPNFilter` (local VPN operator copy, the 8 s live-feed hint and tunnel interface names; Kotlin core twin, Android detection in `:platform` `LocalVPNProbe`). Foundation only. | Integrations, multicam, UI presentation, apps |
| `OpenCineCoreTestSupport` | Deterministic fakes (`FakeCameraSession` in DJI-like, Nikon-like and Luna-like configurations, picture-only and control-only entries) | Test targets only; never link into an app |
| `OpenCineMedia` | Portable media math: `.cube` parsing and interpolation, custom LUT index, LUT exposure compensation, published transfer curves, scope anchors and display scale, traffic lights, false-colour scales (Video, IRE, Limits, CineStop and the LOG/709 reading), zebra defaults, shutter angle, frame-rate sampling, feed framing, camera link health scoring (`CameraLinkHealthScorer`) and its hysteresis signal bars (`LinkSignalBars`, Kotlin `media` twins in `CameraLinkHealth.kt`). The encoded-unit seam: `EncodedVideoUnit` (stream, generation, codec, Annex-B or JPEG payload, random access, parameter sets, host arrival, optional PTS and format), HEVC/AVC NAL math (`Hevc`, `Avc`, `LiveVideo`), decoder parameter-set policy (`EncoderPresentPath`), present policy (`FeedPresentPolicy`, `SerialSessionGate`, `ExtraMirrorHold`), `DeliveryCadence`, and the Apple-only scope tap `LiveFrameTap`. Diagnostics: `PrivacyRedactor` (the host's `isSafeNetwork` keeps its camera access points), the journal event and report model (`DiagnosticEvent`, `DiagnosticEnvironment` with the host's product name, `DiagnosticReport`) and the typed feed incident model (`FeedIncident*` snapshots, recorder, classifier, `FeedIncidentExport`, `FeedIncidentCoding`); the on-disk incident store stays with the app. Foundation plus OpenCineCore; builds with the Swift Android SDK. | Integrations, app cores, Android JNI facades |
| `OpenCineFrameIO` | Optional Frame.io delivery: v4 request planning (`FrameioAPI`), OAuth PKCE primitives and IMS token requests (`FrameioOAuth`, `PKCE`), response models, the upload workflow with injected transport, token storage, clock and pause (`FrameioClient`, `firstWorkspaceProjects`), the saved destination and project listing values, batch results with history and cleanup reporting (`FrameioDelivery`, `FrameioDeliveryReport`, `FrameioUploadHistoryIndex`), and an Apple `URLSession` transport. Foundation only (CryptoKit on Apple platforms). See [OpenCineFrameIO](#opencineframeio). | Apps that deliver to Frame.io; Android JNI facades |
| `OpenCineMotion` | Optional. The typed motion seam: `MotionCapabilities` (supported axes, reference frame, `MotionBounds` position bounds, optional rate bound, feedback max age, arrival tolerance, pose reporting support), `MotionTarget` (made only inside the declared bounds), feedback validity over `ObservedValue<GimbalWaypoint>`, the `MotionService` protocol (stick, recenter, timed move to a target, stop, pose stream) and the `MonitorLayoutCapabilities(_:motion:base:)` projection (gimbal = pan and tilt axes, head tracking = gimbal plus camera-reported pose). Shared trajectory math: `GimbalWaypoint`, `GimbalProgram`, `GimbalProgramCurve`, `GimbalPath`, head-look math (`HeadTrack`) and bounded head tracking (`HeadTrackNative`). The programmed-move runner `GimbalMoveEngine` (timed targets, pause and resume, loop verification, the zoom path and its `NativeProgramZoom` demand) bound to the declared `MotionCapabilities`, display-only `GimbalOverlayMotion`, the world level (`WorldLevel` gravity from a camera attitude, the smoothed `LevelReading`, `WorldLevelTarget` and the `WorldLevelSnap` move and judgement), and the waypoint overlay projection (`GimbalWaypointOverlay`, field of view as a parameter) with its picture-direction mapping (`GimbalWaypointPresentation`). Foundation plus OpenCineCore; Core and Media never depend on it. | Gimbal integrations and app cores |
| `OpenCineRelay` | Optional. The second-screen relay wire, protocol version 1: Bonjour service type, `[u32be length][u8 kind][payload]` framing, JSON messages (hello, state, control token, join denied, commands), the frame blob, exact version check in `WatcherRelayJoin`, the single-holder control lease (`WatcherRelayControlLease`, 20 s park for a dropped watcher), bitrate ladder, encode admission, watcher recovery and focus-point mapping. Golden wire tests pin every message kind. Foundation plus OpenCineCore battery values; sockets, Bonjour and the encoder are in `OpenCineRelayApple`, the passcode keychain stays in the apps. | App cores that host or watch a relay |
| `OpenCineRelayApple` | Optional. The relay's Apple shell: `WatcherRelayHost` (MainActor model) over `WatcherRelayTransport` (Bonjour listener, admission of two source frames, HEVC re-encode via `WatcherRelayEncoder`, per-peer fan-out, join, lease and denial handling), `WatcherRelayReader` (off-main framing), `WatcherRelayBrowser`, the shared-Wi-Fi `WatcherRelayNetwork` parameters (no peer-to-peer, no cellular) and `WatcherRelayKeychain` (the app's relay secrets: writes update in place and count only once they read back, an unreadable Keychain is `unavailable` rather than an empty passcode, and `adoptLegacy*` moves a secret an app kept elsewhere only when stored). The app supplies its version-mismatch copy, log subsystem and journal; state broadcasts default to 0.2 s. Depends on `OpenCineRelay` plus Network, VideoToolbox, CoreVideo, CoreMedia, Observation and os; every file sits behind `#if canImport(Network)`. | iOS apps that host or watch a relay |
| `OpenCineWatch` | Optional. The Apple Watch companion over the watch protocol in `OpenCineRelay` (`WatchRelayEnvelope`, one-byte kind plus JSON; `WatchRelayState`, `WatchRelayFrame`, `WatchRelayCommand`, `WatchCommandResult`, the wrist placeholder and copy). iOS: `WatchRelay` (WatchConnectivity session, drop-stale preview pump of three in flight, JPEG thumbnails through the monitor working space of `OpenCineApple`, Record and shutter commands to the app's closures). watchOS: `WatchReceiver` over any `RelayWatchCodec`, `WatchReceiverScene` (owns the receiver, activates it on appear and re-arms it on return to active), `WatchCompanionScene` and `WatchMonitorView` for the common codec. The app supplies its name for the wrist placeholder (`WatchRelayCopy.openOnIPhone(appName:)`) and maps its camera status to a `WatchRelayState`. Depends on `OpenCineCore` and `OpenCineRelay` (and `OpenCineApple` on iOS) plus WatchConnectivity, SwiftUI, WatchKit, UIKit, CoreImage, CoreVideo, VideoToolbox and os; every file sits behind `#if os(iOS)` or `#if os(watchOS)`. | iOS apps with a watch companion and their watchOS apps |
| `OpenCineApple` | The Apple runtime (plan 3.2, MEDIA-02). `DecodedFrameLease` (stream, generation, format, timestamp and an explicitly released `CVPixelBuffer`) and `DecodedFrameFence` (the stream's current generation; publication refuses and releases a stale lease). `VideoToolboxDecoder`: the retained `AVSampleBufferDisplayLayer`, H.26x format descriptions from parameter sets, the `VTDecompressionSession` creation ladder, live sample buffers (`LiveViewPresentTiming`), generation-fenced decode into leases and the decode-error ledger, with integration hooks (rebuild-class statuses, journal, log subsystem). `UVCVideoSource`: an iPadOS HDMI/UVC capture source that lends each frame as a lease. `JPEGPixelBufferDecoder` (SHELL-04): hardware motion-JPEG decode to `420v` that lends each frame as a lease stamped by its own fence (advance it per live-view stream). Depends on OpenCineCore and OpenCineMedia; every file is gated with `#if canImport`/`#if os`. | iOS apps and Apple integrations |
| Android `com.opencapture.opencine:core` | Kotlin mirror of `OpenCineCore`; the fakes ship as its test fixtures. See [Android](#android). | Android integrations and apps |
| Android `com.opencapture.opencine:media` | Kotlin side of the encoded-unit seam: `EncodedVideoUnit`, `Hevc`/`Avc`/`LiveVideo` NAL math, and the Android decoder's portable policy (`LiveAccessUnit`, `CompressedAccessUnitAdmission`, `DecoderRandomAccessHold`, `DecoderInputOwnership`, `DecoderErrorLifetime`, `EncoderPresentPath`, `LivePictureSps`, `LiveDecoderTuning`, `LiveHevcCodec`, `LivePipelineCadence`, `LiveViewPresentTiming`, `FeedPresentPolicy`), `PrivacyRedactor` and the typed feed incident model (`FeedIncident*`), with the same names as Swift, plus the bounded manual report `BoundedDiagnosticFormatter` (Swift `DiagnosticReport.manualReport`) and the non-blocking `DiagnosticJournal`. No Android framework: MediaCodec and Surface stay in the app. | Android apps |
| Android `com.opencapture.opencine:vulkan` | The native Vulkan live-feed renderer `libopc_vulkan.so` (moved unchanged from Pocket, MEDIA-02): imports the decoder's `AHardwareBuffer`, grades with 3D cubes, draws scopes and grab-pass glass, presents to the `SurfaceView` swapchain; upright-raster (Pocket #482) and present-batch lifetime included. Android library (NDK 28.2, CMake, shaders compiled by the NDK `glslc` and embedded), arm64-v8a only. The JNI facade keeps its original name `com.opencapture.openpocketcine.feed.OpcVulkan` because the 21 exported symbols derive from it. The session that drives it stays in the app. | Android apps |

## Timecode compatibility

`CapabilitySnapshot.timecode` retains its published `SupportStatus` type. Read the additive
`timecodeCapability` for source-declared precision. The support-only initializer does not infer
precision. Swift Codable retains the published enum case tag under `timecode`, adds the richer
field separately, and accepts the published tag, the earlier rich-object checkpoint and explicit
known support strings. Kotlin keeps the original constructor, copy and component signatures.

`CameraTimecode` remains a frame-complete value with an integer `frames` field. Use
`CameraTimecodeReading` and `CameraSnapshot.timecodeReading` for a source that may report only
whole seconds. `frameTimecode` converts a reading only when a frame count exists; the legacy
snapshot observation otherwise has no value and retains its provenance. Current monitor
formatting reads the precise observation. Copying a snapshot preserves that reading.

The legacy FPS-labelled clock helpers remain for an explicitly known positive caller rate.
They synthesize a clock counter, not camera frame telemetry. Their optional note method refuses
nonpositive rates before reserving a reading; static frame-complete synthesis requires a positive
rate. The former unknown-rate guess is unavailable. Current camera observation callers use the
no-FPS seconds-only methods. Swift and Kotlin keep these boundaries in step.

The portable `FrameioInternetHop` token owner remains available through app migration beside the
app shell's `MonitorInternetHop`. It owns no credentials, network actions or UI. Its host supplies
executor confinement and native leave/rejoin actions. Migrate each consumer in its reviewed pin
move before removing either legacy contract in a later incompatible release.

## Retry delay policy

`RetryBackoff` is the pure jittered exponential calculation shared by the integrations.
The caller supplies the initial delay, maximum, growth factor and jitter sample.
Inputs and result use the same caller-chosen unit; it owns no clock, random source,
sleep or retry lifecycle. Swift and Kotlin expose the same values and valid vectors.
Legacy reconnect adapters keep their existing defaults, public names and units;
integer millisecond conversion remains at the consuming boundary.

## OpenCineMedia rules

- Pure functions and value types. No mutable global state: a test rejects `static var` and
  `nonisolated(unsafe)` in `Sources/OpenCineMedia`.
- Imports Foundation and OpenCineCore only. `LiveFrameTap` (CVPixelBuffer to BGRA8) is the one
  Apple-only helper and sits behind `#if canImport(CoreVideo)`. Platform decoders, sample buffers
  and surfaces stay in native runtimes; `EncodedVideoUnit` carries bytes and identity only.
- Vendor framing stays with the integration: a private marker NAL or a vendor live-view enable
  request is stripped or decided before units reach these helpers.
- No camera raw modes. `MonitorTransfer` names a published curve; mapping a camera's colour
  mode or a tap fingerprint to a curve belongs to the integration.
- Per-source inputs are parameters. The live clip ceiling (`clipByte`, measured per source by
  the integration), the operator's LOG/709 reading and the official look's grey-axis curve
  (`lookCurve`, derived from the integration's own cube) are passed in by the caller.
- Numbers are golden. Moving or refactoring must not change a test value; a changed look needs
  an explicit fixture review.
- The 8-bit, 256-bin scope axis is the qualified implementation. Richer formats get new
  descriptors, not a silent change to these functions.
- Renderer size policy stays with the app (`colorCube` caps at 64 for Core Image; OpenZCine
  resamples 65³ imports to 33³ with `resampled(to:)`).

## OpenCineMotion rules

- Optional: nothing in `OpenCineCore` or `OpenCineMedia` imports it, and no camera session is
  required to offer motion. A test enforces both, plus Foundation and OpenCineCore imports only
  and no manufacturer names.
- The integration declares `MotionCapabilities`; shared math takes the declared `MotionBounds`
  as a parameter. A `MotionTarget` exists only inside the bounds, head tracking projects into
  them, and `admits(_:)` rejects a program with an unreachable point, an undeclared zoom change
  or a leg over the declared rate (fuzzed gate tests).
- `MotionService` is the whole command surface today's apps use: stick, recenter, timed
  `move(to:over:)`, `stop` and `poses()`. A programmed move runs as timed targets after
  `admits(_:)`; gimbal mode and speed options stay integration extensions until a second
  integration shares their meaning. Kotlin: package `com.opencapture.opencine.motion` in `:core`
  (capabilities, targets, feedback, service, projection, the world level, and `GimbalWaypoint`,
  `GimbalWaypointSlot`, `GimbalProgram` with `pose`/`duration`, `GimbalProgramCurve`, `GimbalPath`
  and `GimbalWaypointOverlay`; the Kotlin move engine stays in `Android/dji` and head-look math
  is Swift only).
- Raw wire units, coordinate transforms, command pacing, tracking encoders and stick shaping
  stay in the integration. A world reference frame needs the camera to hold one; a phone IMU
  sample alone does not establish it.
- Moved test numbers are golden.

## OpenCineRelay rules

- Optional: no other Core product imports it (a test enforces it). Foundation only, no
  manufacturer or app names (its Apple shell `OpenCineRelayApple` follows the same test with
  Apple networking and encoding frameworks added); user-facing copy that crosses the wire (the version-mismatch
  reason) is a parameter supplied by the app.
- The watch companion's wire (`WatchRelayEnvelope`: kind byte `0x01` state, `0x02` frame, `0x10`
  command, `0x11` result, then the JSON payload) and its copy are the apps' shipped ones byte for
  byte; `OpenCineWatch` follows the relay import test with WatchConnectivity, SwiftUI, WatchKit,
  UIKit, CoreImage and `OpenCineApple` added.
- The wire is frozen at `WatcherRelayProtocol.version` 1. Golden tests pin header bytes, the
  frame blob and every JSON message; changing one is a wire break that needs a new version, a
  negotiation path for old watchers and an adapter, not an edit to the golden.
- Version negotiation is exact (host and watcher must both speak version 1). New optional JSON
  fields stay optional so older peers keep decoding; unknown keys are ignored.
- Sharing the package shares no credentials: each app keeps its own keychain namespace for the
  relay passcode.
- OpenZCine keeps its own `MonitorRelayProtocol` (version 2, `_openzcine-mon._tcp`, JPEG or
  HEVC frames, per-frame focus/box/sound metadata, a TCP presence beacon on port 15741, Android
  and watch peers). Its framing bytes and kind numbers match version 1 here, and its 20 s parked
  lease has the same rule, but every JSON body differs, so one product cannot serve both without
  breaking a shipped peer. Unifying needs: a shared framing and lease layer parameterised by the
  kind set and size limit, per-family message codecs behind it, a new joint version that both
  hosts can offer alongside their current one, and golden tests for both existing wires before
  anything moves.

## OpenCineApple rules

- OS media frameworks (VideoToolbox, AVFoundation, CoreMedia, CoreVideo, UIKit for the UVC
  hardware check) live here and nowhere lower: no other Core product imports them or this
  product, and every file is gated so the package still resolves and builds off Apple platforms.
  A test enforces both, plus no manufacturer names.
- Codec runtime, not presentation policy. Which path shows the picture (compressed layer or
  decoded buffers), assists, random-access holds and recovery requests stay with the app or
  integration that owns the picture; vendor-measured predicates and logging arrive as `Hooks`.
- The display layer lives as long as its decoder. Reparenting a host view never recreates the
  session or advances the generation; only `invalidateSession()` (reset, rebuild, reconnect)
  does, and it fences every in-flight output first.
- A lease is lent, not given: consumers take their own `pixelBuffer` reference to keep pixels past
  the callback. A refused or superseded lease is released at once.
- Operator copy (for example the UVC state messages) stays in the app.

## Import rules

- `OpenCineCore` imports only Foundation. It never imports UI, a manufacturer integration,
  Multicam or an app. Platform media types (`CVPixelBuffer`, `UIImage`, `Bitmap`, GPU textures)
  never appear in portable state.
- Shared code never chooses behavior from a manufacturer name or `IntegrationID`.
- `Tests/OpenCineCoreTests` enforces the import and brand-name rules on `Sources/OpenCineCore`.

## Model in one screen

- **Unknown is `nil`.** Every telemetry field is an `ObservedValue` (named so it never shadows
  Swift's Observation module, so `@Observable` files can import OpenCineCore) whose `value == nil` means
  unknown, never `false`, `0` or `""`. Observations carry origin (camera-reported,
  protocol-derived, image-estimated, clock-derived, operator-provided, unknown), timestamp,
  validity and optional precision. Freshness is computed against a caller-supplied `now`.
- **One host clock.** Production `now` and every timestamp come from `MonotonicInstant.now()`, one
  process-wide reference (Swift `ContinuousClock`, Kotlin `System.nanoTime()`). Integrations never
  keep their own origin, so a cross-brand deadline or freshness check compares like with like;
  sessions take an injectable `() -> MonotonicInstant` for tests.
- **Capabilities have four layers:** support (in `CapabilitySnapshot`), value domain and access,
  current availability with a typed reason, and semantics (native or emulated, readback or
  acknowledgement only, qualification). Any change advances `CapabilityRevision`.
- **Settings use a reviewed sum type** (`SettingValue`) whose case implies its key: ISO ladder or
  bounded auto, shutter as native duration or native angle, aperture, exposure compensation,
  white balance, white balance tint (its own key, so a camera without tint lists it unsupported),
  rational frame rate, focus mode, zoom. `recording` and `focusPoint` are
  command-only controls.
- **Reported state is separate from requested state.** `RecordingState` is camera-reported only.
  Command progress lives in `CommandReceipt`, tracked by `OperationID`:
  `created > admitted > sent > accepted > awaitingObservation > confirmed`, or `rejected`,
  `failed` (`notApplied`, `notSent`, or `superseded` by a newer write to the same setting),
  `timedOut`, `outcomeUnknown`. `receipt(of:)` reads the current stage without waiting.
- **Recording uses explicit start and stop.** UI toggles resolve against a fresh snapshot first.
- **Admission is shared.** `CameraSnapshot.rejection(of:at:)` checks session, connection, control
  epoch, deadline, authority and lease, capability revision, support, access, availability and
  domain. Integrations add their own protocol rules after it.
- **Monitoring entries compose roles.** `MonitorEntryDescriptor` holds an optional picture, an
  optional camera session, telemetry and control authority; at least one role must exist.
- **`CameraSession`** offers a bounded latest-value snapshot feed and reliable outcomes. Its doc
  comment specifies buffering, cancellation and close semantics.
- **Timecode and live audio levels are observations, not settings.** `CameraSnapshot.timecode`
  (`CameraTimecode`; time of day derived from a clock is `.clockDerived` and never claims sync)
  and `CameraSnapshot.audioLevels` (`AudioLevels`, stereo dBFS with optional held peaks), with
  support in `CapabilitySnapshot.timecode` and `.audioLevels`. Live audio samples, camera audio
  settings and clip audio metadata are separate and never imply live levels.
- **`MonitorLayoutCapabilities`** is a separate ten-field layout projection matching the UI's
  current `MonitorCapabilities`, derived from the richer model where Core has vocabulary:
  zoom, focus and iris from writable settings (unknown is no section), timecode and audio from
  observation support (unknown keeps the app's `base`), gimbal and head tracking from
  OpenCineMotion's overload.
- **One control capability model** (`ControlCapabilities` in `OpenCineCameraVocabulary`, Kotlin
  `camera-vocabulary`) is what the shared capture UI reads per user-facing control family (ISO,
  shutter, white balance, tint, iris, ND, focus, tap focus, face metering, EV, codec/colour,
  recording format, audio, live audio levels, zoom, gimbal, head tracking, timecode, recording,
  photo, media, media delete, multiview): support (unknown is never false), access (read-only is a
  readout) and the typed values it offers. Each integration provides it from its body's
  `CameraCaptureProfile` (flags plus `controls` declarations) merged with the live
  `CapabilitySnapshot` and `MotionCapabilities`; apps set no capability literals.
  `MonitorLayoutCapabilities(controls:base:)` and `CaptureSheetCapabilities(controls:)` are
  computed views of it. `Fixtures/control-capabilities-{dji,luna,nikon}.tsv` is its per-body
  export (written by `ControlCapabilityFixtureTests`, checked by Swift and Kotlin), which
  `parity-metrics` reads to compute n/a cells. Host features (assists, relay, watch, settings
  tabs, local stars, the internet hop) are not camera capabilities.

## Integration contract (SHELL-02)

`Integration.swift` and `SavedCameras.swift` (Kotlin `Integration.kt`, `SavedCameras.kt`): how shared
code finds, pairs, connects and forgets cameras of any integration. Apps list their integrations
explicitly; integration copy (steps, failures, prompts) is rendered, never rewritten.

- **`CameraIntegration`** (main actor): `id`, `profiles` (`CameraProfile`: routes and addable routes),
  `discoveryModes`, `discover(_:)` (latest `[NearbyCamera]` per element), `connect(_:)` (one attempt
  as `ConnectionEvent`s: progress with an optional prompt, then `connected` or `failed`, both
  terminal) and `forget(_:)` (route credentials, never the per-install identity).
- **Passive or active discovery.** `.passive` listens and may dial presence only; it never opens a
  control-port connection or sends protocol bytes. `.active` is for an operator pairing or adding
  a setup. A mode the integration does not list finishes at once (conformance scenario 15).
- **One attempt per camera.** `ConnectTarget.cameraID` names the camera; once a newer attempt for it
  starts, the older one emits nothing. Cancelling the consumer cancels the attempt.
- **Typed failures and recovery.** `ConnectionFailure` carries a `Reason` (permission, radio off,
  not found, timed out, not approved, held elsewhere, ...), integration copy, a stable diagnostics
  `code` and `RecoveryAction`s (retry, use or edit a route, pair again, open settings, or an
  integration action).
  Thrown (Swift), it reads as its message through `LocalizedError`.
- **Prompts.** `approveOnCamera`, `acceptNetworkJoin`, or an integration-owned `IntegrationPrompt`
  for the app's prompt slot. `RouteDraft` never prints its secret.
- **`ConnectedCamera`**: the saved record to upsert, the `CameraSession` and typed optional
  `CameraServices` looked up by type (Kotlin `get<T>()`).
- **Saved cameras.** `SavedCamera` (id = the legacy record id, verbatim) with `SavedRoute`s (route
  id minted once, codec-stable `key`, kind, title, network, Bluetooth, last connected, verbatim
  `extras`). Dates are epoch milliseconds in stored JSON on both platforms.
- **`SavedCamerasDocument`** (version 1) holds the cameras plus a merge base per legacy source.
  `merge(_:from:heldExtras:)` is the three-way merge of a `LegacySavedCameraCodec`'s records into
  the document; the store and the codecs live in `OpenCineAppKit` ([appkit](../appkit/README.md))
  and in the integrations that wrote their own legacy format.
- `FakeIntegration` (test support, Kotlin test fixtures) scripts discovery, attempts and a dial log.

## OpenCineFrameIO

Optional. A camera-only consumer never links it: depending on the `OpenCineCore` or
`OpenCineMedia` product compiles nothing from it, and it declares no package dependency, so
`swift package show-dependencies` for a Core-only consumer lists no remote packages. (SwiftPM
resolves every package dependency a manifest declares, even one only an unused product needs;
that is why PKCE takes an injected SHA-256 on non-Apple platforms instead of this package
depending on swift-crypto. An Android facade passes swift-crypto's SHA-256 from its own package.)

This product never names an app. On iOS, `OpenCineFrameIOApple` is the host every app
composes: `FrameioAppConfiguration` (the Adobe client ID and redirect URI from the app's
Info.plist), `FrameioKeychainTokenStore(service:)`, `FrameioWebAuthenticator`
(`ASWebAuthenticationSession` sign-in), `FrameioDestinationStore(key:)`, `FrameioAccountModel`
(sign-in state, the first workspace's projects, the saved destination, upload history and the
delivery remote services) and `FrameioMark`. The app passes only its namespaces
(`FrameioHostNamespace`: keychain service, destination and history keys), so sharing the host
never shares a sign-in. `StoredFrameioToken` keeps the Codable shape the apps already stored.
Android hosts (Custom Tabs, keystore) remain the apps' until their adoption.

### Network hops and camera claims

`MonitorInternetHop` (`OpenCineAppKit`) holds the hop: an operator-approved hop begins with a
token; transferring it to delivery invalidates the popup's token without another network
operation. Only the current token can end the hop, so a late cancelled delivery cannot release
a successor, and the return is consumed once. Apps supply the native leave/rejoin actions
through its `Port` and retain the original connection for rejoin.

Every Frame.io byte, including token refresh and upload parts, goes through
`FrameioHTTPTransport.send`. That is the single place an app enforces route ownership:

1. While the phone's Wi-Fi is a camera access point, the transport refuses (throws) unless the
   operator approved an internet hop for this delivery.
2. Before starting a hop, the app asks whether leaving the current network would take a route
   from a live camera. With OpenCineMulticam, model the hop as a candidate
   `ResourceRequest(entry: <delivery entry>, device: nil, claims: [.infrastructureNetwork(<internet network>)])`
   and call `ResourceAdmission.reasons(admitting:alongside:budget:)` with the live members. Any
   `.wifiNetworkConflict` or `.accessPointTaken` reason means another camera owns the phone's
   Wi-Fi: show it to the operator and do not hop silently.
3. The hop's owner rejoins the camera when delivery ends, on every exit path (success, failure,
   cancellation).

This product deliberately does not depend on OpenCineMulticam or a reachability API; the app
composes them.

## Android

The Core modules of the platform Gradle build (`Android/`) are an Android library, `vulkan` (the
native renderer; building the platform build therefore needs an Android SDK through `ANDROID_HOME`
or `Android/local.properties`), and two
plain Kotlin/JVM modules, `core`
(`com.opencapture.opencine:core`, `0.1.0-SNAPSHOT`) and `media` (`com.opencapture.opencine:media`,
moved from the Pocket/Insta apps; it depends on `core` and keeps the moved code's shape, so explicit
API mode is off there). It has no Android framework dependency, so
app modules depend on it directly and its tests run on the JVM. It mirrors `Sources/OpenCineCore`
type for type with the same semantics, and `FakeCameraSession`, the three fixture families,
`FakePictureSource` and `FakeEntries` are its test fixtures (package
`com.opencapture.opencine.core.testing`). Kotlin 2.4.20, kotlinx-coroutines 1.11.0 and a JVM 17
target match the OpenPocketCine catalog; warnings are errors and explicit API mode is on.

```sh
cd Android && ./gradlew build   # JDK 17 or newer
```

Consume it from an app on a candidate branch with a composite build (path from `Apps/Android`
to a sibling OpenCine checkout). Name the included build `opencine`: the app's own Gradle build
also lives in a directory called `Android`, and two builds cannot share a name. One include
serves every OpenCine module the app uses.

```kotlin
// settings.gradle.kts
includeBuild("../../../OpenCine/Android") {
    name = "opencine"
    dependencySubstitution {
        substitute(module("com.opencapture.opencine:core")).using(project(":core"))
        substitute(module("com.opencapture.opencine:media")).using(project(":media"))
        substitute(module("com.opencapture.opencine:vulkan")).using(project(":vulkan"))
    }
}

// module build.gradle.kts
dependencies {
    implementation("com.opencapture.opencine:core:0.1.0-SNAPSHOT")
    testImplementation(testFixtures("com.opencapture.opencine:core:0.1.0-SNAPSHOT"))
}
```

Once published, drop `includeBuild` and use the Maven coordinate
`com.opencapture.opencine:core:<version>` (plus `testFixtures(...)` for the fakes); the group may
move to the verified Maven Central namespace at publish time. Local multi-repo work then becomes
an opt-in `includeBuild` behind an untracked property.

### App shell contracts stay out of Core (CORE-API decision, 2026-10-02)

The apps' Kotlin `:core-api` modules are not Core and nothing from them was added here:

- OpenInstaCine's (`CameraBackend`, `CameraControls`, `CameraMediaStore`, `CoreSessionSource` and
  their values) is Luna-shaped: Luna shooting, gimbal and focus modes, raw exposure-program and
  storage-location codes, DJI pipeline phase names. It moved to OpenCineInsta360 `Android/`
  (`com.opencapture.opencine:insta360-shell`, next to the adapter `insta360-luna`), the Kotlin twin
  of the Swift `CameraBackend` seam in Insta360Apple.
- OpenPocketCine's is one enum, `ConnectionPhase` (DJI BLE, Wi-Fi and datalink stages); its legacy
  `CameraSession` seam (phase, startScan, disconnect) was retired in both apps. The enum moves to
  OpenCineDJI with the Kotlin DJI session.
- OpenZCine's `com.opencapture.openzcine.core` is Nikon's own session model, not a copy.

Commands and camera-reported state already go through this module (`CameraSession`,
`ConnectionState`, `PowerStatus`, `StorageStatus`, `RecordingState`). A shell value joins Core only
when it is vendor-neutral, keeps unknown distinct from false and carries no raw vendor enum.

### Kotlin mapping

Same names and semantics, in Kotlin idiom. Where they differ:

- Each ID is its own `@JvmInline value class` (Swift: generic `Identifier<Kind>` and
  `Counter<Kind>`). Counters hold a `Long` (Swift `UInt64`).
- Cases without payload are `enum class` with `UPPER_SNAKE` constants; cases with payload are a
  `sealed interface` of `data object` and `data class`. Struct mutation is `copy(...)`.
- `ObservedValue` is covariant: `ObservedValue.unknown` is an `ObservedValue<Nothing>` assignable to any
  `ObservedValue<T>`, and conversions preserve provenance even when their result cannot be represented. Durations are
  `kotlin.time.Duration`; `MonotonicInstant.zero` is `MonotonicInstant.ZERO`.
- The feed is `val snapshots: StateFlow<CameraSnapshot>` (Swift `snapshots()` returning a
  `.bufferingNewest(1)` stream). Same latest-value conflation; `.value` replaces
  `currentSnapshot()`. A `StateFlow` never completes, so `close` leaves the final `Disconnected`
  snapshot in place instead of finishing streams; collectors end with their coroutine scope.
- Cancelling an `outcome(operation)` wait throws `CancellationException` in the waiter instead of
  returning the unfinished receipt. As in Swift, the operation itself is never affected.
  `receipt(operation)` (required on both, no default) does not suspend (Swift: `async`, because
  sessions are actors), so a confined owner or Compose reads it directly.
- `closeNow(reason)` is a Kotlin-only, non-suspending form of `close` for callers that cannot
  suspend (Compose `onDispose`). It schedules the same idempotent close on the session's scope.
- `MonitorEntryDescriptor.validate()` (typed throws) is `validationError(): MonitorEntryError?`.
  `rejection(of:at:)`, `support(of:)` and `value(of:)` are `rejection(command, now)`,
  `support(key)` and `value(key)`.
- No serialization: Swift's `Codable` has no Kotlin counterpart until a consumer persists or sends
  these values (then add kotlinx.serialization). A zero `Rational` denominator throws
  `IllegalArgumentException` at construction.
- Fakes: raw modes are `Int` (Swift `UInt8`), `FakeDevice.settings` is a map, and the fake is
  confined to one thread instead of being an actor. `FakeIntegration`'s flows are cold: discovery
  and an attempt start when collected (Swift: when called).
- Integration contract: `discover` and `connect` return `Flow`; `ConnectionEvent`,
  `ConnectionPrompt`, `ConnectionFailure.Reason` and `RecoveryAction` are sealed interfaces;
  `CameraServices` is an immutable map keyed by `KClass` (`get<T>()`, `plus(type, service)`); saved
  dates are `Long?` epoch milliseconds; `RouteKind.rawValue` is the Swift case name. The
  document's `merge` and `recordMirror` return a copy. `CameraDeviceID.restored(...)` reads a
  stored identity back (Swift: `Codable`).

### Test mapping

Scenarios are action sequences, so shared JSON fixtures would need an interpreter on both sides.
The suites are mirrored by name instead; change a contract and its mirrored test in Swift and
Kotlin together.

| Swift (`Tests/OpenCineCoreTests`) | Kotlin (`Android/core/src/test`) |
|---|---|
| `Conformance` "1." to "15." (20 tests, 11 and 12 disabled) | `ConformanceTest` `01` to `15`, same titles (11 and 12 `@Ignore`) |
| `IntegrationContract` (12 tests, against `FakeIntegration`) | `IntegrationContractTest`, same method names |
| `Values` (6 tests) | `ValuesTest`, same method names |
| `Entries.everyEntryNeedsARole` | `EntriesTest.everyEntryNeedsARole` |
| `LayoutProjection` (2 tests) | `LayoutProjectionTest`, same method names |
| `Feeds` (3 tests) | `FeedsTest`, same method names |
| `Portability.coreImportsOnlyFoundationAndNamesNoManufacturer` | `PortabilityTest.coreImportsOnlyStdlibAndCoroutinesAndNamesNoManufacturer` |
| `Portability.portableStateHoldsNoNativeFrameOrObject` | Not ported: the Kotlin import rule (only `kotlin.*`, `kotlinx.coroutines.flow.*`, `java.util.UUID` and the module's own packages, with the core package never importing motion) keeps platform types out |
| `GroupTargets.strictAndEligibleSubsetFromAdmission` | `GroupTargetsTest`, same name |
| `MotionSeamTests` (`Tests/OpenCineMotionTests`): targets, feedback, layout projection | `motion.MotionSeamTest`, same method names (trajectory and program tests are Swift only) |

Parameterized Swift scenarios run each fixture family inside one JUnit test.

Byte-level media math shares data instead: `Fixtures/live-video-nal-vectors.tsv` is generated by
Swift `LiveVideoNalVectorTests` (which also checks it is current) and replayed by Kotlin
`LiveVideoNalVectorTest`. `EncodedVideoUnitTests` mirrors to `EncodedVideoUnitTest` by name.

## Development

```sh
swift build
swift test
cd Android && ./gradlew build
scripts/android-vulkan-sync-test.sh   # renderer present/acquire lifetime, host CPU, NDK headers
```

The package uses Swift 6 language mode (complete concurrency checking). Platforms: iOS 17,
macOS 13, watchOS 10.

## License

Apache License 2.0. See the root `LICENSE` and `NOTICE`.

## Source-declared battery reports

`PowerStatus.batteryReading` is the common projection of a charge observation and its declared
precision. A fraction prints a percentage; a coarse observation keeps the declared gauge count.
`PowerStatus.exhausted` is an independent camera report. Ordinary low charge does not imply
exhaustion, and a missing charging or external-power report remains unknown.

The relay payload adds optional `batteryReading` and `batteryExhausted` fields while retaining
legacy scalars and constructor signatures. Reading fields use `kind: "fraction"` with `value`, or
`kind: "steps"` with `filled` and `of`; malformed values are rejected. An older message without
these keys is converted at the protocol boundary. An explicitly null reading remains unknown
even if the retained legacy scalar is populated. Legacy messages retain their original key set
when encoded again. State coalescing includes both charge precision and independent exhaustion.

Android Core exposes the same validated portable fields without a JSON dependency. The portable
Nikon gauge stays in its original public package and class, in `:nikon-wire`; that module depends
on Core values and has no JNI, camera-session owner or UI. The Android wrist UI accesses the exact
Core reading through Media type aliases, preserving its existing import boundary; Swift
`OpenCineWatch` imports `OpenCineCore` directly. Phone live, relay,
multicam and wrist consumers use these common values. Fractions do not acquire invented bars,
unknown battery is absent, and only an explicitly exhausted report pulses.

## Common recording and capture values

`CameraSnapshot.recordingFormat` (`CameraRecordingObservations`: dimensions, profile and codec,
each an `ObservedValue` with its origin) holds what the camera says it records. It is separate
from preview dimensions and the transport codec, and a format selection never stands in for a
report. `CameraSnapshot.exposureProgram` is its own observed value (`CameraExposureProgram`).
Both decode as unknown from older payloads. `MonitorCapturePresentation.recordingFormat`,
`recordingLabel` and `exposureProgram` give the shared readout copy on both platforms.

Capture readouts choose between the camera's report and a pending command through
`MonitorCaptureSelection` (`captureValue(_:selection:)`); a pending command never becomes a
report. `CaptureNativeReadoutPresentation` formats the native shutter angle from the common
shutter and the reported cadence, and the focus readout from the common mode with native slots.

Integration-owned capture controls stay typed slots on `CaptureSheetHost`: a native capture panel,
a native quick choice for the format or colour sheet (`CaptureQuickSnapshot.native(sheet:...)`)
and an optional metering source whose unknown mode has no toggle target. Luna's colour names,
native colour choices and shape labels live in the integration (`LunaColorMode.label`, Kotlin
`CameraColorProfile.label`, `aspectLabel`). `MultiviewTile.withPower` is the one projection of
typed power onto a stage tile, and `WatchRelayState.replacing(power:)` the one for the wrist.
