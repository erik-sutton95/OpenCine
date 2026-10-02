import Foundation

/// Malformed input and policy failures contain no wire payloads or credentials.
public enum LunaProtocolError: Error, Equatable, Sendable {
    case malformedFrame
    case invalidChecksum
    case frameTooLarge
    case unsupportedEnvelope
    case malformedMessage
    case invalidIdentifier
    case malformedProtobuf
    case invalidField(Int)
    case missingField(Int)
    case invalidPublicKey
    case keyExchangeRejected(UInt64)
    case invalidIdentity
    case unexpectedModel
    case unsupportedAuthorizationStatus(UInt64)
    case authorizationRejected(UInt64)
    case unexpectedAuthorizationOperation(UInt64)
    case unexpectedResponse
    case responseEncryptionMismatch
    case cameraRejectedRequest
    case malformedMedia
}

/// UCD2's word-fed polynomial checksum, NOT standard CRC-32.
public enum UCD2Checksum {
    private static let table: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte) << 24
        for _ in 0..<8 {
            value = (value << 1) ^ (value & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7)
        }
        return value
    }

    public static func compute(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { compute($0) }
    }

    static func compute(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value ^= UInt32(byte)
            // Four byte-table rounds are equivalent to 32 polynomial bit rounds.
            value = (value << 8) ^ table[Int(value >> 24)]
            value = (value << 8) ^ table[Int(value >> 24)]
            value = (value << 8) ^ table[Int(value >> 24)]
            value = (value << 8) ^ table[Int(value >> 24)]
        }
        return value
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func littleEndian<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        // Callers validate the range. loadUnaligned avoids alignment assumptions.
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    func byte(at offset: Int) -> UInt8 { self[startIndex + offset] }

    func bytes(in range: Range<Int>) -> Data {
        subdata(in: (startIndex + range.lowerBound)..<(startIndex + range.upperBound))
    }
}

/// A complete checksum-validated UCD2 frame. Unknown extensions remain opaque.
public struct UCD2Frame: Equatable, Sendable {
    public static let minimumSize = 16
    public static let defaultMaximumSize = 4 * 1_024 * 1_024
    public static let messageType: UInt8 = 4
    public static let mediaType: UInt8 = 1
    public static let heartbeatType: UInt8 = 5

    public let raw: Data
    public var type: UInt8 { raw.byte(at: 6) }
    public var sequence: UInt8 { raw.byte(at: 7) }
    public var headerLength: Int { Int(raw.byte(at: 5)) }
    public var payloadLength: Int { raw.count - headerLength - 4 }
    public var payload: Data { raw.bytes(in: headerLength..<(raw.count - 4)) }
    public var associatedData: Data { raw.bytes(in: 0..<12) }
    public var isPlain: Bool { headerLength == 12 }
    public var isScheme3Encrypted: Bool {
        headerLength == 43 && raw.byte(at: 12) == 0x40
            && raw.byte(at: 13) == 0x1D && raw.byte(at: 14) == 3
    }

    /// Parses exactly one frame. Use UCD2Reassembler for transport chunks.
    public init(validating raw: Data, maximumSize: Int = defaultMaximumSize) throws {
        guard maximumSize >= Self.minimumSize, raw.count <= maximumSize else {
            throw LunaProtocolError.frameTooLarge
        }
        guard raw.count >= Self.minimumSize, raw.prefix(4) == Data("UCD2".utf8),
              raw.byte(at: 4) == 1, raw.byte(at: 5) >= 12 else {
            throw LunaProtocolError.malformedFrame
        }
        let length = Int(raw.littleEndian(at: 8, as: UInt32.self))
        guard Int(raw.byte(at: 5)) + length + 4 == raw.count else {
            throw LunaProtocolError.malformedFrame
        }
        let actual = raw.withUnsafeBytes { bytes in
            UCD2Checksum.compute(UnsafeRawBufferPointer(rebasing: bytes[..<(raw.count - 4)]))
        }
        guard actual == raw.littleEndian(at: raw.count - 4, as: UInt32.self) else {
            throw LunaProtocolError.invalidChecksum
        }
        self.raw = raw
    }

    // The reassembler checks header, bounds and checksum once before construction.
    fileprivate init(validated raw: Data) { self.raw = raw }

    public static func plain(type: UInt8, sequence: UInt8, payload: Data = Data(),
                             maximumSize: Int = defaultMaximumSize) throws -> UCD2Frame {
        let header = try header(type: type, sequence: sequence, payloadLength: payload.count,
                                encrypted: false, maximumSize: maximumSize)
        return finish(header + payload)
    }

    /// Construct BEFORE encryption; pass these exact bytes as AES-GCM AAD.
    public static func scheme3AssociatedData(sequence: UInt8, plaintextLength: Int,
                                            maximumSize: Int = defaultMaximumSize) throws -> Data {
        try header(type: messageType, sequence: sequence, payloadLength: plaintextLength,
                   encrypted: true, maximumSize: maximumSize)
    }

    public static func scheme3(sequence: UInt8, ciphertext: Data, nonce: Data, tag: Data,
                               maximumSize: Int = defaultMaximumSize) throws -> UCD2Frame {
        guard nonce.count == 12, tag.count == 16 else {
            throw LunaProtocolError.unsupportedEnvelope
        }
        var packet = try scheme3AssociatedData(sequence: sequence, plaintextLength: ciphertext.count,
                                               maximumSize: maximumSize)
        packet.append(contentsOf: [0x40, 0x1D, 3])
        packet.append(nonce)
        packet.append(tag)
        packet.append(ciphertext)
        return finish(packet)
    }

    private static func header(type: UInt8, sequence: UInt8, payloadLength: Int,
                               encrypted: Bool, maximumSize: Int) throws -> Data {
        let headerSize = encrypted ? 43 : 12
        guard payloadLength >= 0, payloadLength <= Int(UInt32.max),
              maximumSize >= headerSize + 4, payloadLength <= maximumSize - headerSize - 4 else {
            throw LunaProtocolError.frameTooLarge
        }
        var result = Data([0x55, 0x43, 0x44, 0x32, 1, UInt8(headerSize), type, sequence])
        result.appendLE(UInt32(payloadLength))
        return result
    }

    private static func finish(_ packet: Data) -> UCD2Frame {
        var result = packet
        result.appendLE(UCD2Checksum.compute(packet))
        return UCD2Frame(validated: result)
    }

    /// Never treats an encrypted payload as a plain message.
    public func plainMessage() throws -> UCD2Message? {
        guard type == Self.messageType else { return nil }
        guard isPlain else { throw LunaProtocolError.unsupportedEnvelope }
        return try UCD2Message(payload: payload)
    }

    public func scheme3Envelope() throws -> Scheme3Envelope {
        guard type == Self.messageType, isScheme3Encrypted else {
            throw LunaProtocolError.unsupportedEnvelope
        }
        return Scheme3Envelope(associatedData: associatedData, nonce: raw.bytes(in: 15..<27),
                               tag: raw.bytes(in: 27..<43), ciphertext: payload)
    }
}

/// Platform crypto must authenticate the tag/AAD before parsing plaintext.
/// This portable package deliberately owns no keys, entropy, AES or P-256 code.
public struct Scheme3Envelope: Equatable, Sendable {
    public let associatedData: Data
    public let nonce: Data
    public let tag: Data
    public let ciphertext: Data
}

/// Nine-byte UCD2 message header. Identifier flag semantics are kept separate.
public struct UCD2Message: Equatable, Sendable {
    public static let identifierMask: UInt32 = 0x3FFF_FFFF
    public static let requestFlags: UInt32 = 0x8000_0000
    public let code: UInt16
    public let contentType: UInt8
    public let identifier: UInt32
    public let identifierFlags: UInt32
    public let reserved: UInt16
    public let body: Data

    public init(code: UInt16, identifier: UInt32, body: Data = Data(), contentType: UInt8 = 2,
                identifierFlags: UInt32 = 0, reserved: UInt16 = 0) throws {
        guard identifier <= Self.identifierMask, identifierFlags & Self.identifierMask == 0 else {
            throw LunaProtocolError.invalidIdentifier
        }
        self.code = code
        self.identifier = identifier
        self.body = body
        self.contentType = contentType
        self.identifierFlags = identifierFlags
        self.reserved = reserved
    }

    public init(payload: Data) throws {
        guard payload.count >= 9 else { throw LunaProtocolError.malformedMessage }
        let tagged: UInt32 = payload.littleEndian(at: 3)
        try self.init(code: payload.littleEndian(at: 0), identifier: tagged & Self.identifierMask,
                      body: payload.bytes(in: 9..<payload.count), contentType: payload.byte(at: 2),
                      identifierFlags: tagged & ~Self.identifierMask,
                      reserved: payload.littleEndian(at: 7))
    }

    public var payload: Data {
        var result = Data()
        result.reserveCapacity(9 + body.count)
        result.appendLE(code)
        result.append(contentType)
        result.appendLE(identifier | identifierFlags)
        result.appendLE(reserved)
        result.append(body)
        return result
    }

    /// Match the outstanding request before interpreting its body. Content type 2 is
    /// protobuf; 1 is raw bytes, observed on the cmd 11 type 2 NV12 thumbnail reply.
    public func successfulResponseBody(for identifier: UInt32, encrypted: Bool,
                                       requiresEncryption: Bool) throws -> Data {
        guard self.identifier == identifier, contentType == 1 || contentType == 2, reserved == 0,
              code == 200 || code == 500 else { throw LunaProtocolError.unexpectedResponse }
        guard encrypted == requiresEncryption else { throw LunaProtocolError.responseEncryptionMismatch }
        guard code == 200 else { throw LunaProtocolError.cameraRejectedRequest }
        return body
    }
}

/// One ordered directional stream. Discard this value on disconnect.
/// Buffering is bounded by maximumFrameSize. A cursor avoids moving the remaining
/// stream for every video packet; compaction occurs only between input batches.
public struct UCD2Reassembler: Sendable {
    public let maximumFrameSize: Int
    public private(set) var rejectedHeaders = 0
    public private(set) var badChecksums = 0
    public private(set) var discardedBytes = 0
    private var buffer = Data()
    private var cursor = 0
    public var pendingByteCount: Int { buffer.count - cursor }

    public init(maximumFrameSize: Int = UCD2Frame.defaultMaximumSize) throws {
        guard maximumFrameSize >= UCD2Frame.minimumSize else { throw LunaProtocolError.frameTooLarge }
        self.maximumFrameSize = maximumFrameSize
    }

    /// Fragmentation/coalescing are arbitrary. Bad frames are counted and skipped
    /// while the next magic/header/checksum is sought. Callers may fail the session
    /// on these diagnostics; no corrupt media is returned.
    public mutating func feed(_ chunk: Data) -> [UCD2Frame] {
        var frames: [UCD2Frame] = []
        var inputOffset = 0
        while inputOffset < chunk.count {
            compact()
            let count = min(maximumFrameSize - pendingByteCount, chunk.count - inputOffset)
            // A full buffer must be a complete bounded frame or invalid header;
            // drain() always makes room before the next iteration.
            buffer.append(chunk.bytes(in: inputOffset..<(inputOffset + count)))
            inputOffset += count
            drain(into: &frames)
        }
        compact()
        return frames
    }

    private mutating func compact() {
        guard cursor > 0 else { return }
        if cursor == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer = buffer.bytes(in: cursor..<buffer.count)
        }
        cursor = 0
    }

    private mutating func discard(_ count: Int) {
        cursor += count
        discardedBytes += count
    }

    private mutating func drain(into frames: inout [UCD2Frame]) {
        while pendingByteCount >= 4 {
            var start = cursor
            while start <= buffer.count - 4 {
                if buffer.byte(at: start) == 0x55, buffer.byte(at: start + 1) == 0x43,
                   buffer.byte(at: start + 2) == 0x44, buffer.byte(at: start + 3) == 0x32 { break }
                start += 1
            }
            if start > buffer.count - 4 {
                discard(pendingByteCount - 3)
                break
            }
            if start > cursor { discard(start - cursor) }
            guard pendingByteCount >= 12 else { break }
            let headerLength = Int(buffer.byte(at: cursor + 5))
            let payloadLength = Int(buffer.littleEndian(at: cursor + 8, as: UInt32.self))
            let total = headerLength + payloadLength + 4
            guard buffer.byte(at: cursor + 4) == 1, headerLength >= 12,
                  total <= maximumFrameSize else {
                rejectedHeaders += 1
                discard(1)
                continue
            }
            guard pendingByteCount >= total else { break }
            let end = cursor + total
            let actual = buffer.withUnsafeBytes { bytes in
                UCD2Checksum.compute(UnsafeRawBufferPointer(rebasing: bytes[cursor..<(end - 4)]))
            }
            guard actual == buffer.littleEndian(at: end - 4, as: UInt32.self) else {
                badChecksums += 1
                discard(1)
                continue
            }
            frames.append(UCD2Frame(validated: buffer.bytes(in: cursor..<end)))
            cursor = end
        }
    }
}
