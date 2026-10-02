import Foundation
import OpenCineCore

extension ConnectionFailure {
    /// A Luna connection failure. The message is the copy the backend has always shown; the code
    /// is `<integration>.<code>` for diagnostics.
    static func luna(
        _ reason: Reason, _ code: String, _ message: String, phase: ConnectionPhase? = nil,
        actions: [RecoveryAction] = [.retry]
    ) -> ConnectionFailure {
        ConnectionFailure(
            reason: reason, phase: phase, title: "Couldn’t connect over Camera Wi-Fi", message: message,
            actions: actions, code: "\(LunaCameraSession.integration.rawValue).\(code)")
    }

    static let lunaHeldElsewhere = luna(
        .heldElsewhere, "approval.held-elsewhere",
        "The camera is connected to another phone. Close the Insta360 app on the other device, then connect again.",
        phase: .awaitingApproval)
    static let lunaLinkClosed = luna(.linkLost, "link.closed", "The camera connection is not open.")
    static let lunaBluetoothClosed = luna(
        .linkLost, "bluetooth.closed", "The camera Bluetooth connection closed.", phase: .link)
}

/// What `LunaIntegration` needs from the Luna backend: discovery, one connection, its session,
/// and forgetting a camera's saved Wi-Fi. `LunaCameraBackend` is the one implementation; tests
/// script a fake.
@MainActor
public protocol LunaConnectPort: AnyObject {
    var eventHandler: ((CameraBackendEvent) -> Void)? { get set }
    /// The serial the last connection verified; `nil` when none was read.
    var connectedSerial: String? { get }
    /// The camera network the last connection joined.
    var joinedNetwork: String? { get }
    func startScan() async throws
    func stopScan()
    /// Bluetooth bootstrap or saved Wi-Fi, then the control link. Throws `ConnectionFailure`.
    func connect(to camera: MonitorCamera) async throws
    func disconnect()
    /// A new core session for the next connection; the previous one closes as replaced.
    func openSession() -> LunaCameraSession
    /// Drops the camera's saved Wi-Fi. The approval identity stays.
    func forget(cameraID: UUID)
}

extension LunaCameraBackend: LunaConnectPort {
    public var connectedSerial: String? { deviceInformation?.serial }
    public var joinedNetwork: String? { credentials?.ssid }
}

/// The Luna `CameraIntegration` (SHELL-02): passive Bluetooth discovery, one connection at a time
/// over the backend's Bluetooth bootstrap or saved Wi-Fi, approval and network-join prompts,
/// typed failures with the backend's copy, and forget. Every backend event is also forwarded to
/// `onEvent` (video, camera information, drops) for the app's live view.
@MainActor
public final class LunaIntegration: CameraIntegration {
    public nonisolated var id: IntegrationID { LunaCameraSession.integration }
    public nonisolated let profiles = [
        CameraProfile(
            id: "\(LunaCameraSession.integration.rawValue).luna-ultra", title: "Luna Ultra", routes: [.cameraAccessPoint])
    ]
    public nonisolated let discoveryModes: Set<DiscoveryMode> = [.passive]
    public var onEvent: ((CameraBackendEvent) -> Void)?

    /// The connect card's plan, in the order the backend runs it.
    public static let steps = [
        ConnectionStep(title: "Connecting over Bluetooth"), ConnectionStep(title: "Joining camera Wi-Fi"),
        ConnectionStep(title: "Opening the video link"), ConnectionStep(title: "Starting the picture"),
    ]
    static let approve = "Approve on the camera"
    static let join = "Tap Join when iOS asks to join the camera network"

    private let port: any LunaConnectPort
    private let now: () -> Date
    private var sightings: [NearbyCamera] = []
    private var listeners: [UUID: AsyncStream<[NearbyCamera]>.Continuation] = [:]
    private var current: Attempt?

    @MainActor
    private final class Attempt {
        let target: ConnectTarget
        let camera: MonitorCamera
        let continuation: AsyncStream<ConnectionEvent>.Continuation
        let id = ConnectionAttemptID()
        var task: Task<Void, Never>?
        var phase: ConnectionPhase = .link
        var step = 0
        var prompt: ConnectionPrompt?
        var note: String?

        init(target: ConnectTarget, camera: MonitorCamera, continuation: AsyncStream<ConnectionEvent>.Continuation) {
            self.target = target
            self.camera = camera
            self.continuation = continuation
        }
    }

    public init(port: any LunaConnectPort, now: @escaping () -> Date = Date.init) {
        self.port = port
        self.now = now
        port.eventHandler = { [weak self] event in self?.handle(event) }
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
        continuation.yield(sightings)
        if first {
            Task { [weak self] in
                do {
                    try await self?.port.startScan()
                } catch {
                    // ponytail: a scan that cannot start (Bluetooth off or denied) ends discovery;
                    // the attempt reports the typed reason. Add a discovery error when a screen shows one.
                    self?.endDiscovery()
                }
            }
        }
        return stream
    }

    private func stopListening(_ key: UUID) {
        guard listeners.removeValue(forKey: key) != nil, listeners.isEmpty else { return }
        port.stopScan()
    }

    private func endDiscovery() {
        let ended = listeners.values
        listeners.removeAll()
        for continuation in ended { continuation.finish() }
    }

    // MARK: Connecting

    public func connect(_ target: ConnectTarget) -> AsyncStream<ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        guard let camera = Self.monitorCamera(for: target) else {
            continuation.yield(
                .failed(.luna(.unsupported, "route.unsupported", "This camera connects over its own Wi-Fi only.")))
            continuation.finish()
            return stream
        }
        // One backend, one connection: a newer attempt ends the older one, whichever camera.
        current?.continuation.finish()
        let attempt = Attempt(target: target, camera: camera, continuation: continuation)
        current = attempt
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancel(attempt) }
        }
        let session = port.openSession()
        report(attempt)
        attempt.task = Task { [weak self] in
            do {
                try await self?.port.connect(to: camera)
                self?.connected(attempt, session: session)
            } catch {
                self?.failed(attempt, error)
            }
        }
        return stream
    }

    public func forget(_ camera: SavedCamera) async {
        if let id = UUID(uuidString: camera.id) { port.forget(cameraID: id) }
    }

    private func cancel(_ attempt: Attempt) {
        guard current === attempt else { return }
        current = nil
        attempt.task?.cancel()
        port.disconnect()
    }

    private func connected(_ attempt: Attempt, session: LunaCameraSession) {
        guard current === attempt else { return }
        current = nil
        attempt.continuation.yield(.connected(ConnectedCamera(saved: record(attempt), session: session)))
        attempt.continuation.finish()
    }

    private func failed(_ attempt: Attempt, _ error: Error) {
        guard current === attempt else { return }
        current = nil
        if !(error is CancellationError) {
            var failure =
                error as? ConnectionFailure
                ?? .luna(.other, "unexpected", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            failure.phase = failure.phase ?? attempt.phase
            attempt.continuation.yield(.failed(failure))
        }
        attempt.continuation.finish()
    }

    private func handle(_ event: CameraBackendEvent) {
        switch event {
        case .discovered(let camera):
            let sighting = NearbyCamera(
                id: camera.id.uuidString, name: camera.name, model: camera.model, routes: [.cameraAccessPoint])
            if let index = sightings.firstIndex(where: { $0.id == sighting.id }) {
                guard sightings[index] != sighting else { break }
                sightings[index] = sighting
            } else {
                sightings.append(sighting)
            }
            for continuation in listeners.values { continuation.yield(sightings) }
        case .phase(let phase):
            if let attempt = current, Self.apply(phase, to: attempt, network: port.joinedNetwork) { report(attempt) }
        case .note(let text):
            if let attempt = current, case .acceptNetworkJoin(let network, _) = attempt.prompt {
                attempt.prompt = .acceptNetworkJoin(network: network, text)
                report(attempt)
            }
        default: break
        }
        onEvent?(event)
    }

    private func report(_ attempt: Attempt) {
        attempt.continuation.yield(
            .progress(
                ConnectionProgress(
                    attempt: attempt.id, phase: attempt.phase, steps: Self.steps, current: attempt.step,
                    note: attempt.note),
                prompt: attempt.prompt))
    }

    /// The backend's link phase as the attempt's phase, step and prompt (the same phases
    /// `LunaCameraSession` reports). `false` for phases that are not progress (`idle`).
    private static func apply(_ phase: CameraConnectionPhase, to attempt: Attempt, network: String?) -> Bool {
        attempt.note = nil
        switch phase {
        case .idle: return false
        case .scanning:
            (attempt.phase, attempt.step, attempt.prompt) = (.link, 0, nil)
            attempt.note = "Looking for the camera"
        case .connecting, .negotiating: (attempt.phase, attempt.step, attempt.prompt) = (.negotiating, 0, nil)
        case .awaitingApproval:
            (attempt.phase, attempt.step, attempt.prompt) = (.awaitingApproval, 0, .approveOnCamera(approve))
        case .readingWiFi, .joiningWiFi:
            (attempt.phase, attempt.step) = (.joiningNetwork, 1)
            if case .acceptNetworkJoin = attempt.prompt {} else {
                attempt.prompt = .acceptNetworkJoin(network: network ?? "", join)
            }
        case .openingVideo: (attempt.phase, attempt.step, attempt.prompt) = (.link, 2, nil)
        case .streaming: (attempt.phase, attempt.step, attempt.prompt) = (.link, 3, nil)
        }
        return true
    }

    private static func monitorCamera(for target: ConnectTarget) -> MonitorCamera? {
        switch target {
        case .saved(let camera, _):
            UUID(uuidString: camera.id).map {
                MonitorCamera(id: $0, name: camera.advertisedName, model: camera.model, capabilities: [.liveVideo])
            }
        case .nearby(let camera):
            UUID(uuidString: camera.id).map {
                MonitorCamera(id: $0, name: camera.name, model: camera.model, capabilities: [.liveVideo])
            }
        case .addRoute: nil
        }
    }

    /// The saved record after a connect: the camera's access point (Bluetooth first) as the
    /// preferred route with the network it joined, the verified serial, and the time.
    private func record(_ attempt: Attempt) -> SavedCamera {
        var camera: SavedCamera
        switch attempt.target {
        case .saved(let saved, _), .addRoute(let saved, _): camera = saved
        case .nearby(let nearby):
            camera = SavedCamera(
                id: nearby.savedID ?? nearby.id, integration: id, advertisedName: nearby.name, model: nearby.model)
        }
        camera.lastConnected = now()
        if let serial = port.connectedSerial, !serial.isEmpty { camera.device = .durable(serial, integration: id) }
        let network = port.joinedNetwork
        if let index = camera.routes.firstIndex(where: { $0.kind == .cameraAccessPoint }) {
            if let network { camera.routes[index].network = network }
            camera.preferredRoute = camera.routes[index].id
        } else {
            let route = SavedRoute(key: "ap", kind: .cameraAccessPoint, network: network, bluetooth: true)
            camera.routes.insert(route, at: 0)
            camera.preferredRoute = route.id
        }
        return camera
    }
}
