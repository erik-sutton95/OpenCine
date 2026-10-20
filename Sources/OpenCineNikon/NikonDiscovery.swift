import Foundation
import OpenCineCore

/// A device's answer on the presence port: who it is and which camera it holds, if any. The app
/// decodes its own presence line into this.
public struct NikonPresence: Hashable, Sendable {
    public var deviceName: String
    /// The camera host this device serves (holds a session with), when it says.
    public var servedCamera: String?
    /// The answer as received, for the fields only the app reads (its relay protocol).
    public var line: Data?

    public init(deviceName: String, servedCamera: String? = nil, line: Data? = nil) {
        self.deviceName = deviceName
        self.servedCamera = servedCamera
        self.line = line
    }
}

/// Why discovery dials a host.
public enum NikonDialPurpose: Hashable, Sendable {
    /// The presence port: reaches no camera service. Presence reads and liveness (a refused dial
    /// proves an occupied address).
    case presence
    /// The camera's PTP/IP control port: a connect-and-hang-up port scan, or a PTP Init.
    case cameraControl
}

/// Every network dial discovery makes. Presence dials can never reach a camera's control
/// service; camera-control dials reach the PTP/IP port, and only `identify` sends PTP bytes.
public protocol NikonDialer: Sendable {
    /// One bounded presence read; `nil` for refused, timed out or not a presence answer.
    func presence(_ host: String) async -> NikonPresence?
    /// Whether something occupies `host`: a presence-port dial that connects or is refused.
    func isAlive(_ host: String) async -> Bool
    /// Sweep pass one: connect to the PTP/IP port and hang up, sending no PTP bytes.
    func scanControlPort(_ hosts: [String]) async -> [String: HostProbeVerdict]
    /// PTP/IP Init: the camera's name, `nil` when the host answers as something else.
    func identify(_ host: String, guid: Data) async throws -> String?
}

/// What discovery reads from the phone besides the network: interfaces, the Bonjour browse and
/// USB-attached cameras. The app supplies it (Bonjour and USB are platform services).
public protocol NikonDiscoverySources: Sendable {
    func interfaces() -> [NikonLocalInterface]
    /// One Bonjour `_ptp._tcp` browse window (passive multicast listening).
    func bonjour(timeout: Duration) async -> [DiscoveredCamera]
    /// Cameras attached over USB; `start` starts the browser first (it shows an OS disclosure).
    func usbCameras(start: Bool) async -> [DiscoveredCamera]
    func log(_ line: String)
}

public struct NikonLocalInterface: Hashable, Sendable {
    public var name: String
    public var address: String
    public var netmask: String?

    public init(name: String, address: String, netmask: String? = nil) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }
}

/// Nikon camera discovery for the cameras list and the pairing surface (SHELL-02, moved from
/// OpenZCine's `NativeCameraDiscoveryService`), over a `NikonDialer`.
///
/// `.passive` (the cameras list): Bonjour, USB, the presence sweep and liveness dials of saved
/// hosts. It never dials the control port and never sends a PTP byte: an Init from an idle device
/// drops another device's live session (single initiator). Enforced twice: the passive pass has
/// no probe step, and its dialer refuses camera-control dials.
///
/// `.active` (an operator pairing or watching a setup): also PTP Init to trusted hosts Bonjour did
/// not report, then a two-pass subnet sweep (mute port scan, then Init only the hosts that
/// answered), stopping at the first find. Hosts another device serves are never dialled.
public final class NikonDiscovery: @unchecked Sendable {
    // SAFETY: `@unchecked Sendable`: the only mutable state is `state`, guarded by `lock`.
    private let dialer: any NikonDialer
    private let sources: any NikonDiscoverySources
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state = (lastSweep: Date.distantPast, shield: Set<String>(), held: [String: String]())

    /// At most one full-subnet presence sweep per this interval; between sweeps the last shield
    /// and held cameras stand.
    public static let presenceSweepInterval: TimeInterval = 30

    public init(
        dialer: any NikonDialer, sources: any NikonDiscoverySources,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dialer = dialer
        self.sources = sources
        self.now = now
    }

    /// One discovery pass.
    /// - `priorityHosts`: saved cameras' last hosts (liveness in `.passive`, trusted probes in `.active`).
    /// - `excludedHosts`: cameras some visible broadcast already serves; never dialled.
    /// - `onPresences`: every completed presence sweep's answers (empty is a verdict too).
    public func discover(
        _ mode: DiscoveryMode, guid: Data, priorityHosts: [String] = [],
        excludedHosts: (@Sendable () async -> Set<String>)? = nil, browsesUSB: Bool = true,
        status: (@Sendable (String) async -> Void)? = nil,
        onPresences: (@Sendable ([String: NikonPresence]) async -> Void)? = nil
    ) async throws -> [DiscoveredCamera] {
        // Resolved here, not as closure-literal defaults (swiftlang/swift#92017).
        let excludedHosts = excludedHosts ?? { [] }
        let status = status ?? { _ in }
        let onPresences = onPresences ?? { _ in }
        let dialer: any NikonDialer = mode == .passive ? PassiveDialer(base: dialer) : dialer
        let usbCameras = browsesUSB ? await sources.usbCameras(start: true) : []

        // Presence runs first and is awaited before anything probes: on a network where Bonjour
        // never delivers, presence answers are the only thing that names a served camera.
        var shielded: Set<String> = []
        if claimPresenceSweep() {
            let swept = scanHosts(priorityHosts: priorityHosts)
            let hits = await presenceSweep(swept, dialer: dialer)
            sources.log(
                "presence sweep hits=\(hits.count) ["
                    + hits.map { "\($0.key)(\($0.value.deviceName) ch=\($0.value.servedCamera ?? "nil"))" }
                    .sorted().joined(separator: " ") + "]")
            if !swept.isEmpty { await onPresences(hits) }
            // An answering host is a device, never a camera; every camera it names is shielded.
            for (host, presence) in hits {
                shielded.formUnion(Self.hostKeys(host))
                if let served = presence.servedCamera, !served.isEmpty { shielded.formUnion(Self.hostKeys(served)) }
            }
            let held = Dictionary(
                hits.compactMap { _, presence -> (String, String)? in
                    guard let served = presence.servedCamera, !served.isEmpty else { return nil }
                    return (served, presence.deviceName)
                }, uniquingKeysWith: { first, _ in first })
            lock.withLock { (state.shield, state.held) = (shielded, held) }
        } else {
            shielded = lock.withLock { state.shield }
        }
        let heldRows = lock.withLock { state.held }
            .map { DiscoveredCamera(ip: $0.key, source: .heldByAnotherDevice, heldByDeviceName: $0.value) }
            .sorted { $0.ip < $1.ip }

        await status("Searching for cameras on Wi‑Fi and USB‑C…")
        // Bonjour first; probes only cover what Bonjour did not report.
        let bonjour = await sources.bonjour(timeout: .milliseconds(1_400))
        let bonjourHosts = Set(bonjour.compactMap { PTPIPPairedHosts.normalizedHost($0.ip) })

        guard mode == .active else {
            // The list never speaks PTP: a saved host's readiness comes from a liveness dial.
            let liveness = Set(
                priorityHosts.filter { !DiscoveredCamera.isUSBHostKey($0) }.compactMap(PTPIPPairedHosts.normalizedHost)
            ).subtracting(bonjourHosts)
            let alive = await withTaskGroup(of: (String, Bool).self) { group in
                for host in liveness { group.addTask { (host, await dialer.isAlive(host)) } }
                var rows: [DiscoveredCamera] = []
                for await (host, isAlive) in group where isAlive { rows.append(DiscoveredCamera(ip: host, source: .liveness)) }
                return rows
            }
            let usbNow = browsesUSB ? await sources.usbCameras(start: false) : []
            return CameraDiscovery.dedupeAndSort(usbNow + bonjour + alive)
        }

        let excluded = await excludedHosts()
        let trusted = await probeTrustedHosts(
            guid: guid, priorityHosts: priorityHosts, excluded: excluded.union(bonjourHosts).union(shielded),
            dialer: dialer)
        let quick = CameraDiscovery.dedupeAndSort(usbCameras + bonjour + trusted)
        if !quick.isEmpty { return quick }

        await status("Still searching your network for cameras…")
        let swept = try await subnetProbe(
            guid: guid, priorityHosts: priorityHosts, excluded: excluded.union(shielded), status: status,
            dialer: dialer)
        let usbNow = browsesUSB ? await sources.usbCameras(start: false) : []
        return CameraDiscovery.dedupeAndSort(usbNow + swept + heldRows)
    }

    // MARK: Passes

    private func claimPresenceSweep() -> Bool {
        lock.withLock {
            let time = now()
            guard time.timeIntervalSince(state.lastSweep) >= Self.presenceSweepInterval else { return false }
            state.lastSweep = time
            return true
        }
    }

    private func scanInterfaces() -> [NikonLocalInterface] {
        sources.interfaces().filter { CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address) }
    }

    private func scanHosts(priorityHosts: [String]) -> [String] {
        let split = CameraDiscovery.prioritizedScanHosts(
            priorityHosts: priorityHosts, localAddresses: scanInterfaces().map(\.address))
        return split.priority + split.remaining
    }

    private func presenceSweep(_ hosts: [String], dialer: any NikonDialer) async -> [String: NikonPresence] {
        var found: [String: NikonPresence] = [:]
        for start in stride(from: 0, to: hosts.count, by: 64) {
            let chunk = hosts[start..<min(start + 64, hosts.count)]
            let hits = await withTaskGroup(of: (String, NikonPresence?).self) { group in
                for host in chunk { group.addTask { (host, await dialer.presence(host)) } }
                var hits: [String: NikonPresence] = [:]
                for await (host, presence) in group { if let presence { hits[host] = presence } }
                return hits
            }
            found.merge(hits) { _, new in new }
        }
        return found
    }

    /// The device serving `host` now, from one fresh presence sweep. The list sweeps at most every
    /// `presenceSweepInterval`, so a phone that went live since is not in its held rows yet. A body
    /// that takes one initiator hands its session to a new one without refusing it (a ZR drops the
    /// phone holding it), so a saved connect and a recovering session ask this before they dial.
    /// Never dials a camera's control port.
    public func currentHolder(of host: String, priorityHosts: [String] = []) async -> String? {
        // A cable or a not-yet-joined access point has no network holder to ask.
        guard !DiscoveredCamera.isUSBHostKey(host), !CameraDiscovery.isAccessPointHostKey(host) else {
            return nil
        }
        let hits = await presenceSweep(scanHosts(priorityHosts: priorityHosts), dialer: dialer)
        return Self.holder(of: host, in: hits)
    }

    /// The device among presence `hits` that names `host` as the camera it serves.
    public static func holder(of host: String, in hits: [String: NikonPresence]) -> String? {
        let wanted = hostKeys(host)
        return hits.sorted { $0.key < $1.key }.first { _, presence in
            guard let served = presence.servedCamera, !served.isEmpty else { return false }
            return !hostKeys(served).isDisjoint(with: wanted)
        }?.value.deviceName
    }

    /// Init the known candidates (saved hosts plus the access-point convention address) in one
    /// parallel round. Trusted addresses: none of the blind sweep's restraint.
    private func probeTrustedHosts(
        guid: Data, priorityHosts: [String], excluded: Set<String>, dialer: any NikonDialer
    ) async -> [DiscoveredCamera] {
        let split = CameraDiscovery.prioritizedScanHosts(
            priorityHosts: priorityHosts, localAddresses: scanInterfaces().map(\.address))
        let hosts = split.priority.filter { !excluded.contains($0) }
        if !hosts.isEmpty || !excluded.isEmpty {
            sources.log(
                "discovery probe pass trusted=[\(hosts.joined(separator: " "))] "
                    + "excluded=[\(excluded.sorted().joined(separator: " "))]")
        }
        guard !hosts.isEmpty else { return [] }
        return await withTaskGroup(of: DiscoveredCamera?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let name = try? await dialer.identify(host, guid: guid) else { return nil }
                    return DiscoveredCamera(ip: host, name: name, source: .subnetProbe)
                }
            }
            var found: [DiscoveredCamera] = []
            for await camera in group { if let camera { found.append(camera) } }
            return found
        }
    }

    /// The subnets this device stands in: the trusted chunk Inits directly; every blind chunk is
    /// port-scanned mute first and only the hosts that answered get an Init. Stops at a find.
    private func subnetProbe(
        guid: Data, priorityHosts: [String], excluded: Set<String>,
        status: @escaping @Sendable (String) async -> Void, dialer: any NikonDialer
    ) async throws -> [DiscoveredCamera] {
        let interfaces = scanInterfaces()
        let localAddresses = interfaces.map(\.address)
        let split = CameraDiscovery.prioritizedScanHosts(priorityHosts: priorityHosts, localAddresses: localAddresses)
        let priorityChunk = split.priority.filter { !excluded.contains($0) }
        let locals = Set(localAddresses.compactMap(PTPIPPairedHosts.normalizedHost))
        let subnets = Array(Set(interfaces.compactMap { CameraDiscovery.subnetBase(for: $0.address) })).sorted()
        let sweep = subnets.flatMap(CameraDiscovery.fastHosts(inSubnet:))
            .filter { !excluded.contains($0) && !locals.contains($0) }
        let chunks = [priorityChunk].filter { !$0.isEmpty }
            + stride(from: 0, to: sweep.count, by: 254).map { Array(sweep[$0..<min($0 + 254, sweep.count)]) }
        sources.log(
            "discovery sweep pass hosts=\(chunks.reduce(0) { $0 + $1.count }) excluded=\(excluded.count) "
                + "on=[\(interfaces.map { "\($0.name) \($0.address)" }.joined(separator: ", "))] "
                + "subnets=[\(subnets.joined(separator: " "))]")
        if interfaces.isEmpty {
            let bridge = sources.interfaces().contains { $0.name.hasPrefix("bridge") }
            await status(
                bridge
                    ? "iPhone hotspot is active. Waiting for your camera to appear…"
                    : "Waiting for Wi‑Fi. Turn on Connect to PC on the camera, then join its network.")
        } else {
            await status("Searching nearby networks for your camera…")
        }
        var found: [DiscoveredCamera] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let identify: [String]
            if index == 0, !priorityChunk.isEmpty {
                identify = chunk
            } else {
                let scan = InfrastructureSweepTally.from(verdicts: await dialer.scanControlPort(chunk))
                identify = scan.openHosts
                sources.log(
                    "discovery sweep scan open=[\(scan.openHosts.joined(separator: " "))] "
                        + "occupied=[\(scan.occupiedHosts.prefix(24).joined(separator: " "))]")
            }
            guard !identify.isEmpty else { continue }
            found += await withTaskGroup(of: DiscoveredCamera?.self) { group in
                for host in identify {
                    group.addTask {
                        guard let name = try? await dialer.identify(host, guid: guid) else { return nil }
                        return DiscoveredCamera(ip: host, name: name, source: .subnetProbe)
                    }
                }
                var cameras: [DiscoveredCamera] = []
                for await camera in group { if let camera { cameras.append(camera) } }
                return cameras
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private static func hostKeys(_ host: String) -> Set<String> {
        var keys: Set<String> = [host]
        if let normalized = PTPIPPairedHosts.normalizedHost(host) { keys.insert(normalized) }
        return keys
    }
}

/// The passive pass's dialer: presence dials go through; a camera-control dial is refused and
/// never reaches the network.
struct PassiveDialer: NikonDialer {
    let base: any NikonDialer

    func presence(_ host: String) async -> NikonPresence? { await base.presence(host) }
    func isAlive(_ host: String) async -> Bool { await base.isAlive(host) }
    func scanControlPort(_ hosts: [String]) async -> [String: HostProbeVerdict] { [:] }
    func identify(_ host: String, guid: Data) async throws -> String? { throw CancellationError() }
}
