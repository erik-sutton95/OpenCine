import Foundation

/// One IPv4 interface of the computer the app runs on, as the station route sees it.
public struct HostInterface: Equatable, Sendable {
    public var name: String
    public var ipv4: String
    public var prefixLength: Int
    public var isUp: Bool
    /// Whether the system's default route leaves through this interface.
    public var carriesDefaultRoute: Bool

    public init(name: String, ipv4: String, prefixLength: Int, isUp: Bool, carriesDefaultRoute: Bool) {
        self.name = name
        self.ipv4 = ipv4
        self.prefixLength = prefixLength
        self.isUp = isUp
        self.carriesDefaultRoute = carriesDefaultRoute
    }

    /// The dotted netmask of `prefixLength`.
    public var netmask: String {
        let bits = min(max(prefixLength, 0), 32)
        let mask: UInt32 = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
        return "\(mask >> 24).\(mask >> 16 & 0xFF).\(mask >> 8 & 0xFF).\(mask & 0xFF)"
    }
}

/// Which interfaces of a computer lead to the cameras' network: Wi-Fi or Ethernet on a private
/// IPv4 subnet, never a tunnel, a peer-to-peer link or a bridge it hosts. A computer may be on the
/// router by Wi-Fi, by Ethernet, or both; a VPN may own the default route.
public enum HostInterfacePick {
    /// Name prefixes that never reach a camera on the local network: VPN tunnels, AirDrop and
    /// low-latency peer links, bridges and hosted access points, Apple's internal network, the
    /// IPv6 transition tunnels and loopback.
    private static let skippedPrefixes = ["utun", "ipsec", "awdl", "llw", "bridge", "anpi", "ap", "gif", "stf", "lo"]

    /// The up interfaces on a private IPv4 subnet (10/8, 172.16/12, 192.168/16), the default
    /// route's first, then by name.
    public static func stationInterfaces(_ all: [HostInterface]) -> [HostInterface] {
        all.filter { iface in
            guard iface.isUp, let address = value(iface.ipv4) else { return false }
            guard !skippedPrefixes.contains(where: { iface.name.hasPrefix($0) }) else { return false }
            return isPrivate(address)
        }
        .sorted {
            $0.carriesDefaultRoute != $1.carriesDefaultRoute ? $0.carriesDefaultRoute : $0.name < $1.name
        }
    }

    /// The hosts to search from `iface`, in address order: its whole subnet when that is a /24 or
    /// narrower, otherwise its own /24. Never the interface itself, the network or the broadcast.
    public static func sweepHosts(_ iface: HostInterface) -> [String] {
        guard let own = value(iface.ipv4) else { return [] }
        let mask = mask(max(iface.prefixLength, 24))
        let network = own & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return (network + 1..<broadcast).filter { $0 != own }.map(text)
    }

    /// The interface whose subnet holds `host`: the one a link to a camera found there leaves by.
    public static func interface(reaching host: String, in interfaces: [HostInterface]) -> HostInterface? {
        guard let target = value(host) else { return nil }
        return interfaces.first { iface in
            guard let own = value(iface.ipv4) else { return false }
            let mask = mask(iface.prefixLength)
            return own & mask == target & mask
        }
    }

    private static func isPrivate(_ address: UInt32) -> Bool {
        address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8
    }

    private static func mask(_ prefix: Int) -> UInt32 {
        let bits = min(max(prefix, 0), 32)
        return bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
    }

    private static func value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            result = result << 8 | UInt32(byte)
        }
        return result
    }

    private static func text(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
}
