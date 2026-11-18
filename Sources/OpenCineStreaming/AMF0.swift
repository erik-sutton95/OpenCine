import Foundation

/// One AMF0 value, as RTMP commands and metadata carry them.
enum AMF0Value: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([AMF0Property])
    case ecmaArray([AMF0Property])
    case null
    case undefined
}

/// One named member of an AMF0 object or ECMA array, in wire order.
struct AMF0Property: Equatable, Sendable {
    let name: String
    let value: AMF0Value
}

enum AMF0Error: Error, Equatable {
    case truncated
    case unsupportedMarker(UInt8)
    case nestedTooDeep
}

/// AMF0 encoding and decoding. Decoding is bounds checked and limits nesting, so hostile bytes
/// throw instead of crashing or recursing without end.
enum AMF0 {
    private static let maxDepth = 32

    private enum Marker {
        static let number: UInt8 = 0x00
        static let boolean: UInt8 = 0x01
        static let string: UInt8 = 0x02
        static let object: UInt8 = 0x03
        static let null: UInt8 = 0x05
        static let undefined: UInt8 = 0x06
        static let ecmaArray: UInt8 = 0x08
        static let objectEnd: UInt8 = 0x09
        static let longString: UInt8 = 0x0C
    }

    static func encode(_ values: [AMF0Value]) -> [UInt8] {
        var out: [UInt8] = []
        for value in values { encode(value, into: &out) }
        return out
    }

    static func decode(_ bytes: [UInt8]) throws -> [AMF0Value] {
        var cursor = ByteCursor(bytes)
        var values: [AMF0Value] = []
        while !cursor.isAtEnd { values.append(try decodeValue(&cursor, depth: 0)) }
        return values
    }

    private static func encode(_ value: AMF0Value, into out: inout [UInt8]) {
        switch value {
        case .number(let number):
            out.append(Marker.number)
            out.appendBigEndian(number.bitPattern)
        case .boolean(let flag):
            out += [Marker.boolean, flag ? 1 : 0]
        case .string(let text):
            let utf8 = Array(text.utf8)
            if utf8.count > Int(UInt16.max) {
                out.append(Marker.longString)
                out.appendBigEndian(UInt32(utf8.count))
            } else {
                out.append(Marker.string)
                out.appendBigEndian(UInt16(utf8.count))
            }
            out += utf8
        case .object(let properties):
            out.append(Marker.object)
            encode(properties, into: &out)
        case .ecmaArray(let properties):
            out.append(Marker.ecmaArray)
            out.appendBigEndian(UInt32(properties.count))
            encode(properties, into: &out)
        case .null:
            out.append(Marker.null)
        case .undefined:
            out.append(Marker.undefined)
        }
    }

    private static func encode(_ properties: [AMF0Property], into out: inout [UInt8]) {
        for property in properties {
            let name = Array(property.name.utf8.prefix(Int(UInt16.max)))
            out.appendBigEndian(UInt16(name.count))
            out += name
            encode(property.value, into: &out)
        }
        out += [0x00, 0x00, Marker.objectEnd]
    }

    private static func decodeValue(_ cursor: inout ByteCursor, depth: Int) throws -> AMF0Value {
        guard depth < maxDepth else { throw AMF0Error.nestedTooDeep }
        let marker = try cursor.byte()
        switch marker {
        case Marker.number:
            return .number(Double(bitPattern: try cursor.uint64()))
        case Marker.boolean:
            return .boolean(try cursor.byte() != 0)
        case Marker.string:
            return .string(try cursor.string(length: Int(try cursor.uint16())))
        case Marker.longString:
            return .string(try cursor.string(length: Int(try cursor.uint32())))
        case Marker.object:
            return .object(try decodeProperties(&cursor, depth: depth + 1))
        case Marker.ecmaArray:
            // The declared count is advisory; the end marker closes the array.
            _ = try cursor.uint32()
            return .ecmaArray(try decodeProperties(&cursor, depth: depth + 1))
        case Marker.null:
            return .null
        case Marker.undefined:
            return .undefined
        default:
            throw AMF0Error.unsupportedMarker(marker)
        }
    }

    private static func decodeProperties(_ cursor: inout ByteCursor, depth: Int) throws -> [AMF0Property] {
        guard depth < maxDepth else { throw AMF0Error.nestedTooDeep }
        var properties: [AMF0Property] = []
        while true {
            let name = try cursor.string(length: Int(try cursor.uint16()))
            if name.isEmpty, try cursor.peek() == Marker.objectEnd {
                _ = try cursor.byte()
                return properties
            }
            properties.append(AMF0Property(name: name, value: try decodeValue(&cursor, depth: depth)))
        }
    }
}

/// A bounds-checked big-endian reader over bytes. Every read throws `AMF0Error.truncated` past the end.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    func peek() throws -> UInt8 {
        guard offset < bytes.count else { throw AMF0Error.truncated }
        return bytes[offset]
    }

    mutating func byte() throws -> UInt8 {
        let value = try peek()
        offset += 1
        return value
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, bytes.count - offset >= count else { throw AMF0Error.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func uint16() throws -> UInt16 { UInt16(try bigEndian(2)) }
    mutating func uint32() throws -> UInt32 { UInt32(try bigEndian(4)) }
    mutating func uint64() throws -> UInt64 { try bigEndian(8) }

    mutating func string(length: Int) throws -> String {
        String(decoding: try take(length), as: UTF8.self)
    }

    private mutating func bigEndian(_ count: Int) throws -> UInt64 {
        try take(count).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        let size = MemoryLayout<T>.size
        for index in (0..<size).reversed() { append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
}
