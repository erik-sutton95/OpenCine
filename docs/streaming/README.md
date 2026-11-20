# Live streaming (RTMPS)

Going live from a camera app to Twitch, YouTube, Facebook, Instagram or any `rtmps://` server,
without OBS. This guide covers the portable engine (part 1 of the series) and the Apple shell
(part 2, Tasks 1 to 7). The design is
`docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`; the plans are
`docs/superpowers/plans/2026-11-05-rtmps-*.md`.

Status: implemented, automated checks passed. No app links these modules yet. Nothing here has
streamed to a real service: the Apple shell has streamed only to a local FFmpeg receiver. The
clean-picture tap, shared UI and app adoption (part 2, Tasks 8 to 11) and Android (part 3) follow.

## Modules

| Module | Layer | Depends on | Contents |
|---|---|---|---|
| `OpenCineStreaming` (Swift) | core | `OpenCineCore` | The engine, below |
| `OpenCineStreamingApple` (Swift) | core | `OpenCineStreaming`, `OpenCineCore`, Apple frameworks | The Apple shell, below |
| `OpenCineStreamingAndroid` (Swift) | vendor | `OpenCineStreaming`, `OpenCineCore`, `OpenCineJNISupport` | The run controller over JNI, below |
| `:streaming` (Android) | core | `:platform`, Android framework | The Android shell, below |

`OpenCineStreaming` imports Foundation and Core only, opens no socket, runs no encoder and names
no manufacturer or app (`StreamingSourceRulesTests`). Service names appear only as preset content.
It is sans-I/O, like Gyro: bytes and values in, bytes and decisions out, on injected clocks.

## What the engine does

| File | Responsibility |
|---|---|
| `StreamDestination.swift` | Parses a pasted server address and key. Only `rtmps://`; the key is trimmed, refused if it is a URL, and appears in no description or mirror |
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
| `StreamConnection.swift` | TLS on Network.framework (system trust, SNI); plain TCP only through the internal interop seam |
| `H264StreamEncoder.swift` | VideoToolbox H.264 High, real time, no reordering, keyframe every 2 s, bitrate changes live |
| `AACStreamEncoder.swift` | AAC-LC 48 kHz stereo 160 kbps from any PCM input; times follow the sample count |
| `StreamPictureFitter.swift` | Any source into the fixed output frame: fit with black bars, or center crop for the vertical preset |
| `StreamKeyStore.swift` | Keys, and entered servers, per preset in the keychain; the service is a host value |
| `StreamMicrophone.swift` | iOS microphone at the input's format (iOS only, verified on device only) |

## The Android shell (part 3)

The run logic is not written twice: `OpenCineStreamingAndroid` keeps `StreamRun`s in an
owner-keyed registry (`StreamRunWire`) and exports them as the Kotlin class
`com.opencapture.opencine.streaming.StreamingNative`. Each run call returns one binary reply, the
actions in order and then the status (format in `StreamRunWire.swift`), so media bytes never pass
through JSON. Presets, the output format and the destination check cross as JSON. An app links the
target into its own Swift Android library and calls `StreamingNative.load` with that library.

| File (`Android/streaming`) | Responsibility |
|---|---|
| `StreamingNative.kt` | The JNI facade and `StreamingNativeApi` (`FakeStreamingNative` in test fixtures) |
| `StreamRunReply.kt` | Decodes a reply into `StreamAction`s and `StreamStatus`; a damaged reply reads as ended |
| `StreamCatalog.kt` | Presets, the output format, the destination check (encrypted or not) and the routes that may stream |
| `StreamConnection.kt` | TCP with TLS for `rtmps://` (system trust, SNI, host name check); plain only when the engine accepted `rtmp://`. Close flushes queued writes first |
| `H264StreamEncoder.kt` | MediaCodec H.264 with surface input: High when offered, no B-frames, keyframe every 2 s, CBR when supported, live bitrate and keyframe requests |
| `AacStreamEncoder.kt` | MediaCodec AAC-LC; times follow the sample count |
| `StreamEncodedMedia.kt` | Splits the codec config into SPS and PPS, finds IDR slices, maps times |
| `StreamPictureSource.kt` | The surface source contract and `StreamFramePacer` (Kotlin twin of the Swift pacer) |
| `StreamPublisher.kt` | Applies the replies: socket, encoders, frame clock, wakes; status as a `StateFlow` |
| `StreamKeyStore.kt` | Keys and entered servers per preset, sealed by `KeystoreSeal`; a lost device key reads as unavailable |
| `StreamMicrophone.kt` | `AudioRecord` at 48 kHz stereo (device only) |
| `StreamDeviceWarnings.kt` | Heat and low battery warnings; never stops a stream |

Pictures never cross JNI or enter this module as pixels: the native runtime's clean-picture tap
(`MonitorCleanPictureTap`, see `docs/native-runtime/README.md`) renders into the encoder's input
surface, and app composition adapts it to `StreamPictureSource`.

Tests: `swift test --filter OpenCineStreamingAndroidTests` (the wire and the export names) and
`cd Android && ./gradlew :streaming:testDebugUnitTest` (replies, catalog, a local socket, encoded
media helpers, keys, warnings and the publisher on a manual scheduler with `FakeStreamingNative`).
The MediaCodec encoders, the microphone and TLS to a real service run on a device only.

## What it does not do

- Open a socket, speak TLS, encode, capture audio or store keys. The platform shells do
  (part 2 Apple, part 3 Android).
- Plain `rtmp://`. The FFmpeg tier reaches a local plain receiver through an internal test seam,
  `StreamDestination(testOnlyPlainServerURL:streamKey:)`; there is no public way to disable TLS.
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
