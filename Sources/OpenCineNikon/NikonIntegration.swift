import Foundation
import OpenCineCore

/// One connect the app's connect funnel runs.
public enum NikonConnectRequest: Equatable, Sendable {
    /// A saved setup the operator chose, by its record's host and declared path.
    case saved(host: String, path: CameraPath.Kind)
    /// A camera discovery sees. `takeOver`: the operator agreed to drop the device holding it.
    case discovered(DiscoveredCamera, takeOver: Bool)
    /// A new setup of `path` for the saved camera whose setup at `anchorHost` names the body: the
    /// app watches for the body on that path, then connects.
    case addSetup(anchorHost: String, anchorPath: CameraPath.Kind, path: CameraPath.Kind)
}

/// A connected session and the setup the app saved it under.
public struct NikonConnection: Sendable {
    public var session: any CameraSession
    public var host: String
    public var path: CameraPath.Kind?

    public init(session: any CameraSession, host: String, path: CameraPath.Kind?) {
        self.session = session
        self.host = host
        self.path = path
    }
}

/// What `NikonIntegration` needs from the app's camera pipeline (OpenZCine: its discovery loop and
/// connect funnel). The app keeps its own save rules: it writes the saved setups as it always has
/// and the integration reads them back.
@MainActor
public protocol NikonConnectPort: AnyObject {
    /// Every discovery pass's cameras.
    var onSightings: (([DiscoveredCamera]) -> Void)? { get set }
    /// Every phase of the connect in flight, with the app's live line when it has one.
    var onPhase: ((CameraConnectionPhase, String?) -> Void)? { get set }
    /// The saved setups as the app stores them.
    var savedRecords: [PTPIPSavedCameraRecord] { get }
    /// Runs discovery passes in `mode` until `stopDiscovery`: `.passive` never dials a camera's
    /// control port (`NikonDiscovery`); `.active` may probe, for pairing.
    func startDiscovery(_ mode: DiscoveryMode)
    func stopDiscovery()
    /// The app's connect funnel. Throws a `ConnectionFailure` (another error is typed here) and
    /// `CancellationError` when cancelled.
    func connect(_ request: NikonConnectRequest) async throws -> NikonConnection
    func cancel()
    /// The app's forget for these setups: the records, the paired-host memory and the access
    /// point's Wi-Fi key. Never the app's pairing identity.
    func forget(hosts: [String])
}

/// Connecting would drop another device's live session on this camera (one initiator per body):
/// the operator decides first.
public struct NikonTakeOverPrompt: IntegrationPrompt {
    public var camera: String
    /// The device holding the camera, when it said.
    public var holder: String?
    public var confirm: @MainActor @Sendable () -> Void
    public var cancel: @MainActor @Sendable () -> Void

    public var fallbackText: String {
        guard let holder, !holder.isEmpty else {
            return "Another device is using this camera. Connecting will disconnect it."
        }
        return "\(holder) is using this camera. Connecting will disconnect it."
    }
}

/// The Nikon `CameraIntegration` (SHELL-02, Kotlin twin `NikonIntegration`) over the app's
/// pipeline: passive discovery for the cameras list and active discovery for pairing, one connect
/// at a time through the app's funnel, the card's steps from the app's connection phases,
/// approve-on-camera and network-join prompts, a take-over prompt before connecting to a camera
/// another device holds, typed failures, and forget.
@MainActor
public final class NikonIntegration: CameraIntegration {
    public nonisolated var id: IntegrationID { NikonCameraSession.integration }
    /// Bodies are told apart by what they report, not by a model table: one profile for the line.
    /// HDMI capture is a picture source, not a setup to add.
    public nonisolated let profiles = [
        CameraProfile(
            id: "\(NikonCameraSession.integration.rawValue).z", title: "Nikon Z", routes: Set(RouteKind.allCases),
            addableRoutes: [.cameraAccessPoint, .infrastructureNetwork, .phoneHotspot, .usb])
    ]
    public nonisolated let discoveryModes: Set<DiscoveryMode> = [.passive, .active]

    private let port: any NikonConnectPort
    private var sightings: [DiscoveredCamera] = []
    private var listeners: [UUID: (mode: DiscoveryMode, continuation: AsyncStream<[NearbyCamera]>.Continuation)] = [:]
    private var running: DiscoveryMode?
    private var current: Attempt?

    @MainActor
    private final class Attempt {
        let id = ConnectionAttemptID()
        let target: ConnectTarget
        let plan: [(step: ConnectionStep, phases: Set<CameraConnectionPhase>)]
        let device: String
        let network: String?
        let continuation: AsyncStream<ConnectionEvent>.Continuation
        var task: Task<Void, Never>?
        var last: ConnectionProgress?
        var lastPrompt: String?

        init(
            target: ConnectTarget, plan: [(step: ConnectionStep, phases: Set<CameraConnectionPhase>)], device: String,
            network: String?, continuation: AsyncStream<ConnectionEvent>.Continuation
        ) {
            self.target = target
            self.plan = plan
            self.device = device
            self.network = network
            self.continuation = continuation
        }
    }

    public init(port: any NikonConnectPort) {
        self.port = port
        port.onSightings = { [weak self] in self?.found($0) }
        port.onPhase = { [weak self] in self?.phase($0, $1) }
    }

    // MARK: Discovery

    public func discover(_ mode: DiscoveryMode) -> AsyncStream<[NearbyCamera]> {
        guard discoveryModes.contains(mode) else { return AsyncStream { $0.finish() } }
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [NearbyCamera].self, bufferingPolicy: .bufferingNewest(1))
        listeners[key] = (mode, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.listeners[key] = nil
                self?.updateDiscovery()
            }
        }
        continuation.yield(nearby())
        updateDiscovery()
        return stream
    }

    /// Active while any listener asks for it, else passive; stopped with no listener.
    private func updateDiscovery() {
        let wanted: DiscoveryMode? =
            listeners.isEmpty ? nil : listeners.values.contains { $0.mode == .active } ? .active : .passive
        guard wanted != running else { return }
        running = wanted
        if let wanted { port.startDiscovery(wanted) } else { port.stopDiscovery() }
    }

    private func found(_ cameras: [DiscoveredCamera]) {
        sightings = cameras
        let list = nearby()
        for listener in listeners.values { listener.continuation.yield(list) }
    }

    /// Sightings as the shared list shows them: a saved setup's sighting names its camera; a
    /// liveness answer only ever lights a saved camera.
    private func nearby() -> [NearbyCamera] {
        let records = port.savedRecords
        let cameras = NikonSavedRecordsV0.layout(records)
        return sightings.compactMap { sighting in
            let saved = CameraStartupPolicy.savedCamera(forDiscovered: sighting, in: records).flatMap { record in
                cameras.first { camera in camera.members.contains { records[$0.position].id == record.id } }?.camera.id
            }
            guard saved != nil || sighting.source != .liveness else { return nil }
            return NearbyCamera(
                id: sighting.id, savedID: saved, name: sighting.displayName, model: "",
                routes: [sighting.isUSB ? .usb : .infrastructureNetwork],
                availability: sighting.isHeldByAnotherDevice ? .unavailable(.busy) : .available)
        }
    }

    // MARK: Connecting

    public func connect(_ target: ConnectTarget) -> AsyncStream<ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        let request: NikonConnectRequest
        let device: String
        var network: String?
        switch target {
        case .saved(let camera, let routeID):
            guard let route = camera.routes.first(where: { $0.id == routeID }),
                let host = route.extras[NikonSavedRecordsV0.Extra.host]
            else { return failing(continuation, stream, "This setup can no longer be reached.") }
            request = .saved(host: host, path: NikonSavedRecordsV0.pathKind(route.kind))
            device = camera.displayName
            network = route.network
        case .nearby(let nearby):
            let sighting =
                sightings.first { $0.id == nearby.id }
                ?? DiscoveredCamera(ip: nearby.id, name: nearby.name, source: nearby.routes.contains(.usb) ? .usb : .subnetProbe)
            request = .discovered(sighting, takeOver: false)
            device = sighting.displayName
        case .addRoute(let camera, let draft):
            let anchor = camera.routes.first { $0.id == camera.preferredRoute } ?? camera.routes.first
            guard let anchor, let host = anchor.extras[NikonSavedRecordsV0.Extra.host], draft.kind != .captureDevice else {
                return failing(continuation, stream, "This setup cannot be added.")
            }
            request = .addSetup(
                anchorHost: host, anchorPath: NikonSavedRecordsV0.pathKind(anchor.kind),
                path: NikonSavedRecordsV0.pathKind(draft.kind))
            device = camera.displayName
        }
        // One funnel, one connection: a newer attempt ends the older one.
        if let older = current {
            current = nil
            older.task?.cancel()
            older.continuation.finish()
        }
        let attempt = Attempt(
            target: target, plan: Self.plan(request), device: device, network: network, continuation: continuation)
        current = attempt
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancel(attempt) }
        }
        if case .discovered(let sighting, _) = request, sighting.isHeldByAnotherDevice {
            askToTakeOver(attempt, sighting)
        } else {
            run(attempt, request)
        }
        return stream
    }

    public func forget(_ camera: SavedCamera) async {
        port.forget(hosts: camera.routes.compactMap { $0.extras[NikonSavedRecordsV0.Extra.host] })
    }

    private func failing(
        _ continuation: AsyncStream<ConnectionEvent>.Continuation, _ stream: AsyncStream<ConnectionEvent>, _ message: String
    ) -> AsyncStream<ConnectionEvent> {
        continuation.yield(.failed(Self.failure(.unsupported, "route.unsupported", message)))
        continuation.finish()
        return stream
    }

    private func askToTakeOver(_ attempt: Attempt, _ sighting: DiscoveredCamera) {
        let prompt = NikonTakeOverPrompt(
            camera: sighting.displayName, holder: sighting.heldByDeviceName,
            confirm: { [weak self] in
                guard let self, self.current === attempt, attempt.task == nil else { return }
                self.run(attempt, .discovered(sighting, takeOver: true))
            },
            cancel: { [weak self] in
                guard let self, self.current === attempt else { return }
                self.current = nil
                attempt.continuation.finish()
            })
        let progress = ConnectionProgress(
            attempt: attempt.id, phase: .negotiating, steps: attempt.plan.map(\.step), current: 0)
        attempt.continuation.yield(.progress(progress, prompt: .integration(prompt)))
    }

    private func run(_ attempt: Attempt, _ request: NikonConnectRequest) {
        attempt.task = Task { [weak self, port] in
            do {
                let connection = try await port.connect(request)
                self?.connected(attempt, connection)
            } catch {
                self?.failed(attempt, error)
            }
        }
    }

    private func cancel(_ attempt: Attempt) {
        guard current === attempt else { return }
        current = nil
        attempt.task?.cancel()
        port.cancel()
    }

    /// The card's plan for a request; each step lists the app phases it covers.
    static func plan(_ request: NikonConnectRequest) -> [(step: ConnectionStep, phases: Set<CameraConnectionPhase>)] {
        let join = (ConnectionStep(title: "Joining the camera’s Wi-Fi"), Set<CameraConnectionPhase>([.readyToJoin, .joiningWiFi]))
        let find = (ConnectionStep(title: "Finding the camera"), Set<CameraConnectionPhase>([.discovering]))
        let connect = (ConnectionStep(title: "Connecting"), Set<CameraConnectionPhase>([.handshaking]))
        let pair = (ConnectionStep(title: "Pairing"), Set<CameraConnectionPhase>([.pairing, .confirmOnCamera]))
        let live = (ConnectionStep(title: "Starting live view"), Set<CameraConnectionPhase>([.preparingLiveView]))
        switch request {
        case .saved(_, .cameraAccessPoint): return [join, find, connect, live]
        case .saved: return [find, connect, live]
        case .discovered: return [connect, pair, live]
        case .addSetup(_, _, let path):
            return [
                (ConnectionStep(title: "Waiting for the camera on \(Self.label(path))"), [.discovering, .readyToJoin, .joiningWiFi]),
                connect, live,
            ]
        }
    }

    private static func label(_ path: CameraPath.Kind) -> String {
        switch path {
        case .cameraAccessPoint: "its Wi-Fi"
        case .infrastructure: "Wi-Fi"
        case .phoneHotspot: "your hotspot"
        case .usbC: "USB-C"
        case .hdmiCapture: "HDMI"
        }
    }

    private func phase(_ phase: CameraConnectionPhase, _ detail: String?) {
        guard let attempt = current, attempt.task != nil else { return }
        let core: ConnectionPhase
        let prompt: ConnectionPrompt?
        let text =
            detail.flatMap { $0.isEmpty ? nil : $0 }
            ?? ConnectionProgressCopy.statusDetail(phase: phase, deviceName: attempt.device, friendlyError: nil)
        switch phase {
        case .readyToJoin, .joiningWiFi:
            core = .joiningNetwork
            prompt = .acceptNetworkJoin(network: attempt.network ?? attempt.device, text)
        case .discovering: (core, prompt) = (.link, nil)
        case .handshaking, .preparingLiveView: (core, prompt) = (.negotiating, nil)
        case .pairing, .confirmOnCamera: (core, prompt) = (.awaitingApproval, .approveOnCamera(text))
        case .idle, .connected, .failed: return
        }
        let step =
            attempt.plan.firstIndex { $0.phases.contains(phase) } ?? attempt.last?.current ?? 0
        let progress = ConnectionProgress(
            attempt: attempt.id, phase: core, steps: attempt.plan.map(\.step), current: step,
            note: prompt == nil ? text : nil)
        guard progress != attempt.last || prompt?.text != attempt.lastPrompt else { return }
        attempt.last = progress
        attempt.lastPrompt = prompt?.text
        attempt.continuation.yield(.progress(progress, prompt: prompt))
    }

    private func connected(_ attempt: Attempt, _ connection: NikonConnection) {
        guard current === attempt else { return }
        current = nil
        attempt.continuation.yield(.connected(ConnectedCamera(saved: record(attempt, connection), session: connection.session)))
        attempt.continuation.finish()
    }

    private func failed(_ attempt: Attempt, _ error: Error) {
        guard current === attempt else { return }
        current = nil
        if !(error is CancellationError) {
            var failure = error as? ConnectionFailure ?? Self.failure(error, message: nil)
            failure.phase = failure.phase ?? attempt.last?.phase
            attempt.continuation.yield(.failed(failure))
        }
        attempt.continuation.finish()
    }

    /// The saved camera the app's save rules produced for this session, read back from its
    /// records; route ids the attempt's camera already had are kept.
    private func record(_ attempt: Attempt, _ connection: NikonConnection) -> SavedCamera {
        let host = PTPIPPairedHosts.normalizedHost(connection.host) ?? connection.host
        let previous: SavedCamera? =
            switch attempt.target {
            case .saved(let camera, _), .addRoute(let camera, _): camera
            case .nearby: nil
            }
        let cameras = NikonSavedRecordsV0.cameras(from: port.savedRecords)
        let matches = { (route: SavedRoute) in
            route.extras[NikonSavedRecordsV0.Extra.host] == host
                && (connection.path.map { NikonSavedRecordsV0.routeKind($0) == route.kind } ?? true)
        }
        guard var camera = cameras.first(where: { $0.routes.contains(where: matches) }) else {
            return previous
                ?? SavedCamera(
                    id: host, integration: id, advertisedName: attempt.device, model: "",
                    routes: [SavedRoute(key: "untyped", kind: .infrastructureNetwork, extras: [NikonSavedRecordsV0.Extra.host: host])])
        }
        if let previous {
            camera.routes = camera.routes.map { route in
                var route = route
                if let mine = previous.routes.first(where: { $0.key == route.key }) { route.id = mine.id }
                return route
            }
        }
        camera.preferredRoute = camera.routes.first(where: matches)?.id ?? camera.preferredRoute
        return camera
    }

    static func failure(_ reason: ConnectionFailure.Reason, _ code: String, _ message: String) -> ConnectionFailure {
        ConnectionFailure(
            reason: reason, title: "Couldn't connect", message: message,
            actions: reason == .permission(.localNetwork) ? [.openSettings, .retry] : [.retry],
            code: "\(NikonCameraSession.integration.rawValue).\(code)")
    }

    /// A connect error, typed. `message`: the app's operator copy for it; `nil` uses the error's.
    public static func failure(_ error: Error, message: String?) -> ConnectionFailure {
        let text = message ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard let error = error as? NativeCameraSessionError else { return failure(.other, "connect.failed", text) }
        return switch error {
        case .initFailed(.busy): failure(.heldElsewhere, "init.busy", text)
        case .localNetworkPermissionDenied: failure(.permission(.localNetwork), "local-network.denied", text)
        case .pairingRejected: failure(.notApproved, "pairing.rejected", text)
        case .timeout: failure(.timedOut, "timeout", text)
        case .noHost: failure(.notFound, "no-host", text)
        case .connectionClosed: failure(.linkLost, "link.closed", text)
        case .savedProfileRequired, .pairingChallengeUnavailable: failure(.notApproved, "pairing.required", text)
        default: failure(.other, "connect.failed", text)
        }
    }
}
