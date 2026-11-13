#if os(iOS)
import Darwin
import Foundation
import NetworkExtension
import OpenCineCore
import os

/// This phone's side of the shared station network on iOS: its IPv4 address and netmask on Wi-Fi
/// (`en0`) or on the Personal Hotspot it hosts (`bridge*`/`ap*`), and joining a router's Wi-Fi
/// with `NEHotspotConfiguration`. The Multiview coordinator and the integrations use it through
/// Core's `StationHostPath`. Android twin: `SharedWiFiPath` in `:platform`.
@MainActor
public final class SharedWiFiPath: StationHostPath {
    public init() {}

    /// Unicast IPv4, not loopback.
    public nonisolated static func validAddress(_ value: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return false }
        let first = UInt8(truncatingIfNeeded: UInt32(bigEndian: address.s_addr) >> 24)
        return first > 0 && first < 224 && first != 127
    }

    public func address(hotspot: Bool) -> String? {
        Self.interfaceAddress(netmask: false, hotspot: hotspot)
    }

    public func netmask(hotspot: Bool) -> String? {
        Self.interfaceAddress(netmask: true, hotspot: hotspot)
    }

    public func join(_ network: StationNetwork) async throws -> String? {
        if network.hotspot { return address(hotspot: true) }
        let ssid = network.ssid
        if await Self.currentSSID() != ssid {
            let config =
                network.password.isEmpty
                ? NEHotspotConfiguration(ssid: ssid)
                : NEHotspotConfiguration(ssid: ssid, passphrase: network.password, isWEP: false)
            config.joinOnce = false
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error,
                        (error as NSError).code
                            != NEHotspotConfigurationError.alreadyAssociated.rawValue
                    {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        // iOS applied the join. It names the network only with location permission (or for
        // networks this app configured); an unnamed Wi-Fi address is accepted too.
        func joined() async -> Bool {
            let current = await Self.currentSSID()
            return current == ssid || (current == nil && address(hotspot: false) != nil)
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if await joined(), address(hotspot: false) != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard await joined() else { return nil }
        return address(hotspot: false)
    }

    /// This phone's Wi-Fi name, nil when iOS withholds it (no permission, the simulator) or does
    /// not answer within three seconds.
    private static func currentSSID() async -> String? {
        #if targetEnvironment(simulator)
            return nil
        #else
            let once = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: nil)
            return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                once.withLock { $0 = continuation }
                let finish: @Sendable (String?) -> Void = { value in
                    once.withLock { pending -> CheckedContinuation<String?, Never>? in
                        defer { pending = nil }
                        return pending
                    }?.resume(returning: value)
                }
                NEHotspotNetwork.fetchCurrent { network in finish(network?.ssid) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
            }
        #endif
    }

    private static func interfaceAddress(netmask: Bool, hotspot: Bool) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }
        defer { freeifaddrs(pointer) }
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            let matches =
                hotspot ? (name.hasPrefix("bridge") || name.hasPrefix("ap")) : name == "en0"
            guard matches, item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let address = netmask ? item.pointee.ifa_netmask : item.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host,
                socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            {
                return String(cString: host)
            }
        }
        return nil
    }
}
#endif
