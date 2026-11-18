# Live streaming (RTMPS)

Going live from a camera app to Twitch, YouTube, Facebook, Instagram or any `rtmps://` server,
without OBS. This guide covers the portable engine (part 1 of the series). The design is
`docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`; the plans are
`docs/superpowers/plans/2026-11-05-rtmps-*.md`.

Status: implemented, automated checks passed. No app links this module yet. Nothing here has
streamed to a real service; that waits for the Apple and Android shells (parts 2 and 3).

## Modules

| Module | Layer | Depends on | Contents |
|---|---|---|---|
| `OpenCineStreaming` (Swift) | core | `OpenCineCore` | The engine, below |

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
