import Foundation
import OpenCineCore

/// A nearby camera as a fake integration's discovery reports it: its Bluetooth id, its name and,
/// for an integration that finds members from its own sightings, the address it was seen at.
/// Kotlin twin: `FakeStationCamera`.
public struct FakeStationCamera: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var modelId: Int?
    public var sightedAt: String?

    public init(id: UUID = UUID(), name: String, modelId: Int? = nil, sightedAt: String? = nil) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.sightedAt = sightedAt
    }

    /// What a commissioner journals for it.
    public var record: StationCameraRecord {
        StationCameraRecord(id: id, name: name, modelId: modelId)
    }

    /// The identity bytes this camera proves over its setup link and on the network.
    public var identity: [UInt8] { Array(name.utf8) }
}

/// A one-shot signal a fake waits on until the test opens it.
@MainActor
public final class FakeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var isOpen = false
    /// Tasks parked on the gate now.
    public var waiting: Int { waiters.count }

    public init() {}

    public func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}

/// The phone's side of a fake shared network. Kotlin twin: `FakeStationHostPath`.
@MainActor
public final class FakeStationHostPath: StationHostPath {
    /// This phone's address per network kind (`false` Wi-Fi, `true` its hotspot).
    public var addresses: [Bool: String]
    public var netmasks: [Bool: String]
    /// Thrown by `join` when set.
    public var joinError: Error?
    /// Every network `join` was asked for.
    public private(set) var joins: [StationNetwork] = []

    public init(
        address: String? = "192.168.1.10", netmask: String? = "255.255.255.248",
        hotspotAddress: String? = nil, hotspotNetmask: String? = nil
    ) {
        addresses = [:]
        netmasks = [:]
        addresses[false] = address
        netmasks[false] = netmask
        addresses[true] = hotspotAddress
        netmasks[true] = hotspotNetmask
    }

    public func address(hotspot: Bool) -> String? { addresses[hotspot] }
    public func netmask(hotspot: Bool) -> String? { netmasks[hotspot] }

    public func join(_ network: StationNetwork) async throws -> String? {
        joins.append(network)
        if let joinError { throw joinError }
        return network.hotspot ? addresses[true] : addresses[false]
    }
}

/// Why a fake commission or link failed.
public struct FakeMultiviewFailure: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A fake integration's camera setup over Bluetooth. Kotlin twin: `FakeStationCommissioner`.
@MainActor
public final class FakeStationCommissioner: StationCommissioner {
    public typealias Camera = FakeStationCamera

    /// Thrown by `connect` when set.
    public var connectError: Error?
    /// `connect` waits here before it answers, when set.
    public var connectGate: FakeGate?
    /// Lines the join reports through `progress`, in order.
    public var joinProgress: [String] = ["Joining shared Wi-Fi"]
    /// Thrown by the join when set.
    public var joinError: Error?
    /// The join finds the camera through `verifyOnNetwork` and reports `.verified`.
    public var verifiesOnJoin = false
    /// The verified join waits here before it reports, when set (the camera's preview already
    /// started while its join still runs).
    public var afterVerifyGate: FakeGate?
    /// The camera's join reply is lost, as a real commissioner sees it: the join looks for the
    /// camera on the network, treats what that throws as "not there yet" unless it is a
    /// `StationVerifyFinal`, and then fails as a silent join.
    public var lostJoinReply = false
    /// Each camera's return results, in order; `.restored` once they run out.
    public var restoreResults: [UUID: [StationRestoreResult]] = [:]
    /// Every return waits here when set.
    public var restoreGate: FakeGate?
    public var scansNetworks = false
    /// Networks a scan reports.
    public var scanFound: [String] = []

    public private(set) var connects: [UUID] = []
    public private(set) var joins: [(camera: UUID, network: StationNetwork, experimental: Bool)] = []
    public private(set) var restores: [UUID] = []
    public private(set) var commissionsClosed = 0
    /// Commission links closed by the caller.
    public private(set) var linksClosed = 0
    public private(set) var scans: [UUID] = []

    /// How a join whose reply was lost fails.
    public static let silentJoin = "The camera did not answer the Wi-Fi join."

    public init() {}

    public func record(_ camera: FakeStationCamera) -> StationCameraRecord { camera.record }

    public func connect(
        _ camera: FakeStationCamera, progress: @escaping @MainActor (String) -> Void
    ) async throws -> any StationCommission {
        connects.append(camera.id)
        progress("Bluetooth pairing")
        if let connectGate { await connectGate.wait() }
        try Task.checkCancellation()
        if let connectError { throw connectError }
        return Commission(camera: camera, owner: self)
    }

    public func closeCommissions() { commissionsClosed += 1 }

    public func restoreAccessPoint(_ record: StationCameraRecord) async -> StationRestoreResult {
        restores.append(record.id)
        if let restoreGate { await restoreGate.wait() }
        var queue = restoreResults[record.id] ?? []
        guard !queue.isEmpty else { return .restored }
        let result = queue.removeFirst()
        restoreResults[record.id] = queue
        return result
    }

    public func scanNetworks(
        through camera: FakeStationCamera,
        beforeStationChange: @escaping @MainActor () throws -> Void,
        onRestored: @escaping @MainActor (Bool) -> Void,
        onFound: @escaping @MainActor (String) -> Void
    ) async throws {
        scans.append(camera.id)
        try beforeStationChange()
        for network in scanFound { onFound(network) }
        let restored = await restoreAccessPoint(camera.record)
        onRestored(restored == .restored)
    }

    private final class Commission: StationCommission {
        let camera: FakeStationCamera
        let owner: FakeStationCommissioner

        init(camera: FakeStationCamera, owner: FakeStationCommissioner) {
            self.camera = camera
            self.owner = owner
        }

        func identity() async throws -> [UInt8] { camera.identity }

        func join(
            _ network: StationNetwork, identity: [UInt8], experimental: Bool,
            progress: @escaping @MainActor (String) -> Void,
            verifyOnNetwork: @escaping @MainActor () async throws -> Bool
        ) async throws -> StationCommissionOutcome {
            owner.joins.append((camera.id, network, experimental))
            for line in owner.joinProgress { progress(line) }
            if let error = owner.joinError { throw error }
            if owner.lostJoinReply {
                do {
                    if try await verifyOnNetwork() { return .verified }
                } catch {
                    if error is CancellationError || error is StationVerifyFinal { throw error }
                }
                throw FakeMultiviewFailure(FakeStationCommissioner.silentJoin)
            }
            if owner.verifiesOnJoin, try await verifyOnNetwork() {
                if let gate = owner.afterVerifyGate { await gate.wait() }
                return .verified
            }
            return .joined
        }

        func close() { owner.linksClosed += 1 }
    }
}

/// A fake member link: cameras answer at the addresses the test places them. Kotlin twin:
/// `FakeMemberLink`.
@MainActor
public final class FakeMemberLink: MultiviewMemberLink {
    public typealias Camera = FakeStationCamera

    public let fakeSession: FakeCameraSession
    public nonisolated var session: any CameraSession { fakeSession }
    /// The session's snapshot as the coordinator reads it; `syncSnapshot()` copies the fake's.
    public var snapshot: CameraSnapshot
    public var pictureHealth: PictureHealth = .live
    public var onStatus: (@MainActor (MultiviewLinkStatus) -> Void)?
    public var repairDeadline: Duration = .seconds(60)
    public var recordReport: MultiviewRecordReport?
    public var autoLUT = MultiviewAutoLUT(colorMode: nil, conversion: nil)

    /// The identity of the camera answering at each address.
    public var answering: [String: [UInt8]] = [:]
    /// Thrown by `startPreview` when set.
    public var startError: Error?
    /// `open` waits here when set.
    public var openGate: FakeGate?
    /// The next repair tick's verdict.
    public var repairStep: (MultiviewRepairContext) -> MultiviewRepairStep = { _ in .healthy }

    public private(set) var probes: [String] = []
    public private(set) var opens: [(address: String, expecting: [UInt8]?)] = []
    public private(set) var starts = 0
    public private(set) var closes = 0
    public private(set) var keepalives = 0
    public private(set) var repairTicks = 0
    public private(set) var openAddress: String?

    public init(session: FakeCameraSession = .djiLike()) {
        fakeSession = session
        snapshot = CameraSnapshot(session: session.id)
    }

    /// Copies the fake session's current snapshot into `snapshot`.
    public func syncSnapshot() async { snapshot = await fakeSession.current }

    /// Places `camera` at `address` on the network.
    public func place(_ camera: FakeStationCamera, at address: String) {
        answering[address] = camera.identity
    }

    public func probe(_ address: String, on network: StationNetwork) async -> Bool {
        probes.append(address)
        return answering[address] != nil
    }

    public func open(
        _ camera: FakeStationCamera, at address: String, expecting identity: [UInt8]?,
        on network: StationNetwork
    ) async throws -> [UInt8] {
        opens.append((address, identity))
        openAddress = nil
        onStatus?(.opening)
        if let openGate { await openGate.wait() }
        try Task.checkCancellation()
        guard let answer = answering[address] else {
            throw FakeMultiviewFailure("Nothing answered at \(address)")
        }
        if let identity, identity != answer {
            throw FakeMultiviewFailure("This network connection did not identify the selected camera.")
        }
        openAddress = address
        return answer
    }

    public func startPreview(_ camera: FakeStationCamera) async throws {
        if let startError { throw startError }
        starts += 1
        onStatus?(.controlling)
        onStatus?(.awaitingPicture)
    }

    public func keepalive() async { keepalives += 1 }

    public func close() {
        closes += 1
        openAddress = nil
    }

    public func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep {
        repairTicks += 1
        return repairStep(context)
    }
}

/// Fake Bluetooth discovery of nearby cameras. Kotlin twin: `FakeNearbyScanner`.
@MainActor
public final class FakeNearbyScanner: NearbyCameraScanner {
    public typealias Camera = FakeStationCamera

    public var ready = true
    public private(set) var scanning = false
    public private(set) var starts = 0
    public private(set) var stops = 0
    private var report: (@MainActor (FakeStationCamera) -> Void)?
    private var ending: CheckedContinuation<Void, Never>?

    public init() {}

    public func waitUntilReady() async -> Bool { ready }

    public func scan(_ found: @escaping @MainActor (FakeStationCamera) -> Void) async {
        starts += 1
        scanning = true
        report = found
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { ending = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
        scanning = false
        report = nil
    }

    public func stop() {
        stops += 1
        finish()
    }

    /// A camera seen while scanning.
    public func see(_ camera: FakeStationCamera) { report?(camera) }

    private func finish() {
        let pending = ending
        ending = nil
        pending?.resume()
    }
}
