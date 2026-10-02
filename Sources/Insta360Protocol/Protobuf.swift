import Foundation

/// The bounded protobuf subset used by Luna bootstrap/control. Unknown fields
/// survive parsing; groups are rejected. No recursive decoding occurs implicitly.
public struct ProtoMessage: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case unsigned(UInt64)
        case fixed64(Data)
        case bytes(Data)
        case fixed32(Data)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value
    }

    public let fields: [Field]

    public init(_ data: Data, maximumBytes: Int = 1_024 * 1_024, maximumFields: Int = 16_384) throws {
        guard maximumBytes >= 0, maximumFields >= 0, data.count <= maximumBytes else {
            throw LunaProtocolError.malformedProtobuf
        }
        var result: [Field] = []
        var offset = 0
        while offset < data.count {
            guard result.count < maximumFields else { throw LunaProtocolError.malformedProtobuf }
            let tag = try Self.readVarint(data, offset: &offset)
            let number = tag >> 3
            guard number > 0, number < 1 << 29 else { throw LunaProtocolError.malformedProtobuf }
            let value: Value
            switch tag & 7 {
            case 0:
                value = .unsigned(try Self.readVarint(data, offset: &offset))
            case 1, 2, 5:
                let count: Int
                if tag & 7 == 2 {
                    let length = try Self.readVarint(data, offset: &offset)
                    guard length <= UInt64(data.count - offset) else {
                        throw LunaProtocolError.malformedProtobuf
                    }
                    count = Int(length)
                } else {
                    count = tag & 7 == 1 ? 8 : 4
                }
                guard count <= data.count - offset else { throw LunaProtocolError.malformedProtobuf }
                let contents = data.bytes(in: offset..<(offset + count))
                offset += count
                switch tag & 7 {
                case 1: value = .fixed64(contents)
                case 5: value = .fixed32(contents)
                default: value = .bytes(contents)
                }
            default:
                throw LunaProtocolError.malformedProtobuf
            }
            result.append(Field(number: Int(number), value: value))
        }
        fields = result
    }

    /// Singular protobuf fields use the last occurrence, after validating the
    /// type of every occurrence of this known field and the complete message.
    public func unsigned(_ number: Int, default defaultValue: UInt64? = nil) throws -> UInt64 {
        var result: UInt64?
        for field in fields where field.number == number {
            guard case let .unsigned(value) = field.value else { throw LunaProtocolError.invalidField(number) }
            result = value
        }
        guard let value = result ?? defaultValue else { throw LunaProtocolError.missingField(number) }
        return value
    }

    public func bytes(_ number: Int) throws -> Data {
        guard let result = try optionalBytes(number) else { throw LunaProtocolError.missingField(number) }
        return result
    }

    public func optionalBytes(_ number: Int) throws -> Data? {
        var result: Data?
        for field in fields where field.number == number {
            guard case let .bytes(value) = field.value else { throw LunaProtocolError.invalidField(number) }
            result = value
        }
        return result
    }

    public func string(_ number: Int) throws -> String {
        guard let result = String(data: try bytes(number), encoding: .utf8) else {
            throw LunaProtocolError.invalidField(number)
        }
        return result
    }

    public func repeatedUnsigned(_ number: Int, maximumValues: Int = 16_384) throws -> [UInt64] {
        guard maximumValues >= 0 else { throw LunaProtocolError.invalidField(number) }
        var result: [UInt64] = []
        for field in fields where field.number == number {
            switch field.value {
            case let .unsigned(value):
                guard result.count < maximumValues else { throw LunaProtocolError.invalidField(number) }
                result.append(value)
            case let .bytes(packed):
                var offset = 0
                while offset < packed.count {
                    guard result.count < maximumValues else { throw LunaProtocolError.invalidField(number) }
                    result.append(try Self.readVarint(packed, offset: &offset))
                }
            default: throw LunaProtocolError.invalidField(number)
            }
        }
        return result
    }

    public static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        while value > 127 {
            result.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }

    public static func integer(field: Int, value: UInt64) throws -> Data {
        try tag(field: field, wire: 0) + varint(value)
    }

    /// Protobuf `sint32` zigzag. Official-app gimbal VirtualRC uses this encoding.
    public static func zigzag32(_ value: Int32) -> UInt64 {
        let doubled = Int32(bitPattern: UInt32(bitPattern: value) << 1)
        return UInt64(UInt32(bitPattern: doubled ^ (value >> 31)))
    }

    public static func signed32(field: Int, value: Int32) throws -> Data {
        try integer(field: field, value: zigzag32(value))
    }

    public static func blob(field: Int, value: Data) throws -> Data {
        try tag(field: field, wire: 2) + varint(UInt64(value.count)) + value
    }

    public static func double(field: Int, value: Double) throws -> Data {
        var bits = value.bitPattern.littleEndian
        let bytes = Data(bytes: &bits, count: 8)
        return try tag(field: field, wire: 1) + bytes
    }

    public func double(_ number: Int) throws -> Double {
        var result: Double?
        for field in fields where field.number == number {
            guard case let .fixed64(value) = field.value, value.count == 8 else {
                throw LunaProtocolError.invalidField(number)
            }
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) { value.copyBytes(to: $0) }
            result = Double(bitPattern: UInt64(littleEndian: raw))
        }
        guard let value = result else { throw LunaProtocolError.missingField(number) }
        return value
    }

    /// Inverse of `zigzag32` for protobuf `sint32` readback.
    public static func unzigzag32(_ value: UInt64) -> Int32 {
        let raw = UInt32(truncatingIfNeeded: value)
        return Int32(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    /// Protobuf `float` (wire type 5). Official-app ROI rectangles use this.
    public static func float(field: Int, value: Float) throws -> Data {
        var bits = value.bitPattern.littleEndian
        return try tag(field: field, wire: 5) + Data(bytes: &bits, count: 4)
    }

    public func float(_ number: Int) throws -> Float {
        var result: Float?
        for field in fields where field.number == number {
            guard case let .fixed32(value) = field.value, value.count == 4 else {
                throw LunaProtocolError.invalidField(number)
            }
            result = Float(bitPattern: value.littleEndian(at: 0, as: UInt32.self))
        }
        guard let value = result else { throw LunaProtocolError.missingField(number) }
        return value
    }

    private static func tag(field: Int, wire: UInt64) throws -> Data {
        guard field > 0, field < 1 << 29 else { throw LunaProtocolError.invalidField(field) }
        return varint(UInt64(field) << 3 | wire)
    }

    private static func readVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw LunaProtocolError.malformedProtobuf }
            let byte = data.byte(at: offset)
            offset += 1
            guard shift != 63 || byte <= 1 else { throw LunaProtocolError.malformedProtobuf }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw LunaProtocolError.malformedProtobuf
    }
}
