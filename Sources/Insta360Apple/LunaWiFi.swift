import CKcp
import Darwin
import Foundation
import OpenCineCore
import NetworkExtension


/// Qualification limit (STATE-01): one joined camera access point (192.168.42.x) per phone, so
/// these addresses are process-wide. Sessions own everything else; two simultaneous Luna
/// connections stay unsupported until this is lifted and qualified on hardware.
@MainActor
enum LunaWiFi {
    static var localAddress: String? {
        if cameraAddresses.contains(screenAddress) { return screenAddress }
        return cameraAddresses.first
    }
    static var cameraInterface: String? { cameraLink?.interface }
    static var cameraMAC: [UInt8]? { cameraLink?.mac }

    private static var cameraAddresses: [String] { cameraLink?.addresses ?? [] }

    private static var cameraLink: (addresses: [String], interface: String, mac: [UInt8]?)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(first) }
        var ips: [String: [String]] = [:]
        var macs: [String: [UInt8]] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let ifname = String(cString: current.pointee.ifa_name)
            guard let addr = current.pointee.ifa_addr else { continue }
            if addr.pointee.sa_family == UInt8(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
                    NI_NUMERICHOST) == 0
                {
                    let text = String(cString: buffer)
                    if text.hasPrefix("192.168.42."), text != "192.168.42.1" {
                        ips[ifname, default: []].append(text)
                    }
                }
            } else if addr.pointee.sa_family == UInt8(AF_LINK) {
                let dl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                let nlen = Int(dl.sdl_nlen)
                let alen = Int(dl.sdl_alen)
                if alen == 6 {
                    withUnsafeBytes(of: dl.sdl_data) { bytes in
                        macs[ifname] = Array(bytes.dropFirst(nlen).prefix(6))
                    }
                }
            }
        }
        guard let name = ips.keys.first, let found = ips[name], !found.isEmpty else { return nil }
        return (found, name, macs[name])
    }
    /// `apply` is the backend's scoped hotspot owner; nil keeps the original direct call.
    /// `prompt` is pending from the system request until iOS answers it.
    static func join(
        _ credentials: LunaStoredWiFi, joinOnce: Bool = false, logPrefix: String,
        apply: (@MainActor (CameraHotspotConfiguration) async throws -> Void)? = nil,
        prompt: LunaJoinPrompt? = nil, reachable: (@MainActor () -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        #if targetEnvironment(macCatalyst) || os(macOS)
            guard localAddress != nil else {
                throw ConnectionFailure.luna(
                    .joinFailed, "wifi.join-manually",
                    "Join the camera Wi-Fi in macOS Wi-Fi settings, then reconnect. Its password has been read securely from the camera.",
                    phase: .joiningNetwork)
            }
        #elseif targetEnvironment(simulator)
            guard localAddress != nil else {
                throw ConnectionFailure.luna(
                    .joinFailed, "wifi.join-on-host",
                    "Join the camera Wi-Fi on the Mac to test the live feed in Simulator. Bluetooth pairing requires a physical device.",
                    phase: .joiningNetwork)
            }
        #else
            // Until iOS answers this request its Join alert may be up; `prompt` holds the
            // attempt's timeout meanwhile (not the address wait below).
            do {
                prompt?.begin()
                defer { prompt?.end() }
                if let apply {
                    do {
                        try await apply(.init(selection: .ssid(credentials.ssid),
                            security: .personal(passphrase: credentials.password), joinOnce: joinOnce))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if let failure = applyFailure(
                            error, network: credentials.ssid, logPrefix: logPrefix)
                        { throw failure }
                    }
                } else {
                    let config = NEHotspotConfiguration(
                        ssid: credentials.ssid, passphrase: credentials.password, isWEP: false)
                    config.joinOnce = joinOnce
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Void, Error>) in
                        NEHotspotConfigurationManager.shared.apply(config) { error in
                            if let error, let failure = applyFailure(
                                error, network: credentials.ssid, logPrefix: logPrefix)
                            {
                                continuation.resume(throwing: failure)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        #endif
        let deadline = Date().addingTimeInterval(18)
        while localAddress == nil, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        guard localAddress != nil else {
            throw ConnectionFailure.luna(
                .joinFailed, "wifi.no-address",
                "The camera Wi-Fi did not assign an address. Reconnect and accept the Wi-Fi join prompt.",
                phase: .joiningNetwork)
        }
        // The camera network is reachable now, before the screen-address claim.
        reachable?()
        await claimScreenAddress(logPrefix: logPrefix)
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// "Already associated" is success; any other refusal uses the shared copy and actions.
    private nonisolated static func applyFailure(
        _ error: Error, network: String, logPrefix: String
    ) -> ConnectionFailure? {
        if let refusal = error as? CameraHotspotJoinRefusal {
            return failure(for: refusal, logPrefix: logPrefix)
        }
        let platformError = error as NSError
        if platformError.domain == NEHotspotConfigurationErrorDomain,
            platformError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
        {
            return nil
        }
        if let refusal = CameraHotspotJoinRefusal(error: platformError, network: network) {
            return failure(for: refusal, logPrefix: logPrefix)
        }
        NSLog("%@ luna: hotspot apply failed %@ %d", logPrefix, platformError.domain, platformError.code)
        return ConnectionFailure.luna(
            .joinFailed, "wifi.join-refused",
            "The camera Wi-Fi could not be joined. Keep the camera powered on and accept the iOS Wi-Fi prompt.",
            phase: .joiningNetwork)
    }

    /// The raw platform code stays in the journal as a closed token; operator copy is shared.
    private nonisolated static func failure(
        for refusal: CameraHotspotJoinRefusal, logPrefix: String
    ) -> ConnectionFailure? {
        guard refusal.reason != .alreadyAssociated else { return nil }
        NSLog("%@ luna: %@", logPrefix, refusal.diagnosticsCode)
        return refusal.failure(integration: LunaCameraSession.integration)
    }
    #endif

    /// DHCP-request 192.168.42.253, then ioctl alias. Keep the DHCP address so
    /// the video TCP socket is not torn down.
    @discardableResult
    static func claimScreenAddress(logPrefix: String) async -> Bool {
        if holdsScreenAddress { return true }
        guard let name = cameraInterface else { return false }
        var dhcpNote = "skipped"
        if let mac = cameraMAC, mac.count == 6 {
            let requested = screenAddress
            let dhcp = await Task.detached(priority: .userInitiated) {
                LunaDHCP.requestScreenAddress(interface: name, mac: mac, requested: requested)
            }.value
            dhcpNote =
                "port=\(dhcp.discoverPort) offer=\(dhcp.offer) ack=\(dhcp.ack) yiaddr=\(dhcp.yiaddr) server=\(dhcp.server)"
            NSLog("%@ wifi: dhcp %@", logPrefix, dhcpNote)
        } else {
            NSLog("%@ wifi: no MAC for DHCP on %@", logPrefix, name)
        }
        let result = name.withCString { ifname in
            screenAddress.withCString { ip in
                "255.255.255.0".withCString { mask in
                    luna_add_ipv4_alias(ifname, ip, mask)
                }
            }
        }
        NSLog(
            "%@ wifi: ioctl alias \(screenAddress) on \(name) rc=%d held=%@ addrs=%@ dhcp=%@",
            logPrefix, result, holdsScreenAddress ? "yes" : "no", cameraAddresses.joined(separator: ","),
            dhcpNote)
        let payload: [String: Any] = [
            "utc": ISO8601DateFormatter().string(from: Date()),
            "interface": name,
            "mac": (cameraMAC ?? []).map { String(format: "%02x", $0) }.joined(separator: ":"),
            "dhcp": dhcpNote,
            "ioctl": result,
            "held": holdsScreenAddress,
            "addresses": cameraAddresses,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("dhcp-claim.json")
        {
            try? data.write(to: url, options: .atomic)
        }
        return holdsScreenAddress
    }
    /// The camera only ever invites the detachable screen's address, so a client
    /// that wants the screen RPC has to be at that address. Verified 2026-09-17:
    /// on an ordinary DHCP lease the camera sends no invitation at all, so there
    /// is no conversation to prime and Color Recovery cannot be set.
    static let screenAddress = "192.168.42.253"

    static var holdsScreenAddress: Bool { cameraAddresses.contains(screenAddress) }

    /// Nil when the address is already held, otherwise what the operator must do.
    /// The app cannot set this itself: Process is unavailable on Mac Catalyst and
    /// iOS offers no API for a manual address, so this matches how joining the
    /// camera Wi-Fi is already handled on macOS.
    static func screenAddressInstruction() -> String? {
        if holdsScreenAddress { return nil }
        guard localAddress != nil else { return "Join the camera Wi-Fi first." }
        #if targetEnvironment(macCatalyst) || os(macOS)
            return
                "In System Settings, Wi-Fi, Details for the camera network, set TCP/IP to "
                + "Configure IPv4 Manually with address \(screenAddress), mask 255.255.255.0, "
                + "router 192.168.42.1. Then reconnect."
        #else
            return
                "In Settings, Wi-Fi, the camera network, Configure IP, set Manual with address "
                + "\(screenAddress), mask 255.255.255.0, router 192.168.42.1. Then reconnect."
        #endif
    }

    /// `remove` is the backend's hotspot owner; nil keeps the original direct call.
    static func leave(ssid: String, remove: (@MainActor (String) -> Void)? = nil) {
        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            if let remove { remove(ssid) } else {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
        #endif
    }
}
