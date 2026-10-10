import Foundation

/// The shared length-prefixed stream contract: `[u32be length including kind][u8 kind][payload]`.
/// Deployed tag inventories and byte limits are immutable input facts.
public enum RelayStreamFraming {
    public static let headerBytes = 5

    public struct Decoded: Equatable, Sendable {
        public let kind: UInt8
        public let payload: Data
        public let consumedBytes: Int

        public init(kind: UInt8, payload: Data, consumedBytes: Int) {
            self.kind = kind
            self.payload = payload
            self.consumedBytes = consumedBytes
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case payloadTooLarge(declared: Int)
        case unknownKind(UInt8)
    }

    public static func encode(kind: UInt8, payload: Data) -> Data {
        var output = Data(capacity: headerBytes + payload.count)
        output.appendBigEndian(UInt32(payload.count + 1))
        output.append(kind)
        output.append(payload)
        return output
    }

    public static func decode(from buffer: Data, profile: RelayWireProfile) throws -> Decoded? {
        guard buffer.count >= headerBytes else { return nil }
        let declared = buffer.bigEndianLength
        guard declared >= 1 else { throw DecodeError.payloadTooLarge(declared: declared) }
        guard declared - 1 <= profile.maximumPayloadBytes else {
            throw DecodeError.payloadTooLarge(declared: declared - 1)
        }
        let total = 4 + declared
        guard buffer.count >= total else { return nil }
        let kind = buffer[buffer.startIndex + 4]
        guard profile.messageKinds.contains(kind) else { throw DecodeError.unknownKind(kind) }
        let payload = Data(buffer[(buffer.startIndex + headerBytes)..<(buffer.startIndex + total)])
        return Decoded(kind: kind, payload: payload, consumedBytes: total)
    }
}

/// One stream's incremental framing state. The socket owner confines it to its own executor;
/// the next receive is admitted only after the current batch has been consumed.
public struct RelayStreamBuffer: Sendable {
    public let profile: RelayWireProfile
    private var buffer = Data()
    public var pendingByteCount: Int { buffer.count }

    public init(profile: RelayWireProfile) { self.profile = profile }

    public mutating func append(_ bytes: Data) throws -> [RelayStreamFraming.Decoded] {
        buffer.append(bytes)
        var messages: [RelayStreamFraming.Decoded] = []
        while let message = try RelayStreamFraming.decode(from: buffer, profile: profile) {
            buffer.removeFirst(message.consumedBytes)
            messages.append(message)
        }
        return messages
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

/// Metadata is a typed codec's original Codable value; image/parameter bytes remain opaque.
public enum RelayFrameBlob {
    public enum DecodeError: Error, Equatable, Sendable { case truncated(declared: Int) }

    public static func encode<Metadata: Encodable>(metadata: Metadata, image: Data) throws -> Data {
        let json = try JSONEncoder().encode(metadata)
        var output = Data(capacity: 4 + json.count + image.count)
        output.appendBigEndian(UInt32(json.count))
        output.append(json)
        output.append(image)
        return output
    }

    public static func decode<Metadata: Decodable>(
        _ type: Metadata.Type, from payload: Data
    ) throws -> (metadata: Metadata, image: Data) {
        guard payload.count >= 4 else { throw DecodeError.truncated(declared: payload.count) }
        let count = payload.bigEndianLength
        guard count <= payload.count - 4 else { throw DecodeError.truncated(declared: count) }
        let split = payload.startIndex + 4 + count
        let metadata = try JSONDecoder().decode(
            type, from: Data(payload[(payload.startIndex + 4)..<split]))
        return (metadata, Data(payload[split..<payload.endIndex]))
    }
}

/// Shared one-byte-tagged JSON envelopes, including the existing phone/watch v1 contracts.
public enum RelayEnvelopeFraming {
    public enum DecodeError: Error, Equatable, Sendable {
        case empty
        case unknownKind(UInt8)
    }

    public static func encode<Payload: Encodable>(kind: UInt8, payload: Payload) throws -> Data {
        var output = Data([kind])
        output.append(try JSONEncoder().encode(payload))
        return output
    }

    public static func kind(of envelope: Data, admittedKinds: Set<UInt8>) throws -> UInt8 {
        guard let first = envelope.first else { throw DecodeError.empty }
        guard admittedKinds.contains(first) else { throw DecodeError.unknownKind(first) }
        return first
    }

    public static func decode<Payload: Decodable>(_ type: Payload.Type, from envelope: Data) throws
        -> Payload
    {
        guard !envelope.isEmpty else { throw DecodeError.empty }
        return try JSONDecoder().decode(type, from: envelope.dropFirst())
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    fileprivate var bigEndianLength: Int {
        Int(self[startIndex]) << 24 | Int(self[startIndex + 1]) << 16
            | Int(self[startIndex + 2]) << 8 | Int(self[startIndex + 3])
    }
}
