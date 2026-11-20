import Foundation
import OpenCineCore
import OpenCineStreaming

/// Owner-keyed Android bridge over the portable `StreamRun`, so the Android shell runs the same
/// connect, reconnect, queue, bitrate and status logic as iOS.
///
/// Every run input returns one binary reply: the actions to apply, in order, then the status.
/// Big-endian; strings are UTF-8 with a 16-bit length:
///
/// - `1` connect: u16 port, string host
/// - `2` write: u32 count, bytes
/// - `3` disconnect
/// - `4` set video bitrate: i32 bits per second
/// - `5` request keyframe
/// - `6` wake: i64 nanoseconds on the caller's monotonic clock
/// - `127` status: u8 phase (0 connecting, 1 live, 2 reconnecting, 3 ended), i32 attempt,
///   u8 end (0 none, 1 stopped, 2 refused, 3 gave up), string reason, i64 live since (-1 none),
///   i32 sent bitrate, i32 video bitrate, i32 dropped video groups, i32 dropped audio packets,
///   u8 health (0 good, 1 congested, 2 offline)
///
/// An unknown owner answers with an ended, stopped status and nothing else. The stream key enters
/// only through `create` and leaves only inside the publish commands of a `write`.
public final class StreamRunWire: @unchecked Sendable {
    /// Process-local registry; every run call names its owner.
    public static let shared = StreamRunWire()

    private let lock = NSLock()
    private var runs: [String: StreamRun] = [:]

    public init() {}

    // MARK: Runs

    /// Parses the destination and format and allocates a run. JSON: `{"owner": id, "tls": bool}`,
    /// or `{"error": name}` with a `StreamDestinationError` case name or `invalidFormat`.
    public func create(serverURL: String, streamKey: String, formatJSON: String, nowNs: Int64) -> String {
        let destination: StreamDestination
        do {
            destination = try StreamDestination(serverURL: serverURL, streamKey: streamKey)
        } catch {
            return Self.json(["error": Self.name(of: error)])
        }
        guard let format = Self.decodeFormat(formatJSON) else { return Self.json(["error": "invalidFormat"]) }
        let owner = UUID().uuidString
        lock.withLock {
            runs[owner] = StreamRun(destination: destination, format: format, now: Self.instant(nowNs))
        }
        return Self.json(["owner": owner, "tls": Self.usesTLS(destination)])
    }

    public func start(owner: String) -> [UInt8] { update(owner) { $0.start() } }

    public func connected(owner: String, nowNs: Int64) -> [UInt8] {
        update(owner) { $0.connected(at: Self.instant(nowNs)) }
    }

    public func received(owner: String, bytes: [UInt8], nowNs: Int64) -> [UInt8] {
        update(owner) { $0.received(bytes, at: Self.instant(nowNs)) }
    }

    public func connectionLost(owner: String, nowNs: Int64) -> [UInt8] {
        update(owner) { $0.connectionLost(at: Self.instant(nowNs)) }
    }

    public func wrote(owner: String, count: Int, nowNs: Int64) -> [UInt8] {
        update(owner) { $0.wrote(count, at: Self.instant(nowNs)) }
    }

    public func tick(owner: String, nowNs: Int64) -> [UInt8] {
        update(owner) { $0.tick(at: Self.instant(nowNs)) }
    }

    public func stop(owner: String, nowNs: Int64) -> [UInt8] {
        update(owner) { $0.stop(at: Self.instant(nowNs)) }
    }

    public func publishVideoConfig(owner: String, sps: [UInt8], pps: [UInt8], nowNs: Int64) -> [UInt8] {
        publish(owner, .videoConfig(sps: sps, pps: pps), nowNs)
    }

    public func publishVideo(
        owner: String, annexB: [UInt8], isKeyframe: Bool, decodeMs: UInt32, presentMs: UInt32, nowNs: Int64
    ) -> [UInt8] {
        publish(owner, .video(annexB: annexB, isKeyframe: isKeyframe, decodeMs: decodeMs, presentMs: presentMs), nowNs)
    }

    public func publishAudioConfig(owner: String, audioSpecificConfig: [UInt8], nowNs: Int64) -> [UInt8] {
        publish(owner, .audioConfig(audioSpecificConfig: audioSpecificConfig), nowNs)
    }

    public func publishAudio(owner: String, raw: [UInt8], presentMs: UInt32, nowNs: Int64) -> [UInt8] {
        publish(owner, .audio(raw: raw, presentMs: presentMs), nowNs)
    }

    /// Retires the owner. Later calls naming it answer ended.
    public func close(owner: String) { _ = lock.withLock { runs.removeValue(forKey: owner) } }

    // MARK: Values for the settings page

    /// The presets a picker shows, then the custom server, as a JSON array.
    public func presetsJSON() -> String {
        let presets = (StreamServicePreset.all + [.custom]).map { preset -> [String: Any] in
            [
                "id": preset.id, "displayName": preset.displayName,
                "serverURL": preset.serverURL.map { $0 as Any } ?? NSNull(),
                "requiresServerEntry": preset.requiresServerEntry,
                "maxVideoBitrateBps": preset.maxVideoBitrateBps.map { $0 as Any } ?? NSNull(),
                "portrait": preset.aspect == .portrait9x16, "keyHint": preset.keyHint,
            ]
        }
        return Self.json(presets)
    }

    /// The output format for a go-live, as the JSON `create` takes. `fpsNum` or `fpsDen` 0 means
    /// the source does not state its rate. `connected` holds width and height pairs. `nil` for an
    /// unknown preset or a bad size.
    public func formatJSON(
        presetID: String, selectedWidth: Int, selectedHeight: Int, fpsNum: Int, fpsDen: Int, connected: [Int32]
    ) -> String? {
        guard let preset = (StreamServicePreset.all + [.custom]).first(where: { $0.id == presetID }),
            selectedWidth > 0, selectedHeight > 0, connected.count.isMultiple(of: 2)
        else { return nil }
        let rate = fpsNum > 0 && fpsDen > 0 ? Rational(fpsNum, fpsDen) : nil
        let others = stride(from: 0, to: connected.count, by: 2).map {
            StreamSourceFormat(width: Int(connected[$0]), height: Int(connected[$0 + 1]), frameRate: nil)
        }
        let format = StreamOutputFormat.resolve(
            selected: StreamSourceFormat(width: selectedWidth, height: selectedHeight, frameRate: rate),
            connected: others, preset: preset)
        return Self.encodeFormat(format)
    }

    /// Checks a server address and key without starting anything. JSON `{"ok": true, "tls": bool}`
    /// or `{"error": name}`.
    public func checkDestination(serverURL: String, streamKey: String) -> String {
        do {
            let destination = try StreamDestination(serverURL: serverURL, streamKey: streamKey)
            return Self.json(["ok": true, "tls": Self.usesTLS(destination)])
        } catch {
            return Self.json(["error": Self.name(of: error)])
        }
    }

    /// Whether a stream may start on the route named by a `StreamConnectionRoute` case name.
    public func canStream(route: String) -> Bool {
        let routes: [String: StreamConnectionRoute] = [
            "usbCable": .usbCable, "captureCard": .captureCard, "sharedWiFi": .sharedWiFi,
            "deviceHotspot": .deviceHotspot, "cameraWiFi": .cameraWiFi,
        ]
        return StreamConnectionRoute.canStream(routes[route])
    }

    // MARK: Encoding

    static func encode(_ actions: [StreamRun.Action], status: StreamRun.Status) -> [UInt8] {
        encode(actions, status: WireStatus(status))
    }

    private static func encode(_ actions: [StreamRun.Action], status: WireStatus) -> [UInt8] {
        var out: [UInt8] = []
        for action in actions {
            switch action {
            case .connect(let host, let port):
                out.append(1)
                out.appendBigEndian(port)
                out.appendString(host)
            case .write(let bytes):
                out.append(2)
                out.appendBigEndian(UInt32(bytes.count))
                out += bytes
            case .disconnect:
                out.append(3)
            case .setVideoBitrate(let bps):
                out.append(4)
                out.appendBigEndian(UInt32(bitPattern: Int32(clamping: bps)))
            case .requestKeyframe:
                out.append(5)
            case .wake(let instant):
                out.append(6)
                out.appendBigEndian(UInt64(bitPattern: nanoseconds(instant)))
            }
        }
        out.append(127)
        out.append(status.phase)
        out.appendBigEndian(UInt32(bitPattern: Int32(clamping: status.attempt)))
        out.append(status.end)
        out.appendString(status.reason)
        out.appendBigEndian(UInt64(bitPattern: status.liveSinceNs))
        for value in status.counters {
            out.appendBigEndian(UInt32(bitPattern: Int32(clamping: value)))
        }
        out.append(status.health)
        return out
    }

    /// The status record's fields.
    private struct WireStatus {
        var phase: UInt8 = 3
        var attempt = 0
        var end: UInt8 = 1
        var reason = ""
        var liveSinceNs: Int64 = -1
        /// Sent bitrate, video bitrate, dropped video groups, dropped audio packets.
        var counters = [0, 0, 0, 0]
        var health: UInt8 = 2

        /// Ended, stopped: what an unknown owner answers.
        init() {}

        init(_ status: StreamRun.Status) {
            end = 0
            switch status.phase {
            case .connecting: phase = 0
            case .live: phase = 1
            case .reconnecting(let count):
                phase = 2
                attempt = count
            case .ended(let ending):
                phase = 3
                switch ending {
                case .stopped: end = 1
                case .refused(let text):
                    end = 2
                    reason = text
                case .gaveUp: end = 3
                }
            }
            liveSinceNs = status.liveSince.map(StreamRunWire.nanoseconds) ?? -1
            counters = [
                status.sentBitrateBps, status.videoBitrateBps, status.droppedVideoGroups,
                status.droppedAudioPackets,
            ]
            switch status.health {
            case .good: health = 0
            case .congested: health = 1
            case .offline: health = 2
            }
        }
    }

    private func update(_ owner: String, _ body: (inout StreamRun) -> [StreamRun.Action]) -> [UInt8] {
        lock.withLock {
            guard var run = runs[owner] else { return Self.encode([], status: WireStatus()) }
            let actions = body(&run)
            runs[owner] = run
            return Self.encode(actions, status: run.status)
        }
    }

    private func publish(_ owner: String, _ packet: StreamMediaPacket, _ nowNs: Int64) -> [UInt8] {
        update(owner) { $0.publish(packet, at: Self.instant(nowNs)) }
    }

    private static func instant(_ nanoseconds: Int64) -> MonotonicInstant {
        MonotonicInstant(.nanoseconds(nanoseconds))
    }

    fileprivate static func nanoseconds(_ instant: MonotonicInstant) -> Int64 {
        let (seconds, attoseconds) = instant.sinceReference.components
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }

    private static func usesTLS(_ destination: StreamDestination) -> Bool {
        destination.tcURL.lowercased().hasPrefix("rtmps://")
    }

    /// The error's case name, never its payload (a destination error carries none today).
    private static func name(of error: Error) -> String {
        guard let error = error as? StreamDestinationError else { return "invalidServerURL" }
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" })
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeFormat(_ format: StreamOutputFormat) -> String {
        json([
            "width": format.width, "height": format.height, "fpsNum": format.frameRate.numerator,
            "fpsDen": format.frameRate.denominator, "videoBitrateBps": format.videoBitrateBps,
            "keyframeIntervalSeconds": format.keyframeIntervalSeconds, "audioBitrateBps": format.audioBitrateBps,
            "audioSampleRate": format.audioSampleRate, "audioChannels": format.audioChannels,
        ])
    }

    private static func decodeFormat(_ text: String) -> StreamOutputFormat? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        guard let width = int("width"), let height = int("height"), let fpsNum = int("fpsNum"),
            let fpsDen = int("fpsDen"), let video = int("videoBitrateBps"),
            let keyframe = int("keyframeIntervalSeconds"), let audio = int("audioBitrateBps"),
            let rate = int("audioSampleRate"), let channels = int("audioChannels"),
            width > 0, height > 0, fpsNum > 0, fpsDen > 0, video > 0, keyframe > 0, audio > 0, rate > 0,
            channels > 0
        else { return nil }
        return StreamOutputFormat(
            width: width, height: height, frameRate: Rational(fpsNum, fpsDen), videoBitrateBps: video,
            keyframeIntervalSeconds: keyframe, audioBitrateBps: audio, audioSampleRate: rate,
            audioChannels: channels)
    }
}

extension [UInt8] {
    fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendString(_ text: String) {
        let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
        appendBigEndian(UInt16(bytes.count))
        self += bytes
    }
}
