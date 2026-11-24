import Darwin
import Foundation
import Insta360Protocol
import Network
import NetworkExtension
import OpenCineCore

/// The phone's side of a Wi-Fi or hotspot setup: this phone on the network the camera joined, and
/// the camera found there. A camera in station role has no fixed address (firmware 1.1.15 reports
/// none over Bluetooth), so the phone's subnet is searched for the Luna control port answering the
/// UCD2 greeting; the control link then checks the camera's serial against the one Bluetooth read,
/// and another camera on the same network is skipped.
@MainActor
enum LunaStationPath {
    /// One IPv4 interface address with its netmask.
    struct Address: Equatable, Sendable {
        var address: String
        var netmask: String
    }

    /// This phone's address on the Personal Hotspot it hosts (`bridge*`/`ap*`) or on Wi-Fi (`en0`).
    /// On a Mac: its first interface on a private network (Wi-Fi or Ethernet, the default route's
    /// first).
    static func address(hotspot: Bool) -> Address? {
        #if targetEnvironment(macCatalyst)
            if !hotspot { return stationAddresses(hotspot: false).first }
        #endif
        return interfaceAddress(hotspot: hotspot)
    }

    /// Every network to search for a camera: on a Mac each interface on a private network, the
    /// default route's first; elsewhere this phone's one address.
    static func stationAddresses(hotspot: Bool) -> [Address] {
        #if targetEnvironment(macCatalyst)
            if !hotspot {
                return HostInterfacePick.stationInterfaces(HostInterfaces.current()).map {
                    Address(address: $0.ipv4, netmask: $0.netmask)
                }
            }
        #endif
        return interfaceAddress(hotspot: hotspot).map { [$0] } ?? []
    }

    /// This device's address toward `host`: on a Mac, the interface on that host's subnet.
    static func address(hotspot: Bool, toward host: String) -> Address? {
        #if targetEnvironment(macCatalyst)
            if !hotspot {
                let interfaces = HostInterfacePick.stationInterfaces(HostInterfaces.current())
                if let iface = HostInterfacePick.interface(reaching: host, in: interfaces) {
                    return Address(address: iface.ipv4, netmask: iface.netmask)
                }
            }
        #endif
        return address(hotspot: hotspot)
    }

    private static func interfaceAddress(hotspot: Bool) -> Address? {
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
        #if targetEnvironment(macCatalyst)
            // A Mac does not join: it is on the network by Wi-Fi or Ethernet already, and its
            // Wi-Fi name says nothing about an Ethernet link to the same router.
            guard let local = address(hotspot: false) else {
                throw ConnectionFailure.luna(
                    .joinFailed, "station.host-off-network", StationCopy.noStationNetwork,
                    phase: .joiningNetwork, actions: [.retry])
            }
            return local
        #else
            return try await joinNetwork(network, logPrefix: logPrefix, apply: apply)
        #endif
    }

    private static func joinNetwork(
        _ network: LunaStationNetwork, logPrefix: String,
        apply: (@MainActor (CameraHotspotConfiguration) async throws -> Void)?
    ) async throws -> Address {
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

    /// What one host on the setup's network answered.
    enum ProbeResult: Equatable, Sendable {
        /// The Luna control port answered with a UCD2 frame.
        case camera
        /// Nothing answered, or something that is not a Luna.
        case absent
        /// iOS held the connection back: Local Network access is off for this app.
        case localNetworkDenied
    }

    /// The first host answering the Luna control port with a UCD2 frame, searched in rounds until
    /// `budget` runs out (checked after every batch); `preferred` (an address the camera reported)
    /// is tried first and hosts in `excluding` are never probed. Nil when no host answered. When
    /// the last round was held back by iOS's Local Network permission, that is the failure
    /// instead: the search keeps going while the first-run prompt is on screen, so allowing it
    /// there still finds the camera.
    static func findCamera(
        on local: Address, preferred: String?, budget: Duration, excluding: Set<String> = [],
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> String? {
        try await findCamera(
            on: local, preferred: preferred, budget: budget, excluding: excluding, isCurrent: isCurrent,
            clock: .live, probe: { host, local in await probe(host, local: local) })
    }

    /// ``findCamera(on:preferred:budget:excluding:isCurrent:)`` with `probe` answering for each
    /// host and the search time and the pause between rounds on `clock`.
    static func findCamera(
        on local: Address, preferred: String?, budget: Duration, excluding: Set<String> = [],
        isCurrent: @escaping @MainActor () -> Bool,
        clock: HostClock, probe: @escaping @Sendable (_ host: String, _ local: String) async -> ProbeResult
    ) async throws -> String? {
        try await findCamera(
            on: [local], preferred: preferred, budget: budget, excluding: excluding, isCurrent: isCurrent,
            clock: clock, probe: probe)?.host
    }

    /// A camera found on one of this device's networks, and this device's address on that network.
    struct Found: Equatable, Sendable {
        var host: String
        /// This device's address on the camera's network: the link to the camera leaves from it.
        var local: String
    }

    /// The hosts to search on every network in `locals` (in that order, nearest first within
    /// each), each with the address it is dialled from; `preferred` first, from the network that
    /// holds it (else the first), and none twice.
    nonisolated static func searchOrder(_ locals: [Address], preferred: String?) -> [Found] {
        let networks = locals.map { ($0, candidates(around: $0)) }
        var order: [Found] = []
        if let preferred, let first = locals.first {
            let local = networks.first { $0.1.contains(preferred) }?.0 ?? first
            order.append(Found(host: preferred, local: local.address))
        }
        var seen = Set(order.map(\.host))
        for (local, hosts) in networks {
            for host in hosts where seen.insert(host).inserted {
                order.append(Found(host: host, local: local.address))
            }
        }
        return order
    }

    /// ``findCamera(on:preferred:budget:excluding:isCurrent:clock:probe:)`` over every network in
    /// `locals` (a computer on Wi-Fi and Ethernet), the first listed searched first in each round.
    static func findCamera(
        on locals: [Address], preferred: String?, budget: Duration, excluding: Set<String> = [],
        isCurrent: @escaping @MainActor () -> Bool,
        clock: HostClock, probe: @escaping @Sendable (_ host: String, _ local: String) async -> ProbeResult
    ) async throws -> Found? {
        let hosts = searchOrder(locals, preferred: preferred).filter { !excluding.contains($0.host) }
        let batches = stride(from: 0, to: hosts.count, by: 32).map { Array(hosts[$0..<min($0 + 32, hosts.count)]) }
        let deadline = clock.now() + budget
        var denied = false
        search: while clock.now() < deadline {
            denied = false
            for batch in batches {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                let (found, deniedHere) = await withTaskGroup(
                    of: (Found, ProbeResult).self, returning: (Found?, Bool).self
                ) { group in
                    for candidate in batch {
                        group.addTask { (candidate, await probe(candidate.host, candidate.local)) }
                    }
                    var deniedHere = false
                    for await (candidate, result) in group {
                        switch result {
                        case .camera:
                            group.cancelAll()
                            return (candidate, deniedHere)
                        case .localNetworkDenied: deniedHere = true
                        case .absent: break
                        }
                    }
                    return (nil, deniedHere)
                }
                if let found { return found }
                denied = denied || deniedHere
                if clock.now() >= deadline { break search }
            }
            try Task.checkCancellation()
            try await clock.sleep(.seconds(1))
        }
        if denied {
            throw ConnectionFailure.luna(
                .permission(.localNetwork), "local-network.denied",
                "Local Network access is off. Enable it in Settings, then connect again.",
                phase: .joiningNetwork, actions: [.openSettings, .retry])
        }
        return nil
    }

    /// The camera this connect asked for on a network several cameras may share: ``findCamera``
    /// until `open` takes a host. A host `open` turns down as another camera (a `.wrongCamera`
    /// failure: its serial is not the one Bluetooth read) is left out from then on and the search
    /// goes on within the same `budget`. Hosts in `excluding` (other connections of this app hold
    /// them) are never probed. Nil when the budget ran out first; any other failure of `open` ends
    /// the search.
    static func findRequestedCamera(
        on local: Address, preferred: String?, budget: Duration, excluding: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool, open: (_ host: String) async throws -> Void
    ) async throws -> String? {
        try await findRequestedCamera(
            on: [local], preferred: preferred, budget: budget, excluding: excluding, isCurrent: isCurrent,
            clock: .live, probe: { host, local in await probe(host, local: local) }, open: { host, _ in try await open(host) }
        )?.host
    }

    /// ``findRequestedCamera(on:preferred:budget:excluding:isCurrent:open:)`` over every network
    /// in `locals`; `open` gets the host and this device's address on its network.
    static func findRequestedCamera(
        on locals: [Address], preferred: String?, budget: Duration, excluding: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool, open: (_ host: String, _ local: String) async throws -> Void
    ) async throws -> Found? {
        try await findRequestedCamera(
            on: locals, preferred: preferred, budget: budget, excluding: excluding, isCurrent: isCurrent,
            clock: .live, probe: { host, local in await probe(host, local: local) }, open: open)
    }

    /// ``findRequestedCamera(on:preferred:budget:excluding:isCurrent:open:)`` with `probe`
    /// answering for each host and the search time on `clock`.
    static func findRequestedCamera(
        on local: Address, preferred: String?, budget: Duration, excluding: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool, clock: HostClock,
        probe: @escaping @Sendable (_ host: String, _ local: String) async -> ProbeResult,
        open: (_ host: String) async throws -> Void
    ) async throws -> String? {
        try await findRequestedCamera(
            on: [local], preferred: preferred, budget: budget, excluding: excluding, isCurrent: isCurrent,
            clock: clock, probe: probe, open: { host, _ in try await open(host) })?.host
    }

    /// ``findRequestedCamera(on:preferred:budget:excluding:isCurrent:clock:probe:open:)`` over
    /// every network in `locals`.
    static func findRequestedCamera(
        on locals: [Address], preferred: String?, budget: Duration, excluding: Set<String>,
        isCurrent: @escaping @MainActor () -> Bool, clock: HostClock,
        probe: @escaping @Sendable (_ host: String, _ local: String) async -> ProbeResult,
        open: (_ host: String, _ local: String) async throws -> Void
    ) async throws -> Found? {
        let deadline = clock.now() + budget
        var skipped = excluding
        repeat {
            guard
                let found = try await findCamera(
                    on: locals, preferred: preferred, budget: deadline - clock.now(), excluding: skipped,
                    isCurrent: isCurrent, clock: clock, probe: probe)
            else { return nil }
            do {
                try await open(found.host, found.local)
                return found
            } catch let failure as ConnectionFailure where failure.reason == .wrongCamera {
                skipped.insert(found.host)
            }
        } while clock.now() < deadline
        return nil
    }

    /// Connects to `host`:6666 from `local`, sends the preface and waits up to 3.2 s for a frame
    /// that starts with the UCD2 magic (the camera answers slowly in Wi-Fi power save). A
    /// cancelled probe ends at once.
    nonisolated static func probe(_ host: String, local: String) async -> ProbeResult {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(local), port: .any)
        parameters.includePeerToPeer = false
        let connection = NWConnection(
            host: .init(host), port: .init(rawValue: LunaProtocol.defaultPort)!, using: parameters)
        let queue = DispatchQueue(label: "luna.station.probe")
        let once = ProbeOnce()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.start(continuation)
                queue.asyncAfter(deadline: .now() + 3.2) { once.finish(.absent) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: LunaProtocol.tcpPreface, completion: .contentProcessed { _ in })
                        connection.receive(minimumIncompleteLength: 4, maximumLength: 64) { data, _, _, _ in
                            once.finish(data.map { $0.prefix(4) == Data("UCD2".utf8) } ?? false ? .camera : .absent)
                        }
                    case .waiting(let error):
                        var dnsCode: Int32?
                        if case .dns(let code) = error { dnsCode = code }
                        once.finish(
                            CameraNetworkPermissionPolicy.isLocalNetworkDenied(
                                dnsErrorCode: dnsCode,
                                pathDenied: connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                                ? .localNetworkDenied : .absent)
                    case .failed, .cancelled: once.finish(.absent)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            once.finish(.absent)
        }
        connection.cancel()
        return result
    }
}

/// Resumes a probe's continuation exactly once; a finish before the continuation exists (a probe
/// cancelled before it started) is kept for it.
private final class ProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LunaStationPath.ProbeResult, Never>?
    private var early: LunaStationPath.ProbeResult?
    private var done = false

    func start(_ continuation: CheckedContinuation<LunaStationPath.ProbeResult, Never>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: LunaStationPath.ProbeResult) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let pending = continuation
        continuation = nil
        if pending == nil { early = value }
        lock.unlock()
        pending?.resume(returning: value)
    }
}
