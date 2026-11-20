# RTMPS Streaming, Part 3: Android Shell and Android Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream one camera from each Android app (OpenPocketCine, OpenInstaCine, OpenZCine) to an RTMPS service, matching iOS: the portable run controller reused over JNI, an Android `:streaming` shell (socket, MediaCodec H.264 and AAC, microphone, Keystore keys, device warnings), the clean-picture tap in the native runtime, the Compose twin of the shared streaming UI, composition with lifecycle rules, and adoption in the three apps.

**Architecture:** `StreamRun` (part 2) stays the only run logic. `OpenCineStreamingAndroid` wraps it in an owner-keyed registry (`StreamRunWire`, like `GyroLoggingWire`) and exports it as `com.opencapture.opencine.streaming.StreamingNative`. Inputs cross JNI as primitives and byte arrays; each call returns one binary reply holding the actions in order and the status, so a video frame's RTMP bytes never pass through JSON. Kotlin applies the actions: it owns the socket, the encoders, the clocks and the picture surface. Pictures never cross JNI: the native runtime's clean tap renders LUT-on, assists-off frames straight into the encoder's input surface.

**Tech Stack:** Swift 6 (Swift Testing) for the wire; Kotlin, `MediaCodec`, `AudioRecord`, `SSLSocket`, Android Keystore (`KeystoreSeal`), GLES/EGL, Jetpack Compose. JUnit on the JVM. No third-party package.

**Spec:** `docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`. Part 1: `docs/superpowers/plans/2026-11-05-rtmps-1-timecode-and-engine.md`. Part 2: `docs/superpowers/plans/2026-11-18-rtmps-2-apple-shell.md`.

## Global Constraints

- `OpenCineStreamingAndroid` depends on `OpenCineStreaming`, `OpenCineCore` and `OpenCineJNISupport` only; the JNI file is `#if os(Android)`.
- Android `:streaming` depends on `:platform` (for `KeystoreSeal`) and the Android framework only: never UI, an integration, the native runtime, an app or a third-party package. No brand or app names (rules test).
- The JNI class `com.opencapture.opencine.streaming.StreamingNative` and its member names are the native contract; change both sides in step (export-names test, as Gyro).
- A stream key never appears in a log, `toString`, exception message, status value or failure text.
- Output values from the spec: H.264, 2 second keyframe interval, AAC-LC stereo at 48 kHz and 160 kbps, about 3 Mbps at 720p and 6 Mbps at 1080p, reconnect for up to 2 minutes, output does not queue while offline.
- `rtmps://` uses TLS with the system trust store, SNI and host name verification. Plain `rtmp://` is accepted only when the portable engine accepts it (owner decision 2026-11-20: custom servers may use it, with a warning that the stream and key are not encrypted); the wire reports which one the destination is and Kotlin never decides it.
- What goes out: the clean camera picture with the monitor LUT when one is on, never assists or app controls.
- Streaming is a passenger: a stream failure never disturbs camera control, the monitor or recording; starting or stopping never sends a camera command.
- Foreground only: leaving the app ends the stream; the screen stays awake while live. Thermal and low battery warn, never stop.
- Tests are deterministic: manual instants, no sleeps. Local socket tests are event driven.

## Review Focus

1. **The JNI owner is gone or never existed** (a stale stop after close). Every wire call answers "ended", never crashes. Test: `unknownOwnerRepliesEnded` (Task 1).
2. **A video frame larger than one socket write while the connection drops mid-write.** The connection reports `lost` once and the publisher reconnects without writing to the dead socket. Test: `lostIsReportedOnceAfterPeerCloses` (Task 3), `lostConnectionWaitsToReconnect` (Task 6).
3. **The encoder's first output is its codec config with SPS and PPS in one buffer.** It is split into `videoConfig` and reaches the run before any frame. Test: `codecConfigSplitsIntoSpsAndPps` (Task 4).
4. **Keystore has lost its key after a backup restore.** The page shows "re-enter key", never offers a stale key. Test: `lostDeviceKeyIsUnavailableNotAbsent` (Task 5).
5. **The app goes to the background while reconnecting.** The stream ends, the timers stop, and returning offers one-tap restart. Test: `backgroundEndsTheStreamAndOffersRestart` (Task 9).

## File Structure

| Path | Responsibility |
| --- | --- |
| `Sources/OpenCineStreamingAndroid/StreamRunWire.swift` | Owner registry over `StreamRun`; binary replies; presets, format and destination checks as JSON |
| `Sources/OpenCineStreamingAndroid/StreamingNativeJNI.swift` | `Java_com_opencapture_opencine_streaming_StreamingNative_*` exports |
| `Tests/OpenCineStreamingAndroidTests/*` | Wire behavior and the export-names contract |
| `Android/streaming/.../StreamingNative.kt` | JNI facade and `StreamingNativeApi` |
| `Android/streaming/.../StreamRunReply.kt` | Reply decoding: `StreamAction`, `StreamStatus` |
| `Android/streaming/.../StreamCatalog.kt` | Presets, output format, destination check (JSON from the wire) |
| `Android/streaming/.../StreamConnection.kt` | Socket connection, TLS or plain as the wire says |
| `Android/streaming/.../H264StreamEncoder.kt`, `AacStreamEncoder.kt` | MediaCodec encoders and their pure helpers |
| `Android/streaming/.../StreamKeyStore.kt` | Keys and entered servers per preset, sealed by `KeystoreSeal` |
| `Android/streaming/.../StreamMicrophone.kt` | `AudioRecord` at 48 kHz stereo |
| `Android/streaming/.../StreamDeviceWarnings.kt` | Thermal and battery warnings |
| `Android/streaming/.../StreamPublisher.kt` | Drives the wire: socket, clocks, encoders, picture source |
| `Android/native-runtime/.../MonitorCleanPictureTap.kt` | LUT-on, assists-off picture rendered into an encoder surface |
| `Android/monitor-ui/.../livestream/*` | Compose twin of the shared streaming UI (`docs/streaming/ui-contract.md`) |
| `Android/appkit-native/.../LiveStreamCoordinator.kt` | Composition: publisher, microphone, tap, lifecycle, warnings, screen awake |

---

### Task 1: `OpenCineStreamingAndroid`, the JNI wire

**Files:**

- Modify: `Package.swift` (product `OpenCineStreamingAndroid`, target with `OpenCineStreaming`, `OpenCineCore`, `OpenCineJNISupport`; test target), `atlas/repos/opencine/meta.json`, `AGENTS.md` (boundary and JNI rule bullets beside Gyro)
- Create: `Sources/OpenCineStreamingAndroid/StreamRunWire.swift`, `StreamingNativeJNI.swift`; `Tests/OpenCineStreamingAndroidTests/StreamRunWireTests.swift`, `StreamingNativeExportNamesTests.swift`

**Interfaces:**

- Produces (Swift): `public final class StreamRunWire: @unchecked Sendable` with `static let shared`; `create(serverURL:streamKey:format:nowNs:) -> String` (JSON `{"owner":…,"tls":…}` or `{"error":"notRTMPS|invalidServerURL|emptyKey|keyLooksLikeURL|…"}`); `start(owner:)`, `connected(owner:nowNs:)`, `received(owner:bytes:nowNs:)`, `connectionLost(owner:nowNs:)`, `wrote(owner:count:nowNs:)`, `tick(owner:nowNs:)`, `stop(owner:nowNs:)`, `publishVideoConfig(owner:sps:pps:nowNs:)`, `publishVideo(owner:annexB:isKeyframe:decodeMs:presentMs:nowNs:)`, `publishAudioConfig(owner:asc:nowNs:)`, `publishAudio(owner:raw:presentMs:nowNs:)`, each `-> [UInt8]`; `close(owner:)`; `presetsJSON() -> String` (presets then custom); `formatJSON(presetID:selectedWidth:selectedHeight:fpsNum:fpsDen:connected:[Int32]) -> String?`; `checkDestination(serverURL:streamKey:) -> String` (`{"ok":true,"tls":…}` or `{"error":…}`); `canStream(route: String) -> Bool`.
- Reply encoding (big-endian), actions in order then one status record:
  `1 connect u16 port, u16 n, host` · `2 write u32 n, bytes` · `3 disconnect` · `4 setVideoBitrate i32` · `5 requestKeyframe` · `6 wake i64 ns` · `127 status u8 phase(0 connecting,1 live,2 reconnecting,3 ended), i32 attempt, u8 end(0 none,1 stopped,2 refused,3 gaveUp), u16 n, reason, i64 liveSinceNs(-1 none), i32 sentBps, i32 videoBps, i32 droppedGroups, i32 droppedAudio, u8 health(0 good,1 congested,2 offline)`.
- An unknown owner replies with only a status record: phase ended, end stopped.

- [ ] **Step 1: Failing tests** `startRepliesConnectThenStatus`, `liveRunWritesMediaAndReportsLive` (driven by part 1's `SimulatedRTMPServer`), `refusalEndsWithoutTheKey`, `wakeCarriesNanoseconds`, `unknownOwnerRepliesEnded`, `badDestinationNamesTheError`, `tlsFollowsTheScheme`, `presetsEndWithCustom`, `formatFollowsTheSourceAndPreset`, `keyIsInNoReplyOrJSON`, plus the export-names pair (`everyExportMatchesTheKotlinNativeContract`, `everyKotlinMemberMatchesTheExportParameterCount`).
- [ ] **Step 2:** `swift test --filter OpenCineStreamingAndroidTests`; expected: missing module.
- [ ] **Step 3: Implement.** `NSLock`-guarded `[String: StreamRun]`; `MonotonicInstant(.nanoseconds(nowNs))`; `tls` is `destination.tcURL.hasPrefix("rtmps://")`. The JNI file only converts types and calls the wire.
- [ ] **Step 4:** pass; `python3 atlas/tools/atlas.py api --write --build`; `atlas check`.
- [ ] **Step 5: Commit** `feat(streaming): reuse the run controller on Android over JNI`.

### Task 2: Android `:streaming` module and the facade

**Files:** `Android/settings.gradle.kts`; create `Android/streaming/build.gradle.kts`, `consumer-rules.pro`, `StreamingNative.kt`, `StreamRunReply.kt`, `StreamCatalog.kt`; test fixture `FakeStreamingNative.kt`; tests `StreamRunReplyTest`, `StreamCatalogTest`, `StreamingRulesTest`.

**Interfaces:**

- `interface StreamingNativeApi` with the Task 1 members (`ByteArray` replies, `String` JSON), `object StreamingNative : StreamingNativeApi` with `load(library): Boolean` and `isAvailable`.
- `sealed interface StreamAction { Connect(host, port), Write(bytes), Disconnect, SetVideoBitrate(bps), RequestKeyframe, Wake(atNs) }`; `data class StreamStatus(phase: StreamPhase, liveSinceNs: Long?, sentBitrateBps, videoBitrateBps, droppedVideoGroups, droppedAudioPackets, health: StreamHealth)`; `sealed interface StreamPhase { Connecting, Live, Reconnecting(attempt), Ended(end: StreamEnd) }`; `sealed interface StreamEnd { Stopped, Refused(reason), GaveUp }`; `enum StreamHealth { GOOD, CONGESTED, OFFLINE }`; `class StreamRunReply(actions, status)` with `companion fun decode(bytes: ByteArray): StreamRunReply`.
- `data class StreamServicePreset(id, displayName, serverUrl: String?, requiresServerEntry, maxVideoBitrateBps: Int?, portrait: Boolean, keyHint)`; `data class StreamOutputFormat(width, height, fpsNum, fpsDen, videoBitrateBps, keyframeIntervalSeconds, audioBitrateBps, audioSampleRate, audioChannels)`; `sealed interface StreamDestinationCheck { Ok(tls), Invalid(reason: StreamDestinationProblem) }`; `class StreamCatalog(native: StreamingNativeApi)` with `presets()`, `format(...)`, `check(server, key)`, `canStream(route)`.

Tests: `decodesEveryActionInOrder`, `statusRoundTripsEveryPhase`, `truncatedReplyIsEnded`, `presetsDecodeWithCustomLast`, `destinationProblemsMapFromTheWire`, `streamingImportsOnlyPlatformAndAndroid` (rules: no `monitorui`, `runtime`, `dji`, `nikon`, `insta360`, app packages; no brand names).

Commit: `feat(streaming): add the Android streaming facade`.

### Task 3: Socket connection

**Files:** `StreamConnection.kt`, `StreamConnectionTest.kt`.

- `interface StreamConnection { fun open(onEvent: (StreamConnectionEvent) -> Unit); fun write(bytes: ByteArray); fun close() }`, `sealed interface StreamConnectionEvent { Opened, Received(bytes), Wrote(count), Lost }`; `class SocketStreamConnection(host, port, tls: Boolean, connectTimeoutMs = 10_000)`: one reader thread, one writer thread, events in order, `Lost` at most once and never after `close()`. TLS: `SSLSocketFactory.getDefault()`, SNI by host, `HttpsURLConnection.getDefaultHostnameVerifier()` on the session; failure is `Lost`.
- Tests (plain local `ServerSocket`, latches, no sleeps): `deliversBytesBothWays`, `reportsWrittenCounts`, `lostIsReportedOnceAfterPeerCloses`, `refusedConnectionIsLost`, `closeReportsNothing`.

Commit: `feat(streaming): add the Android stream connection`.

### Task 4: Encoders

**Files:** `H264StreamEncoder.kt`, `AacStreamEncoder.kt`, `StreamEncodedMedia.kt` (pure helpers), tests `StreamEncodedMediaTest`.

- `class H264StreamEncoder(format)`: `MediaCodec` `video/avc` with surface input (`inputSurface: Surface`), High profile when the codec lists it, `KEY_I_FRAME_INTERVAL` from the format, `KEY_MAX_B_FRAMES` 0, CBR-like `BITRATE_MODE_CBR` when supported else VBR; `setBitrate(bps)` (`PARAMETER_KEY_VIDEO_BITRATE`), `requestKeyframe()` (`PARAMETER_KEY_REQUEST_SYNC_FRAME`), `start(output: (StreamMediaPacket) -> Unit)`, `release()`. Output drained on its own thread.
- `class AacStreamEncoder(format)`: `audio/mp4a-latm` AAC-LC, `encode(pcm16: ShortArray, frames: Int)`; emits `AudioConfig` once and frames whose times follow the sample count from 0.
- Pure: `StreamEncodedMedia.splitParameterSets(config: ByteArray): Pair<ByteArray, ByteArray>?`, `annexBHasIdr(bytes)`, `class AacTimeline(sampleRate)` (`ms(forSampleIndex)`).
- Kotlin `sealed interface StreamMediaPacket { VideoConfig(sps, pps), Video(annexB, isKeyframe, decodeMs, presentMs), AudioConfig(asc), Audio(raw, presentMs) }`.
- Tests: `codecConfigSplitsIntoSpsAndPps`, `threeByteStartCodesSplitToo`, `configWithoutPpsIsRejected`, `aacFramesAdvanceBy1024Samples`, `idrIsAKeyframe`.

Commit: `feat(streaming): encode H.264 and AAC on Android`.

### Task 5: Keys, microphone and device warnings

**Files:** `StreamKeyStore.kt`, `StreamMicrophone.kt`, `StreamDeviceWarnings.kt`, tests `StreamKeyStoreTest`, `StreamDeviceWarningsTest`.

- `class StreamKeyStore(storage: StreamKeyStorage, seal: StreamSecretSeal)`; `StreamKeyStorage` (string get/put/remove; production `SharedPreferences` under a host file name), `StreamSecretSeal` (production over `KeystoreSeal(alias)` with a host alias); `sealed interface Lookup { Absent, Stored(value), Unavailable }`; `key(presetId)`, `server(presetId)`, `save(key, server, presetId): Boolean`, `remove(presetId): Boolean`. Accounts `stream-key.<id>`, `stream-server.<id>`. `toString` holds no key.
- `class StreamMicrophone(sampleRate = 48_000, channels = 2)`: `start(onPcm: (ShortArray, Int) -> Unit)`, `stop()`, `StreamMicrophoneError.PermissionDenied`. Device only.
- `enum StreamDeviceWarning { HOT, CRITICAL_HEAT, LOW_BATTERY }`, `fun streamDeviceWarnings(thermalStatus: Int, batteryPercent: Int?, charging: Boolean?): Set<StreamDeviceWarning>` (severe and above: HOT; critical and above: CRITICAL_HEAT; at or below 15 % and not charging: LOW_BATTERY; unknown stays silent); `class StreamDeviceMonitor(context)` delivering changes.
- Tests: `savedKeyReadsBack`, `removeForgetsKeyAndServer`, `lostDeviceKeyIsUnavailableNotAbsent`, `keyIsInNoDescription`, `severeThermalWarns`, `lowBatteryWarnsOnlyOffCharger`, `unknownBatteryIsSilent`.

Commit: `feat(streaming): keep keys in Keystore, capture audio and watch the device`.

### Task 6: `StreamPublisher`

**Files:** `StreamPublisher.kt`, `StreamFramePacer.kt`, `StreamPictureSource.kt`, tests `StreamPublisherTest`, `StreamFramePacerTest`.

- `interface StreamPictureSource { fun attach(surface: Surface, width: Int, height: Int, crop: Boolean, onPicture: () -> Unit); fun draw(presentationTimeNs: Long, slate: Boolean); fun detach() }`.
- `class StreamFramePacer(slateAfterNs = 2_000_000_000)`: `submit(atNs)`, `frame(atNs): Frame { PICTURE, SLATE }` (twin of the Swift pacer, same test names).
- `class StreamPublisher(native, catalogFormat, serverUrl, key, crop, picture: StreamPictureSource?, connect: (host, port, tls) -> StreamConnection, video: StreamVideoEncoder, audio: StreamAudioEncoder?, clock: () -> Long, scheduler: StreamScheduler)`: one executor confines everything; `start(): StreamDestinationCheck`, `stop()`, `submitAudio(pcm, frames)`, `status: StateFlow<StreamStatus>`. Applies replies in order; a connection generation drops events from closed connections; the frame clock runs at the format rate and calls `picture.draw(pts, slate)` only while live; media times are ms since `start()`.
- Tests with fakes and a manual scheduler: `appliesActionsInOrder`, `lostConnectionWaitsToReconnect`, `stopEndsTheRun`, `framesWaitUntilLive`, `keyframeAndBitrateReachTheEncoder`, `staleConnectionEventsAreIgnored`, `slowSourceRepeatsFrames`, `fastSourceSkipsToTheNewest`, `lostSourceShowsSlateAfterTwoSeconds`, `noPictureYetIsSlate`.

Commit: `feat(streaming): publish from Android encoders through the run controller`.

### Task 7: The clean-picture tap (native runtime, separate PR)

`MonitorCleanPictureTap` in `:native-runtime`: Vulkan and GLES live sessions submit raw identity frames only while an output is attached (Vulkan through an additive `nativeSetNeedClean` and `nativeCopyClean` pair); the tap applies the look-only plan (LUT, desqueeze; never peaking, zebra, false colour or split) on its own GL thread and renders fitted or cropped into the encoder surface with the presentation time. `MonitorLiveFeedIntegration` carries an optional tap. Tests: `fitRectKeepsShapeWithBars`, `cropFillsVertical`, `assistsNeverReachTheCleanPlan`, `noOutputNoWork`, `newestFrameWins`. No streaming type enters the runtime.

Commit: `feat(runtime): tap the clean monitor picture for streaming on Android`.

### Task 8: Compose twin of the shared streaming UI

**Files:** `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/livestream/*`, tests in `monitor-ui/src/test`.

Mirror `docs/streaming/ui-contract.md` exactly: the same screens, states, copy and accessibility identifiers (as test tags and content descriptions) as the SwiftUI views. Values and actions only; no engine import (presets reach the views as values). Tests pin what the contract pins: shown copy per state, disabled reasons, the masked key, the plain `rtmp://` warning, identifiers, plus the monitor-ui brand rules.

Commit: `feat(ui): live stream settings, go live control and status on Android`.

### Task 9: Composition in `appkit-native`

**Files:** `LiveStreamHost.kt` (host values: preferences file, Keystore alias, the connection route, the source format), `LiveStreamCoordinator.kt`, tests.

`LiveStreamCoordinator` holds the publisher, microphone, tap hookup and device monitor; exposes the UI state of Task 8; keeps the screen awake while live (`FLAG_KEEP_SCREEN_ON` through a host callback); ends the stream when the activity stops (the Android twin of the iOS background rule) and offers restart on return; warns on heat and low battery and never stops for them; never sends a camera command. Tests with fakes: `backgroundEndsTheStreamAndOffersRestart`, `startNeverSendsACameraCommand`, `ineligibleRouteNeverStarts`, `warningsNeverStopTheStream`.

Commit: `feat(appkit): compose live streaming on Android`.

### Task 10: Adopt in the three Android apps (one PR per app)

Per app: pin OpenCine to the main commit holding Tasks 1 to 9; add `OpenCineStreamingAndroid` to the app's Swift Android library and its `stageSwiftCore` inputs; call `StreamingNative.load` with the app's library; add `RECORD_AUDIO`; pass `LiveStreamHost` (preferences file and Keystore alias `<applicationId>.live-stream`, route mapping from the app's existing connection mode: camera access point `cameraWiFi`, shared network `sharedWiFi`, phone hotspot `deviceHotspot`, USB-C `usbCable`, HDMI capture `captureCard`); give the live feed integration the clean tap; show the settings section and Go live control where the iOS app does. Each app runs its own checks; hardware stays untested until the owner's pass.

## Not in this part

Program strip and cuts, timecode alignment (part 4), the cable route for Pocket and Insta (part 5), desktop (project 2). A Kotlin end-to-end run to FFmpeg needs the Swift library on the JVM and is not built; the Swift interop tiers cover the engine and the Apple shell, and the Android pipeline is covered by the hardware checklist.
