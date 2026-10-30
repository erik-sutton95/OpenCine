import Darwin
import Foundation
import Insta360Protocol
import Network
import NetworkExtension
import OpenCineCore

/// The phone's side of a Wi-Fi or hotspot setup: this phone on the network the camera joined, and
/// the camera found there. A camera in station role has no fixed address (firmware 1.1.15 reports
/// none over Bluetooth), so the phone's subnet is searched for the Luna control port answering the
/// UCD2 greeting; the control link then checks the camera's serial against the one Bluetooth read.
@MainActor
enum LunaStationPath {
    /// One IPv4 interface address with its netmask.
    struct Address: Equatable, Sendable {
        var address: String
        var netmask: String
    }

    /// This phone's address on the Personal Hotspot it hosts (`bridge*`/`ap*`) or on Wi-Fi (`en0`).
    static func address(hotspot: Bool) -> Address? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            let matches = hotspot ? (name.hasPrefix("bridge") || name.hasPrefix("ap")) : name == "en0"
            guard matches, item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                let mask = item.pointee.ifa_netmask,
                let text = numeric(address), let maskText = numeric(mask),
                !text.hasPrefix("169.254."), !text.hasPrefix("192.168.42.")
            else { continue }
            return Address(address: text, netmask: maskText)
        }
        return nil
    }

    private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
            getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                NI_NUMERICHOST) == 0
        else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The hosts to search on this phone's network, nearest first: the whole subnet when it is a
    /// /24 or smaller (a Personal Hotspot is a /28), otherwise the phone's own /24. Never the
    /// phone itself, the network or the broadcast address.
    nonisolated static func candidates(around address: Address) -> [String] {
        func value(_ text: String) -> UInt32? {
            var raw = in_addr()
            guard inet_pton(AF_INET, text, &raw) == 1 else { return nil }
            return UInt32(bigEndian: raw.s_addr)
        }
        guard let own = value(address.address), let mask = value(address.netmask) else { return [] }
        let searched = mask.nonzeroBitCount >= 24 ? mask : 0xFFFF_FF00
        let network = own & searched
        let broadcast = network | ~searched
        guard broadcast > network + 1 else { return [] }
        let hosts = (network + 1..<broadcast).filter { $0 != own }
        return hosts.sorted { $0.distance(to: own).magnitude < $1.distance(to: own).magnitude }
            .map { "\($0 >> 24).\($0 >> 16 & 0xFF).\($0 >> 8 & 0xFF).\($0 & 0xFF)" }
    }

    /// Puts this phone on `network` (a router's Wi-Fi; a hotspot is this phone's own) and returns
    /// its address there. Uses the app's scoped hotspot owner when it has one.
    static func joinPhone(
        to network: LunaStationNetwork, logPrefix: String,
        apply: (@MainActor (CameraHotspotConfiguration) async throws -> Void)?
    ) async throws -> Address {
        if network.hotspot {
            let deadline = Date().addingTimeInterval(5)
            while address(hotspot: true) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            guard let hosted = address(hotspot: true) else {
                throw ConnectionFailure.luna(
                    .joinFailed, "station.hotspot-off",
                    "Turn on Personal Hotspot in Settings, keep that page open, then connect again.",
                    phase: .joiningNetwork, actions: [.openSettings, .retry])
            }
            return hosted
        }
        if await currentSSID() != network.ssid {
            #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
                let security: CameraHotspotConfiguration.Security =
                    network.password.isEmpty ? .open : .personal(passphrase: network.password)
                let configuration = CameraHotspotConfiguration(
                    selection: .ssid(network.ssid), security: security, joinOnce: false)
                do {
                    if let apply {
                        try await apply(configuration)
                    } else {
                        let config =
                            network.password.isEmpty
                            ? NEHotspotConfiguration(ssid: network.ssid)
                            : NEHotspotConfiguration(
                                ssid: network.ssid, passphrase: network.password, isWEP: false)
                        config.joinOnce = false
                        try await NEHotspotConfigurationManager.shared.apply(config)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let platform = error as NSError
                    let refusal =
                        error as? CameraHotspotJoinRefusal
                        ?? CameraHotspotJoinRefusal(error: platform, network: network.ssid)
                    let associated =
                        refusal?.reason == .alreadyAssociated
                        || (platform.domain == NEHotspotConfigurationErrorDomain
                            && platform.code == NEHotspotConfigurationError.alreadyAssociated.rawValue)
                    if !associated {
                        NSLog("%@ luna: station join failed %@ %d", logPrefix, platform.domain, platform.code)
                        throw ConnectionFailure.luna(
                            .joinFailed, "station.phone-join",
                            "This iPhone could not join “\(network.ssid)”. Join it in Settings › Wi-Fi, then connect again.",
                            phase: .joiningNetwork, actions: [.openSettings, .retry])
                    }
                }
            #endif
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let name = await currentSSID()
            if let joined = address(hotspot: false), name == nil || name == network.ssid { return joined }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ConnectionFailure.luna(
            .joinFailed, "station.phone-not-joined",
            "This iPhone is not on “\(network.ssid)”. Join it in Settings › Wi-Fi, then connect again.",
            phase: .joiningNetwork, actions: [.openSettings, .retry])
    }

    /// This phone's Wi-Fi name; nil when iOS withholds it (no location permission) or off Wi-Fi.
    static func currentSSID() async -> String? {
        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            await NEHotspotNetwork.fetchCurrent()?.ssid
        #else
            nil
        #endif
    }

    /// The first host answering the Luna control port with a UCD2 frame, searched in rounds until
    /// `budget` runs out; `preferred` (an address the camera reported) is tried first.
    static func findCamera(
        on local: Address, preferred: String?, budget: Duration, isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> String? {
        let hosts = (preferred.map { [$0] } ?? []) + candidates(around: local).filter { $0 != preferred }
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            for batch in stride(from: 0, to: hosts.count, by: 32).map({ Array(hosts[$0..<min($0 + 32, hosts.count)]) }) {
                let found = await withTaskGroup(of: String?.self) { group in
                    for host in batch {
                        group.addTask { await probe(host, local: local.address) ? host : nil }
                    }
                    for await host in group where host != nil {
                        group.cancelAll()
                        return host
                    }
                    return nil
                }
                if let found { return found }
                try Task.checkCancellation()
            }
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    /// Connects to `host`:6666 from `local`, sends the preface and waits up to 2.5 s for a frame
    /// that starts with the UCD2 magic (the camera answers slowly in Wi-Fi power save).
    nonisolated static func probe(_ host: String, local: String) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(local), port: .any)
        parameters.includePeerToPeer = false
        let connection = NWConnection(
            host: .init(host), port: .init(rawValue: LunaProtocol.defaultPort)!, using: parameters)
        let queue = DispatchQueue(label: "luna.station.probe")
        let answered: Bool = await withCheckedContinuation { continuation in
            let once = ProbeOnce(continuation)
            queue.asyncAfter(deadline: .now() + 3.2) { once.finish(false) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: LunaProtocol.tcpPreface, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 64) { data, _, _, _ in
                        once.finish(data.map { $0.prefix(4) == Data("UCD2".utf8) } ?? false)
                    }
                case .failed, .cancelled: once.finish(false)
                case .waiting: once.finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.cancel()
        return answered
    }
}

/// Resumes a probe's continuation exactly once.
private final class ProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
