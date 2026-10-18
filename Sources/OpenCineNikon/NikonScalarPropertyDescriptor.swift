import Foundation

/// Exact scalar descriptor facts reported by one Nikon property read.
/// Parsing does not establish a property meaning, current owner or permission to write.
public struct NikonScalarPropertyDescriptor: Equatable, Sendable {
    /// The reported range or enumeration, retaining the original scalar bytes.
    public enum Form: Equatable, Sendable {
        /// No range or enumeration was advertised.
        case none
        /// The reported minimum, maximum and step.
        case range(minimum: [UInt8], maximum: [UInt8], step: [UInt8])
        /// The reported values in camera order, including unknown values.
        case enumeration([[UInt8]])
    }

    /// Exact full property identity, never a truncated extended alias.
    public let property: UInt32
    /// UINT8, UINT16, UINT32 or UINT64 scalar width.
    public let valueByteCount: Int
    /// The body's GetSet flag, independent of its current operational admission.
    public let writable: Bool
    /// Factory value reported in the descriptor.
    public let defaultValue: [UInt8]
    /// Current value reported in the descriptor; later value readback may differ.
    public let currentValue: [UInt8]
    /// Exact declared form and values.
    public let form: Form

    /// Parses the existing standard or extended scalar dataset with exact identity, type,
    /// GetSet, form and length checks. Read-only observations remain readable observations.
    public static func parse(
        _ data: Data, property: UInt32, valueByteCount: Int
    ) -> Self? {
        let bytes = [UInt8](data)
        let type: UInt16
        switch valueByteCount {
        case 1: type = 0x0002
        case 2: type = 0x0004
        case 4: type = 0x0006
        case 8: type = 0x0008
        default: return nil
        }
        guard bytes.count >= 7 else { return nil }
        let header: Int
        if ByteCoding.readUInt32LE(bytes, at: 0) == property,
            ByteCoding.readUInt16LE(bytes, at: 4) == type, bytes[6] <= 1,
            bytes.count > 7 + valueByteCount * 2
        {
            header = 7
        } else if property <= UInt32(UInt16.max),
            UInt32(ByteCoding.readUInt16LE(bytes, at: 0)) == property,
            ByteCoding.readUInt16LE(bytes, at: 2) == type, bytes[4] <= 1,
            bytes.count > 5 + valueByteCount * 2
        {
            header = 5
        } else {
            return nil
        }
        let index = header + valueByteCount * 2
        let start = index + 1
        let form: Form
        switch bytes[index] {
        case 0:
            guard start == bytes.count else { return nil }
            form = .none
        case 1:
            guard start + valueByteCount * 3 == bytes.count else { return nil }
            form = .range(
                minimum: Array(bytes[start..<(start + valueByteCount)]),
                maximum: Array(bytes[(start + valueByteCount)..<(start + valueByteCount * 2)]),
                step: Array(bytes[(start + valueByteCount * 2)..<bytes.count]))
        case 2:
            guard start + 2 <= bytes.count else { return nil }
            let count = Int(ByteCoding.readUInt16LE(bytes, at: start))
            let valuesStart = start + 2
            guard valuesStart + count * valueByteCount == bytes.count else { return nil }
            form = .enumeration(
                (0..<count).map { item in
                    let valueStart = valuesStart + item * valueByteCount
                    return Array(bytes[valueStart..<(valueStart + valueByteCount)])
                })
        default: return nil
        }
        return Self(
            property: property, valueByteCount: valueByteCount, writable: bytes[header - 1] == 1,
            defaultValue: Array(bytes[header..<(header + valueByteCount)]),
            currentValue: Array(bytes[(header + valueByteCount)..<index]), form: form)
    }
}
