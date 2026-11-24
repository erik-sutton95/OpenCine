#if canImport(Darwin)
    import Foundation

    /// This device's IPv4 interfaces as the station route reads them (`HostInterfacePick` chooses
    /// among them). Apple platforms only: the integrations and the app shell share this one reader.
    public enum HostInterfaces {
        /// Every IPv4 interface address, up and running or not, marked where the default route
        /// leaves.
        public static func current() -> [HostInterface] {
            var pointer: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
            defer { freeifaddrs(first) }
            let route = defaultRouteAddress()
            var result: [HostInterface] = []
            var current: UnsafeMutablePointer<ifaddrs>? = first
            while let item = current {
                defer { current = item.pointee.ifa_next }
                guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { dotted($0.pointee.sin_addr) }
                let mask =
                    item.pointee.ifa_netmask.map {
                        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    } ?? 0
                let flags = Int32(item.pointee.ifa_flags)
                result.append(
                    HostInterface(
                        name: String(cString: item.pointee.ifa_name), ipv4: ipv4, prefixLength: mask.nonzeroBitCount,
                        isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0, carriesDefaultRoute: ipv4 == route))
            }
            return result
        }

        /// The local address the default route uses: a UDP socket connected to a documentation
        /// address (RFC 5737; connecting a UDP socket sends nothing) reports it.
        static func defaultRouteAddress() -> String? {
            let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard socket >= 0 else { return nil }
            defer { close(socket) }
            var remote = sockaddr_in()
            remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_port = UInt16(53).bigEndian
            guard inet_pton(AF_INET, "192.0.2.1", &remote.sin_addr) == 1 else { return nil }
            let connected = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return nil }
            var local = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
            }
            guard named == 0 else { return nil }
            return dotted(local.sin_addr)
        }

        private static func dotted(_ address: in_addr) -> String {
            let value = UInt32(bigEndian: address.s_addr)
            return "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
        }
    }
#endif
