import Foundation

/// Detached-screen UDP envelope (CRC-HQX). Portable; no sockets.
public enum ScreenWire {
    public static let crcInitial: UInt16 = 0xEF4A
    public static let kcpPush: UInt8 = 81
    public static let kcpAck: UInt8 = 82

    public static func crcHQX(_ data: Data, initial: UInt16 = crcInitial) -> UInt16 {
        var crc = initial
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    public struct Envelope: Equatable, Sendable {
        public var kind: UInt8
        public var source: UInt16
        public var destination: UInt16
        public var payload: Data

        public init(kind: UInt8, source: UInt16, destination: UInt16, payload: Data) {
            self.kind = kind
            self.source = source
            self.destination = destination
            self.payload = payload
        }

        public func encode() throws -> Data {
            var prefix = Data()
            prefix.append(kind)
            prefix.appendLE(source)
            prefix.appendLE(destination)
            let length = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: length) { prefix.append(contentsOf: $0.prefix(3)) }
            var encoded = prefix
            encoded.appendLE(Self.crc(prefix + Data(count: 4)))
            encoded.appendLE(crcHQX(payload))
            encoded.append(payload)
            return encoded
        }

        private static func crc(_ data: Data) -> UInt16 { crcHQX(data) }
    }

    public static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard data.count >= 12 else { throw LunaProtocolError.malformedFrame }
        let payloadLength = Int(data[5]) | Int(data[6]) << 8 | Int(data[7]) << 16
        guard payloadLength == data.count - 12 else { throw LunaProtocolError.malformedFrame }
        let headerCRC = data.littleEndian(at: 8, as: UInt16.self)
        let payloadCRC = data.littleEndian(at: 10, as: UInt16.self)
        var header = data.prefix(8) + Data(count: 4)
        header = Data(header)
        guard crcHQX(header) == headerCRC, crcHQX(data.suffix(from: 12)) == payloadCRC else {
            throw LunaProtocolError.malformedFrame
        }
        let source = data.littleEndian(at: 1, as: UInt16.self)
        let destination = data.littleEndian(at: 3, as: UInt16.self)
        return Envelope(
            kind: data[0], source: source, destination: destination,
            payload: Data(data[12...]))
    }

    public static func rpc(service: UInt16, method: UInt16, identifier: UInt32, body: Data)
        -> Data
    {
        var payload = Data()
        payload.append(1)
        payload.appendLE(service)
        payload.appendLE(method)
        payload.append(0)
        payload.appendLE(identifier)
        payload.append(body)
        return payload
    }

    public static func kind2Hello(
        flag: UInt8, transaction: UInt32, conversation: UInt32, tail: UInt32
    ) throws -> Data {
        var payload = Data()
        payload.append(flag)
        payload.appendLE(transaction)
        payload.appendLE(conversation)
        payload.appendLE(tail)
        return try Envelope(kind: 2, source: 0x0800, destination: 0, payload: payload).encode()
    }

    public struct Kind2: Equatable, Sendable {
        public var flag: UInt8
        public var transaction: UInt32
        public var conversation: UInt32
        public var tail: UInt32
    }

    public static func decodeKind2(_ envelope: Envelope) throws -> Kind2 {
        guard envelope.kind == 2, envelope.payload.count == 13 else {
            throw LunaProtocolError.malformedFrame
        }
        let payload = envelope.payload
        return Kind2(
            flag: payload[0],
            transaction: payload.littleEndian(at: 1, as: UInt32.self),
            conversation: payload.littleEndian(at: 5, as: UInt32.self),
            tail: payload.littleEndian(at: 9, as: UInt32.self))
    }

    public struct KCPSegment: Equatable, Sendable {
        public var conversation: UInt32
        public var command: UInt8
        public var fragmentsRemaining: UInt8
        public var window: UInt16
        public var timestamp: UInt32
        public var sequence: UInt32
        public var una: UInt32
        public var payload: Data

        public func encode() -> Data {
            var data = Data()
            data.appendLE(conversation)
            data.append(command)
            data.append(fragmentsRemaining)
            data.appendLE(window)
            data.appendLE(timestamp)
            data.appendLE(sequence)
            data.appendLE(una)
            data.appendLE(UInt32(payload.count))
            data.append(payload)
            return data
        }
    }

    public static func decodeKCP(_ data: Data) throws -> [KCPSegment] {
        var segments: [KCPSegment] = []
        var offset = 0
        while offset + 24 <= data.count {
            let conversation: UInt32 = data.littleEndian(at: offset, as: UInt32.self)
            let command = data[offset + 4]
            let frg = data[offset + 5]
            let window: UInt16 = data.littleEndian(at: offset + 6, as: UInt16.self)
            let timestamp: UInt32 = data.littleEndian(at: offset + 8, as: UInt32.self)
            let sequence: UInt32 = data.littleEndian(at: offset + 12, as: UInt32.self)
            let una: UInt32 = data.littleEndian(at: offset + 16, as: UInt32.self)
            let length = Int(data.littleEndian(at: offset + 20, as: UInt32.self))
            offset += 24
            guard offset + length <= data.count else { throw LunaProtocolError.malformedFrame }
            segments.append(
                KCPSegment(
                    conversation: conversation, command: command, fragmentsRemaining: frg,
                    window: window, timestamp: timestamp, sequence: sequence, una: una,
                    payload: data.subdata(in: offset..<(offset + length))))
            offset += length
        }
        return segments
    }

    public static func push(
        conversation: UInt32, sequence: UInt32, una: UInt32, payload: Data,
        fragmentsRemaining: UInt8 = 0, timestamp: UInt32 = 0
    ) -> Data {
        KCPSegment(
            conversation: conversation, command: kcpPush, fragmentsRemaining: fragmentsRemaining,
            window: 128, timestamp: timestamp, sequence: sequence, una: una, payload: payload
        ).encode()
    }
}
