import Foundation
import OpenCineCore
import OpenCineMedia

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
    /// Whether this run has heard the camera advertise, so Bluetooth can reach it now.
    func hasSeen(_ cameraID: UUID) -> Bool
    /// Whether saved camera Wi-Fi exists for a camera that is not advertising.
    func hasSavedWiFi(cameraID: UUID) -> Bool
    /// Bluetooth bootstrap or saved Wi-Fi, then the control link. Throws `ConnectionFailure`.
    func connect(to camera: MonitorCamera) async throws
    func disconnect()
    /// A new core session for the next connection; the previous one closes as replaced.
    func openSession() -> LunaCameraSession
    /// Optional source service for this exact session, registered by the connected camera.
    func mediaService(for session: CameraSessionID) -> (any CameraMediaService)?
    /// Drops the camera's saved Wi-Fi. The approval identity stays.
    func forget(cameraID: UUID)
}

extension LunaConnectPort {
    public func mediaService(for session: CameraSessionID) -> (any CameraMediaService)? { nil }
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
    /// Why passive discovery is not running (Bluetooth off or not allowed); `nil` while it runs.
    /// Discovery stays subscribed: the app shows this in its pairing slot and calls
    /// `retryDiscovery()` (back from Settings, for example).
    public private(set) var discoveryFailure: ConnectionFailure? {
        didSet {
            if discoveryFailure != oldValue {
                onDiscoveryFailure?(discoveryFailure)
                publishDiscoveryRunning()
            }
        }
    }
    public var onDiscoveryFailure: ((ConnectionFailure?) -> Void)?

    /// The connect card's plan, in the order the backend runs it.
    public static let steps = [
        ConnectionStep(title: "Connecting over Bluetooth"), ConnectionStep(title: "Joining camera Wi-Fi"),
        ConnectionStep(title: "Opening the video link"), ConnectionStep(title: "Starting the picture"),
    ]
    /// How long a saved connection gives Bluetooth to hear the camera before saved Wi-Fi.
    static let sightingGrace: TimeInterval = 4
    static let sightingStep = Duration.milliseconds(100)
    static let approve = "Approve on the camera"
    static let reading = "Reading Wi-Fi credentials…"
    static let joining = "Joining camera Wi-Fi…"

    private let port: any LunaConnectPort
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var sightings: [NearbyCamera] = []
    private var listeners: [UUID: AsyncStream<[NearbyCamera]>.Continuation] = [:]
    /// Sighting graces holding the scan, so the last discovery listener leaving cannot stop it.
    private var graceScans = 0
    private var runningListeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
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

    public init(
        port: any LunaConnectPort, now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.port = port
        self.now = now
        self.sleep = sleep
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
        if first { startScanning() }
        return stream
    }

    /// Starts the scan again while discovery is subscribed and not running.
    public func retryDiscovery() {
        if !listeners.isEmpty, discoveryFailure != nil { startScanning() }
    }

    /// Whether passive discovery is running now (IA-336): a failed start leaves the pages without
    /// a scanning status until `retryDiscovery()` succeeds.
    public var discoveryRunning: AsyncStream<Bool> {
        AsyncStream<Bool> { continuation in
            let key = UUID()
            runningListeners[key] = continuation
            continuation.yield(discoveryFailure == nil)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.runningListeners[key] = nil }
            }
        }
    }

    private func publishDiscoveryRunning() {
        for continuation in runningListeners.values { continuation.yield(discoveryFailure == nil) }
    }

    private func startScanning() {
        Task { [weak self] in
            do {
                try await self?.port.startScan()
                self?.discoveryFailure = nil
            } catch {
                guard let self, !self.listeners.isEmpty else { return }
                self.discoveryFailure =
                    error as? ConnectionFailure ?? .luna(.other, "bluetooth.scan-failed", error.localizedDescription)
            }
        }
    }

    private func stopListening(_ key: UUID) {
        guard listeners.removeValue(forKey: key) != nil, listeners.isEmpty else { return }
        discoveryFailure = nil
        // A sighting grace still waiting for the advert keeps the scan (Kotlin twin: `listening`).
        if graceScans == 0 { port.stopScan() }
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
            // Replaced before it started: never dial the older camera.
            if let self, self.current !== attempt { return }
            await self?.waitForSightingIfSaved(attempt)
            if let self, self.current !== attempt { return }
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

    /// The baseline grace for a saved camera: Bluetooth for a few seconds first, because an
    /// advert proves the camera is awake and waking its Wi-Fi is quicker than dialling a sleeping
    /// access point. Only a camera with saved Wi-Fi is dialled after the grace; one without it
    /// stays on the Bluetooth path, which the backend has always taken at once.
    private func waitForSightingIfSaved(_ attempt: Attempt) async {
        guard case .saved(let saved, _) = attempt.target, let id = UUID(uuidString: saved.id),
            port.hasSavedWiFi(cameraID: id), !port.hasSeen(id)
        else { return }
        attempt.note = "Looking for the camera"
        report(attempt)
        // A radio that cannot scan still has the saved Wi-Fi route (the baseline did the same).
        guard (try? await port.startScan()) != nil else {
            attempt.note = nil
            return
        }
        graceScans += 1
        defer {
            graceScans -= 1
            // A cancelled grace stops the scan it needed unless a listener still wants it.
            if Task.isCancelled, graceScans == 0, listeners.isEmpty { port.stopScan() }
        }
        let deadline = now().addingTimeInterval(Self.sightingGrace)
        while !port.hasSeen(id), now() < deadline {
            if Task.isCancelled { return }
            do { try await sleep(Self.sightingStep) } catch { return }
        }
        attempt.note = nil
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
        var services = CameraServices()
        if let media = port.mediaService(for: session.id), media.sessionID == session.id {
            services.register(media, as: (any CameraMediaService).self)
        }
        attempt.continuation.yield(
            .connected(ConnectedCamera(saved: record(attempt), session: session, services: services)))
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
            failure.message = Self.operatorMessage(failure.message)
            attempt.continuation.yield(.failed(failure))
        }
        attempt.continuation.finish()
    }

    private func handle(_ event: CameraBackendEvent) {
        switch event {
        case .discovered(let camera):
            let sighting = NearbyCamera(
                id: camera.id.uuidString, name: Self.title(advertised: camera.name), model: profiles[0].title,
                routes: [.cameraAccessPoint])
            if let index = sightings.firstIndex(where: { $0.id == sighting.id }) {
                guard sightings[index] != sighting else { break }
                sightings[index] = sighting
            } else {
                sightings.append(sighting)
            }
            for continuation in listeners.values { continuation.yield(sightings) }
        case .phase(let phase):
            if let attempt = current, Self.apply(phase, to: attempt) { report(attempt) }
        default: break
        }
        onEvent?(event)
    }

    /// A sighting's name: Luna advertises the last characters of its serial, shown after the model.
    public static func title(advertised: String) -> String {
        let trimmed = advertised.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Luna Ultra" }
        if trimmed.lowercased().contains("luna") { return trimmed }
        return "Luna Ultra \(trimmed)"
    }

    /// What the operator reads for a failed attempt: the backend's copy, except time-outs and
    /// dropped links, which read as OpenInstaCine has always shown them (its `friendly()` rules).
    static func operatorMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return "The camera didn't respond in time. Check Bluetooth, force quit the Insta360 app on every phone near the camera, then try again."
        }
        if lower.contains("disconnected") || lower.contains("camera disappeared") {
            return "The camera ended the connection. Force quit the Insta360 app on every phone near the camera, then try again."
        }
        return raw
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
    private static func apply(_ phase: CameraConnectionPhase, to attempt: Attempt) -> Bool {
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
            // The Wi-Fi step's caption is its phase, as the app has always shown it.
            (attempt.phase, attempt.step, attempt.prompt) = (.joiningNetwork, 1, nil)
            attempt.note = phase == .readingWiFi ? reading : joining
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
