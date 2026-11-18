import Foundation

/// Something the session tells its host while bytes flow.
public enum StreamSessionEvent: Equatable, Sendable {
    /// The server accepted the stream; media now flows.
    case live
    /// The session ended. No more bytes go out.
    case failed(StreamFailure)
}

/// Why a session ended. Text in a failure never holds the stream key.
public enum StreamFailure: Error, Equatable, Sendable {
    /// The server refused the connection or the stream, for example a wrong key. Retrying the same
    /// settings cannot help, so the reconnect policy never retries this.
    case refused(reason: String)
    /// The server sent bytes that break the protocol.
    case protocolError
    /// The server or the connection ended the session.
    case closedByServer
}

/// The RTMP publish conversation, without I/O: bytes and values in, bytes and events out.
///
/// The host opens a TLS connection to `destination.host` and `destination.port`, writes the bytes
/// of `start()`, then passes every received byte to `receive(_:)` and writes `outbound`. Once the
/// session reports `.live`, encoded media goes through `send(_:)`. It runs the simple handshake,
/// then `connect`, `releaseStream`, `FCPublish`, `createStream` and `publish`.
public struct RTMPPublishSession: Sendable {
    public enum State: Equatable, Sendable {
        case idle, handshaking, connecting, publishing, live, closed
    }

    /// What one call to `receive(_:)` produced: bytes to write and events for the host.
    public struct Output: Equatable, Sendable {
        public var outbound: [UInt8]
        public var events: [StreamSessionEvent]

        public init(outbound: [UInt8] = [], events: [StreamSessionEvent] = []) {
            self.outbound = outbound
            self.events = events
        }
    }

    public private(set) var state: State = .idle

    private enum ChunkStream {
        static let control: UInt32 = 2
        static let command: UInt32 = 3
        static let audio: UInt32 = 4
        static let video: UInt32 = 6
    }

    private enum MessageType {
        static let setChunkSize: UInt8 = 1
        static let acknowledgement: UInt8 = 3
        static let userControl: UInt8 = 4
        static let windowAckSize: UInt8 = 5
        static let setPeerBandwidth: UInt8 = 6
        static let audio: UInt8 = 8
        static let video: UInt8 = 9
        static let commandAMF3: UInt8 = 17
        static let commandAMF0: UInt8 = 20
    }

    private static let handshakeSize = 1536
    private static let outboundChunkSize = 4096

    private let destination: StreamDestination
    private let random: @Sendable (Int) -> [UInt8]
    private var writer = RTMPChunkWriter()
    private var reader = RTMPChunkReader()
    private var handshake: [UInt8] = []
    private var sentC2 = false

    private var nextTransaction = 1.0
    private var pendingCommands: [Double: String] = [:]
    private var streamID: UInt32?

    private var bytesReceived: UInt32 = 0
    private var lastAcknowledged: UInt32 = 0
    private var serverWindow: UInt32?
    private var announcedWindow: UInt32?

    private var videoConfigSent = false
    private var keyframeSent = false
    private var audioConfigSent = false
    private var lastVideoMs: UInt32?
    private var lastAudioMs: UInt32?

    public init(destination: StreamDestination) {
        self.init(destination: destination, random: { count in
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        })
    }

    init(destination: StreamDestination, random: @escaping @Sendable (Int) -> [UInt8]) {
        self.destination = destination
        self.random = random
    }

    /// C0 and C1. Call once, right after the connection opens.
    public mutating func start() -> [UInt8] {
        guard state == .idle else { return [] }
        state = .handshaking
        return [0x03] + [0, 0, 0, 0] + [0, 0, 0, 0] + random(Self.handshakeSize - 8)
    }

    /// Takes bytes from the server, in pieces of any size.
    public mutating func receive(_ bytes: [UInt8]) -> Output {
        var output = Output()
        switch state {
        case .idle, .closed:
            return output
        case .handshaking:
            handshake += bytes
            guard handshake.count >= 1 + Self.handshakeSize else { return output }
            guard handshake[0] == 0x03 else {
                fail(.protocolError, into: &output)
                return output
            }
            if !sentC2 {
                sentC2 = true
                output.outbound += handshake[1...Self.handshakeSize]
            }
            guard handshake.count >= 1 + 2 * Self.handshakeSize else { return output }
            let rest = Array(handshake[(1 + 2 * Self.handshakeSize)...])
            handshake = []
            state = .connecting
            output.outbound += sendConnect()
            readMessages(rest, into: &output)
        case .connecting, .publishing, .live:
            readMessages(bytes, into: &output)
        }
        return output
    }

    /// Bytes for one media packet. Empty until live, for audio before its config, and for video
    /// before its config and first keyframe.
    public mutating func send(_ packet: StreamMediaPacket) -> [UInt8] {
        guard state == .live, let streamID else { return [] }
        switch packet {
        case .videoConfig(let sps, let pps):
            guard let payload = FLVPayload.videoConfig(sps: sps, pps: pps) else { return [] }
            videoConfigSent = true
            return media(MessageType.video, payload, at: lastVideoMs ?? 0, stream: streamID)
        case .video(let annexB, let isKeyframe, let decodeMs, let presentMs):
            guard videoConfigSent, keyframeSent || isKeyframe else { return [] }
            let decode = max(decodeMs, lastVideoMs ?? 0)
            let composition = Int32(clamping: max(-0x80_0000, min(0x7F_FFFF, Int64(presentMs) - Int64(decode))))
            guard let payload = FLVPayload.video(annexB: annexB, isKeyframe: isKeyframe, compositionMs: composition) else {
                return []
            }
            keyframeSent = true
            lastVideoMs = decode
            return media(MessageType.video, payload, at: decode, stream: streamID)
        case .audioConfig(let config):
            audioConfigSent = true
            return media(MessageType.audio, FLVPayload.audioConfig(config), at: lastAudioMs ?? 0, stream: streamID)
        case .audio(let raw, let presentMs):
            guard audioConfigSent else { return [] }
            let time = max(presentMs, lastAudioMs ?? 0)
            lastAudioMs = time
            return media(MessageType.audio, FLVPayload.audio(raw), at: time, stream: streamID)
        }
    }

    /// Ends the stream politely: `FCUnpublish` and `deleteStream` when a stream exists. The host
    /// writes these bytes, then closes the connection.
    public mutating func close() -> [UInt8] {
        guard state != .closed else { return [] }
        let wasPublishing = state == .live || state == .publishing
        state = .closed
        guard wasPublishing, let streamID else { return [] }
        return command("FCUnpublish", [.null, .string(destination.streamKey)])
            + command("deleteStream", [.null, .number(Double(streamID))])
    }

    // MARK: Reading

    private mutating func readMessages(_ bytes: [UInt8], into output: inout Output) {
        guard !bytes.isEmpty else { return }
        bytesReceived &+= UInt32(truncatingIfNeeded: bytes.count)
        let messages: [RTMPMessage]
        do {
            messages = try reader.push(bytes)
        } catch {
            fail(.protocolError, into: &output)
            return
        }
        for message in messages {
            guard state != .closed else { return }
            handle(message, into: &output)
        }
        if let window = serverWindow, state != .closed, bytesReceived &- lastAcknowledged >= window {
            lastAcknowledged = bytesReceived
            output.outbound += control(MessageType.acknowledgement, bigEndian(bytesReceived))
        }
    }

    private mutating func handle(_ message: RTMPMessage, into output: inout Output) {
        switch message.typeID {
        case MessageType.windowAckSize:
            if let size = Self.uint32(message.payload), size > 0 { serverWindow = size }
        case MessageType.setPeerBandwidth:
            if let size = Self.uint32(message.payload), size > 0, announcedWindow != size {
                announcedWindow = size
                output.outbound += control(MessageType.windowAckSize, bigEndian(size))
            }
        case MessageType.userControl:
            // A ping request (event 6) gets a ping response (event 7) with the same time.
            if message.payload.count >= 6, message.payload[0] == 0, message.payload[1] == 6 {
                output.outbound += control(MessageType.userControl, [0, 7] + message.payload[2..<6])
            }
        case MessageType.commandAMF0, MessageType.commandAMF3:
            let payload = message.typeID == MessageType.commandAMF3 ? Array(message.payload.dropFirst()) : message.payload
            guard let values = try? AMF0.decode(payload), case .string(let name)? = values.first else {
                fail(.protocolError, into: &output)
                return
            }
            handleCommand(name, values, into: &output)
        default:
            break
        }
    }

    private mutating func handleCommand(_ name: String, _ values: [AMF0Value], into output: inout Output) {
        let transaction: Double? = if values.count > 1, case .number(let id) = values[1] { id } else { nil }
        switch name {
        case "_result":
            guard let transaction, let method = pendingCommands.removeValue(forKey: transaction) else { return }
            switch method {
            case "connect":
                if let info = Self.info(values), let code = info.code, code != "NetConnection.Connect.Success" {
                    fail(.refused(reason: redacted(info.text)), into: &output)
                    return
                }
                state = .publishing
                output.outbound += command("releaseStream", [.null, .string(destination.streamKey)])
                pendingCommands.removeValue(forKey: nextTransaction - 1)
                output.outbound += command("FCPublish", [.null, .string(destination.streamKey)])
                pendingCommands.removeValue(forKey: nextTransaction - 1)
                output.outbound += command("createStream", [.null])
            case "createStream":
                guard values.count > 3, case .number(let id) = values[3], id >= 0, id <= Double(UInt32.max) else {
                    fail(.protocolError, into: &output)
                    return
                }
                let stream = UInt32(id)
                streamID = stream
                output.outbound += command("publish", [.null, .string(destination.streamKey), .string("live")], stream: stream)
            default:
                break
            }
        case "_error":
            guard let transaction, let method = pendingCommands.removeValue(forKey: transaction) else { return }
            let text = Self.info(values)?.text ?? "\(method) failed"
            fail(.refused(reason: redacted(text)), into: &output)
        case "onStatus":
            guard let info = Self.info(values), let code = info.code else { return }
            if code == "NetStream.Publish.Start" {
                guard state == .publishing else { return }
                state = .live
                output.events.append(.live)
            } else if code == "NetConnection.Connect.Closed" {
                fail(.closedByServer, into: &output)
            } else if info.level == "error" || code.hasSuffix(".BadName") || code.hasSuffix(".Rejected")
                || code.hasSuffix(".Failed")
            {
                fail(.refused(reason: redacted(info.text)), into: &output)
            }
        case "close":
            fail(.closedByServer, into: &output)
        default:
            break
        }
    }

    private mutating func fail(_ failure: StreamFailure, into output: inout Output) {
        state = .closed
        output.events.append(.failed(failure))
    }

    // MARK: Writing

    private mutating func sendConnect() -> [UInt8] {
        var out = control(MessageType.setChunkSize, bigEndian(UInt32(Self.outboundChunkSize)))
        writer.chunkSize = Self.outboundChunkSize
        out += command("connect", [
            .object([
                AMF0Property(name: "app", value: .string(destination.app)),
                AMF0Property(name: "type", value: .string("nonprivate")),
                AMF0Property(name: "flashVer", value: .string("FMLE/3.0 (compatible; OpenCine)")),
                AMF0Property(name: "tcUrl", value: .string(destination.tcURL)),
            ])
        ])
        return out
    }

    private mutating func command(_ name: String, _ arguments: [AMF0Value], stream: UInt32 = 0) -> [UInt8] {
        let transaction = nextTransaction
        nextTransaction += 1
        pendingCommands[transaction] = name
        let payload = AMF0.encode([.string(name), .number(transaction)] + arguments)
        return writer.encode(
            RTMPMessage(
                chunkStreamID: ChunkStream.command, typeID: MessageType.commandAMF0, messageStreamID: stream,
                timestamp: 0, payload: payload))
    }

    private mutating func control(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        writer.encode(
            RTMPMessage(chunkStreamID: ChunkStream.control, typeID: type, messageStreamID: 0, timestamp: 0, payload: payload))
    }

    private mutating func media(_ type: UInt8, _ payload: [UInt8], at time: UInt32, stream: UInt32) -> [UInt8] {
        let csid = type == MessageType.video ? ChunkStream.video : ChunkStream.audio
        return writer.encode(
            RTMPMessage(chunkStreamID: csid, typeID: type, messageStreamID: stream, timestamp: time, payload: payload))
    }

    // MARK: Values

    private struct StatusInfo {
        var level: String?
        var code: String?
        var description: String?
        var text: String { [code, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ") }
    }

    /// The information object of a reply or status: the first object after the transaction ID
    /// that names a code or level, or the last object.
    private static func info(_ values: [AMF0Value]) -> StatusInfo? {
        let objects: [[AMF0Property]] = values.dropFirst(2).compactMap {
            if case .object(let properties) = $0 { properties } else { nil }
        }
        guard let chosen = objects.last(where: { $0.contains { $0.name == "code" || $0.name == "level" } }) ?? objects.last
        else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let value)? = chosen.first(where: { $0.name == key })?.value { value } else { nil }
        }
        return StatusInfo(level: string("level"), code: string("code"), description: string("description"))
    }

    /// Server text with every form of the stream key removed, so it may reach a failure value.
    private func redacted(_ text: String) -> String {
        let key = destination.streamKey
        var forms: Set<String> = [key]
        for allowed in [CharacterSet.urlQueryAllowed, .urlPathAllowed, .alphanumerics] {
            if let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) {
                forms.insert(encoded)
                forms.insert(encoded.lowercased())
            }
        }
        var result = text
        for form in forms.sorted(by: { $0.count > $1.count }) where !form.isEmpty {
            result = result.replacingOccurrences(of: form, with: "[key]", options: .caseInsensitive)
        }
        return result
    }

    private static func uint32(_ bytes: [UInt8]) -> UInt32? {
        bytes.count >= 4 ? bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } : nil
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        out.appendBigEndian(value)
        return out
    }
}
