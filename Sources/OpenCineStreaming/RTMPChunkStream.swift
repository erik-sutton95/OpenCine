import Foundation

/// One RTMP message, before chunking or after reassembly.
struct RTMPMessage: Equatable, Sendable {
    var chunkStreamID: UInt32
    var typeID: UInt8
    var messageStreamID: UInt32
    var timestamp: UInt32
    var payload: [UInt8]
}

enum RTMPChunkError: Error, Equatable {
    /// A message declares more bytes than the reader holds for one message, or partial messages
    /// together pass that bound.
    case messageTooLarge
    /// A Set Chunk Size message carries zero or a value with the reserved top bit set.
    case invalidChunkSize
    /// A compressed header arrives on a chunk stream that has had no full header yet.
    case missingPriorHeader
}

/// The largest value a three-byte timestamp field holds before the extended field takes over.
private let extendedTimestampMarker: UInt32 = 0xFF_FFFF

/// Splits messages into chunks. It keeps the last header per chunk stream, so later messages use
/// compressed headers (type 1 or 2) when they can, and type 0 when the stream ID changes or the
/// timestamp goes backward.
struct RTMPChunkWriter {
    var chunkSize = 128

    private struct LastHeader {
        var messageStreamID: UInt32
        var length: Int
        var typeID: UInt8
        var timestamp: UInt32
    }

    private var last: [UInt32: LastHeader] = [:]

    mutating func encode(_ message: RTMPMessage) -> [UInt8] {
        let csid = message.chunkStreamID
        let length = message.payload.count
        var out: [UInt8] = []
        out.reserveCapacity(length + 18 + length / max(chunkSize, 1))

        let format: UInt8
        let field: UInt32
        if let prior = last[csid], prior.messageStreamID == message.messageStreamID,
            message.timestamp >= prior.timestamp
        {
            field = message.timestamp - prior.timestamp
            format = prior.length == length && prior.typeID == message.typeID ? 2 : 1
        } else {
            format = 0
            field = message.timestamp
        }
        let extended = field >= extendedTimestampMarker

        Self.appendBasicHeader(format: format, csid: csid, into: &out)
        out.appendBigEndian24(extended ? extendedTimestampMarker : field)
        if format <= 1 {
            out.appendBigEndian24(UInt32(length))
            out.append(message.typeID)
        }
        if format == 0 {
            out.append(contentsOf: withUnsafeBytes(of: message.messageStreamID.littleEndian, Array.init))
        }
        if extended { out.appendBigEndian(field) }

        let size = max(chunkSize, 1)
        var offset = 0
        repeat {
            if offset > 0 {
                Self.appendBasicHeader(format: 3, csid: csid, into: &out)
                if extended { out.appendBigEndian(field) }
            }
            let end = min(offset + size, length)
            out += message.payload[offset..<end]
            offset = end
        } while offset < length

        last[csid] = LastHeader(
            messageStreamID: message.messageStreamID, length: length, typeID: message.typeID,
            timestamp: message.timestamp)
        return out
    }

    private static func appendBasicHeader(format: UInt8, csid: UInt32, into out: inout [UInt8]) {
        switch csid {
        case 2..<64:
            out.append(format << 6 | UInt8(csid))
        case 64..<320:
            out += [format << 6, UInt8(csid - 64)]
        default:
            let value = csid - 64
            out += [format << 6 | 1, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
    }
}

/// Reassembles messages from chunks delivered in pieces of any size. It keeps unconsumed bytes and
/// per-chunk-stream state between `push` calls. A Set Chunk Size message takes effect for the
/// chunks after it at once, and an Abort message drops that stream's partial message.
struct RTMPChunkReader {
    var chunkSize = 128
    private let maxMessageBytes: Int

    private struct StreamState {
        var timestamp: UInt32 = 0
        /// The last header's timestamp field: absolute after type 0, a delta after type 1 or 2.
        var timestampField: UInt32 = 0
        var length = 0
        var typeID: UInt8 = 0
        var messageStreamID: UInt32 = 0
        var hasExtendedTimestamp = false
    }

    private var buffer: [UInt8] = []
    private var start = 0
    private var streams: [UInt32: StreamState] = [:]
    /// Half-received messages per chunk stream, kept apart from the headers so they grow in place.
    private var partials: [UInt32: [UInt8]] = [:]
    /// Bytes held in half-received messages across all chunk streams (bounded by `maxMessageBytes`).
    private(set) var partialBytes = 0

    init(maxMessageBytes: Int = 16 * 1024 * 1024) {
        self.maxMessageBytes = maxMessageBytes
    }

    mutating func push(_ bytes: [UInt8]) throws -> [RTMPMessage] {
        buffer += bytes
        var messages: [RTMPMessage] = []
        while let message = try readChunk() {
            if let message { messages.append(message) }
        }
        if start > 0 {
            buffer.removeFirst(start)
            start = 0
        }
        return messages
    }

    /// Reads one chunk. `nil` when the buffer does not hold a whole chunk yet; `.some(nil)` when a
    /// chunk was consumed without completing a message.
    private mutating func readChunk() throws -> RTMPMessage?? {
        var at = start
        func need(_ count: Int) -> Bool { buffer.count - at >= count }
        func read(_ count: Int) -> UInt32 {
            defer { at += count }
            return buffer[at..<at + count].reduce(0) { $0 << 8 | UInt32($1) }
        }

        guard need(1) else { return nil }
        let first = buffer[at]
        at += 1
        let format = first >> 6
        var csid = UInt32(first & 0x3F)
        if csid == 0 {
            guard need(1) else { return nil }
            csid = 64 + read(1)
        } else if csid == 1 {
            guard need(2) else { return nil }
            let low = read(1)
            csid = 64 + low + read(1) * 256
        }

        guard var state = streams[csid] ?? (format == 0 ? StreamState() : nil) else {
            throw RTMPChunkError.missingPriorHeader
        }
        let headerSize = [11, 7, 3, 0][Int(format)]
        guard need(headerSize) else { return nil }
        var field = state.timestampField
        if format <= 2 { field = read(3) }
        if format <= 1 {
            state.length = Int(read(3))
            state.typeID = UInt8(read(1))
        }
        if format == 0 {
            let raw = read(4)
            state.messageStreamID = raw.byteSwapped
        }
        let extended = format == 3 ? state.hasExtendedTimestamp : field == extendedTimestampMarker
        if extended {
            guard need(4) else { return nil }
            let value = read(4)
            if format != 3 { field = value }
        }

        let continuing = format == 3 && partials[csid] != nil
        // A new header abandons a half message on this stream; its bytes are given back only when
        // the new chunk is taken, so a header split across reads is not counted twice.
        var abandoned = 0
        if !continuing {
            guard state.length <= maxMessageBytes else { throw RTMPChunkError.messageTooLarge }
            abandoned = partials[csid]?.count ?? 0
            switch format {
            case 0: state.timestamp = field
            case 1, 2: state.timestamp = state.timestamp &+ field
            default: state.timestamp = state.timestamp &+ state.timestampField
            }
            if format != 3 {
                state.timestampField = field
                state.hasExtendedTimestamp = extended
            }
        }
        let have = continuing ? partials[csid]?.count ?? 0 : 0
        let take = min(max(chunkSize, 1), state.length - have)
        guard need(take) else { return nil }
        guard partialBytes - abandoned + take <= maxMessageBytes else { throw RTMPChunkError.messageTooLarge }

        partialBytes -= abandoned
        if continuing {
            partials[csid]?.append(contentsOf: buffer[at..<at + take])
        } else {
            partials[csid] = Array(buffer[at..<at + take])
        }
        at += take
        partialBytes += take
        start = at
        streams[csid] = state

        guard partials[csid]?.count == state.length, let payload = partials.removeValue(forKey: csid) else {
            return .some(nil)
        }
        partialBytes -= payload.count
        let message = RTMPMessage(
            chunkStreamID: csid, typeID: state.typeID, messageStreamID: state.messageStreamID,
            timestamp: state.timestamp, payload: payload)
        try applyControl(message)
        return .some(message)
    }

    private mutating func applyControl(_ message: RTMPMessage) throws {
        guard message.messageStreamID == 0, message.payload.count >= 4 else { return }
        let value = message.payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch message.typeID {
        case 1:
            guard value > 0, value & 0x8000_0000 == 0 else { throw RTMPChunkError.invalidChunkSize }
            chunkSize = Int(value)
        case 2:
            if let dropped = partials.removeValue(forKey: value) { partialBytes -= dropped.count }
        default:
            break
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian24(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
