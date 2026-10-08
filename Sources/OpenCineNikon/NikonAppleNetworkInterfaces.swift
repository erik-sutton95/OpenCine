#if canImport(Darwin)
    import Darwin
    import Foundation

    /// Apple interface facts used by Nikon discovery and camera-network guidance. Reads the OS
    /// snapshot only; it never joins a network, requests permission or probes a camera.
    public enum NikonAppleNetworkInterfaces {
        /// Up, non-loopback private IPv4 interfaces in the OS's original order, including its
        /// supplied netmask when the existing numeric-address filter admits one.
        public static func snapshot() -> [NikonLocalInterface] {
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
            defer { freeifaddrs(interfaces) }

            var addresses: [NikonLocalInterface] = []
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let interface = cursor {
                defer { cursor = interface.pointee.ifa_next }
                guard let socketAddress = interface.pointee.ifa_addr,
                    admitsIPv4(
                        flags: interface.pointee.ifa_flags, family: socketAddress.pointee.sa_family),
                    let address = numericIPv4Address(
                        from: socketAddress, length: socklen_t(socketAddress.pointee.sa_len))
                else { continue }
                let netmask = interface.pointee.ifa_netmask.flatMap {
                    numericIPv4Address(from: $0, length: socklen_t($0.pointee.sa_len))
                }
                addresses.append(
                    NikonLocalInterface(
                        name: String(cString: interface.pointee.ifa_name), address: address,
                        netmask: netmask))
            }
            return addresses
        }

        /// Whether the live snapshot includes a Personal Hotspot bridge interface.
        public static func isPersonalHotspotActive() -> Bool {
            snapshot().contains { $0.name.hasPrefix("bridge") }
        }

        /// Distinct /24 bases of this device's current Personal Hotspot interfaces, in OS order.
        public static func hotspotSubnetBases() -> [String] {
            hotspotSubnetBases(in: snapshot())
        }

        /// Operator-readable subnet of the first interface admitted by Nikon's existing scan policy.
        public static func currentScanSubnetLabel() -> String? {
            currentScanSubnetLabel(in: snapshot())
        }

        /// The AWDL radio fact used by existing camera-network staging. A simulator has no radio of
        /// its own and reads as on; a failed OS snapshot likewise never blocks a join.
        public static func isWiFiRadioOn() -> Bool {
            #if targetEnvironment(simulator)
                return true
            #else
                var interfaces: UnsafeMutablePointer<ifaddrs>?
                guard getifaddrs(&interfaces) == 0, let first = interfaces else { return true }
                defer { freeifaddrs(interfaces) }
                var cursor: UnsafeMutablePointer<ifaddrs>? = first
                while let interface = cursor {
                    defer { cursor = interface.pointee.ifa_next }
                    if isWiFiRadioInterface(
                        name: String(cString: interface.pointee.ifa_name),
                        flags: interface.pointee.ifa_flags)
                    {
                        return true
                    }
                }
                return false
            #endif
        }

        static func admitsIPv4(flags: UInt32, family: sa_family_t) -> Bool {
            let flags = Int32(bitPattern: flags)
            return (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
                && family == sa_family_t(AF_INET)
        }

        static func isWiFiRadioInterface(name: String, flags: UInt32) -> Bool {
            let flags = Int32(bitPattern: flags)
            return name.hasPrefix("awdl") && (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
        }

        static func hotspotSubnetBases(in interfaces: [NikonLocalInterface]) -> [String] {
            var bases: [String] = []
            var seen: Set<String> = []
            for interface in interfaces where interface.name.hasPrefix("bridge") {
                guard let base = CameraDiscovery.subnetBase(for: interface.address),
                    seen.insert(base).inserted
                else { continue }
                bases.append(base)
            }
            return bases
        }

        static func currentScanSubnetLabel(in interfaces: [NikonLocalInterface]) -> String? {
            guard
                let address = interfaces.first(where: {
                    CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address)
                })?.address
            else { return nil }
            let octets = address.split(separator: ".")
            guard octets.count == 4 else { return nil }
            return octets.prefix(3).joined(separator: ".") + ".x"
        }

        /// The same numeric private-IPv4 admission used for interfaces and resolved Bonjour addresses.
        static func ipv4Address(from data: Data) -> String? {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            return data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                return numericIPv4Address(from: address, length: socklen_t(data.count))
            }
        }

        private static func numericIPv4Address(
            from socketAddress: UnsafePointer<sockaddr>, length: socklen_t
        ) -> String? {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { return nil }
            let address = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return CameraDiscovery.isPrivateIPv4(address) ? address : nil
        }
    }
#endif
