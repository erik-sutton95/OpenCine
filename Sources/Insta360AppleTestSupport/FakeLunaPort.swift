import Foundation
import Insta360Apple
import OpenCineCore
import OpenCineMedia

/// A scripted Luna backend behind `LunaIntegration`, for tests: it records scans, connects and
/// forgets, emits the backend's events on demand, and holds each connect until the test finishes
/// it. Like the real backend, a new connect or a disconnect cancels the one in flight.
@MainActor
public final class FakeLunaPort: LunaConnectPort {
    public var eventHandler: ((CameraBackendEvent) -> Void)?
    public var connectedSerial: String?
    public var joinedNetwork: String?
    public var makeMediaService: ((CameraSessionID) -> (any CameraMediaService)?)?
    /// Thrown by `startScan()` when set (Bluetooth off, for example).
    public var scanFailure: Error?
    /// Cameras this run has heard advertise (the backend's Bluetooth reachability).
    public var seen: Set<UUID> = []
    /// Cameras with saved Wi-Fi credentials in the backend's store.
    public var savedWiFi: Set<UUID> = []
    public private(set) var scans = 0
    public private(set) var scanStops = 0
    public private(set) var connects: [MonitorCamera] = []
    /// The route of every connect, in order.
    public private(set) var routes: [LunaRoute] = []
    /// Wi-Fi and hotspot passwords the backend keeps, by network and kind.
    public private(set) var stations: [LunaStationNetwork] = []
    /// Whether the most recent connect started after the camera had advertised.
    public private(set) var connectSawSighting: Bool?
    public private(set) var disconnects = 0
    public private(set) var forgotten: [UUID] = []
    /// The camera behind every session this port opens.
    public let camera = FakeLuna()
    private var pending: CheckedContinuation<Void, Error>?

    public init() {}

    public func emit(_ event: CameraBackendEvent) { eventHandler?(event) }

    /// Ends the connect in flight: success, or the error the backend would throw.
    public func finishConnect(throwing error: Error? = nil) {
        let waiter = pending
        pending = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }

    public func startScan() async throws {
        scans += 1
        if let scanFailure { throw scanFailure }
    }

    public func stopScan() { scanStops += 1 }

    public func hasSeen(_ cameraID: UUID) -> Bool { seen.contains(cameraID) }

    public func hasSavedWiFi(cameraID: UUID) -> Bool { savedWiFi.contains(cameraID) }

    public func connect(to camera: MonitorCamera) async throws {
        try await connect(to: camera, route: .cameraWiFi(restoreAccessPoint: false))
    }

    public func connect(to camera: MonitorCamera, route: LunaRoute) async throws {
        cancelPending()
        connects.append(camera)
        routes.append(route)
        connectSawSighting = seen.contains(camera.id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPending() }
        }
    }

    public func disconnect() {
        disconnects += 1
        cancelPending()
    }

    public func openSession() -> LunaCameraSession { camera.makeSession() }
    public func mediaService(for session: CameraSessionID) -> (any CameraMediaService)? {
        makeMediaService?(session)
    }

    public func forget(cameraID: UUID) { forgotten.append(cameraID) }

    public func stationPassword(for network: String, hotspot: Bool) -> String? {
        stations.last { $0.ssid == network && $0.hotspot == hotspot }?.password
    }

    public func saveStation(_ network: LunaStationNetwork) {
        stations.removeAll { $0.ssid == network.ssid && $0.hotspot == network.hotspot }
        stations.append(network)
    }

    private func cancelPending() {
        let waiter = pending
        pending = nil
        waiter?.resume(throwing: CancellationError())
    }
}
