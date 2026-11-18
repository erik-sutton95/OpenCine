import Foundation

@testable import OpenCineStreaming

/// SIMULATED: a scripted RTMP server for session tests. It answers the handshake, replies to
/// `connect`, `createStream` and `publish` with scripted `_result` and `onStatus` messages, and
/// records every message it decodes. It is not a real server and proves nothing about one; the
/// FFmpeg interop tier and the hardware pass do that.
struct SimulatedRTMPServer {
    struct Command: Equatable {
        let values: [AMF0Value]
        var name: String? { if case .string(let s) = values.first { s } else { nil } }
        /// The arguments after the name, transaction ID and command object.
        func argument(_ index: Int) -> AMF0Value? {
            values.indices.contains(3 + index) ? values[3 + index] : nil
        }
        func objectValue(_ key: String) -> AMF0Value? {
            guard values.count > 2, case .object(let properties) = values[2] else { return nil }
            return properties.first { $0.name == key }?.value
        }
    }

    var windowAckSize: UInt32 = 2_500_000
    var chunkSizeToAnnounce: Int?
    var connectDescriptionPadding = 0
    var publishCode = "NetStream.Publish.Start"
    var publishLevel = "status"
    var publishDescription = "Publishing."
    /// When set, S2 is held back until C2 arrives, as a strict server may do.
    var holdsS2UntilC2 = false
    /// When set, `connect` gets an `_error` reply.
    var rejectsConnect = false

    private(set) var messages: [RTMPMessage] = []
    private(set) var bytesReceived = 0
    private var handshake: [UInt8] = []
    private var handshakeDone = false
    private var c1: [UInt8] = []
    private var reader = RTMPChunkReader()
    private var writer = RTMPChunkWriter()

    var commands: [Command] {
        messages.filter { $0.typeID == 20 }.compactMap { (try? AMF0.decode($0.payload)).map(Command.init) }
    }
    var commandNames: [String] { commands.compactMap(\.name) }
    func command(_ name: String) -> Command? { commands.first { $0.name == name } }
    var media: [RTMPMessage] { messages.filter { $0.typeID == 8 || $0.typeID == 9 } }

    mutating func receive(_ bytes: [UInt8]) throws -> [UInt8] {
        bytesReceived += bytes.count
        var input = bytes
        var out: [UInt8] = []
        if !handshakeDone {
            handshake += input
            input = []
            if c1.isEmpty, handshake.count >= 1537 {
                c1 = Array(handshake[1..<1537])
                let s1 = [UInt8](repeating: 0x5A, count: 1536)
                out += [0x03] + s1
                if !holdsS2UntilC2 { out += c1 }
            }
            guard handshake.count >= 1537 + 1536 else { return out }
            if holdsS2UntilC2 { out += c1 }
            input = Array(handshake[(1537 + 1536)...])
            handshakeDone = true
        }
        for message in try reader.push(input) {
            messages.append(message)
            out += respond(to: message)
        }
        return out
    }

    /// Bytes for any server message, chunked with the server's current chunk size.
    mutating func send(_ message: RTMPMessage) -> [UInt8] {
        writer.encode(message)
    }

    mutating func sendCommand(_ values: [AMF0Value], streamID: UInt32 = 0) -> [UInt8] {
        send(RTMPMessage(chunkStreamID: 3, typeID: 20, messageStreamID: streamID, timestamp: 0, payload: AMF0.encode(values)))
    }

    mutating func sendStatus(code: String, level: String, description: String) -> [UInt8] {
        sendCommand(
            [
                .string("onStatus"), .number(0), .null,
                .object([
                    AMF0Property(name: "level", value: .string(level)),
                    AMF0Property(name: "code", value: .string(code)),
                    AMF0Property(name: "description", value: .string(description)),
                ]),
            ], streamID: 1)
    }

    private mutating func control(_ type: UInt8, _ value: UInt32, extra: [UInt8] = []) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendBigEndian(value)
        return send(RTMPMessage(chunkStreamID: 2, typeID: type, messageStreamID: 0, timestamp: 0, payload: payload + extra))
    }

    private mutating func respond(to message: RTMPMessage) -> [UInt8] {
        guard message.typeID == 20, let values = try? AMF0.decode(message.payload),
            case .string(let name) = values.first, values.count > 1
        else { return [] }
        let transaction = values[1]
        switch name {
        case "connect":
            var out = control(5, windowAckSize) + control(6, windowAckSize, extra: [2])
            if rejectsConnect {
                return out + sendCommand([
                    .string("_error"), transaction, .null,
                    .object([
                        AMF0Property(name: "level", value: .string("error")),
                        AMF0Property(name: "code", value: .string("NetConnection.Connect.Rejected")),
                        AMF0Property(name: "description", value: .string("Unknown application.")),
                    ]),
                ])
            }
            if let size = chunkSizeToAnnounce {
                out += control(1, UInt32(size))
                writer.chunkSize = size
            }
            out += sendCommand([
                .string("_result"), transaction,
                .object([AMF0Property(name: "fmsVer", value: .string("FMS/3,0,1,123"))]),
                .object([
                    AMF0Property(name: "level", value: .string("status")),
                    AMF0Property(name: "code", value: .string("NetConnection.Connect.Success")),
                    AMF0Property(
                        name: "description",
                        value: .string("Connection succeeded." + String(repeating: " ", count: connectDescriptionPadding))),
                ]),
            ])
            return out
        case "releaseStream", "FCPublish":
            return sendCommand([.string("_error"), transaction, .null, .null])
        case "createStream":
            return sendCommand([.string("_result"), transaction, .null, .number(1)])
        case "publish":
            return sendStatus(code: publishCode, level: publishLevel, description: publishDescription)
        default:
            return []
        }
    }
}

/// A session and a simulated server wired together, with every byte pumped between them.
struct SessionRun {
    var session: RTMPPublishSession
    var server = SimulatedRTMPServer()
    var events: [StreamSessionEvent] = []

    init(key: String = "SECRETKEY", server: SimulatedRTMPServer = SimulatedRTMPServer()) throws {
        let destination = try StreamDestination(serverURL: "rtmps://live.example.com/app", streamKey: key)
        session = RTMPPublishSession(destination: destination, random: { Array(repeating: 0xC1, count: $0) })
        self.server = server
    }

    /// Runs the handshake and the command exchange until neither side has more to say.
    mutating func connectToLive(oneByteAtATime: Bool = false) throws {
        var toServer = session.start()
        while !toServer.isEmpty {
            let toClient = try server.receive(toServer)
            toServer = deliver(toClient, oneByteAtATime: oneByteAtATime)
        }
    }

    /// Delivers server bytes to the session and returns what the session sends back.
    mutating func deliver(_ bytes: [UInt8], oneByteAtATime: Bool = false) -> [UInt8] {
        var outbound: [UInt8] = []
        let pieces = oneByteAtATime ? bytes.map { [$0] } : [bytes]
        for piece in pieces {
            let output = session.receive(piece)
            outbound += output.outbound
            events += output.events
        }
        return outbound
    }

    /// Sends a media packet and lets the server decode whatever went out.
    mutating func send(_ packet: StreamMediaPacket) throws -> [UInt8] {
        let bytes = session.send(packet)
        _ = try server.receive(bytes)
        return bytes
    }
}
