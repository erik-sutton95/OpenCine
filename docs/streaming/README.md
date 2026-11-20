# Live streaming (RTMPS)

Going live from a camera app to Twitch, YouTube, Facebook, Instagram or any `rtmps://` server (or
a plain `rtmp://` Custom server, with a warning), without OBS. This guide covers the portable
engine (part 1 of the series), the Apple shell and the shared iOS surfaces (part 2). The design
is `docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`; the plans are
`docs/superpowers/plans/2026-11-05-rtmps-1-*.md` and `2026-11-18-rtmps-2-*.md`. The surfaces
follow [the UI contract](ui-contract.md), which the Compose twins mirror.

Status: implemented, automated checks passed. Nothing here has streamed to a real service: the
Apple shell has streamed only to a local FFmpeg receiver. Android (part 3), program switching and
timecode alignment (part 4) follow.

## Modules

| Module | Layer | Depends on | Contents |
|---|---|---|---|
| `OpenCineStreaming` (Swift) | core | `OpenCineCore` | The engine, below |
| `OpenCineStreamingApple` (Swift) | core | `OpenCineStreaming`, `OpenCineCore`, Apple frameworks | The Apple shell, below |

`OpenCineStreaming` imports Foundation and Core only, opens no socket, runs no encoder and names
no manufacturer or app (`StreamingSourceRulesTests`). Service names appear only as preset content.
It is sans-I/O, like Gyro: bytes and values in, bytes and decisions out, on injected clocks.

## What the engine does

| File | Responsibility |
|---|---|
| `StreamDestination.swift` | Parses a pasted server address and key. `rtmps://` (port 443), or plain `rtmp://` (port 1935) only where the preset allows it (Custom); the key is trimmed, refused if it is a URL, and appears in no description or mirror |
| `AMF0.swift` | AMF0 values, encoding, and bounds-checked decoding with a nesting limit |
| `RTMPChunkStream.swift` | Message to chunk writer and incremental chunk to message reader, extended timestamps, Set Chunk Size and Abort |
| `StreamMediaPacket.swift` | The public media input (H.264 Annex-B, AAC) and the FLV tag bodies |
| `RTMPPublishSession.swift` | Simple handshake, `connect`, `releaseStream`, `FCPublish`, `createStream`, `publish`, ping and acknowledgement, media sending, close, failures with the key removed |
| `StreamSendQueue.swift` | Bounded send queue: drops whole video groups before audio, never configuration |
| `StreamPolicies.swift` | Bitrate steps on queue delay; reconnect backoff from 1 to 15 s inside a 2 minute window; refusals never retry |
| `StreamOutputFormat.swift` | The output rule (match the source, 720p from wireless feeds, 1080p only from a real 1080p source) and the connection routes that may stream |
| `StreamServicePreset.swift` | The one service table; facts and sources in [services.md](services.md) |
| `StreamRun.swift` | One stream from go-live to stop: connect, reconnect, bounded queue and in-flight bytes, bitrate, status. Media is dropped, not queued, while offline; the codec config is resent on each return |
| `StreamFramePacer.swift` | Picks each output frame's picture: newest wins, repeats when the source is slow, a slate after 2 s without pictures |

## The Apple shell (`OpenCineStreamingApple`)

| File | Responsibility |
|---|---|
| `StreamPublisher.swift` | Applies `StreamRun`'s actions: socket, encoders, frame clock at the output rate, wake timers; reports status |
| `StreamConnection.swift` | TLS on Network.framework (system trust, SNI), or plain TCP for an allowed `rtmp://` destination; the publisher picks from `StreamDestination.isEncrypted` |
| `H264StreamEncoder.swift` | VideoToolbox H.264 High, real time, no reordering, keyframe every 2 s, bitrate changes live |
| `AACStreamEncoder.swift` | AAC-LC 48 kHz stereo 160 kbps from any PCM input; times follow the sample count |
| `StreamPictureFitter.swift` | Any source into the fixed output frame: fit with black bars, or center crop for the vertical preset |
| `StreamKeyStore.swift` | Keys, and entered servers, per preset in the keychain; the service is a host value |
| `StreamMicrophone.swift` | iOS microphone at the input's format (iOS only, verified on device only) |

## The shared surfaces and their composition (iOS)

| File | Responsibility |
|---|---|
| `MonitorPresentation/LiveStreamPresentation.swift` | The values and every string: settings card, Go live control, status readout, notices, warnings, eligibility |
| `MonitorUI/LiveStream/LiveStreamSettingsCard.swift` | The Sharing tab card: service, server, masked key with paste, save and remove, quality, the monitor switch, why going live is blocked |
| `MonitorUI/LiveStream/LiveStreamMonitorControls.swift` | The Go live control with one confirmation to start and one to stop, the status readout, notice and warning, and the app-level Live pill |
| `OpenCineAppKitApple/LiveStreamCoordinator.swift` | One app's streaming: keys in the keychain, validation, go-live from the host's route and source, the clean picture tap and microphone, status from the run, background ends the stream |
| `OpenCineAppKitApple/LiveStreamMonitorOverlay.swift` | The overlay and settings section over the coordinator, and `liveStreamLifecycle` (background, heat, battery, the Live pill while no monitor overlay is on screen) |

An app gives a `LiveStreamHost`: its keychain service, its connection route as a
`StreamConnectionRoute` (Core's `RouteKind` maps with `StreamConnectionRoute(_:)`), its source
format, a closure that sets the clean picture tap on its live runtime, and `microphoneAccess`,
its own microphone permission path, asked only after the operator confirms (shared code never
raises the prompt; `LiveStreamHost.systemMicrophoneAccess` is the plain system request). It passes the
coordinator to `withLiveStream(_:)` on its settings configuration and as `liveStream` on its live
screen host, installs `liveStreamLifecycle` at its root, keeps the screen awake while
`isRunning`, and declares `NSMicrophoneUsageDescription`. No brand or app branch exists in
shared code: eligibility is the route value.

## What it does not do

- Open a socket, speak TLS, encode, capture audio or store keys. The platform shells do
  (part 2 Apple, part 3 Android).
- Plain `rtmp://` for a service preset. Only a Custom server may be plain `rtmp://`
  (`StreamServicePreset.allowsPlainRTMP`); the UI warns that the stream and key are unencrypted.
- Program switching and timecode alignment (part 4). Camera timecode behavior is still to be
  measured on hardware; see [timecode-measurements.md](timecode-measurements.md).

## Tests

- `swift test --filter OpenCineStreamingTests`: every suite, on manual values; no sockets, no sleeps.
- Golden bytes: `RTMPGoldenTests` decodes `Fixtures/rtmp-ffmpeg-publish.hex`, the bytes FFmpeg's
  RTMP sender puts on the wire after the handshake, and checks our AMF0 and FLV output against it.
  The Android tests (part 3) read the same fixture.
- Regenerate the fixture with FFmpeg on the path: `python3 scripts/streaming-rtmp-capture.py`.
  It proxies one second of an FFmpeg publish between an FFmpeg sender and receiver and fails if
  the fixture passes 64 KB.
- `swift test --filter OpenCineStreamingAppleTests`: encoders, fitter, key store, socket and publisher on
  the macOS host. The socket tests use a local listener; the rest run without network.
- Apple interop tier, off by default:
  `OPENCINE_FFMPEG_INTEROP=1 swift test --filter StreamAppleInteropTests`. Synthetic pictures and a tone
  go through the real fitter, VideoToolbox, the AAC encoder, the run controller and a plain local
  socket to FFmpeg, in real time; `ffprobe` checks H.264 High 1280x720, AAC 48 kHz stereo and
  timestamps that never go backward.
- FFmpeg interop tier, off by default:
  `OPENCINE_FFMPEG_INTEROP=1 swift test --filter RTMPInteropTests`. FFmpeg encodes H.264 and AAC
  and listens as the receiver; the session publishes to it over local TCP, and `ffprobe` checks
  the received file for codecs, size, duration and timestamps that never go backward, with and
  without a forced keyframe and resent parameter sets mid-stream. This tier is SIMULATED as far as
  the services go: it proves the wire format, not a real ingest.

## Key safety

The stream key is a secret. It goes on the wire only in `releaseStream`, `FCPublish`, `publish`
and `FCUnpublish`, never in `connect` or its `tcUrl`. Server text passes through one redaction,
which removes the key and its URL-encoded forms, before it reaches a `StreamFailure`.
