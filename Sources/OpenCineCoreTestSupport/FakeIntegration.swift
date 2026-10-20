import Foundation
import OpenCineCore

/// A scripted `CameraIntegration`. Tests publish nearby lists, drive each attempt and read what
/// discovery dialled. Discovery dials every endpoint for presence; `.active` also dials its
/// control port, so a passive run never logs a `.cameraControl` dial.
@MainActor
public final class FakeIntegration: CameraIntegration {
    public enum DialPurpose: Hashable, Sendable {
        /// Reachability only; cannot reach a camera's control service.
        case presence
        case cameraControl
    }

    public struct Dial: Hashable, Sendable {
        public var endpoint: String
        public var purpose: DialPurpose
    }

    public nonisolated let id: IntegrationID
    public nonisolated let profiles: [CameraProfile]
    public nonisolated let discoveryModes: Set<DiscoveryMode>
    /// What `discoveryRunning` reports; `false` scripts a blocked radio or denied permission.
    public nonisolated let discoveryIsRunning: Bool
    /// The plan every attempt reports.
    public var steps: [ConnectionStep]
    /// Hosts discovery dials.
    public var endpoints: [String]
    /// Called with each new attempt before `connect` returns: a SIMULATED app answers every
    /// connect here (`attempt.connect(session:)`) instead of scripting it from a test.
    public var onAttempt: ((FakeAttempt) -> Void)?

    public private(set) var dials: [Dial] = []
    /// Modes discovery started with, in order.
    public private(set) var discoveries: [DiscoveryMode] = []
    public private(set) var attempts: [FakeAttempt] = []
    public private(set) var forgotten: [SavedCamera] = []
    private var nearby: [NearbyCamera] = []
    private let runs = Locked<[UUID: Run]>([:])

    private struct Run {
        var mode: DiscoveryMode
        var continuation: AsyncStream<[NearbyCamera]>.Continuation
    }

    public init(
        id: IntegrationID = IntegrationID("test.fake-integration"),
        profiles: [CameraProfile] = [
            CameraProfile(
                id: "test.fake-integration.body", title: "Test Body",
                routes: [.cameraAccessPoint, .infrastructureNetwork], addableRoutes: [.infrastructureNetwork])
        ],
        discoveryModes: Set<DiscoveryMode> = [.passive, .active],
        steps: [ConnectionStep] = [
            ConnectionStep(title: "Link"), ConnectionStep(title: "Approve"),
            ConnectionStep(title: "Join network"), ConnectionStep(title: "Video"),
        ],
        endpoints: [String] = [],
        discoveryRunning: Bool = true
    ) {
        self.id = id
        self.profiles = profiles
        self.discoveryModes = discoveryModes
        self.steps = steps
        self.endpoints = endpoints
        self.discoveryIsRunning = discoveryRunning
    }

    /// A stable status stream, as an integration that cannot change its radio reports.
    public nonisolated var discoveryRunning: AsyncStream<Bool> {
        let running = discoveryIsRunning
        return AsyncStream<Bool> { continuation in
            continuation.yield(running)
            continuation.finish()
        }
    }

    /// Modes of the discovery runs whose consumer is still listening.
    public var liveDiscoveries: [DiscoveryMode] { runs.withLock { $0.values.map(\.mode) } }

    /// The attempt for a camera that is still running, if any.
    public func liveAttempt(for cameraID: String) -> FakeAttempt? {
        attempts.last { $0.target.cameraID == cameraID && $0.end == nil }
    }

    /// Replaces the nearby list and yields it to every live discovery run.
    public func publish(_ list: [NearbyCamera]) {
        nearby = list
        for run in runs.withLock({ Array($0.values) }) { run.continuation.yield(list) }
    }

    public func discover(_ mode: DiscoveryMode) -> AsyncStream<[NearbyCamera]> {
        guard discoveryModes.contains(mode) else { return AsyncStream { $0.finish() } }
        discoveries.append(mode)
        for endpoint in endpoints {
            dials.append(Dial(endpoint: endpoint, purpose: .presence))
            if mode == .active { dials.append(Dial(endpoint: endpoint, purpose: .cameraControl)) }
        }
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [NearbyCamera].self, bufferingPolicy: .bufferingNewest(1))
        runs.withLock { $0[key] = Run(mode: mode, continuation: continuation) }
        continuation.onTermination = { [runs] _ in runs.withLock { $0[key] = nil } }
        continuation.yield(nearby)
        return stream
    }

    public func connect(_ target: ConnectTarget) -> AsyncStream<ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        liveAttempt(for: target.cameraID)?.finish(.superseded)
        let attempt = FakeAttempt(integration: id, target: target, steps: steps, continuation: continuation)
        attempts.append(attempt)
        onAttempt?(attempt)
        return stream
    }

    public func forget(_ camera: SavedCamera) async { forgotten.append(camera) }
}

/// One scripted attempt. Its events reach the consumer only while it is live: once it is
/// connected, failed, cancelled by the consumer or superseded by a newer attempt for the same
/// camera, everything it tries to emit is dropped.
@MainActor
public final class FakeAttempt {
    public enum End: Hashable, Sendable {
        case connected
        case failed
        /// The consumer stopped listening.
        case cancelled
        /// A newer attempt for the same camera started.
        case superseded
    }

    public let id = ConnectionAttemptID()
    public let target: ConnectTarget
    public let steps: [ConnectionStep]
    private let integration: IntegrationID
    private let continuation: AsyncStream<ConnectionEvent>.Continuation
    private let ended = Locked<End?>(nil)
    /// Events this attempt tried to emit after it ended (what a late callback would do).
    public private(set) var dropped = 0

    init(
        integration: IntegrationID, target: ConnectTarget, steps: [ConnectionStep],
        continuation: AsyncStream<ConnectionEvent>.Continuation
    ) {
        self.integration = integration
        self.target = target
        self.steps = steps
        self.continuation = continuation
        continuation.onTermination = { [ended] _ in
            ended.withLock { if $0 == nil { $0 = .cancelled } }
        }
    }

    /// `nil` while the attempt runs.
    public var end: End? { ended.withLock { $0 } }

    public func progress(
        _ phase: ConnectionPhase, step: Int, prompt: ConnectionPrompt? = nil, note: String? = nil
    ) {
        emit(.progress(
            ConnectionProgress(attempt: id, phase: phase, steps: steps, current: step, note: note),
            prompt: prompt))
    }

    /// Connects with `saved`, else the record a first connect would build from the target.
    public func connect(
        session: any CameraSession, saved: SavedCamera? = nil, services: CameraServices = .init()
    ) {
        let record = saved ?? defaultRecord()
        if emit(.connected(ConnectedCamera(saved: record, session: session, services: services))) {
            finish(.connected)
        }
    }

    public func fail(_ failure: ConnectionFailure) {
        if emit(.failed(failure)) { finish(.failed) }
    }

    func finish(_ end: End) {
        ended.withLock { if $0 == nil { $0 = end } }
        continuation.finish()
    }

    @discardableResult
    private func emit(_ event: ConnectionEvent) -> Bool {
        guard end == nil, case .enqueued = continuation.yield(event) else {
            dropped += 1
            return false
        }
        return true
    }

    private func defaultRecord() -> SavedCamera {
        switch target {
        case .saved(let camera, _), .addRoute(let camera, _): camera
        case .nearby(let nearby):
            SavedCamera(
                id: nearby.savedID ?? nearby.id, integration: integration, advertisedName: nearby.name,
                model: nearby.model,
                routes: RouteKind.allCases.filter(nearby.routes.contains).map {
                    SavedRoute(key: $0.rawValue, kind: $0)
                })
        }
    }
}

/// A value behind a lock, for state a stream's termination handler changes off the main actor.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
