# RTMPS Streaming, Part 2: Apple Shell and iOS Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream one camera from each iOS app to an RTMPS service: a portable run controller over part 1's engine, the Apple shell under it (TLS socket, H.264 and AAC encoders, picture fitting, microphone, keychain), the clean-picture tap, the shared SwiftUI surfaces, and adoption in OpenPocketCine, OpenInstaCine and OpenZCine.

**Architecture:** Part 1 left a sans-I/O publish session. This part adds `StreamRun`, also sans-I/O and in `OpenCineStreaming`, which owns reconnects, the send queue, bitrate and status, so Android (part 3) reuses it over JNI. `OpenCineStreamingApple` is a thin driver: it opens the socket, runs the encoders and the clock, and applies `StreamRun`'s actions. The picture reaches it through a neutral frame contract implemented by the native runtime; the UI takes values and actions only; apps add host values.

**Tech Stack:** Swift 6, Swift Testing, Network.framework (TLS), VideoToolbox (H.264), AVFoundation and AudioToolbox (AAC, microphone), Security (keychain), SwiftUI. FFmpeg 8 for the opt-in interop tier only.

**Spec:** `docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`. Part 1: `docs/superpowers/plans/2026-11-05-rtmps-1-timecode-and-engine.md`.

## Global Constraints

- `OpenCineStreaming` stays Foundation and Core only, opens no socket and names no manufacturer or app.
- `OpenCineStreamingApple` depends on `OpenCineStreaming`, `OpenCineCore` and Apple frameworks only: never UI, an integration, an app or a third-party package. No `static var`, no `nonisolated(unsafe)`.
- No third-party package. FFmpeg only in scripts and the opt-in test tier.
- Only `rtmps://`. TLS cannot be disabled through public API; the interop tier uses an internal seam.
- A stream key never appears in a log, description, error, status value or failure text.
- Output values from the spec: H.264, 2 second keyframe interval, AAC-LC stereo at 48 kHz and 160 kbps, about 3 Mbps at 720p and 6 Mbps at 1080p, reconnect for up to 2 minutes, output does not queue while offline.
- What goes out: the clean camera picture with the monitor LUT when one is on, never assists or app controls.
- Streaming is a passenger: a stream failure never disturbs camera control, the monitor or recording, and starting or stopping a stream never sends a camera command.
- Foreground only: leaving the app ends the stream after the OS grace; the screen stays awake while live.
- Tests are deterministic: manual instants, no sleeps. The interop tier is the exception and is off by default.

## Review Focus

1. **The network drops and returns while frames keep arriving.** Nothing queues while offline; on return the first video out is a keyframe after fresh config. Test: `offlineMediaIsDroppedAndReconnectStartsWithConfig` (Task 1).
2. **The server refuses the key mid-retry.** The run ends at once with the refusal text, key removed, and never retries. Test: `refusalDuringReconnectEnds` (Task 1).
3. **A slow uplink.** In-flight bytes stay bounded, the queue drops whole groups, the bitrate steps down and the status says congested. Test: `slowWritesStepBitrateDownAndReportCongestion` (Task 1).
4. **The source changes size mid-stream (a cut, a reconnecting camera, a rotated capture card).** The output size never changes; the picture is fitted with bars. Test: `differentSourceSizesFitTheSameOutput` (Task 5).
5. **A keychain the device has not unlocked yet.** Reading a key reports unavailable, never "no key", so the page does not offer to replace a saved key. Test: `lockedKeychainIsUnavailableNotAbsent` (Task 3).

## File Structure

| Path | Responsibility |
| --- | --- |
| `Sources/OpenCineStreaming/StreamRun.swift` | Portable run controller: connect, reconnect, queue, in-flight bound, bitrate, status |
| `Sources/OpenCineStreamingApple/StreamKeyStore.swift` | Keys and entered servers per preset in the keychain |
| `Sources/OpenCineStreamingApple/StreamConnection.swift` | TLS socket on Network.framework behind a small protocol |
| `Sources/OpenCineStreamingApple/H264StreamEncoder.swift` | VideoToolbox H.264 to `StreamMediaPacket` |
| `Sources/OpenCineStreamingApple/AACStreamEncoder.swift` | PCM to AAC-LC `StreamMediaPacket` |
| `Sources/OpenCineStreamingApple/StreamPictureFitter.swift` | Any source buffer into the fixed output frame |
| `Sources/OpenCineStreamingApple/StreamPublisher.swift` | Drives `StreamRun`: socket, clock, encoders |
| `Sources/OpenCineStreamingApple/StreamMicrophone.swift` | iOS microphone capture at 48 kHz stereo |
| `Tests/OpenCineStreamingAppleTests/*` | One suite per task, plus the extended interop tier |
| `docs/streaming/README.md` | Area guide, extended |

---

### Task 1: `StreamRun`, the portable run controller

**Files:**

- Create: `Sources/OpenCineStreaming/StreamRun.swift`, `Tests/OpenCineStreamingTests/StreamRunTests.swift`

**Interfaces:**

- Consumes: part 1's `RTMPPublishSession`, `StreamSendQueue`, `StreamBitratePolicy`, `StreamReconnectPolicy`, `StreamDestination`, `StreamOutputFormat`, `StreamMediaPacket`, Core's `MonotonicInstant`.
- Produces:
  - `public struct StreamRun: Sendable`, `init(destination: StreamDestination, format: StreamOutputFormat, now: MonotonicInstant, maxQueueBytes: Int = 4 * 1024 * 1024, maxInFlightBytes: Int = 256 * 1024)`
  - `public enum Action: Equatable, Sendable { case connect(host: String, port: UInt16), write([UInt8]), disconnect, setVideoBitrate(Int), requestKeyframe, wake(at: MonotonicInstant) }`
  - Inputs, each returning `[Action]`: `start()`, `connected(at:)`, `received(_ bytes: [UInt8], at:)`, `connectionLost(at:)`, `publish(_ packet: StreamMediaPacket, at:)`, `wrote(_ count: Int, at:)`, `tick(at:)`, `stop(at:)`
  - `public private(set) var status: Status`, with `Status { phase: Phase; liveSince: MonotonicInstant?; sentBitrateBps: Int; videoBitrateBps: Int; droppedVideoGroups: Int; droppedAudioPackets: Int; health: Health }`, `Phase { connecting, live, reconnecting(attempt: Int), ended(End) }`, `End { stopped, refused(reason: String), gaveUp }` (a protocol error reconnects like a drop), `Health { good, congested, offline }`

- [ ] **Step 1: Write the failing tests** (a fake server built from part 1's `SimulatedRTMPServer` answers through `received`)

```swift
@Test func startConnectsThenGoesLive()            // start -> [.connect(host, 443)]; connected -> .write(C0C1); ... phase .live
@Test func mediaFlowsOnlyWhileLiveAndWithinInFlight() // writes stop at maxInFlightBytes until wrote(_:at:) frees room
@Test func offlineMediaIsDroppedAndReconnectStartsWithConfig()
    // connectionLost -> [.disconnect, .wake(at: now + 1 s)], phase .reconnecting(attempt: 1), health .offline;
    // publish while offline writes nothing; tick at the wake -> .connect; once live again the first media out is
    // the remembered videoConfig and audioConfig, then .requestKeyframe, and interframes wait for a keyframe
@Test func refusalDuringReconnectEnds()             // .refused -> phase .ended(.refused) with no key in it, no .wake
@Test func givesUpAfterTwoMinutes()                 // drops every 10 s from the first failure: ended(.gaveUp) at 120 s
@Test func slowWritesStepBitrateDownAndReportCongestion() // queue over 1 s behind -> .setVideoBitrate below target, health .congested
@Test func stopClosesPolitely()                     // live: stop -> [.write(FCUnpublish+deleteStream), .disconnect], ended(.stopped)
@Test func statusCountsSentBitrate()                // wrote 375_000 bytes over 1 s -> sentBitrateBps 3_000_000
```

- [ ] **Step 2: Run to verify failure.** `swift test --filter StreamRunTests`; expected: missing type.

- [ ] **Step 3: Implement.** A fresh `RTMPPublishSession` per connection. Remember the latest `videoConfig` and `audioConfig`; on `.live` send them first and request a keyframe. While not live, `publish` only updates the remembered config. Drain the queue while in-flight bytes are under the bound. Observe `queue.queuedDuration` on every `wrote` and `tick`; emit `.setVideoBitrate` only on change. Sent bitrate is the bytes acknowledged by `wrote` over the last 2 s. Health: offline while not live, congested while the queue is over 1 s behind or a group dropped in the last 5 s, else good. Floor bitrate: a third of the format's bitrate.

- [ ] **Step 4: Run to verify pass**, then `python3 atlas/tools/atlas.py api --write --build`.

- [ ] **Step 5: Commit** `feat(streaming): run a stream with reconnects, a bounded queue and status`.

### Task 2: `OpenCineStreamingApple` module

**Files:**

- Modify: `Package.swift` (product, `.target(name: "OpenCineStreamingApple", dependencies: ["OpenCineStreaming", "OpenCineCore"])`, test target), `atlas/repos/opencine/meta.json` (product and `layers.core`), `AGENTS.md` (boundary bullet beside `OpenCineGyroApple`)
- Create: `Tests/OpenCineStreamingAppleTests/StreamingAppleSourceRulesTests.swift`

Every source file sits behind `#if canImport(VideoToolbox) && canImport(Network)` so the macOS host runs the encoder and socket tests; iOS-only pieces add `#if os(iOS)`. The rules test pins imports to Foundation, `OpenCineCore`, `OpenCineStreaming` and Apple system frameworks (AVFoundation, AudioToolbox, CoreMedia, CoreVideo, CoreImage, Accelerate, Network, Security, VideoToolbox, UIKit), forbids `static var` and `nonisolated(unsafe)`, and rejects camera and app names.

Commit: `feat(streaming): add the Apple shell module`.

### Task 3: `StreamKeyStore`

**Files:** Create `Sources/OpenCineStreamingApple/StreamKeyStore.swift`, `Tests/OpenCineStreamingAppleTests/StreamKeyStoreTests.swift`.

**Interfaces:**

- Produces: `public struct StreamKeyStore: Sendable`, `init(service: String)`, internal `init(service:items:)` with the same four-operation seam as `WatcherRelayKeychain`; `public enum Lookup: Equatable, Sendable { case absent, stored(String), unavailable(Int32) }`; `func key(for presetID: String) -> Lookup`; `func server(for presetID: String) -> Lookup`; `func save(key: String, server: String?, for presetID: String) -> Bool`; `func remove(for presetID: String) -> Bool`.

Tests: `savedKeyReadsBack`, `removeForgetsKeyAndServer`, `lockedKeychainIsUnavailableNotAbsent` (`errSecInteractionNotAllowed` gives `.unavailable`), `writeUpdatesInPlace` (never delete first), `keyIsInNoDescription`. Accounts are `stream-key.<presetID>` and `stream-server.<presetID>`; accessibility after first unlock, this device only. The service is a host value.

Commit: `feat(streaming): keep stream keys in the keychain`.

### Task 4: `StreamConnection`

**Files:** Create `Sources/OpenCineStreamingApple/StreamConnection.swift`, `Tests/OpenCineStreamingAppleTests/StreamConnectionTests.swift`.

**Interfaces:**

- Produces: `public protocol StreamConnection: Sendable { func open(onEvent: @escaping @Sendable (StreamConnectionEvent) -> Void); func write(_ bytes: [UInt8]); func close() }`; `public enum StreamConnectionEvent: Sendable { case opened, received([UInt8]), wrote(Int), lost }`; `public struct NetworkStreamConnection: StreamConnection` with `init(host: String, port: UInt16)` (TLS) and internal `init(plainHost:port:)` for the interop tier.

Tests (local plain listener on `NWListener`, deterministic by events): `deliversBytesBothWays`, `reportsWrittenCounts`, `reportsLostWhenPeerCloses`, `refusedConnectionIsLost`. TLS uses the system trust store and the host name for SNI; no certificate pinning.

Commit: `feat(streaming): add the TLS stream connection`.

### Task 5: Encoders and picture fitting

**Files:** Create `H264StreamEncoder.swift`, `AACStreamEncoder.swift`, `StreamPictureFitter.swift` and their test suites.

**Interfaces:**

- `public final class H264StreamEncoder: @unchecked Sendable`: `init(format: StreamOutputFormat)`, `func encode(_ buffer: CVPixelBuffer, at presentMs: UInt32, forceKeyframe: Bool, output: @escaping @Sendable ([StreamMediaPacket]) -> Void)`, `func setBitrate(_ bps: Int)`, `func invalidate()`. H.264 High, auto level, real-time, no frame reordering, `MaxKeyFrameIntervalDuration` equal to the format's interval, average bitrate plus a one-second data rate limit. Emits `.videoConfig` with the first keyframe and whenever SPS or PPS change.
- `public final class AACStreamEncoder: @unchecked Sendable`: `init(format: StreamOutputFormat)`, `func encode(_ buffer: AVAudioPCMBuffer, startMs: UInt32) -> [StreamMediaPacket]`. AAC-LC at the format's rate, channels and bitrate; emits `.audioConfig` once; frame times follow the sample count.
- `public struct StreamPictureFitter: Sendable`: `init(width: Int, height: Int, mode: Mode)`, `enum Mode { case fit, centerCrop }`, `func fit(_ source: CVPixelBuffer) -> CVPixelBuffer?`. Fit keeps the source shape with black bars; center crop fills (the 9:16 preset).

Tests: `firstOutputIsConfigThenKeyframe`, `keyframeEveryTwoSeconds` (60 frames at 30 fps give keyframes at 0 and 60), `forcedKeyframeIsHonored`, `aacConfigIs48kStereoLC` (`[0x11, 0x90]`), `aacFramesAdvanceBy1024Samples`, `differentSourceSizesFitTheSameOutput` (1024x768 and 1920x1080 both give 1280x720; the 4:3 source has black side bars), `centerCropFillsVertical`.

Commit: `feat(streaming): encode H.264 and AAC and fit the picture on Apple`.

### Task 6: `StreamPublisher` and the end-to-end interop tier

**Files:** Create `StreamPublisher.swift`, `StreamPublisherTests.swift`, `StreamAppleInteropTests.swift`.

**Interfaces:**

- `public actor StreamPublisher`: `init(destination: StreamDestination, format: StreamOutputFormat, connection: @escaping @Sendable (String, UInt16) -> any StreamConnection = { NetworkStreamConnection(host: $0, port: $1) }, now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now)`; `func start()`; `func stop()`; `nonisolated func submitVideo(_ buffer: CVPixelBuffer)`; `nonisolated func submitAudio(_ buffer: AVAudioPCMBuffer)`; `var status: StreamRun.Status`; `nonisolated var statusUpdates: AsyncStream<StreamRun.Status>`.

Media times are milliseconds since `start()`. Video is paced by an output clock at the format's frame rate: the newest submitted picture is encoded on each tick, repeated when the source is slower and skipped when faster, so the encoder session and rate never change. When no picture arrives for 2 s the last one is replaced by a neutral black slate until pictures return; audio continues throughout (spec: selected camera drops). Video goes through the fitter and the encoder; a `.requestKeyframe` action forces the next frame. `.wake` schedules one task that calls `tick`. Tests with a scripted fake connection and a manual clock: `appliesActionsInOrder`, `wakeCallsTick`, `stopEndsTheRun`, `slowSourceRepeatsFrames`, `lostSourceShowsSlateAfterTwoSeconds`. Interop (`OPENCINE_FFMPEG_INTEROP=1`): synthetic 1280x720 frames and a sine through the real encoders and a plain socket to FFmpeg; `ffprobe` sees H.264 High and AAC-LC 48 kHz stereo, 1280x720, timestamps that never go backward.

Commit: `feat(streaming): publish from Apple encoders through the run controller`.

### Task 7: Microphone

**Files:** Create `StreamMicrophone.swift` (`#if os(iOS)`).

`public final class StreamMicrophone`: `init()`, `func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws`, `func stop()`. `AVAudioSession` category `.playAndRecord` with `.mixWithOthers` and `.allowBluetoothHFP`, an `AVAudioEngine` input tap converted to 48 kHz stereo float. Throws `StreamMicrophoneError.permissionDenied` when access is denied. The usage string is an app value (`NSMicrophoneUsageDescription`). Verified on device only; the host build compiles it out.

Commit: `feat(streaming): capture the microphone on iOS`.

### Task 8: The clean-picture tap

**Files:** Create `Sources/OpenCineApple/MonitorCleanPictureTap.swift`, `Tests/OpenCineAppleTests/MonitorCleanPictureTapTests.swift`; modify `Sources/OpenCineApple/MonitorLiveVideoRuntime.swift` (one optional hook, called from `applyAssistResult`).

Today the runtime offers `onIdentityFrame` (raw buffer, no LUT, no time), `onSourceFrame` (raw lease with `timeNs`) and `onPreviewFrame` (only with `demand.externalPreview`). None gives "LUT on, assists off" as a pixel buffer, and `MonitorImageCompositor.applyProduct` downscales to its working width before the LUT. So:

**Interfaces:**

- Produces: `public struct MonitorCleanFrame: @unchecked Sendable { public let pixelBuffer: CVPixelBuffer; public let timeNs: UInt64 }`; `public final class MonitorCleanPictureTap: @unchecked Sendable`, `init(maxWidth: Int)`, `func render(identity: CIImage, effects: MonitorImageEffects, timeNs: UInt64) -> MonitorCleanFrame?` (LUT only, at the source size capped to `maxWidth`, into its own `CVPixelBufferPool`, BGRA); on the runtime `public var onCleanFrame: ((MonitorCleanFrame) -> Void)?` and `public var cleanPictureTap: MonitorCleanPictureTap?`, rendered off the main thread only while both are set.
- Neutral: no streaming type crosses into `OpenCineApple`. The composition layer passes `MonitorCleanFrame.pixelBuffer` to `StreamPublisher.submitVideo`.

Tests (macOS host, synthetic buffers): `lutAppliesAndAssistsDoNot` (peaking and false colour on in `effects`, a known LUT: output equals the LUT-only render), `noTapNoWork` (no render call while `onCleanFrame` is nil), `timeIsKept`.

Commit: `feat(apple): tap the clean monitor picture for streaming`.

### Task 9: Shared SwiftUI

**Files:** Create `Sources/MonitorPresentation/LiveStreamPresentation.swift` (values: `LiveStreamSettingsState`, `LiveStreamStatusState`, `LiveStreamEligibility`), `Sources/MonitorUI/LiveStream/LiveStreamSettingsSection.swift`, `LiveStreamGoLiveButton.swift`, `LiveStreamStatusReadout.swift`, and tests in `MonitorPresentationTests` and `MonitorUITests`; modify `Sources/OpenCineCameraControls/Settings/MonitorOperatorSettingsConfiguration.swift` (an optional `liveStream` source rendered on the Sharing tab) and `MonitorOperatorSettingsScreen.swift`.

- Settings section: service picker over `StreamServicePreset.all + [.custom]` (names and hints from the preset table, passed in as values so UI does not import the engine), server field when `requiresServerEntry`, masked key field with paste and remove, quality line ("720p, 3 Mbps" from `StreamOutputFormat`), the Instagram width note, the eligibility reason when disabled.
- Go live control beside the monitor controls: disabled with its reason when not eligible; one confirmation naming service and quality to start and one to stop.
- Status readout while live: elapsed, sent bitrate, dropped frames, health. Every control has an accessibility label.
- Compose twins: part 3. Record the exception in the PR until then.

Tests: `ineligibleRouteDisablesGoLiveWithReason`, `keyFieldNeverShowsTheKey`, `qualityLineFollowsFormat`, `statusReadoutAnnouncesHealth`, plus a brand-scan rule test over the new files.

Commit: `feat(ui): live stream settings, go live control and status`.

### Task 10: Composition in `OpenCineAppKitApple`

**Files:** Create `Sources/OpenCineAppKitApple/LiveStreamHost.swift` (host values: keychain service, the connection route closure, the source format closure), `LiveStreamCoordinator.swift` (`@MainActor @Observable`: holds the `StreamPublisher`, `StreamMicrophone`, the clean tap hookup, screen-awake while live, ends the stream on `scenePhase` background after the OS grace and offers restart on return; warns on serious thermal state or low battery and never stops for them); modify `Package.swift` (the `OpenCineAppKitApple` target gains `OpenCineStreaming` and `OpenCineStreamingApple`; update `atlas/repos/opencine/meta.json` `allowed_target_edges` if `atlas check` asks).

Tests (hosted, SIMULATED connection): `backgroundEndsTheStreamAndOffersRestart`, `startNeverSendsACameraCommand` (a recording fake camera sees no command), `streamFailureLeavesTheMonitorRunning`.

Commit: `feat(appkit): compose live streaming on iOS`.

### Task 11: Adopt in the three iOS apps (draft PRs, one per app)

Per app: move the OpenCine pin to the commit with Tasks 1 to 10; add `NSMicrophoneUsageDescription`; pass `LiveStreamHost` with the app's keychain service (`<bundle id>.live-stream`) and its connection route mapping: OpenZCine (camera access point gives `.cameraWiFi`, phone hotspot `.deviceHotspot`, Wi-Fi network `.sharedWiFi`, USB-C `.usbCable`, HDMI capture `.captureCard`); OpenPocketCine and OpenInstaCine (camera access point `.cameraWiFi`, station mode on a shared network `.sharedWiFi`, hotspot `.deviceHotspot`). The route mapping reads only the app's existing connection mode, never a camera command. Each app runs its own checks; hardware stays untested until the owner's pass.

## Not in this part

Program strip and cuts, timecode alignment and grades (part 4, after the timecode measurements), the cable route for Pocket and Insta (part 5), Android (part 3), desktop (project 2).
