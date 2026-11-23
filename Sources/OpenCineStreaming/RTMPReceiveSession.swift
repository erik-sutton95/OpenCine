import Foundation

// The server side of RTMP, so a camera that publishes its own stream can publish to this device.
// Portable: bytes in, bytes and events out, no socket. Platform shells add the listener and decoders.

/// The video codec of a received stream.
public enum RTMPReceivedCodec: String, Equatable, Sendable {
    case avc
    case hevc
}

/// One coded video frame as it arrived: length-prefixed NAL units (the decoder configuration
/// record states the prefix size).
public struct RTMPReceivedVideoFrame: Equatable, Sendable {
    public var codec: RTMPReceivedCodec
    public var keyframe: Bool
    /// The message timestamp, milliseconds.
    public var decodeMs: UInt32
    /// Presentation minus decode time, milliseconds.
    public var compositionMs: Int32
    public var data: [UInt8]
}

/// Why a receive session closed.
public enum RTMPReceiveFailure: Equatable, Sendable {
    /// Not plain RTMP version 3 (an RTMPS or RTMPE client).
    case handshakeVersion(UInt8)
    /// The chunk stream could not be read.
    case chunkStream(String)
    /// The publisher asked to publish under a key other than the session's token.
    case unexpectedStreamKey
}

/// What a publisher did, in order. No event carries the stream key.
public enum RTMPReceiveEvent: Equatable, Sendable {
    case handshakeDone
    case connect(app: String)
    /// The publisher started publishing under the expected key.
    case publish(type: String?)
    /// Any other command, by name (for the log).
    case command(String)
    case metadata([String: String])
    /// An AVCDecoderConfigurationRecord or HEVCDecoderConfigurationRecord. `enhanced` is true for
    /// the Enhanced RTMP FourCC form.
    case videoConfig(codec: RTMPReceivedCodec, record: [UInt8], enhanced: Bool)
    case videoFrame(RTMPReceivedVideoFrame)
    case videoEnd
    /// The AAC AudioSpecificConfig.
    case audioConfig([UInt8])
    case audioFrame(timestampMs: UInt32, bytes: [UInt8])
    /// Something this receiver does not take, reported once per kind.
    case unsupported(String)
    /// The publisher ended the stream (FCUnpublish, deleteStream or closeStream).
    case unpublished(String)
    case failed(RTMPReceiveFailure)
}

/// The server half of one RTMP connection: the simple handshake, the connect, createStream and
/// publish replies, acknowledgements, and the FLV audio and video tags of AVC, legacy and
/// Enhanced RTMP HEVC, and AAC. Only a publisher using `expectedStreamKey` is accepted; any other
/// key closes the session.
public struct RTMPReceiveSession: Sendable {
    public enum State: Equatable, Sendable { case waitingC0C1, waitingC2, connected, closed }

    public struct Output: Equatable, Sendable {
        public var outbound: [UInt8] = []
        public var events: [RTMPReceiveEvent] = []
        public init() {}
    }

    public private(set) var state: State = .waitingC0C1

    private static let handshakeSize = 1536
    private static let window: UInt32 = 2_500_000
    private static let outboundChunkSize = 4096

    private var buffer: [UInt8] = []
    private var reader = RTMPChunkReader()
    private var writer = RTMPChunkWriter()
    private var bytesReceived: UInt32 = 0
    private var lastAcknowledged: UInt32 = 0
    private var peerWindow: UInt32?
    private var reported: Set<String> = []
    private let random: @Sendable (Int) -> [UInt8]
    private let expectedStreamKey: String
    /// The peer published under the expected key; media and data before that are dropped.
    private var published = false

    public init(expectedStreamKey: String) {
        self.init(expectedStreamKey: expectedStreamKey, random: { count in
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        })
    }

    init(expectedStreamKey: String, random: @escaping @Sendable (Int) -> [UInt8]) {
        self.expectedStreamKey = expectedStreamKey
        self.random = random
    }

    /// Takes bytes from the publisher, in pieces of any size.
    public mutating func receive(_ bytes: [UInt8]) -> Output {
        var output = Output()
        switch state {
        case .closed:
            return output
        case .waitingC0C1:
            buffer += bytes
            guard buffer.count >= 1 + Self.handshakeSize else { return output }
            guard buffer[0] == 0x03 else {
                state = .closed
                output.events.append(.failed(.handshakeVersion(buffer[0])))
                return output
            }
            let c1 = Array(buffer[1...Self.handshakeSize])
            // S0, S1 (time, zero, random), S2 (the publisher's C1 echoed).
            output.outbound = [0x03] + [0, 0, 0, 0] + [0, 0, 0, 0] + random(Self.handshakeSize - 8) + c1
            buffer.removeFirst(1 + Self.handshakeSize)
            state = .waitingC2
            if !buffer.isEmpty {
                let rest = buffer
                buffer = []
                let more = receive(rest)
                output.outbound += more.outbound
                output.events += more.events
            }
        case .waitingC2:
            buffer += bytes
            guard buffer.count >= Self.handshakeSize else { return output }
            let rest = Array(buffer[Self.handshakeSize...])
            buffer = []
            state = .connected
            output.events.append(.handshakeDone)
            readMessages(rest, into: &output)
        case .connected:
            readMessages(bytes, into: &output)
        }
        return output
    }

    // MARK: Messages

    private mutating func readMessages(_ bytes: [UInt8], into output: inout Output) {
        guard !bytes.isEmpty else { return }
        bytesReceived &+= UInt32(truncatingIfNeeded: bytes.count)
        let messages: [RTMPMessage]
        do {
            messages = try reader.push(bytes)
        } catch {
            state = .closed
            output.events.append(.failed(.chunkStream("\(error)")))
            return
        }
        for message in messages {
            guard state != .closed else { return }
            handle(message, into: &output)
        }
        if let window = peerWindow, state != .closed, bytesReceived &- lastAcknowledged >= window {
            lastAcknowledged = bytesReceived
            output.outbound += control(3, bigEndian(bytesReceived))
        }
    }

    private mutating func handle(_ message: RTMPMessage, into output: inout Output) {
        if !published, [8, 9, 15, 18].contains(message.typeID) {
            return report("media before publish", into: &output)
        }
        switch message.typeID {
        case 1, 2, 3, 6:
            break  // chunk size and abort are the reader's; acks and bandwidth need nothing
        case 5:
            if message.payload.count >= 4 {
                let size = message.payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if size > 0 { peerWindow = size }
            }
        case 4:
            if message.payload.count >= 6, message.payload[0] == 0, message.payload[1] == 6 {
                output.outbound += control(4, [0, 7] + message.payload[2..<6])
            }
        case 20, 17:
            let payload = message.typeID == 17 ? Array(message.payload.dropFirst()) : message.payload
            guard let values = try? AMF0.decode(payload), case .string(let name)? = values.first else {
                report("undecodable command", into: &output)
                return
            }
            command(name, values, stream: message.messageStreamID, into: &output)
        case 18, 15:
            let payload = message.typeID == 15 ? Array(message.payload.dropFirst()) : message.payload
            guard let values = try? AMF0.decode(payload) else {
                report("undecodable data message", into: &output)
                return
            }
            if let metadata = Self.metadata(values) { output.events.append(.metadata(metadata)) }
        case 9:
            video(message.payload, at: message.timestamp, into: &output)
        case 8:
            audio(message.payload, at: message.timestamp, into: &output)
        default:
            report("message type \(message.typeID)", into: &output)
        }
    }

    private mutating func command(
        _ name: String, _ values: [AMF0Value], stream: UInt32, into output: inout Output
    ) {
        let transaction: Double = if values.count > 1, case .number(let id) = values[1] { id } else { 0 }
        switch name {
        case "connect":
            var app = ""
            var encoding = 0.0
            if values.count > 2, case .object(let properties) = values[2] {
                for property in properties {
                    switch (property.name, property.value) {
                    case ("app", .string(let value)): app = value
                    case ("objectEncoding", .number(let value)): encoding = value
                    default: break
                    }
                }
            }
            output.events.append(.connect(app: app))
            output.outbound += control(5, bigEndian(Self.window))
            output.outbound += control(6, bigEndian(Self.window) + [2])
            output.outbound += control(1, bigEndian(UInt32(Self.outboundChunkSize)))
            writer.chunkSize = Self.outboundChunkSize
            output.outbound += reply(
                "_result", transaction,
                [
                    .object([
                        AMF0Property(name: "fmsVer", value: .string("FMS/3,0,1,123")),
                        AMF0Property(name: "capabilities", value: .number(31)),
                    ]),
                    .object([
                        AMF0Property(name: "level", value: .string("status")),
                        AMF0Property(name: "code", value: .string("NetConnection.Connect.Success")),
                        AMF0Property(name: "description", value: .string("Connection succeeded.")),
                        AMF0Property(name: "objectEncoding", value: .number(encoding)),
                    ]),
                ])
        case "createStream":
            output.events.append(.command(name))
            output.outbound += reply("_result", transaction, [.null, .number(1)])
        case "publish":
            let key: String = if values.count > 3, case .string(let value) = values[3] { value } else { "" }
            let type: String? = if values.count > 4, case .string(let value) = values[4] { value } else { nil }
            guard !expectedStreamKey.isEmpty, key == expectedStreamKey else {
                state = .closed
                output.events.append(.failed(.unexpectedStreamKey))
                return
            }
            published = true
            output.events.append(.publish(type: type))
            let id = stream == 0 ? 1 : stream
            output.outbound += control(4, [0, 0] + bigEndian(id))
            output.outbound += reply(
                "onStatus", 0,
                [
                    .null,
                    .object([
                        AMF0Property(name: "level", value: .string("status")),
                        AMF0Property(name: "code", value: .string("NetStream.Publish.Start")),
                        AMF0Property(name: "description", value: .string("Publishing.")),
                    ]),
                ], stream: id, chunkStream: 5)
        case "FCPublish":
            output.events.append(.command(name))
            output.outbound += reply(
                "onFCPublish", 0,
                [
                    .null,
                    .object([AMF0Property(name: "code", value: .string("NetStream.Publish.Start"))]),
                ])
            if transaction > 0 { output.outbound += reply("_result", transaction, [.null]) }
        case "FCUnpublish", "deleteStream", "closeStream":
            output.events.append(.unpublished(name))
            if transaction > 0 { output.outbound += reply("_result", transaction, [.null]) }
        default:
            output.events.append(.command(name))
            if transaction > 0 { output.outbound += reply("_result", transaction, [.null]) }
        }
    }

    // MARK: Media

    private mutating func video(_ payload: [UInt8], at time: UInt32, into output: inout Output) {
        guard let first = payload.first else { return }
        if first & 0x80 != 0 {
            // Enhanced RTMP: [isExHeader:1][frameType:3][packetType:4][FourCC:4] ...
            let packetType = first & 0x0F
            let frameType = (first >> 4) & 0x07
            guard payload.count >= 5 else { return report("short enhanced video tag", into: &output) }
            let fourCC = String(decoding: payload[1..<5], as: UTF8.self)
            let codec: RTMPReceivedCodec
            switch fourCC {
            case "hvc1": codec = .hevc
            case "avc1": codec = .avc
            default: return report("enhanced video FourCC \(fourCC)", into: &output)
            }
            guard frameType != 5 else { return }  // command frame, no picture
            let body = Array(payload[5...])
            switch packetType {
            case 0:
                output.events.append(.videoConfig(codec: codec, record: body, enhanced: true))
            case 1:
                guard body.count >= 3 else { return }
                output.events.append(
                    .videoFrame(
                        RTMPReceivedVideoFrame(
                            codec: codec, keyframe: frameType == 1, decodeMs: time,
                            compositionMs: Self.si24(body[0], body[1], body[2]), data: Array(body[3...]))))
            case 3:
                output.events.append(
                    .videoFrame(
                        RTMPReceivedVideoFrame(
                            codec: codec, keyframe: frameType == 1, decodeMs: time, compositionMs: 0, data: body)))
            case 2:
                output.events.append(.videoEnd)
            case 4:
                report("enhanced video metadata", into: &output)
            default:
                report("enhanced video packet type \(packetType)", into: &output)
            }
            return
        }
        let codecID = first & 0x0F
        let frameType = first >> 4
        // 7 is AVC; 12 is the common non-standard legacy HEVC id.
        guard codecID == 7 || codecID == 12 else {
            return report("video codec id \(codecID)", into: &output)
        }
        guard frameType != 5 else { return }
        guard payload.count >= 5 else { return }
        let codec: RTMPReceivedCodec = codecID == 7 ? .avc : .hevc
        let body = Array(payload[5...])
        switch payload[1] {
        case 0:
            output.events.append(.videoConfig(codec: codec, record: body, enhanced: false))
        case 1:
            output.events.append(
                .videoFrame(
                    RTMPReceivedVideoFrame(
                        codec: codec, keyframe: frameType == 1, decodeMs: time,
                        compositionMs: Self.si24(payload[2], payload[3], payload[4]), data: body)))
        case 2:
            output.events.append(.videoEnd)
        default:
            report("video packet type \(payload[1])", into: &output)
        }
    }

    private mutating func audio(_ payload: [UInt8], at time: UInt32, into output: inout Output) {
        guard let first = payload.first else { return }
        let format = first >> 4
        guard format == 10 else { return report("audio format \(format)", into: &output) }
        guard payload.count >= 2 else { return }
        if payload[1] == 0 {
            output.events.append(.audioConfig(Array(payload[2...])))
        } else {
            output.events.append(.audioFrame(timestampMs: time, bytes: Array(payload[2...])))
        }
    }

    private mutating func report(_ kind: String, into output: inout Output) {
        if reported.insert(kind).inserted { output.events.append(.unsupported(kind)) }
    }

    // MARK: Writing

    private mutating func reply(
        _ name: String, _ transaction: Double, _ arguments: [AMF0Value], stream: UInt32 = 0,
        chunkStream: UInt32 = 3
    ) -> [UInt8] {
        writer.encode(
            RTMPMessage(
                chunkStreamID: chunkStream, typeID: 20, messageStreamID: stream, timestamp: 0,
                payload: AMF0.encode([.string(name), .number(transaction)] + arguments)))
    }

    private mutating func control(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        writer.encode(
            RTMPMessage(chunkStreamID: 2, typeID: type, messageStreamID: 0, timestamp: 0, payload: payload))
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func si24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int32 {
        let raw = Int32(a) << 16 | Int32(b) << 8 | Int32(c)
        return raw & 0x80_0000 != 0 ? raw - 0x100_0000 : raw
    }

    private static func metadata(_ values: [AMF0Value]) -> [String: String]? {
        var result: [String: String] = [:]
        var found = false
        for value in values {
            let properties: [AMF0Property]
            switch value {
            case .object(let list), .ecmaArray(let list): properties = list
            default: continue
            }
            found = true
            for property in properties {
                switch property.value {
                case .number(let number):
                    result[property.name] =
                        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
                case .string(let text): result[property.name] = text
                case .boolean(let flag): result[property.name] = flag ? "true" : "false"
                default: break
                }
            }
        }
        return found ? result : nil
    }
}
