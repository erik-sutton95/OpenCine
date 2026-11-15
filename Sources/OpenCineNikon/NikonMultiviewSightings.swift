import Foundation
import OpenCineCore

// Shared Multiview (Plan 6): what Multiview's Add camera lists for Nikon and the policy the shared
// coordinator follows. Z bodies join a network only from their own menus, so the list is passive
// sightings plus the app's saved router and hotspot setups; only the body the operator picks is
// opened (`NikonMultiviewLink`). Kotlin twins: `NikonMultiviewSightings.kt`, same names.

/// A Z body Multiview's Add camera lists: a passive sighting or a saved router or hotspot setup on
/// this phone's network. It carries no serial: the body is identified only when it is picked and
/// opened. Kotlin twin: `NikonMultiviewCamera`.
public struct NikonMultiviewCamera: Hashable, Sendable {
    /// The dotted IPv4 address the body was seen or saved at, normalized (`NikonMultiview.address`).
    public var host: String
    public var name: String
    /// Another device holds the body now: listing it would invite an Init that drops that device.
    public var heldByAnotherDevice: Bool
    /// The holding device's name, when its presence answer gave one.
    public var holder: String?

    public init(host: String, name: String, heldByAnotherDevice: Bool = false, holder: String? = nil) {
        self.host = NikonMultiview.address(host) ?? host
        self.name = name
        self.heldByAnotherDevice = heldByAnotherDevice
        self.holder = holder
    }

    /// The stage's id for this camera: the same for every sighting of the same host.
    public var id: UUID { NikonMultiview.stageID(host: host) }

    /// The coordinator's record of it (`MultiviewCoordinator`'s `describe`).
    public var record: StationCameraRecord { StationCameraRecord(id: id, name: name, modelId: nil) }
}

/// A saved router or hotspot setup the Add list offers even when the passive pass did not see it
/// (a body answers liveness only while it is on). Kotlin twin: `NikonMultiviewSavedSetup`.
public struct NikonMultiviewSavedSetup: Hashable, Sendable {
    public var host: String
    public var name: String

    public init(host: String, name: String) {
        self.host = host
        self.name = name
    }
}

/// Nikon's answers to the shared Multiview. Kotlin twin: `NikonMultiview`.
public enum NikonMultiview {
    /// Bodies are never found by probing (an Init from an idle device drops another device's
    /// session): members come from sightings. A body another device holds is refused, so the Add
    /// list does not offer it. Every body shows its picture.
    public static let policy = MultiviewCameraPolicy<NikonMultiviewCamera>(
        discoversByProbe: false, hostKey: { NikonDiscovery.hostKey($0) },
        qualification: { camera, _ in camera.heldByAnotherDevice ? .refused(.notReachable) : .qualified },
        hasPreview: { _ in true })

    /// `host` as the normalized dotted IPv4 address the coordinator opens, or `nil` for a USB key,
    /// an access-point key or anything else that is not a network address.
    public static func address(_ host: String) -> String? {
        guard let key = PTPIPPairedHosts.normalizedHost(host), StationSubnet.validAddress(key) else {
            return nil
        }
        return key
    }

    /// The Add list: passive `sightings` (`NikonDiscovery.multiviewSightings`) and the `saved`
    /// setups, one row per host, without `excludedHosts` (members and this app's own Live View).
    /// A saved setup names the row of its host. USB and access-point keys are never listed.
    public static func addList(
        sightings: [DiscoveredCamera], saved: [NikonMultiviewSavedSetup], excludedHosts: Set<String> = []
    ) -> [NikonMultiviewCamera] {
        let excluded = Set(excludedHosts.map(NikonDiscovery.hostKey))
        let names = Dictionary(
            saved.compactMap { setup in address(setup.host).map { ($0, setup.name) } },
            uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var list: [NikonMultiviewCamera] = []
        for sighting in sightings {
            guard let host = address(sighting.ip), !excluded.contains(host), seen.insert(host).inserted
            else { continue }
            list.append(
                NikonMultiviewCamera(
                    host: host, name: names[host] ?? sighting.displayName,
                    heldByAnotherDevice: sighting.isHeldByAnotherDevice, holder: sighting.heldByDeviceName))
        }
        for setup in saved {
            guard let host = address(setup.host), !excluded.contains(host), seen.insert(host).inserted
            else { continue }
            list.append(NikonMultiviewCamera(host: host, name: setup.name))
        }
        return list
    }

    /// A UUID fixed by the host (two FNV-1a 64-bit hashes), so the stage knows a repeated sighting.
    static func stageID(host: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in "nikon-multiview:\(host)".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let high = fnv(0xCBF2_9CE4_8422_2325)
        let low = fnv(0x8422_2325_CBF2_9CE4)
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

/// Multiview's nearby discovery for Nikon (Kotlin twin: `NikonMultiviewScanner`): repeated passive
/// passes (`NikonDiscovery.multiviewSightings`: no control-port dial, no PTP byte) merged with the
/// saved setups, reported as the shared `NearbyCameraScanner` reports cameras, until `stop()` or
/// cancellation. Hosts in `excludedHosts` (members and this app's own Live View) are neither dialled
/// nor listed.
public final class NikonMultiviewScanner: NearbyCameraScanner, @unchecked Sendable {
    public typealias Camera = NikonMultiviewCamera
    // SAFETY: `@unchecked Sendable`: the only mutable state is `generation`, guarded by `lock`.
    private let sightings: @Sendable (_ savedHosts: [String], _ excludedHosts: Set<String>) async -> [DiscoveredCamera]
    private let saved: @MainActor @Sendable () -> [NikonMultiviewSavedSetup]
    private let excludedHosts: @MainActor @Sendable () -> Set<String>
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var generation = 0

    /// - `sightings`: one passive pass, normally `NikonDiscovery.multiviewSightings`.
    /// - `saved`: the app's saved router and hotspot setups.
    /// - `excludedHosts`: hosts a member or this app's own Live View holds, asked before each pass.
    /// - `interval`: the pause between passes (the presence sweep inside a pass keeps its own limit).
    public init(
        sightings: @escaping @Sendable (_ savedHosts: [String], _ excludedHosts: Set<String>) async -> [DiscoveredCamera],
        saved: @escaping @MainActor @Sendable () -> [NikonMultiviewSavedSetup],
        excludedHosts: @escaping @MainActor @Sendable () -> Set<String>,
        interval: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.sightings = sightings
        self.saved = saved
        self.excludedHosts = excludedHosts
        self.interval = interval
        self.sleep = sleep
    }

    /// Passive discovery needs no radio permission.
    public func waitUntilReady() async -> Bool { true }

    public func scan(_ found: @escaping @MainActor (NikonMultiviewCamera) -> Void) async {
        let pass = lock.withLock { generation }
        func current() -> Bool { !Task.isCancelled && lock.withLock { generation == pass } }
        while current() {
            let setups = await saved()
            let excluded = await excludedHosts()
            let keys = Set(excluded.map(NikonDiscovery.hostKey))
            let rows = await sightings(
                setups.map(\.host).filter { !keys.contains(NikonDiscovery.hostKey($0)) }, excluded)
            guard current() else { return }
            for camera in NikonMultiview.addList(sightings: rows, saved: setups, excludedHosts: excluded) {
                await found(camera)
            }
            do { try await sleep(interval) } catch { return }
        }
    }

    public func stop() { lock.withLock { generation &+= 1 } }
}
