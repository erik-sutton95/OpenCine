# 1080p streaming (native and upscaled) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two new Quality choices for live streaming: "1080p upscaled" (any sub-1080p source, LUT kept) and "1080p from camera" (a camera that publishes its own 1080p stream to the phone, relayed outward), on iOS and Android, with the native choice hidden on Android until a hardware pass.

**Architecture:** The portable engine (`OpenCineStreaming`) gains a quality choice in its output rule and an RTMP receive session; each platform shell adds a listener and decoders. Core gains a brand-free capability value that an integration declares per camera; the DJI integration declares it and adds the Bluetooth livestream commands and a provisioning sequence. The shared coordinator (Swift `OpenCineAppKitApple`, Kotlin `appkit-native`) runs the native relay through a host protocol the app implements, so shared code never names a manufacturer.

**Tech Stack:** Swift 6 (Swift Testing), SwiftUI, Network.framework, VideoToolbox, AVFoundation; Kotlin, Compose, MediaCodec, JNI through `OpenCineStreamingAndroid` and `OpenCineDJIAndroid`.

**Spec:** `docs/superpowers/specs/2026-11-21-dji-1080p-streaming-design.md` (and `docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`, `docs/streaming/ui-contract.md`).

## Global Constraints

- Core, `OpenCineStreaming`, shared UI and the app shell name no manufacturer (`ContractTests`, `SharedUIRulesTests`, `CameraControlsRulesTest`). The DJI integration declares the capability.
- Swift and Kotlin twins change together with mirrored tests; JNI class and member names stay (`StreamingNativeExportNamesTests`, `llvm-nm` parity for DJI).
- Add, never break: new protocol members and interface members get defaults so an app that has not moved its pin still builds.
- Bitrate: about 6 Mbps at 1080p for both new choices (`6_000_000`, capped by the preset).
- Native output: H.264 out (the existing encoder), 1920x1080, the camera's frame rate (30 by default).
- Stop always ends the camera's livestream (`02/8E` end, bounded wait of 6 s), then closes Bluetooth and the receiver, on every exit path.
- The receiver accepts only the expected publisher: a fresh random stream key per session; a log shows at most its first 4 characters.
- Native mode sends the camera's own sound and never asks for the microphone.
- The upscaled output is always named "1080p upscaled", never plain "1080p".
- No em dash character anywhere. Commits as Erik Sutton, no co-author lines.
- Do not restyle the Go Live button (another workstream owns its look). UI changes: Quality choices, the native status line, the network choice in the start confirmation, and the native monitor screen built from existing components.
- Pocket 4 Pro is declared; Pocket 4 and Pocket 3 are experimental (need the existing experimental switch). Nothing else.
- Android: everything is built and unit tested, but no app passes a camera source on Android, so the native choice never shows there until a hardware pass.

## Review Focus

1. **App killed or backgrounded while the camera is live:** every start sends the cleanup end first; background and terminate send the end before anything else. Test: `backgroundEndsTheCameraStreamFirst` (Swift and Kotlin coordinator).
2. **A second publisher or a wrong key on port 1935** (another device on the hotspot): refused and closed, the running relay keeps its publisher. Test: `wrongStreamKeyIsRefused` (`RTMPReceiveSessionTests`).
3. **The remembered choice no longer applies** (camera feed now 1080p, camera without the capability, no saved network): the effective choice falls back to Camera feed and the settings card says why the other is unavailable; the remembered value is kept. Test: `rememberedChoiceFallsBackWhenNotOffered`.
4. **Bytes arrive split anywhere** (one byte at a time, mid-handshake, mid-chunk): the receiver yields the same events. Test: `fixtureReplaysInAnyChunking`.
5. **Camera stream drops while live:** the outward stream stays up on the slate, one background retry, then Retry offered; ending stays the operator's action. Test: `cameraLossKeepsTheStreamAndRetriesOnce`.

---

## PR 1 (OpenCine): 1080p upscaled choice, both platforms

Branch `feat/stream-1080p-upscaled` from `origin/main`.

### Task 1.1: The engine's quality choice (Swift engine, JNI, Kotlin catalog)

**Files:**

- Modify: `Sources/OpenCineStreaming/StreamOutputFormat.swift`
- Modify: `Sources/OpenCineStreamingAndroid/StreamRunWire.swift`, `Sources/OpenCineStreamingAndroid/StreamingNativeJNI.swift`
- Modify: `Android/streaming/src/main/kotlin/com/opencapture/opencine/streaming/StreamCatalog.kt`, `StreamingNative.kt`, testFixtures `FakeStreamingNative.kt`
- Test: `Tests/OpenCineStreamingTests/StreamOutputFormatTests.swift` (extend), `Tests/OpenCineStreamingAndroidTests/` (export names), `Android/streaming/src/test/.../StreamCatalogTest.kt`

**Interfaces:**

- Produces (Swift): `public enum StreamQualityChoice: String, CaseIterable, Hashable, Sendable { case cameraFeed, upscaled1080p }` with `static func offered(for source: StreamSourceFormat?) -> [StreamQualityChoice]` (`cameraFeed` always; `upscaled1080p` when the source is known and its short side is below 1080). `StreamOutputFormat.resolve(selected:connected:preset:choice: StreamQualityChoice = .cameraFeed)`: `upscaled1080p` gives the 1080 tier (1920x1080, 6 Mbps before the preset cap, swapped for 9:16).
- Produces (JNI): `StreamingNative.formatFor(presetId, width, height, fpsNum, fpsDen, connected, choice: String): String?`; Kotlin interface member with a default that calls `format` when the choice is `cameraFeed` and returns null otherwise.
- Produces (Kotlin): `enum class StreamQualityChoice(val wireName: String) { CAMERA_FEED("cameraFeed"), UPSCALED_1080P("upscaled1080p") }` with `companion fun offered(width: Int?, height: Int?): List<StreamQualityChoice>`; `StreamCatalog.format(..., choice: StreamQualityChoice = CAMERA_FEED)`.

- [ ] Write failing tests: `upscaledChoiceGivesThe1080Tier` (720p source, twitch preset: 1920x1080 at the preset cap; instagram: 1080x1920), `upscaledIsOfferedOnlyBelow1080` (720p: both; 1080p: camera feed only; nil: camera feed only), JNI `formatFor` returns the same JSON as `format` for `cameraFeed`; Kotlin `offered` mirror and catalog passes the choice through the fake.
- [ ] Run, see them fail; implement; run `swift test --filter 'StreamOutputFormat|StreamingNative'` and `./gradlew :streaming:test`; commit `feat(streaming): 1080p upscaled output choice`.

### Task 1.2: Quality choices in the presentation values and both settings cards

**Files:**

- Modify: `Sources/MonitorPresentation/LiveStreamPresentation.swift`, `Sources/MonitorUI/LiveStream/LiveStreamSettingsCard.swift`, `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/LiveStreamPresentation.kt`, `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/livestream/LiveStreamViews.kt`, `docs/streaming/ui-contract.md`
- Test: `Tests/MonitorPresentationTests/LiveStreamPresentationTests.swift`, `Android/monitor-ui/src/test/kotlin/com/opencapture/monitorui/LiveStreamCopyTest.kt`, `Tests/MonitorUITests/LiveStreamHostedTests.swift`

**Interfaces:**

- Produces: `public enum LiveStreamQualityKind { case source, upscaled }` on `LiveStreamQuality.kind` (default `.source`); `line` reads `1080p upscaled, 30 fps, 6 Mbps` for `.upscaled`.
- `public struct LiveStreamQualityOption: Hashable, Sendable, Identifiable { id, title, detail: String?, unavailableReason: String? }`.
- `LiveStreamSettingsState.qualityOptions: [LiveStreamQualityOption]` (default `[]`), `selectedQualityID: String` (default `"cameraFeed"`), `showsQualityPicker` (more than one option), `qualityDetail` (the selected option's detail).
- `LiveStreamSettingsActions.selectQuality: (String) -> Void` (init parameter defaulted). Kotlin: same names; `LiveStreamActions.selectQuality(id: String) {}` default body.
- Copy (`LiveStreamCopy`, Kotlin same): `qualityCameraFeed = "Camera feed"`, `qualityUpscaled = "1080p upscaled"`, `qualityUpscaledDetail = "The camera feed scaled up to 1080p, with your LUT."`.
- Card: with `showsQualityPicker`, the Quality row is a `Menu` (the service row's look) with identifier `monitor.livestream.qualityChoice`, the line stays `monitor.livestream.quality`, the detail is a note `monitor.livestream.qualityDetail`; an unavailable option is listed disabled with its reason as the note when selected-but-unavailable. Locked while live.

- [ ] Failing tests: `upscaledQualityLineSaysUpscaled`, `qualityPickerShowsOnlyWithChoices`, Kotlin mirrors in `LiveStreamCopyTest`; hosted test that the picker lists both titles.
- [ ] Implement, run `swift test --filter LiveStreamPresentation`, `./gradlew :monitor-ui:test`, the MonitorUI scheme build; update the UI contract (Quality copy section and the card row table); commit `feat(monitor-ui): quality choices on the live stream card`.

### Task 1.3: Coordinators offer, remember and use the choice; LUT keeps its width

**Files:**

- Modify: `Sources/OpenCineAppKitApple/LiveStreamCoordinator.swift`, `Android/appkit-native/src/main/kotlin/com/opencapture/opencine/appkitnative/LiveStreamCoordinator.kt`, `LiveStreamComposition.kt` (preferences), `Sources/OpenCineApple/MonitorCleanPictureTap.swift`, `Sources/OpenCineApple/MonitorImageCompositor.swift`
- Test: `Tests/OpenCineAppKitAppleTests/LiveStreamCoordinatorTests.swift`, `Android/appkit-native/src/test/.../LiveStreamCoordinatorTest.kt`

**Interfaces:**

- Swift `LiveStreamCoordinator.selectQuality(_ id: String)` (ignored while running or for an unknown id), remembered under `opencine.livestream.quality`. Kotlin `selectQuality(id)`, `LiveStreamSettings.selectedQualityId: String?` with a default getter (null) and setter (no-op) so other implementors still compile.
- Effective choice: the remembered one when offered for the current source, else `cameraFeed`.
- `MonitorImageCompositor.applyProduct(to:effects:display:workingWidth: CGFloat? = nil)`; the clean picture tap passes its own `maxWidth`, so a 1080p source keeps 1920 wide with a LUT on.

- [ ] Failing tests (both platforms): `upscaledChoiceStreams1920x1080`, `rememberedChoiceFallsBackWhenNotOffered` (1080p source: options only Camera feed, start uses 1080 from source; remembered value survives a new coordinator), `qualityIsLockedWhileLive`.
- [ ] Implement; `swift test --filter LiveStreamCoordinator`, `./gradlew :appkit-native:test`; full verification (AGENTS.md list), API snapshots (`atlas api --write --build`, `./gradlew updateKotlinAbi updateAndroidApi`), `atlas consumers --write` if stale; commit `feat(appkit): stream in 1080p upscaled`.
- [ ] Code review (`superpowers:requesting-code-review`), PR, CI gate green, merge. Then pin moves: OpenInstaCine, OpenZCine and OpenPocketCine (check for open pin-bot PRs first).

## PR 2 (OpenCine): native capability, receiver, DJI livestream commands

Branch `feat/camera-stream-receiver` from `origin/main` after PR 1.

### Task 2.1: Core capability (Swift and Kotlin)

**Files:** Create `Sources/OpenCineCore/CameraStreamPublishing.swift`, `Android/core/src/main/kotlin/com/opencapture/opencine/core/CameraStreamPublishing.kt`; tests `Tests/OpenCineCoreTests/CameraStreamPublishingTests.swift`, `Android/core/src/test/.../CameraStreamPublishingTest.kt`.

**Interfaces:** `public struct CameraStreamPublishing: Hashable, Sendable { enum Codec: String { case h264, hevc }; width: Int; height: Int; frameRates: [Int]; codecs: [Codec] (preferred first); takesLUT: Bool; experimental: Bool; func frameRate(near: Int?) -> Int }` (the requested rate when listed, else the highest listed at or below 30, else the first). Kotlin twin same names (`Codec.H264`, `Codec.HEVC`).

- [ ] Test `frameRateFallsBackToAListedRate` on both; implement; commit `feat(core): camera stream publishing capability`.

### Task 2.2: DJI livestream commands and the capability declaration

**Files:** Create `Sources/OpenCineDJI/LivestreamCommands.swift`, `Sources/OpenCineDJI/DJIStreamPublishing.swift`; modify `Sources/OpenCineDJIAndroid/DjiNativeWire.swift`, `Android/dji/src/main/kotlin/com/opencapture/opencine/dji/DjiNative.kt`; create `Android/dji/src/main/kotlin/com/opencapture/opencine/dji/DjiStreamPublishing.kt`; create `Fixtures/dji-livestream-frames.tsv`; tests `Tests/OpenCineDJITests/LivestreamCommandsTests.swift`, `Tests/OpenCineDJIAndroidTests/DjiNativeWireTests.swift`, `Android/dji/src/test/.../DjiStreamPublishingTest.kt`.

**Interfaces:**

- `LivestreamCommands.prepare(seq:)` (= `02/E1 1A` to receiver 08), `start(seq:)` (`02/8E 01 01 1A 00 01 01`), `end(seq:)` (`... 01 02`), `preset(frameRate:bitrateKbps:modeBytes:)` (1080p `0A`, bitrate u16le, two mode bytes default `02 01`, fps code 25 is 2 and 30 is 3, three zeros), `configureDirectURL(url:preset:seq:)` (version 00), `configureJSON(url:preset:codec:seq:)` (version 01; JSON keys `rtmpAddress`, `codec` `AVC|HEVC`, `EnhancedRTMP` true for HEVC, `supportStopLive` false, `watermark` 0, `orientation` `landscape`; slashes escaped). Moblin (MIT) credited as wire reference.
- `DJIStreamPublishing.capability(for: CameraModel) -> CameraStreamPublishing?`: Pocket 4 Pro `[.hevc, .h264]`, 25 and 30, `experimental: false`; Pocket 4 the same with `experimental: true`; Pocket 3 `[.h264]`, `experimental: true`; else nil. `takesLUT: false`, 1920x1080. Kotlin `DjiStreamPublishing.capability(model: CameraModel)` twin by model name.
- JNI command kinds 68 `livestreamPrepare`, 69 `livestreamConfigure` (extra `version\u{1f}url\u{1f}codec\u{1f}fps\u{1f}kbps`), 70 `livestreamStart`, 71 `livestreamEnd`; Kotlin `DjiNative.CMD_LIVESTREAM_*` and `waitKey` entries.
- Golden frames in the TSV (name, hex payload) used by the Swift command test, the Swift JNI wire test and (by key) the Kotlin test.

- [ ] Failing tests: `framesMatchTheGoldens` (prepare, start, end, configure v01 HEVC at 30 fps 6000 kbps for `rtmp://172.20.10.1:1935/live/abcd`, v00 for Pocket 3 with the handbook's Mimo preset `0A 70 17 02 01 02 00 00 00`), `onlyListedBodiesDeclareTheCapability` (Swift and Kotlin), `livestreamKindsEncodeTheGoldens` (JNI wire), Kotlin `waitKey` for the four kinds.
- [ ] Implement, run `swift test --filter 'Livestream|DjiNativeWire|DJIStreamPublishing'`, `./gradlew :dji:test`; commit `feat(dji): livestream commands and the stream publishing capability`.

### Task 2.3: Portable RTMP receive session and the receiver token

**Files:** Create `Sources/OpenCineStreaming/RTMPReceiveSession.swift`, `Sources/OpenCineStreaming/StreamReceiverToken.swift`, `Fixtures/rtmp-receive/` (recorded publisher bytes); tests `Tests/OpenCineStreamingTests/RTMPReceiveSessionTests.swift`.

**Interfaces:** `RTMPReceiveSession(expectedStreamKey: String)` with `receive(_ bytes: [UInt8]) -> Output` (`outbound`, `events`), `state`. Events: `handshakeDone`, `connect(app:)`, `publish(type:)` (only for the expected key), `metadata([String: String])`, `videoConfig(codec:record:enhanced:)`, `videoFrame(RTMPReceivedVideoFrame)`, `videoEnd`, `audioConfig([UInt8])`, `audioFrame(timestampMs:bytes:)`, `unsupported(String)` (once per kind), `unpublished(String)`, `failed(RTMPReceiveFailure)` (`handshakeVersion`, `chunkStream`, `unexpectedStreamKey`). `StreamReceiverToken.random()`, `.value` (32 lowercase hex), `.logLabel` (first 4 characters then `****`), `publishURL(host:port:) -> String` = `rtmp://<host>:<port>/live/<value>`.

- [ ] Failing tests: `publisherGoesLiveAndItsMediaArrives` (our `RTMPPublishSession` into the receiver), `enhancedAndLegacyHEVCTagsParse`, `wrongStreamKeyIsRefused`, `acknowledgesAfterThePublishersWindow`, `fixtureReplaysInAnyChunking` (each recorded fixture fed whole, in 1-byte and in 4093-byte pieces: same events; counts of configs, keyframes, frames and AAC frames), `tokenNeverLogsMoreThanFourCharacters`.
- [ ] Implement (lift the spike session, add the key check and typed failures); commit `feat(streaming): RTMP receive session for a camera's own stream`.

### Task 2.4: Apple listener, video and audio decoders

**Files:** Create `Sources/OpenCineStreamingApple/RTMPLocalReceiver.swift`, `RTMPVideoDecoder.swift`, `RTMPAudioDecoder.swift`; tests `Tests/OpenCineStreamingAppleTests/RTMPVideoDecoderTests.swift`, `RTMPLocalReceiverFFmpegTests.swift` (opt-in `OPENCINE_RTMP_FFMPEG=1`; with `OPENCINE_WRITE_FIXTURES=1` it rewrites `Fixtures/rtmp-receive/`).

**Interfaces:** `RTMPLocalReceiver(port: UInt16 = 1935, token: StreamReceiverToken, onEvent:)` with `start()`, `stop()`, events `listening(port:)`, `listenFailed(String)`, `publisherConnected(remote:)`, `publisherDisconnected(remote:reason:)`, `session(RTMPReceiveEvent)`; newest publisher replaces the old one. `RTMPVideoDecoder(onPicture:onError:)` with `configure(codec:record:) -> Configuration?`, `decode(_:)`, `reset()`; pictures in display order. `RTMPAudioDecoder(onBuffer: (AVAudioPCMBuffer) -> Void)` with `configure(audioSpecificConfig:)`, `decode(_ bytes: [UInt8])`.

- [ ] Failing tests: `decodesTheRecordedH264AndHEVCFixturesInDisplayOrder` (fixture frames through the decoder: picture count, size, increasing presentation times), `aacFixtureDecodesToPCM`; the opt-in ffmpeg harness.
- [ ] Implement, full verification, snapshots; commit `feat(streaming-apple): local RTMP receiver and decoders`; review, PR, CI, merge.

## PR 3 (OpenCine): iOS native relay, presentation and DJI provisioning

Branch `feat/camera-1080p-relay-ios`.

### Task 3.1: Presentation for the native choice and its status (Swift and Kotlin values, both views)

**Files:** `Sources/MonitorPresentation/LiveStreamPresentation.swift`, `Sources/MonitorUI/LiveStream/LiveStreamMonitorControls.swift`, `LiveStreamSettingsCard.swift`, Kotlin `LiveStreamPresentation.kt`, `livestream/LiveStreamViews.kt`, `docs/streaming/ui-contract.md`; tests as in 1.2.

**Interfaces:**

- `LiveStreamQualityKind.camera`; line `1080p from camera, 30 fps, 6 Mbps`.
- Copy: `qualityCamera = "1080p from camera"`, `qualityCameraDetail = "Sharper picture, encoded by the camera, standard color, no LUT."`, `qualityCameraNeedsNetwork = "Save a shared network in the camera's Wi-Fi setup to use this."`; start message for the camera kind: `<quality>. The camera's own picture goes out in standard color, without the monitor LUT, with the camera's sound. Camera recording is separate.`
- `LiveStreamNetworkChoice { id, name }`; `LiveStreamMonitorState.networkChoices` (default `[]`): with two or more, the start confirmation offers one button per network, `Go live over <name>`, hotspot first.
- `LiveStreamCameraStatus`: `starting` ("Starting the camera's stream."), `live` ("1080p from camera. Assists, scopes and camera controls are off in this mode."), `recovering` ("The camera's stream stopped. Trying again."), `lost` ("The camera's stream did not come back." with Retry), `notResponding` ("The camera is not responding. Hold its power button about 10 seconds to restart it.") on `LiveStreamMonitorState.cameraStatus`; identifiers `monitor.livestream.cameraStatus`, `monitor.livestream.cameraRetry`.
- `LiveStreamEnd.cameraDidNotStart` notice: "The camera did not start its stream. Try again, or choose Camera feed in the live stream settings."
- Actions: `retryCamera()` (Swift monitor actions and Kotlin `LiveStreamActions`, defaulted), `start(network:)`.

- [ ] Failing tests for every new string and the confirmation buttons (Swift and Kotlin), implement, commit `feat(monitor-ui): 1080p from camera choice and status`.

### Task 3.2: The coordinator's native relay (Swift)

**Files:** Create `Sources/OpenCineAppKitApple/LiveStreamCameraSource.swift`, `LiveStreamCameraRelay.swift`, `LiveStreamCameraMonitor.swift`; modify `LiveStreamCoordinator.swift`, `Sources/OpenCineStreaming/StreamOutputFormat.swift` (`camera1080p` choice); tests `Tests/OpenCineAppKitAppleTests/LiveStreamCameraRelayTests.swift`.

**Interfaces:**

- Host protocol (app implements):

  ```swift
  @MainActor public protocol LiveStreamCameraSource: AnyObject {
      var publishing: CameraStreamPublishing? { get }
      var networks: [LiveStreamNetwork] { get }          // hotspot first
      func prepare(_ network: LiveStreamNetwork) async throws -> String   // phone address there
      func startPublishing(to url: String, network: LiveStreamNetwork, frameRate: Int) async throws
      func endPublishing() async                          // bounded, never throws
      func finished()                                     // back to the normal connect flow
  }
  public struct LiveStreamNetwork: Hashable, Sendable { id: String; name: String; isHotspot: Bool }
  public enum LiveStreamCameraError: Error { case notResponding; case refused(String) }
  ```

  `LiveStreamHost.camera: (any LiveStreamCameraSource)?` (init parameter defaulted to nil).
- `StreamQualityChoice.camera1080p`, offered when `publishing != nil` (listed disabled with `qualityCameraNeedsNetwork` when there is no network); its output is `1920x1080` at `publishing.frameRate(near: 30)`.
- Relay seam: `LiveStreamCameraRelaying` (open with token and sinks for picture and PCM, events `listenFailed`, `connected`, `firstPicture`, `lost`; close), production `CameraStreamRelay` over `RTMPLocalReceiver` and the decoders; it also feeds `LiveStreamCameraMonitor`'s display layer.
- Coordinator: `cameraStreamActive: Bool`, `retryCamera()`, `start(network:)`, `prepareForTermination()`; a `sleep: (Duration) async throws -> Void` seam for the first-picture wait (60 s) and the retry pause.
- Flow: prepare, open relay with a fresh token, `startPublishing`, wait for the first picture, then the publisher (no microphone; pictures and camera PCM go straight to it; `attachPicture` is never called). Start error or no picture: `endPublishing`, one retry, then `ended(.cameraDidNotStart)` (`notResponding` sets the status line). Lost while live: keep the publisher (it slates after 2 s), `endPublishing`, one restart, then `lost` with Retry. Stop, background, terminate, failure: publisher stop, `endPublishing`, relay close, `finished()`.
- `LiveStreamCameraMonitor(coordinator:)`: the relayed picture fit to the screen, `LiveStreamMonitorOverlay` on top, the status line from `cameraStatus`.

- [ ] Failing tests (fakes for source, relay and publisher; scripted sleep): `cameraChoiceNeedsTheCapability`, `cameraChoiceListedDisabledWithoutANetwork`, `cameraStartOrderAndNoMicrophone`, `goesLiveOnlyAfterTheFirstPicture`, `startErrorEndsCleanlyAndRetriesOnce`, `cameraLossKeepsTheStreamAndRetriesOnce`, `stopEndsTheCameraStreamAndReturnsTheCamera`, `backgroundEndsTheCameraStreamFirst`, `severalNetworksAreOfferedHotspotFirst`.
- [ ] Implement, verify, commit `feat(appkit): relay a camera's own 1080p stream`.

### Task 3.3: DJI provisioning sequence (Apple)

**Files:** Create `Sources/OpenCineDJIApple/DJICameraStreamPublisher.swift`; test `Tests/OpenCineDJIAppleTests/DJICameraStreamPublisherTests.swift`.

**Interfaces:** `DJILivestreamLink` protocol (`next() -> UInt16`, `exchange(_:timeout:) async throws -> Duml.Frame`, `close() async`), production over `DjiAppleMultiviewProvisioner` (connect and pair inside `DJICameraStreamPublisher.connect(camera:host:)`). `DJICameraStreamPublisher(link:model:log:)` with `start(url:network:frameRate:codec:) async throws` and `end() async`. Sequence: end (cleanup, reply not required), prepare (reply must start `00`), settle 1 s, join with `MulticamJoinPolicy`, configure (version 00 for Pocket 3, version 01 otherwise; reply `00`), start (reply `00`, else `DJICameraStreamError.startRefused(payload)`; no reply is `noReply`). `end()` sends end with a 6 s timeout, ignores the result, closes the link. The log never contains the password or more than the token's log label.

- [ ] Failing tests with a scripted link: `startSendsTheProvenSequence`, `joinRetriesOn01FFThenSucceeds`, `startRefusalCarriesTheReply` (`D6`), `endAlwaysClosesTheLink`, `logHoldsNoSecret`; implement; full verification, snapshots; commit `feat(dji-apple): provision a camera's own livestream`; review, PR, CI, merge.

## PR 4 (OpenPocketCine): pin and wiring (iOS)

Branch `feat/camera-1080p-relay` in OpenPocketCine.

### Task 4.1: Pocket camera source and the native monitor

**Files:** Create `ios/OpenPocketCine/PocketCameraStream.swift`; modify `ios/OpenPocketCine/AppModel+LiveStream.swift`, `ios/OpenPocketCine/AppRoot.swift`, `opencine-pins.txt`, `docs/PARITY.md`; test `ios/OpenPocketCineTests/LiveStreamHostTests.swift`.

**Interfaces:** `PocketCameraStreamSource: LiveStreamCameraSource` over the app model: `publishing` from `DJIStreamPublishing.capability(for:)` of the connected (or last connected) camera, gated by the experimental switch for experimental bodies; `networks` from `MultiviewNetworkStore` (hotspot first, id `ssid|hotspot`); `prepare` releases the camera like Multiview (`openMultiview()`), joins the phone to a Wi-Fi network (not the hotspot) through `SharedWiFiPath`, waits up to 20 s for the address (hotspot fallback `172.20.10.1`); `startPublishing` drives `DJICameraStreamPublisher`; `endPublishing` its `end()`; `finished()` resumes the normal connect flow (`closeMultiview()`). `AppRoot` presents `LiveStreamCameraMonitor` while `cameraStreamActive`, and calls `prepareForTermination()` on `UIApplication.willTerminateNotification`.

- [ ] Failing host tests: `cameraSourceNeedsADeclaredBody`, `networksListTheHotspotFirst`; implement; `just check native-check`; Debug device build and install; commit, PR, CI, merge; parity exception recorded (Android hidden until hardware pass).

## PR 5 (OpenCine): Android twin, hidden

Branch `feat/camera-1080p-relay-android`.

### Task 5.1: JNI receiver registry and Kotlin reply

**Files:** `Sources/OpenCineStreamingAndroid/StreamingNativeJNI.swift`, `StreamRunWire.swift` (receiver registry), `Android/streaming/.../StreamingNative.kt`, create `RtmpReceiveReply.kt`, `Fixtures/rtmp-receive-reply-vectors.tsv`; tests both sides.

**Interfaces:** `receiverCreate(token: String): String` (owner), `receiverFeed(owner, bytes): ByteArray`, `receiverClose(owner)`, interface defaults throw `UnsupportedOperationException`. Reply: `u32 outbound length, outbound, u16 event count, events [u8 kind, u32 length, body]` (kinds: 1 publish, 2 videoConfig `[codec, enhanced, record]`, 3 videoFrame `[codec, key, u32 dts, i32 cts, data]`, 4 audioConfig, 5 audioFrame `[u32 ts, data]`, 6 unpublished, 7 failed `[reason utf8]`, 8 metadata (ignored), 9 videoEnd).

- [ ] Vector test on both sides (Swift encodes, Kotlin decodes the same hex), export-name test; implement; commit.

### Task 5.2: Kotlin listener, decoders, relay and coordinator twin; DJI provisioning twin

**Files:** create `Android/streaming/.../RtmpLocalReceiver.kt`, `CameraStreamDecoder.kt` (MediaCodec video to YUV, converted to RGBA into a `MonitorCleanPictureTap` owned by the relay; AAC to PCM), `Android/appkit-native/.../LiveStreamCameraSource.kt`, `CameraStreamRelay.kt`, modify `LiveStreamCoordinator.kt`; create `Android/dji/.../DjiCameraStreamPublisher.kt`; tests `LiveStreamCameraRelayTest.kt`, `DjiCameraStreamPublisherTest.kt` mirroring 3.2 and 3.3 by name.

- [ ] Mirrored failing tests, implement, `cd Android && ./gradlew test lint assembleRelease`, API snapshots, commit, review, PR, CI, merge. No app passes a camera source on Android.

## Hardware checklist (owner, after PR 4 is on the phone)

Written to `build.md` on the NAS for the live page. First item is the design's open risk: recovery of a camera left live by a killed app.
