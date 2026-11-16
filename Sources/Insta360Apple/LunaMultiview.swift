import Foundation
import OpenCineCore

/// Luna's answers to a Multiview stage (Kotlin twin: `LunaMultiview`): which nearby Lunas may join,
/// how a sighting is journaled, and the identity a member proves (its serial). A Luna joins a stage
/// over Bluetooth (`LunaStationCommissioner` moves it onto the shared network) and is found there by
/// a greeting probe on its control port, opened only with its serial checked (`LunaMemberLink`).
public enum LunaMultiview {
    /// Every available Luna sighting may join, with its picture; one another device holds is not
    /// offered. Luna has no experimental join path. Members are found by probing the shared
    /// network: a probe opens no session, and a camera is opened only with its serial checked.
    public static let policy = MultiviewCameraPolicy<NearbyCamera>(
        discoversByProbe: true,
        qualification: { camera, experimental in
            if experimental { return .refused(.unsupportedConfiguration) }
            if case .unavailable = camera.availability { return .refused(.operationUnavailable) }
            return .qualified
        },
        hasPreview: { _ in true })

    /// The journal record of a sighting: its Bluetooth peripheral and name. A Luna reports no model
    /// code in its advertisement, so none is kept.
    public static func record(_ camera: NearbyCamera) -> StationCameraRecord {
        StationCameraRecord(id: peripheral(camera), name: camera.name, modelId: nil)
    }

    /// The camera a backend connects to for `camera`.
    public static func monitorCamera(_ camera: NearbyCamera) -> MonitorCamera {
        MonitorCamera(id: peripheral(camera), name: camera.name, model: camera.model, capabilities: [])
    }

    /// The identity a member proves: its serial's bytes.
    public static func identity(serial: String) -> [UInt8] { Array(serial.utf8) }

    /// The serial an identity carries; nil for none.
    public static func serial(identity: [UInt8]) -> String? {
        guard !identity.isEmpty else { return nil }
        return String(decoding: identity, as: UTF8.self)
    }

    /// A sighting's Bluetooth peripheral. iOS names Lunas by peripheral UUID; any other id (a
    /// sighting from elsewhere) gets a stable UUID derived from its text.
    static func peripheral(_ camera: NearbyCamera) -> UUID {
        if let id = UUID(uuidString: camera.id) { return id }
        var bytes = Array(repeating: UInt8(0), count: 16)
        for (index, byte) in camera.id.utf8.enumerated() { bytes[index % 16] ^= byte &+ UInt8(index % 251) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Luna's `StationCommissioner` (Kotlin twin alike): moves a nearby Luna from its own access point
/// onto the stage's shared network over Bluetooth, as a Wi-Fi or hotspot setup's connect does, and
/// back. Each commission and each return runs on a port of its own (`makePort`, a fresh backend),
/// so the stage's members keep their connections. Hardware-untested.
@MainActor
public final class LunaStationCommissioner: StationCommissioner {
    public typealias Camera = NearbyCamera

    /// How long a join keeps asking `verifyOnNetwork` after the camera moved (the prep's search
    /// budget after a move: the camera needs a DHCP lease first).
    public static let verifyBudget: Duration = .seconds(60)
    /// The pause between two `verifyOnNetwork` tries.
    public static let verifyInterval: Duration = .seconds(3)
    /// Tries of a return to the access point, and the pause between deferred ones.
    public static let returnAttempts = 3
    public static let returnInterval: Duration = .seconds(3)

    private let makePort: @MainActor () -> any LunaStationPort
    private let clock: HostClock
    private var commissions: [Commission] = []

    /// - Parameters:
    ///   - makePort: a new connection (a `LunaCameraBackend`) for one commission or return.
    ///   - clock: the waits between tries.
    public init(makePort: @escaping @MainActor () -> any LunaStationPort, clock: HostClock = .live) {
        self.makePort = makePort
        self.clock = clock
    }

    /// Luna has no experimental join path.
    public var joinsExperimentally: Bool { false }
    /// The camera may ask the operator to allow this phone (Bluetooth authorization).
    public var asksApprovalOnCamera: Bool { true }

    public func record(_ camera: NearbyCamera) -> StationCameraRecord { LunaMultiview.record(camera) }

    /// Bluetooth reaches the camera, which approves this phone (the operator may tap Allow), and the
    /// serial is read. The link stays open for `join`.
    public func connect(
        _ camera: NearbyCamera, progress: @escaping @MainActor (String) -> Void
    ) async throws -> any StationCommission {
        let commission = Commission(port: makePort(), clock: clock)
        commissions.append(commission)
        commission.onClose = { [weak self, weak commission] in
            self?.commissions.removeAll { $0 === commission }
        }
        do {
            commission.serial = try await commission.port.authorizeForStation(
                LunaMultiview.monitorCamera(camera))
        } catch {
            commission.close()
            throw error
        }
        return commission
    }

    public func closeCommissions() {
        for commission in commissions { commission.close() }
        commissions.removeAll()
    }

    /// One camera's return to its own access point over Bluetooth, retried while the camera defers
    /// (`LunaAccessPointReturn.retrying`). Only `returned` is restored; every other answer, the
    /// camera's own refusals included, is `deferred` with its copy, so the cleanup journal keeps it
    /// and a later close tries again (Plan 3 cleanup ruling). Cancelled or thrown: `failed`.
    public func restoreAccessPoint(_ record: StationCameraRecord) async -> StationRestoreResult {
        let port = makePort()
        defer { port.disconnect() }
        let clock = clock
        do {
            let result = try await LunaAccessPointReturn.retrying(
                attempts: Self.returnAttempts,
                waitBetween: { try await clock.sleep(Self.returnInterval) },
                { try await port.returnToAccessPoint(cameraID: record.id) })
            switch result {
            case .returned: return .restored
            case .deferred(let failure), .failed(let failure): return .deferred(failure.message)
            }
        } catch {
            return .failed
        }
    }

    /// One camera's Bluetooth link while it moves onto the network.
    @MainActor
    final class Commission: StationCommission {
        let port: any LunaStationPort
        let clock: HostClock
        var serial = ""
        var onClose: (() -> Void)?
        private var closed = false

        init(port: any LunaStationPort, clock: HostClock) {
            self.port = port
            self.clock = clock
        }

        func identity() async throws -> [UInt8] { LunaMultiview.identity(serial: serial) }

        /// Moves the camera, then asks `verifyOnNetwork` until it found the camera or
        /// `verifyBudget` passed (`.joined`: the caller searches once more).
        func join(
            _ network: StationNetwork, identity: [UInt8], experimental: Bool,
            progress: @escaping @MainActor (String) -> Void,
            verifyOnNetwork: @escaping @MainActor () async throws -> Bool
        ) async throws -> StationCommissionOutcome {
            progress("Moving the camera to “\(network.ssid)”…")
            _ = try await port.moveOntoStation(
                LunaStationNetwork(ssid: network.ssid, password: network.password, hotspot: network.hotspot))
            let deadline = clock.now() + LunaStationCommissioner.verifyBudget
            while true {
                try Task.checkCancellation()
                do {
                    if try await verifyOnNetwork() { return .verified }
                } catch let final as StationVerifyFinal {
                    throw final
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Not on the network yet: the camera is still taking its address.
                }
                guard clock.now() + LunaStationCommissioner.verifyInterval < deadline else {
                    return .joined
                }
                try await clock.sleep(LunaStationCommissioner.verifyInterval)
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            port.disconnect()
            onClose?()
        }
    }
}

/// Nearby Lunas for a Multiview stage's Add list, from the integration's passive discovery (Kotlin
/// twin: `LunaNearbyScanner`).
@MainActor
public final class LunaNearbyScanner: NearbyCameraScanner {
    public typealias Camera = NearbyCamera
    private let discover: @MainActor () -> AsyncStream<[NearbyCamera]>

    /// - Parameter discover: the integration's passive discovery (`LunaIntegration.discover`).
    public init(discover: @escaping @MainActor () -> AsyncStream<[NearbyCamera]>) {
        self.discover = discover
    }

    public convenience init(integration: LunaIntegration) {
        self.init(discover: { [weak integration] in
            integration?.discover(.passive) ?? AsyncStream { $0.finish() }
        })
    }

    /// Bluetooth readiness shows in the sightings themselves (none while it is off).
    public func waitUntilReady() async -> Bool { true }

    public func scan(_ found: @escaping @MainActor (NearbyCamera) -> Void) async {
        for await sightings in discover() {
            guard !Task.isCancelled else { return }
            for camera in sightings { found(camera) }
        }
    }

    /// The coordinator cancels the scan's task, which ends the discovery subscription.
    public func stop() {}
}
