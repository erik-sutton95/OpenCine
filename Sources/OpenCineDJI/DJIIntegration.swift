import Foundation
import OpenCineCore

/// The common session identity exposed through DJI's downward integration boundary.
public typealias DJICameraSessionID = CameraSessionID

/// The common control epoch exposed through DJI's downward integration boundary.
public typealias DJIControlEpoch = ControlEpoch

/// Source name for the common route kind used by DJI connection execution. It adds no
/// manufacturer-specific route and keeps optional network facts separate from route intent.
public typealias DJIConnectionRoute = RouteKind

/// A stage of a DJI connect, as the app's pipeline reports it: Bluetooth, then Wi-Fi, then the
/// datalink.
public enum DJIConnectionStage: Hashable, Sendable {
    case scanning
    case connectingBluetooth
    case pairing
    case awaitingApproval
    case readingWiFi
    case joiningWiFi
    /// A setup that moved the camera: looking for it on that network.
    case findingCamera
    case openingDatalink
}

/// One DJI camera Bluetooth discovery sees.
public struct DJISighting: Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: CameraModel
    public var modelId: Int?

    public init(id: String, name: String, model: CameraModel, modelId: Int? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.modelId = modelId
    }
}

/// How the next connect reaches the camera. A password is given only when a setup is being
/// added; otherwise the app's saved network supplies it.
public enum DJISetup: Equatable, Sendable {
    case cameraWiFi
    case wifi(network: String, password: String?)
    case phoneHotspot(network: String, password: String?)
}

public struct DJIConnection: Sendable {
    public var session: any CameraSession
    /// Actual source-owned optional services belonging to this connection.
    public var services: CameraServices
    /// The camera network this phone joined (camera Wi-Fi), when known.
    public var joinedNetwork: String?
    /// The camera as the pipeline connected it: its advertised name and model id, saved with the
    /// record (a sighting's name is the list title).
    public var camera: DJISighting?

    public init(
        session: any CameraSession, joinedNetwork: String? = nil, camera: DJISighting? = nil,
        services: CameraServices = .init()
    ) {
        self.session = session
        self.services = services
        self.joinedNetwork = joinedNetwork
        self.camera = camera
    }
}

/// What `DJIIntegration` needs from the app's DJI connect pipeline: Bluetooth discovery, one
/// connection over a setup, the stages it passes, and forgetting a camera's saved Wi-Fi.
@MainActor
public protocol DJIConnectPort: AnyObject {
    /// The full sighting list on every change while scanning.
    var onSightings: (([DJISighting]) -> Void)? { get set }
    /// Every stage of the connect in flight, with its live text when there is one.
    var onStage: ((DJIConnectionStage, String?) -> Void)? { get set }
    func startScan()
    func stopScan()
    /// Throws a `ConnectionFailure` for a failure (another error reads as `.other`) and
    /// `CancellationError` when cancelled. `restoreAccessPoint`: the camera may still be in
    /// station role from a setup that moved it.
    func connect(cameraID: String, setup: DJISetup, restoreAccessPoint: Bool) async throws
        -> DJIConnection
    func disconnect()
    /// Drops the camera's saved Wi-Fi. Never the per-install pairing state.
    func forget(cameraID: String)
}

/// The DJI `CameraIntegration` (SHELL-02, Kotlin twin `DjiIntegration`): passive Bluetooth
/// discovery, one connection at a time over camera Wi-Fi or a Wi-Fi or hotspot setup that moves
/// the camera, the connect card's steps, the approval prompt, failures with route actions, and
/// forget.
@MainActor
public final class DJIIntegration: CameraIntegration {
    public nonisolated var id: IntegrationID { DJICameraSessionAdapter.integration }
    public nonisolated let profiles: [CameraProfile] = CameraModel.byId.sorted { $0.key < $1.key }
        .filter { $0.value.verified && !$0.value.isDrone }
        .map { key, model in
            let moving: Set<RouteKind> =
                MulticamSupport.appears(model) ? [.infrastructureNetwork, .phoneHotspot] : []
            return CameraProfile(
                id:
                    "\(DJICameraSessionAdapter.integration.rawValue).model.\(String(format: "0x%04x", key))",
                title: model.name, routes: moving.union([.cameraAccessPoint]), addableRoutes: moving
            )
        }
    public nonisolated let discoveryModes: Set<DiscoveryMode> = [.passive]

    /// The app's saved cameras. A camera network another saved camera owns (its access point
    /// or advertised name), or one of another body family, is never saved with this camera.
    public var savedCameras: () -> [SavedCamera] = { [] }
    /// Stores a record before an attempt starts: a setup that moves the camera is remembered
    /// (with a route being added) before it can move the camera, so a later camera Wi-Fi connect
    /// restores the access point even when this attempt fails. The app upserts it.
    public var saveRecord: (SavedCamera) -> Void = { _ in }

    static let approve = "Approve on the camera"
    static let looking = "Looking for the camera"
    /// The Wi-Fi step's caption while the app reports no setup progress (the apps' phase labels).
    static let reading = "Reading Wi-Fi credentials…"
    static let joining = "Joining camera Wi-Fi…"

    private let port: any DJIConnectPort
    private let now: () -> Date
    private var sightings: [DJISighting] = []
    private var listeners: [UUID: AsyncStream<[NearbyCamera]>.Continuation] = [:]
    private var current: Attempt?

    @MainActor
    private final class Attempt {
        let id = ConnectionAttemptID()
        let target: ConnectTarget
        let route: SavedRoute?
        let steps: [ConnectionStep]
        let continuation: AsyncStream<ConnectionEvent>.Continuation
        var task: Task<Void, Never>?
        var last: ConnectionProgress?

        init(
            target: ConnectTarget, route: SavedRoute?,
            continuation: AsyncStream<ConnectionEvent>.Continuation
        ) {
            self.target = target
            self.route = route
            self.steps = DJIIntegration.steps(route)
            self.continuation = continuation
        }
    }

    public init(port: any DJIConnectPort, now: @escaping () -> Date = Date.init) {
        self.port = port
        self.now = now
        port.onSightings = { [weak self] in self?.found($0) }
        port.onStage = { [weak self] in self?.stage($0, $1) }
    }

    /// The connect card's plan: camera Wi-Fi, or moving the camera to a Wi-Fi or hotspot setup.
    public static func steps(_ route: SavedRoute?) -> [ConnectionStep] {
        let moving = route.map { $0.kind != .cameraAccessPoint } ?? false
        let network = route?.network ?? (route?.kind == .phoneHotspot ? "Hotspot" : "Wi-Fi")
        return [
            ConnectionStep(title: "Connecting over Bluetooth"),
            ConnectionStep(
                title: moving ? "Moving the camera to \(network)" : "Joining camera Wi-Fi"),
            ConnectionStep(title: moving ? "Finding the camera" : "Opening the video link"),
            ConnectionStep(title: "Starting the picture"),
        ]
    }

    // MARK: Discovery

    public func discover(_ mode: DiscoveryMode) -> AsyncStream<[NearbyCamera]> {
        guard discoveryModes.contains(mode) else { return AsyncStream { $0.finish() } }
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [NearbyCamera].self, bufferingPolicy: .bufferingNewest(1))
        let first = listeners.isEmpty
        listeners[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stopListening(key) }
        }
        continuation.yield(sightings.map(nearby))
        if first { port.startScan() }
        return stream
    }

    private func stopListening(_ key: UUID) {
        guard listeners.removeValue(forKey: key) != nil, listeners.isEmpty else { return }
        port.stopScan()
    }

    private func found(_ list: [DJISighting]) {
        sightings = list
        for continuation in listeners.values { continuation.yield(list.map(nearby)) }
    }

    private func nearby(_ sighting: DJISighting) -> NearbyCamera {
        NearbyCamera(
            id: sighting.id, name: sighting.name, model: sighting.model.name,
            routes: [.cameraAccessPoint])
    }

    // MARK: Connecting

    public func connect(_ target: ConnectTarget) -> AsyncStream<ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        let cameraID = target.cameraID
        var route: SavedRoute?
        var setup = DJISetup.cameraWiFi
        var restore = false
        switch target {
        case .saved(let camera, let routeID):
            route = camera.routes.first { $0.id == routeID }
            setup = Self.setup(route, password: nil)
            restore = Self.mayBeInStationRole(camera)
            if let route, Self.moves(route.kind) {
                saveRecord(Self.stamping(camera, movingTo: route.kind))
            }
        case .nearby: break
        case .addRoute(let camera, let draft):
            guard draft.kind == .infrastructureNetwork || draft.kind == .phoneHotspot,
                let network = draft.network
            else {
                continuation.yield(
                    .failed(
                        Self.failure(
                            .unsupported, "route.unsupported", "This setup cannot be added.")))
                continuation.finish()
                return stream
            }
            let added = SavedRoute(
                key: draft.kind == .phoneHotspot ? "hotspot" : "wifi", kind: draft.kind,
                title: draft.title,
                network: network, bluetooth: true)
            route = added
            setup = Self.setup(added, password: draft.secret)
            restore = Self.mayBeInStationRole(camera)
            var adding = camera
            adding.routes.removeAll { $0.key == added.key }
            adding.routes.append(added)
            saveRecord(Self.stamping(adding, movingTo: added.kind))
        }
        // One pipeline, one connection: a newer attempt ends the older one.
        current?.continuation.finish()
        let attempt = Attempt(target: target, route: route, continuation: continuation)
        current = attempt
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancel(attempt) }
        }
        attempt.task = Task { [weak self, port] in
            // Replaced before it started: never dial the older camera.
            if let self, self.current !== attempt { return }
            do {
                let connection = try await port.connect(
                    cameraID: cameraID, setup: setup, restoreAccessPoint: restore)
                self?.connected(attempt, connection)
            } catch {
                self?.failed(attempt, error)
            }
        }
        return stream
    }

    public func forget(_ camera: SavedCamera) async { port.forget(cameraID: camera.id) }

    private static func setup(_ route: SavedRoute?, password: String?) -> DJISetup {
        guard let route, let network = route.network else { return .cameraWiFi }
        switch route.kind {
        case .infrastructureNetwork: return .wifi(network: network, password: password)
        case .phoneHotspot: return .phoneHotspot(network: network, password: password)
        default: return .cameraWiFi
        }
    }

    private static func moves(_ kind: RouteKind) -> Bool {
        kind == .infrastructureNetwork || kind == .phoneHotspot
    }

    /// `camera` remembering that a setup of `kind` may move it to station role: that route
    /// becomes preferred, or without one the legacy `lastSetup` stays in `extras`. Camera Wi-Fi
    /// is stamped only once live, so a failed restore is retried on the next connect.
    public static func stamping(_ camera: SavedCamera, movingTo kind: RouteKind) -> SavedCamera {
        guard moves(kind) else { return camera }
        var camera = camera
        if let route = camera.routes.first(where: { $0.kind == kind }) {
            camera.preferredRoute = route.id
            camera.extras["lastSetup"] = nil
        } else {
            camera.preferredRoute = nil
            camera.extras["lastSetup"] = kind == .phoneHotspot ? "phoneHotspot" : "wifi"
        }
        return camera
    }

    /// The iOS save rule (D9): a network another saved camera owns, or of another body family.
    static func ownedElsewhere(
        _ network: String, by camera: SavedCamera, among saved: [SavedCamera]
    ) -> Bool {
        func same(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let other = saved.contains { other in
            other.id != camera.id
                && (same(other.advertisedName)
                    || other.routes.contains { $0.kind == .cameraAccessPoint && same($0.network) })
        }
        return other
            || CameraBodyFamily.ssidConflictsWithBody(
                ssid: network, modelId: camera.extras["modelId"].flatMap { Int($0) },
                advertisedName: camera.advertisedName)
    }

    /// A setup that moves the camera may have left it in station role (the legacy `lastSetup`).
    private static func mayBeInStationRole(_ camera: SavedCamera) -> Bool {
        let preferred = camera.routes.first { $0.id == camera.preferredRoute }?.kind
        return preferred == .infrastructureNetwork || preferred == .phoneHotspot
            || ["wifi", "phoneHotspot"].contains(camera.extras["lastSetup"] ?? "")
    }

    private func cancel(_ attempt: Attempt) {
        guard current === attempt else { return }
        current = nil
        attempt.task?.cancel()
        port.disconnect()
    }

    private func stage(_ stage: DJIConnectionStage, _ text: String?) {
        guard let attempt = current else { return }
        let (phase, step, prompt, note): (ConnectionPhase, Int, ConnectionPrompt?, String?) =
            switch stage {
            case .scanning: (.link, 0, nil, Self.looking)
            case .connectingBluetooth, .pairing: (.link, 0, nil, nil)
            case .readingWiFi: (.link, 1, nil, text ?? Self.reading)
            case .awaitingApproval: (.awaitingApproval, 0, .approveOnCamera(Self.approve), nil)
            case .joiningWiFi: (.joiningNetwork, 1, nil, text ?? Self.joining)
            case .findingCamera: (.joiningNetwork, 2, nil, text)
            case .openingDatalink: (.negotiating, 2, nil, nil)
            }
        let progress = ConnectionProgress(
            attempt: attempt.id, phase: phase, steps: attempt.steps, current: step, note: note)
        guard progress != attempt.last else { return }
        attempt.last = progress
        attempt.continuation.yield(.progress(progress, prompt: prompt))
    }

    private func connected(_ attempt: Attempt, _ connection: DJIConnection) {
        guard current === attempt else { return }
        current = nil
        attempt.continuation.yield(
            .connected(
                ConnectedCamera(
                    saved: record(attempt, connection), session: connection.session,
                    services: connection.services)))
        attempt.continuation.finish()
    }

    private func failed(_ attempt: Attempt, _ error: Error) {
        guard current === attempt else { return }
        current = nil
        if !(error is CancellationError) {
            let joinFailure =
                (error as? CameraHotspotJoinRefusal)?.failure(
                    integration: DJICameraSessionAdapter.integration)
            var failure =
                error as? ConnectionFailure
                ?? joinFailure
                ?? Self.failure(
                    .other, "connect.failed",
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            failure.phase = failure.phase ?? attempt.last?.phase
            attempt.continuation.yield(.failed(withRouteActions(failure, attempt)))
        }
        attempt.continuation.finish()
    }

    static func failure(_ reason: ConnectionFailure.Reason, _ code: String, _ message: String)
        -> ConnectionFailure
    {
        ConnectionFailure(
            reason: reason, title: "Couldn’t connect over Camera Wi-Fi", message: message,
            actions: [.retry],
            code: "\(DJICameraSessionAdapter.integration.rawValue).\(code)")
    }

    /// Route actions: edit the setup that failed, or fall back to the camera's own Wi-Fi.
    private func withRouteActions(_ failure: ConnectionFailure, _ attempt: Attempt)
        -> ConnectionFailure
    {
        guard let route = attempt.route, route.kind != .cameraAccessPoint else { return failure }
        var failure = failure
        let camera: SavedCamera? =
            switch attempt.target {
            case .saved(let camera, _), .addRoute(let camera, _): camera
            case .nearby: nil
            }
        let ap = camera?.routes.first { $0.kind == .cameraAccessPoint }
        failure.title =
            "Couldn’t connect over \(route.title ?? route.network ?? (route.kind == .phoneHotspot ? "Hotspot" : "Wi-Fi"))"
        failure.actions =
            failure.actions.filter { $0 != .retry } + [.editRoute(route.id), .retry]
            + (ap.map { [.useRoute($0.id)] } ?? [])
        return failure
    }

    /// The saved record after a connect: the route it used as preferred, the joined camera
    /// network on camera Wi-Fi unless another camera owns it, the advertised name and model id
    /// (legacy save rules) and the time.
    private func record(_ attempt: Attempt, _ connection: DJIConnection) -> SavedCamera {
        var camera: SavedCamera
        switch attempt.target {
        case .saved(let saved, _): camera = saved
        case .addRoute(let saved, _):
            camera = saved
            if let route = attempt.route {
                camera.routes.removeAll { $0.key == route.key }
                camera.routes.append(route)
            }
        case .nearby(let nearby):
            camera = SavedCamera(
                id: nearby.savedID ?? nearby.id, integration: id, advertisedName: nearby.name,
                model: nearby.model)
        }
        if !camera.routes.contains(where: { $0.kind == .cameraAccessPoint }) {
            camera.routes.insert(
                SavedRoute(key: "ap", kind: .cameraAccessPoint, bluetooth: true), at: 0)
        }
        let identity = connection.camera ?? sightings.first { $0.id == camera.id }
        if let name = connection.camera?.name, !name.isEmpty { camera.advertisedName = name }
        if let modelId = identity?.modelId { camera.extras["modelId"] = String(modelId) }
        // The connect leaves the camera in the role of the route it used.
        camera.extras["lastSetup"] = nil
        let joined = connection.joinedNetwork.flatMap {
            Self.ownedElsewhere($0, by: camera, among: savedCameras()) ? nil : $0
        }
        if attempt.route == nil || attempt.route?.kind == .cameraAccessPoint, let joined,
            let index = camera.routes.firstIndex(where: { $0.kind == .cameraAccessPoint })
        {
            camera.routes[index].network = joined
        }
        let key = attempt.route?.key ?? "ap"
        camera.preferredRoute = (camera.routes.first { $0.key == key } ?? camera.routes[0]).id
        camera.lastConnected = now()
        return camera
    }
}
