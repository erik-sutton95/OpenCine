# RTMPS Streaming, Part 1: Timecode Measurement and Portable Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure how real camera timecode behaves, and build the Foundation-and-Core Swift engine that turns encoded H.264 and AAC into a valid RTMP publish stream, proven against FFmpeg.

**Architecture:** `OpenCineStreaming` is a sans-I/O module in the `core` layer: it takes bytes and values in and gives bytes and decisions out, on injected clocks. It opens no socket, runs no encoder and has no UI. Later parts put a TLS socket and encoders under it on each platform. This is the same split as Gyro.

**Tech Stack:** Swift 6 (Swift Testing), SwiftPM, FFmpeg 8 as the reference sender and receiver (developer tool only, never linked).

**Spec:** `docs/superpowers/specs/2026-11-05-rtmps-streaming-design.md`

## The series

| Part | Delivers | Spec milestones |
| --- | --- | --- |
| **1 (this plan)** | Timecode measurement, portable engine | 1, 2 |
| 2 | Apple shell (TLS, encoders, audio, keychain), picture contract, shared SwiftUI, iOS adoption in all three apps | 3, 4 |
| 3 | Android shell, JNI facade (its tests run `Fixtures/rtmp-ffmpeg-publish.hex`, so the fixture is shared as the spec asks), shared Compose UI, Android adoption | 3, 4 |
| 4 | Program strip, hard cuts, **Line up cameras**, timecode aligner and grades | 5, 6 |
| 5 | Capture moved to shared code; Pocket and Insta cable route on Android and iPad | 7 |

Parts 2 to 5 are planned when the part before lands, because their interfaces depend on what it finds (Part 4 especially, on Task 1 here). Part 2 and Part 3 can run in parallel. The desktop shell (milestone 8) belongs to project 2's plan.

## Global Constraints

- Work only in a task-owned worktree on a feature branch from `main`. Stage files explicitly with `git add <path>`.
- Conventional Commits. No co-author trailers. Never the em dash character anywhere.
- Pushing, opening a PR and merging need the owner's explicit go-ahead.
- `Sources/OpenCineStreaming` imports only `Foundation` and `OpenCineCore`, and names no camera manufacturer or app. Service names may appear only as preset content.
- No third-party package. FFmpeg is used only by scripts and by a test tier that is off by default.
- No mutable global state: no `static var`, no `nonisolated(unsafe)`.
- Only `rtmps://` is accepted. Plain `rtmp://` is refused. The FFmpeg tier reaches the wire through an internal test seam, not through a public way to disable TLS.
- A stream key never appears in `description`, `debugDescription`, a `Mirror`, an error, a log or a failure message.
- Tests are deterministic: manual instants, no sleeps, no wall-clock budgets. Test behavior at the boundary, not private helpers.
- Output values from the spec: H.264 with a 2 second keyframe interval, AAC-LC stereo at 48 kHz and 160 kbps, about 3 Mbps at 720p and 6 Mbps at 1080p, reconnect for up to 2 minutes.

## Review Focus

1. **A key pasted with a trailing newline or spaces, or a whole URL pasted into the key field.** Whitespace is trimmed; a key containing `://` is refused with a clear error. Tests: `destinationTrimsPastedWhitespace`, `keyThatIsAURLIsRefused` (Task 2).
2. **A server error message that echoes the stream key.** The key is removed before the text reaches any failure value. Test: `failureTextNeverContainsKey` (Task 6).
3. **Garbage, truncated or hostile bytes from a server.** A thrown error or a failed session, never a crash or unbounded memory. Tests: `truncatedInputThrows` (Task 3), `oversizedMessageIsRejected` (Task 4), `garbageEndsSessionWithProtocolFailure` (Task 6).
4. **The network delivering bytes in arbitrary pieces, including one at a time.** The session still reaches live. Test: `reachesLiveWithOneByteDelivery` (Task 6).
5. **Timestamps that go backward, and long streams past 4.66 hours.** Output never goes backward and extended timestamps stay valid. Tests: `timestampsNeverGoBackward` (Task 6), `extendedTimestampRoundTrips` (Task 4).

## File Structure

| Path | Responsibility |
| --- | --- |
| `docs/streaming/timecode-measurements.md` | Task 1 results that Part 4 plans from |
| `docs/streaming/README.md` | Area guide |
| `Sources/OpenCineStreaming/StreamDestination.swift` | Server URL and key parsing, redaction |
| `Sources/OpenCineStreaming/AMF0.swift` | AMF0 values, encode, decode |
| `Sources/OpenCineStreaming/RTMPChunkStream.swift` | Message to chunk writer, chunk to message reader |
| `Sources/OpenCineStreaming/StreamMediaPacket.swift` | Public media input and FLV tag payloads |
| `Sources/OpenCineStreaming/RTMPPublishSession.swift` | Handshake, command sequence, media sending, failures |
| `Sources/OpenCineStreaming/StreamSendQueue.swift` | Bounded queue, drop policy |
| `Sources/OpenCineStreaming/StreamPolicies.swift` | Bitrate and reconnect policy |
| `Sources/OpenCineStreaming/StreamOutputFormat.swift` | Quality rule, connection route |
| `Sources/OpenCineStreaming/StreamServicePreset.swift` | The one service data table |
| `Tests/OpenCineStreamingTests/*.swift` | One suite per task |
| `Fixtures/rtmp-ffmpeg-publish.hex` | Recorded sender bytes from FFmpeg |
| `scripts/streaming-rtmp-capture.py` | Regenerates the fixture |

---

### Task 1: Measure camera timecode on real hardware

No product code. This needs the owner's hands and one of each brand, and it does not block Tasks 2 to 9.

**Method:** the screen recording of an app's monitor holds both the picture and the timecode readout in the same frame. Aim every camera at one screen showing a millisecond clock. Each recording then gives pairs of (clock shown in the picture, timecode shown in the readout), and `timecode minus clock` is that camera's offset against a shared reference. Recording one camera at a time is fine because the reference is absolute.

**Files:**

- Create: `docs/streaming/timecode-measurements.md`

**Interfaces:**

- Produces: for each brand, whether timecode advances while idle, whether it follows the camera clock, its offset, its drift over 30 minutes; for each cross-brand pairing, pass or fail. Part 4 reads this.

- [ ] **Step 1: Publish the clock and checklist page**

Publish one live hands-on page (the owner's rule for checklists: each item can be passed, skipped or noted, and the state is readable back). It shows a full-screen millisecond clock with a large readout, and these items for each of Nikon Z, Pocket and Luna:

1. Timecode mode noted as the camera reports it (free run, record run or time of day), and set to time of day if the camera offers it.
2. A 60 second screen recording of the monitor with the camera aimed at the clock and not recording. Readout visible.
3. App's clock setting done where it exists (Nikon: on connect, Luna: `LunaCameraSession.syncClock`; Pocket: note whether any exists), then a second 60 second recording.
4. After 30 minutes of running, a third 60 second recording.

- [ ] **Step 2: Owner runs the checklist**

Ping the owner, naming what is needed. Do not guess the results. A skipped item stays skipped in the results.

- [ ] **Step 3: Read the recordings**

For each recording, extract 20 frames with `ffmpeg -i <file> -vf fps=1/3 frame-%02d.png`, read the clock and the readout from each frame, and compute the offset's mean and spread. Luna's readout has whole seconds, so record that its offset is only known to about 1 second.

- [ ] **Step 4: Write `docs/streaming/timecode-measurements.md`**

One table per brand (mode, advances while idle, follows clock, offset before and after clock setting, offset after 30 minutes), then one table per cross-brand pairing. Spec pass rule: measured error under one frame at the output rate over the 30 minute run. Same-brand pairings are listed as not tested, since the test set has one of each brand. End with what this means for Part 4, in plain terms.

- [ ] **Step 5: Commit**

```bash
git add docs/streaming/timecode-measurements.md
git commit -m "docs(streaming): record camera timecode measurements"
```

---

### Task 2: `OpenCineStreaming` module and `StreamDestination`

**Files:**

- Create: `Sources/OpenCineStreaming/StreamDestination.swift`, `Tests/OpenCineStreamingTests/StreamDestinationTests.swift`, `Tests/OpenCineStreamingTests/StreamingSourceRulesTests.swift`
- Modify: `Package.swift` (product, `.target(name: "OpenCineStreaming", dependencies: ["OpenCineCore"])`, test target, a dependency-rules comment line near the Gyro one), `atlas/repos/opencine/meta.json` (`products` entry shaped like `OpenCineGyro`; `layers.core` gains `OpenCineStreaming`, `OpenCineStreamingTests`)

**Interfaces:**

- Produces:
- `public struct StreamDestination: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable`
- `public init(serverURL: String, streamKey: String) throws`
- `public let host: String`, `port: UInt16`, `app: String`, `tcURL: String`; `public let streamKey: String` (the only way to read it)
- `public enum StreamDestinationError: Error, Equatable, Sendable { case notRTMPS, invalidServerURL, emptyKey, keyLooksLikeURL }`
- `init(testOnlyPlainServerURL:streamKey:)` is `internal`, for Task 9's FFmpeg tier.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesServicePath() throws {
    let d = try StreamDestination(serverURL: "rtmps://live.example.com:443/rtmp/", streamKey: "abc")
    #expect(d.host == "live.example.com")
    #expect(d.port == 443)
    #expect(d.app == "rtmp")
    #expect(d.tcURL == "rtmps://live.example.com:443/rtmp")
}
@Test func defaultPortIs443() throws {
    #expect(try StreamDestination(serverURL: "rtmps://a.example.com/live2", streamKey: "k").port == 443)
}
@Test func plainRTMPIsRefused() {
    #expect(throws: StreamDestinationError.notRTMPS) {
        try StreamDestination(serverURL: "rtmp://a.example.com/live2", streamKey: "k")
    }
}
@Test func destinationTrimsPastedWhitespace() throws {
    let d = try StreamDestination(serverURL: " rtmps://a.example.com/app\n", streamKey: "  key-1?s=2&t=3 \n")
    #expect(d.streamKey == "key-1?s=2&t=3")
}
@Test func emptyKeyIsRefused() { /* "  \n" throws .emptyKey */ }
@Test func keyThatIsAURLIsRefused() { /* "rtmps://x/y" throws .keyLooksLikeURL */ }
@Test func keyIsInNoDescription() throws {
    let d = try StreamDestination(serverURL: "rtmps://a.example.com/app", streamKey: "SECRETKEY")
    for text in ["\(d)", String(reflecting: d), String(describing: Mirror(reflecting: d).children.map { "\($0)" })] {
        #expect(!text.contains("SECRETKEY"))
    }
}
```

`StreamingSourceRulesTests` follows `Tests/OpenCineGyroTests/GyroSourceRulesTests.swift`: imports limited to `Foundation` and `OpenCineCore`; no `static var` or `nonisolated(unsafe)`; none of `Nikon`, `DJI`, `Insta360`, `Luna`, `OpenZCine`, `OpenPocketCine`, `OpenInstaCine`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OpenCineStreamingTests 2>&1 | tail -20`
Expected: FAIL, no such module or missing type.

- [ ] **Step 3: Implement `StreamDestination`**

Parse by hand or with `URLComponents`. `app` is the path with its outer slashes removed, and may hold several segments. `customMirror` exposes only `host`, `port` and `app`. Do not conform to `Codable`: Parts 2 and 3 store the key in secure storage.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OpenCineStreamingTests 2>&1 | tail -5`
Expected: all pass.

Run: `python3 atlas/tools/atlas.py check`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add Package.swift atlas/repos/opencine/meta.json Sources/OpenCineStreaming Tests/OpenCineStreamingTests
git commit -m "feat(streaming): add the portable module and stream destination"
```

---

### Task 3: AMF0

**Files:**

- Create: `Sources/OpenCineStreaming/AMF0.swift`, `Tests/OpenCineStreamingTests/AMF0Tests.swift`

**Interfaces:**

- Produces (all `internal`):
- `enum AMF0Value: Equatable, Sendable { case number(Double), boolean(Bool), string(String), object([AMF0Property]), ecmaArray([AMF0Property]), null, undefined }`
- `struct AMF0Property: Equatable, Sendable { let name: String; let value: AMF0Value }`
- `enum AMF0 { static func encode(_ values: [AMF0Value]) -> [UInt8]; static func decode(_ bytes: [UInt8]) throws -> [AMF0Value] }`
- `enum AMF0Error: Error, Equatable { case truncated, unsupportedMarker(UInt8), nestedTooDeep }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func encodesCommandExactly() {
    #expect(AMF0.encode([.string("connect"), .number(1), .null]) ==
        [0x02, 0x00, 0x07] + Array("connect".utf8) +
        [0x00, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0] + [0x05])
}
@Test func objectEndsWithEndMarker() {
    #expect(AMF0.encode([.object([AMF0Property(name: "a", value: .boolean(true))])]) ==
        [0x03, 0x00, 0x01, 0x61, 0x01, 0x01, 0x00, 0x00, 0x09])
}
@Test func stringOver65535UsesLongMarker() {
    #expect(AMF0.encode([.string(String(repeating: "x", count: 70_000))]).first == 0x0C)
}
@Test func decodeRoundTripsEveryValue() throws { /* number, boolean, string, object, ecmaArray, null, undefined */ }
@Test(arguments: [[UInt8]([0x02, 0x00, 0x09, 0x61]), [0x00, 0x3F], [0x03, 0x00, 0x01]])
func truncatedInputThrows(bytes: [UInt8]) { #expect(throws: AMF0Error.truncated) { try AMF0.decode(bytes) } }
@Test func unknownMarkerThrows() { /* [0x7F] throws .unsupportedMarker(0x7F) */ }
@Test func deepNestingThrows() { /* 1000 nested object markers throws .nestedTooDeep, no stack overflow */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AMF0Tests 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Implement**

Big-endian doubles. Decoding uses a bounds-checked cursor and a nesting limit of 32. Decode also accepts the long string marker `0x0C`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AMF0Tests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineStreaming/AMF0.swift Tests/OpenCineStreamingTests/AMF0Tests.swift
git commit -m "feat(streaming): encode and decode AMF0"
```

---

### Task 4: RTMP chunk stream

**Files:**

- Create: `Sources/OpenCineStreaming/RTMPChunkStream.swift`, `Tests/OpenCineStreamingTests/RTMPChunkStreamTests.swift`

**Interfaces:**

- Produces (all `internal`):
- `struct RTMPMessage: Equatable, Sendable { var chunkStreamID: UInt32; var typeID: UInt8; var messageStreamID: UInt32; var timestamp: UInt32; var payload: [UInt8] }`
- `struct RTMPChunkWriter { var chunkSize: Int /* default 128 */; mutating func encode(_ message: RTMPMessage) -> [UInt8] }`
- `struct RTMPChunkReader { var chunkSize: Int; init(maxMessageBytes: Int = 16 * 1024 * 1024); mutating func push(_ bytes: [UInt8]) throws -> [RTMPMessage] }`
- `enum RTMPChunkError: Error, Equatable { case messageTooLarge, invalidChunkSize, missingPriorHeader }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func firstMessageIsType0HeaderExactly() {
    var w = RTMPChunkWriter()
    #expect(w.encode(RTMPMessage(chunkStreamID: 3, typeID: 20, messageStreamID: 0, timestamp: 1, payload: [0xAA])) ==
        [0x03, 0, 0, 1, 0, 0, 1, 20, 0, 0, 0, 0, 0xAA])
}
@Test func splitsAtChunkSizeWithType3Continuation() {
    var w = RTMPChunkWriter(); w.chunkSize = 2
    let out = w.encode(RTMPMessage(chunkStreamID: 3, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [1, 2, 3]))
    #expect(Array(out.suffix(4)) == [1, 2, 0xC3, 3])
}
@Test func roundTripsAcrossChunkSizes() throws { /* sizes 1, 128, 4096, message over several chunks, several csids interleaved */ }
@Test func extendedTimestampRoundTrips() throws {
    var w = RTMPChunkWriter(); w.chunkSize = 16
    var r = RTMPChunkReader(); r.chunkSize = 16
    let m = RTMPMessage(chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: 0x0100_0000,
        payload: Array(repeating: 7, count: 100))
    #expect(try r.push(w.encode(m)) == [m])
}
@Test func deltaHeaderRoundTrips() throws { /* second message on a csid uses a type 1 or 2 header */ }
@Test func backwardTimestampUsesAbsoluteHeader() throws { /* lower timestamp on the same csid round-trips */ }
@Test func readerHandlesTwoAndThreeByteChunkStreamIDs() throws { /* csid 64 and 320 */ }
@Test func oversizedMessageIsRejected() {
    var r = RTMPChunkReader(maxMessageBytes: 1024)
    #expect(throws: RTMPChunkError.messageTooLarge) {
        try r.push([0x03, 0, 0, 0, 0xFF, 0xFF, 0xFF, 8, 0, 0, 0, 0])
    }
}
@Test func type3WithoutPriorHeaderThrows() { /* [0xC3, 1] throws .missingPriorHeader */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RTMPChunkStreamTests 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Implement**

The writer repeats a four-byte extended timestamp on each type 3 continuation when the timestamp or delta needs one (FFmpeg and common servers expect this). The message stream ID in a type 0 header is little-endian; every other field is big-endian. The reader stays incremental: it keeps unconsumed bytes and per-chunk-stream state between `push` calls, and never holds more than `maxMessageBytes` per message.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter RTMPChunkStreamTests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineStreaming/RTMPChunkStream.swift Tests/OpenCineStreamingTests/RTMPChunkStreamTests.swift
git commit -m "feat(streaming): write and read the RTMP chunk stream"
```

---

### Task 5: Media packets and FLV payloads

**Files:**

- Create: `Sources/OpenCineStreaming/StreamMediaPacket.swift`, `Tests/OpenCineStreamingTests/StreamMediaPacketTests.swift`

**Interfaces:**

- Produces:
- `public enum StreamMediaPacket: Equatable, Sendable`, cases: `videoConfig(sps: [UInt8], pps: [UInt8])`, `video(annexB: [UInt8], isKeyframe: Bool, decodeMs: UInt32, presentMs: UInt32)`, `audioConfig(audioSpecificConfig: [UInt8])`, `audio(raw: [UInt8], presentMs: UInt32)`
- `enum FLVPayload` (`internal`): `static func videoConfig(sps:pps:) -> [UInt8]?`, `static func video(annexB:isKeyframe:compositionMs:) -> [UInt8]?`, `static func audioConfig(_:) -> [UInt8]`, `static func audio(_:) -> [UInt8]`. A `nil` means the input held nothing valid.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func avcConfigRecordIsExact() {
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
    let pps: [UInt8] = [0x68, 0xEE]
    #expect(FLVPayload.videoConfig(sps: sps, pps: pps) ==
        [0x17, 0x00, 0, 0, 0] + [0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05] + sps + [0x01, 0x00, 0x02] + pps)
}
@Test func convertsThreeAndFourByteStartCodesToLengthPrefix() {
    let annexB: [UInt8] = [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 1, 0x41, 0xBB]
    #expect(FLVPayload.video(annexB: annexB, isKeyframe: true, compositionMs: 33) ==
        [0x17, 0x01, 0x00, 0x00, 0x21] + [0, 0, 0, 2, 0x65, 0xAA] + [0, 0, 0, 2, 0x41, 0xBB])
}
@Test func interframeUsesFrameType2() { /* first byte 0x27 */ }
@Test func emptyAnnexBIsNil() { /* [] and a lone start code both give nil */ }
@Test func audioTagsAreExact() {
    #expect(FLVPayload.audioConfig([0x11, 0x90]) == [0xAF, 0x00, 0x11, 0x90])
    #expect(FLVPayload.audio([1, 2]) == [0xAF, 0x01, 1, 2])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter StreamMediaPacketTests 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Implement**

Video tag composition time is a signed 24-bit big-endian value, `presentMs - decodeMs`. SPS and PPS inside a keyframe's Annex-B are kept as they are.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter StreamMediaPacketTests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineStreaming/StreamMediaPacket.swift Tests/OpenCineStreamingTests/StreamMediaPacketTests.swift
git commit -m "feat(streaming): package H.264 and AAC for RTMP"
```

---

### Task 6: `RTMPPublishSession`

**Files:**

- Create: `Sources/OpenCineStreaming/RTMPPublishSession.swift`, `Tests/OpenCineStreamingTests/RTMPPublishSessionTests.swift`, `Tests/OpenCineStreamingTests/SimulatedRTMPServer.swift` (test support, labeled SIMULATED in its doc comment)

**Interfaces:**

- Consumes: `StreamDestination`, `AMF0`, `RTMPChunkWriter`, `RTMPChunkReader`, `FLVPayload`, `StreamMediaPacket`.
- Produces:
- `public struct RTMPPublishSession: Sendable`
- `public init(destination: StreamDestination)`, plus `internal init(destination:, random: @Sendable (Int) -> [UInt8])`
- `public enum State: Equatable, Sendable { case idle, handshaking, connecting, publishing, live, closed }`
- `public private(set) var state: State`
- `public mutating func start() -> [UInt8]` (C0 and C1)
- `public mutating func receive(_ bytes: [UInt8]) -> Output`
- `public struct Output: Equatable, Sendable { public var outbound: [UInt8]; public var events: [StreamSessionEvent] }`
- `public mutating func send(_ packet: StreamMediaPacket) -> [UInt8]`
- `public mutating func close() -> [UInt8]`
- `public enum StreamSessionEvent: Equatable, Sendable { case live, failed(StreamFailure) }`
- `public enum StreamFailure: Error, Equatable, Sendable { case refused(reason: String), protocolError, closedByServer }`. `refused` never triggers a reconnect (Task 7 relies on this).

- [ ] **Step 1: Write the failing tests**

`SimulatedRTMPServer` answers the handshake and replies to `connect`, `createStream` and `publish` with scripted `_result` and `onStatus` messages, and records every message it decodes.

```swift
@Test func reachesLiveAndSendsTheKeyOnlyInPublish() throws {
    let run = try SessionRun(key: "SECRETKEY")
    run.connectToLive()
    #expect(run.session.state == .live)
    #expect(run.server.commandNames == ["connect", "releaseStream", "FCPublish", "createStream", "publish"])
    #expect(run.server.command("publish")?.argument(1) == .string("SECRETKEY"))
    #expect(run.server.command("connect")?.objectValue("tcUrl") == .string("rtmps://live.example.com:443/app"))
}
@Test func reachesLiveWithOneByteDelivery() throws { /* server replies pushed one byte per receive call */ }
@Test func answersPingAndAcknowledgesWindow() throws { /* user control ping 6 gets pong 7; ack after the window size */ }
@Test func raisesItsChunkSizeBeforeConnect() throws { /* set chunk size 4096 appears before connect, and is honored */ }
@Test func honorsServerChunkSize() throws { /* a large reply after the server's set chunk size decodes */ }
@Test func badNameIsRefusedAndNamesNoKey() throws {
    /* onStatus NetStream.Publish.BadName gives .failed(.refused), state .closed */
}
@Test func failureTextNeverContainsKey() throws {
    /* description "bad key SECRETKEY" reaches the event as text without SECRETKEY */
}
@Test func garbageEndsSessionWithProtocolFailure() throws { /* random bytes after handshake gives .failed(.protocolError), no crash */ }
@Test func mediaBeforeLiveIsIgnored() throws { /* send returns [] */ }
@Test func videoWaitsForConfigAndAKeyframe() throws {
    /* interframes before videoConfig and first keyframe return []; after a config and keyframe they flow */
}
@Test func timestampsNeverGoBackward() throws {
    /* decodeMs 100 then 90: the server sees 100 then a value not below 100 */
}
@Test func closeSendsUnpublishAndDelete() throws { /* FCUnpublish then deleteStream; no key in deleteStream */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RTMPPublishSessionTests 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Implement**

Simple handshake: C0 is `0x03`; C1 is a 4 byte time, 4 zero bytes and 1528 random bytes; C2 echoes S1. Part 2 proves this against the real services.

Command sequence, in order: set chunk size 4096, `connect` (`app`, `type: "nonprivate"`, `flashVer: "FMLE/3.0 (compatible; OpenCine)"`, `tcUrl`), then on success `releaseStream`, `FCPublish`, `createStream`, then `publish(key, "live")` on the returned stream ID. Reach `live` on `NetStream.Publish.Start`.

Chunk stream IDs: 2 for protocol control, 3 for commands, 4 for audio, 6 for video. Clamp each track's timestamp to at least its previous value. Failure text passes through one private `redacted(_:)` that removes the key, and any URL-encoded form of it, before it reaches a `StreamFailure`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter RTMPPublishSessionTests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineStreaming/RTMPPublishSession.swift Tests/OpenCineStreamingTests/RTMPPublishSessionTests.swift Tests/OpenCineStreamingTests/SimulatedRTMPServer.swift
git commit -m "feat(streaming): run the RTMP publish session"
```

---

### Task 7: Send queue, bitrate and reconnect policy

**Files:**

- Create: `Sources/OpenCineStreaming/StreamSendQueue.swift`, `Sources/OpenCineStreaming/StreamPolicies.swift`, `Tests/OpenCineStreamingTests/StreamSendQueueTests.swift`, `Tests/OpenCineStreamingTests/StreamPoliciesTests.swift`

**Interfaces:**

- Consumes: `StreamMediaPacket`, `StreamFailure`, `MonotonicInstant` (Core).
- Produces:
- `public struct StreamSendQueue: Sendable`: `init(maxBytes: Int)`, `mutating func enqueue(_ packet: StreamMediaPacket)`, `mutating func next() -> StreamMediaPacket?`, `var queuedBytes: Int`, `private(set) var droppedVideoGroups: Int`, `private(set) var droppedAudioPackets: Int`
- `public struct StreamBitratePolicy: Sendable`: `init(targetBps: Int, floorBps: Int)`, `mutating func observe(queuedDuration: Duration, at: MonotonicInstant) -> Int` (the bitrate to use)
- `public struct StreamReconnectPolicy: Sendable`: `init(startedAt: MonotonicInstant)`, `mutating func decide(after failure: StreamFailure?, at: MonotonicInstant) -> Decision`, `mutating func wentLive()`, `enum Decision: Equatable { case retry(after: Duration), giveUp }`

- [ ] **Step 1: Write the failing tests**

```swift
// `bytes(_:)`, `annex(_:)`, `isAudio` and `isKeyframe` are small test helpers in this suite.
@Test func dropsOldestWholeVideoGroupBeforeAudio() {
    var q = StreamSendQueue(maxBytes: 2_000)
    q.enqueue(.audio(raw: bytes(100), presentMs: 0))
    q.enqueue(.video(annexB: annex(800), isKeyframe: true, decodeMs: 0, presentMs: 0))
    q.enqueue(.video(annexB: annex(800), isKeyframe: false, decodeMs: 33, presentMs: 33))
    q.enqueue(.video(annexB: annex(800), isKeyframe: true, decodeMs: 66, presentMs: 66))
    #expect(q.droppedVideoGroups == 1)
    #expect(q.droppedAudioPackets == 0)
    #expect(q.next()?.isAudio == true)
    #expect(q.next()?.isKeyframe == true) // the group starting at 66
}
@Test func configIsNeverDropped() { /* videoConfig and audioConfig survive overflow and come out first */ }
@Test func nextVideoOutAfterADropIsAKeyframe() { /* never an interframe without its group */ }
@Test func staysWithinMaxBytesWhenOnlyAudioIsQueued() { /* oldest audio drops, droppedAudioPackets rises */ }
@Test func bitrateStepsDownWhenQueueStaysBehindAndNeverBelowFloor() { /* over 1 s queued for several observations */ }
@Test func bitrateRecoversSlowlyAfterClearNetwork() { /* no rise until 10 s clear, then small steps, never above target */ }
@Test func reconnectBacksOffThenGivesUpAtTwoMinutes() {
    var p = StreamReconnectPolicy(startedAt: .zero)
    #expect(p.decide(after: .closedByServer, at: .zero + .seconds(1)) == .retry(after: .seconds(1)))
    #expect(p.decide(after: .closedByServer, at: .zero + .seconds(2)) == .retry(after: .seconds(2)))
    #expect(p.decide(after: .closedByServer, at: .zero + .seconds(121)) == .giveUp)
}
@Test func refusalNeverRetries() { /* .refused gives .giveUp at once */ }
@Test func goingLiveResetsTheWindow() { /* wentLive, then a new drop gets a fresh 2 minutes from that drop */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "StreamSendQueueTests|StreamPoliciesTests" 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Implement**

Backoff doubles from 1 second up to 15 seconds. The 2 minute window opens at the first failure since last live.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "StreamSendQueueTests|StreamPoliciesTests" 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenCineStreaming/StreamSendQueue.swift Sources/OpenCineStreaming/StreamPolicies.swift Tests/OpenCineStreamingTests/StreamSendQueueTests.swift Tests/OpenCineStreamingTests/StreamPoliciesTests.swift
git commit -m "feat(streaming): bound the send queue and add network policies"
```

---

### Task 8: Output format, connection route and service presets

**Files:**

- Create: `Sources/OpenCineStreaming/StreamOutputFormat.swift`, `Sources/OpenCineStreaming/StreamServicePreset.swift`, `Tests/OpenCineStreamingTests/StreamOutputFormatTests.swift`, `Tests/OpenCineStreamingTests/StreamServicePresetTests.swift`
- Create: `docs/streaming/services.md`

**Interfaces:**

- Consumes: `Rational` (Core), `StreamDestination`.
- Produces:
- `public struct StreamSourceFormat: Hashable, Sendable { width: Int, height: Int, frameRate: Rational? }`
- `public struct StreamOutputFormat: Hashable, Sendable { width, height: Int; frameRate: Rational; videoBitrateBps: Int; keyframeIntervalSeconds: Int; audioBitrateBps: Int; audioSampleRate: Int; audioChannels: Int }`
- `public extension StreamOutputFormat { static func resolve(selected: StreamSourceFormat, connected: [StreamSourceFormat], preset: StreamServicePreset) -> StreamOutputFormat }`
- `public enum StreamConnectionRoute: Hashable, Sendable { case usbCable, captureCard, sharedWiFi, deviceHotspot, cameraWiFi }`
- `public extension StreamConnectionRoute { static func canStream(_ route: StreamConnectionRoute?) -> Bool }`
- `public struct StreamServicePreset: Hashable, Sendable, Identifiable { id: String; displayName: String; serverURL: String?; requiresServerEntry: Bool; maxVideoBitrateBps: Int?; aspect: Aspect; keyHint: String; enum Aspect { case landscape16x9, portrait9x16 } }`
- `public extension StreamServicePreset { static let all: [StreamServicePreset]; static let custom: StreamServicePreset }`

- [ ] **Step 1: Write the failing tests**

```swift
private let p720 = StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(25, 1))
private let p1080 = StreamSourceFormat(width: 1920, height: 1080, frameRate: Rational(30, 1))
private let nikon = StreamSourceFormat(width: 1024, height: 768, frameRate: nil)

@Test func wirelessSourceStaysAt720() {
    let f = StreamOutputFormat.resolve(selected: p720, connected: [p720], preset: .custom)
    #expect(f.width == 1280 && f.height == 720)
    #expect(f.frameRate == Rational(25, 1))
    #expect(f.videoBitrateBps == 3_000_000)
    #expect(f.keyframeIntervalSeconds == 2)
    #expect(f.audioBitrateBps == 160_000 && f.audioSampleRate == 48_000 && f.audioChannels == 2)
}
@Test func captureSourceEarns1080() { /* 1920x1080, 6_000_000 */ }
@Test func aboveSourceIsNeverOffered() { /* 4K source caps at 1080p */ }
@Test func nikon4By3GivesA720Frame() { /* 1024x768 gives 1280x720 output, source shape kept by the shell */ }
@Test func bestConnectedSourceSetsSizeSelectedSetsRate() { /* selected p720, connected also p1080: 1920x1080 at 25 fps */ }
@Test func unknownFrameRateFallsBackTo30() { /* frameRate nil gives 30 */ }
@Test func presetCapsBitrate() { /* preset with maxVideoBitrateBps 2_000_000 lowers 3_000_000 to 2_000_000 */ }
@Test func portraitPresetSwapsToVertical() { /* Instagram from p720 gives 720x1280 */ }

@Test func routesThatMayStream() {
    #expect(StreamConnectionRoute.canStream(.usbCable))
    #expect(StreamConnectionRoute.canStream(.captureCard))
    #expect(StreamConnectionRoute.canStream(.sharedWiFi))
    #expect(StreamConnectionRoute.canStream(.deviceHotspot))
    #expect(!StreamConnectionRoute.canStream(.cameraWiFi))
    #expect(!StreamConnectionRoute.canStream(nil))
}

@Test func tableHoldsTheFourServices() {
    #expect(StreamServicePreset.all.map(\.id) == ["twitch", "youtube", "facebook", "instagram"])
}
@Test func everyFixedServerParsesAsRTMPS() throws {
    for p in StreamServicePreset.all { if let url = p.serverURL { _ = try StreamDestination(serverURL: url, streamKey: "k") } }
}
@Test func instagramAsksForServerAndIsVertical() {
    let p = StreamServicePreset.all.first { $0.id == "instagram" }!
    #expect(p.serverURL == nil && p.requiresServerEntry && p.aspect == .portrait9x16)
}
@Test func customAsksForServer() { /* serverURL nil, requiresServerEntry, landscape, no bitrate cap */ }
@Test func everyPresetHasAKeyHint() { /* keyHint non-empty for each, including custom */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "StreamOutputFormatTests|StreamServicePresetTests" 2>&1 | tail -20`
Expected: FAIL, missing types.

- [ ] **Step 3: Confirm each service's current requirements**

From each service's own documentation, record in `docs/streaming/services.md`, with the page link and today's date: server address, maximum bitrate, required codecs, keyframe interval, framing, and where the user finds a key. Starting points to confirm, not to trust:

- Twitch: `rtmps://ingest.global-contribute.live-video.net/app`, 6 Mbps
- YouTube: `rtmps://a.rtmps.youtube.com/live2`
- Facebook: `rtmps://live-api-s.facebook.com:443/rtmp/`
- Instagram: server issued with the key, vertical

If a service contradicts the spec's defaults, stop and tell the owner before implementing Step 4.

- [ ] **Step 4: Implement**

Sizes: best connected height of 1080 or more gives 1920x1080; 720 or more gives 1280x720; below that, the source's own height at 16:9, rounded to even, at 2 Mbps. `resolve` swaps width and height for `portrait9x16`. `keyHint` is one plain sentence each.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter "StreamOutputFormatTests|StreamServicePresetTests" 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenCineStreaming/StreamOutputFormat.swift Sources/OpenCineStreaming/StreamServicePreset.swift Tests/OpenCineStreamingTests/StreamOutputFormatTests.swift Tests/OpenCineStreamingTests/StreamServicePresetTests.swift docs/streaming/services.md
git commit -m "feat(streaming): add output format rules and service presets"
```

---

### Task 9: Prove it against FFmpeg, then land the module's docs

**Files:**

- Create: `scripts/streaming-rtmp-capture.py`, `Fixtures/rtmp-ffmpeg-publish.hex`, `Tests/OpenCineStreamingTests/RTMPGoldenTests.swift`, `Tests/OpenCineStreamingTests/RTMPInteropTests.swift`, `docs/streaming/README.md`, `atlas/api/swift/OpenCineStreaming.txt` (generated)
- Modify: `AGENTS.md` (a boundary bullet beside Gyro), `README.md` (area guide table row)

**Interfaces:**

- Consumes: everything above, and `StreamDestination.init(testOnlyPlainServerURL:streamKey:)`.
- Produces: the public engine that Parts 2 and 3 build on.

- [ ] **Step 1: Write the capture script and record the fixture**

`scripts/streaming-rtmp-capture.py` is a TCP proxy between `ffmpeg -listen 1 -f flv -i rtmp://127.0.0.1:<a>/live/fixturekey -c copy -f null -` and a sender running `ffmpeg -re -f lavfi -i testsrc=s=64x36:r=10:d=1 -f lavfi -i sine=d=1 -c:v libx264 -g 10 -c:a aac -f flv rtmp://127.0.0.1:<b>/live/fixturekey`. It writes the sender-to-receiver bytes after the handshake to `Fixtures/rtmp-ffmpeg-publish.hex`, and fails if that is over 64 KB. Standard library Python only, with a timeout on every wait.

Run: `python3 scripts/streaming-rtmp-capture.py`
Expected: `Fixtures/rtmp-ffmpeg-publish.hex` written, under 64 KB.

- [ ] **Step 2: Write the golden tests**

```swift
@Test func readerDecodesARealSender() throws {
    let messages = try Golden.messages()
    #expect(Golden.commandNames(messages).starts(with: ["connect", "releaseStream", "FCPublish", "createStream"]))
    #expect(Golden.commandNames(messages).contains("publish"))
    #expect(messages.contains { $0.typeID == 9 && $0.payload.starts(with: [0x17, 0x00]) })
    #expect(messages.contains { $0.typeID == 8 && $0.payload.starts(with: [0xAF, 0x00]) })
}
@Test func amfReencodesARealSenderExactly() throws {
    for m in try Golden.messages() where m.typeID == 20 {
        #expect(AMF0.encode(try AMF0.decode(m.payload)) == m.payload)
    }
}
```

- [ ] **Step 3: Run the golden tests and fix what they find**

Run: `swift test --filter RTMPGoldenTests 2>&1 | tail -20`
Expected: pass. A failure here is a real format bug: fix it in the owning source file and add a smaller test in that task's suite.

- [ ] **Step 4: Write the FFmpeg interop tier**

`RTMPInteropTests` runs only when `OPENCINE_FFMPEG_INTEROP=1` and `ffmpeg` is on the path, on macOS, using `.enabled(if:)`. It starts `ffmpeg -listen 1` as the receiver writing `out.flv` to a temp directory, generates H.264 and AAC with FFmpeg from `testsrc2` and `sine`, drives `RTMPPublishSession` over a plain TCP `NWConnection` to the receiver, closes it, and runs `ffprobe` on `out.flv`.

```swift
@Test(.enabled(if: Interop.available), .timeLimit(.minutes(1)))
func ffmpegReceivesAPlayableStream() async throws {
    let probe = try await Interop.publishThenProbe(seconds: 3, cuts: 0)
    #expect(probe.videoCodec == "h264")
    #expect(probe.audioCodec == "aac")
    #expect(probe.width == 1280 && probe.height == 720)
    #expect(probe.packetTimesNeverGoBackward)
}
@Test(.enabled(if: Interop.available), .timeLimit(.minutes(1)))
func reconfiguredVideoStaysPlayable() async throws {
    let probe = try await Interop.publishThenProbe(seconds: 3, cuts: 1) // a keyframe forced mid-stream
    #expect(probe.packetTimesNeverGoBackward)
    #expect(probe.videoDurationSeconds > 2.5)
}
```

- [ ] **Step 5: Run the interop tier and the module's whole suite**

Run: `OPENCINE_FFMPEG_INTEROP=1 swift test --filter RTMPInteropTests 2>&1 | tail -20`
Expected: 2 tests pass. If a run stalls, stop it and restart only that test.

Run: `swift test --filter OpenCineStreamingTests -Xswiftc -strict-concurrency=complete 2>&1 | tail -5`
Expected: all pass, no concurrency warnings. The interop tier reports as skipped.

- [ ] **Step 6: Write the docs and the API snapshot**

`docs/streaming/README.md` follows `docs/gyro/README.md`: modules, what the engine does and does not do, how to regenerate the fixture, how to run the interop tier, and "Status: implemented, automated checks passed. No app links this module yet." Add the boundary bullet to `AGENTS.md`: `OpenCineStreaming` imports Foundation and Core only, opens no socket, and names no manufacturer or app.

Run: `python3 atlas/tools/atlas.py api --write --build`
Expected: `atlas/api/swift/OpenCineStreaming.txt` created.

- [ ] **Step 7: Run the repo checks**

Run: `python3 atlas/tools/atlas.py check && python3 atlas/tools/atlas.py api --check --build && scripts/check-repository-hygiene.sh`
Expected: exit 0 each.

- [ ] **Step 8: Commit**

```bash
git add scripts/streaming-rtmp-capture.py Fixtures/rtmp-ffmpeg-publish.hex Tests/OpenCineStreamingTests/RTMPGoldenTests.swift Tests/OpenCineStreamingTests/RTMPInteropTests.swift docs/streaming/README.md atlas/api/swift/OpenCineStreaming.txt AGENTS.md README.md
git commit -m "test(streaming): prove the engine against FFmpeg and document it"
```
