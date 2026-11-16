import Foundation

/// The phone's IPv4 subnet on a station network, as a bounded list of hosts to look for cameras
/// on. Kotlin twin: `StationSubnet`.
public enum StationSubnet {
    /// Every unicast host of `address`'s subnet except `address` and `excluding`, in address
    /// order; nil for a malformed address or mask, a non-contiguous mask, or a subnet with more
    /// than 1,022 hosts or fewer than two.
    public static func hosts(address: String, mask: String, excluding: Set<String> = [])
        -> [String]?
    {
        guard let ip = parse(address), let netmask = parse(mask) else { return nil }
        let hostBits = ~netmask
        guard hostBits > 1, hostBits <= 1023, hostBits & (hostBits &+ 1) == 0 else { return nil }
        let network = ip & netmask
        return (1..<hostBits).compactMap { offset in
            let value = network | offset
            let host = [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
            return value == ip || excluding.contains(host) ? nil : host
        }
    }

    /// A dotted IPv4 unicast address a camera can hold: not 0.x, loopback or multicast and above.
    public static func validAddress(_ value: String) -> Bool {
        guard let address = parse(value) else { return false }
        let first = address >> 24
        return first > 0 && first < 224 && first != 127
    }

    private static func parse(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let byte = UInt8(part)
            else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
