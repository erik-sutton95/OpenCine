import Foundation
import Observation
import OpenCineCore

/// The shared connection flow over the app's integrations: saved cameras, nearby sightings, at
/// most one live attempt per camera, the last failure per camera and the pairing state.
///
/// Discovery: while no camera is live and no attempt runs, every integration discovers in
/// `.passive`; the pair page asks for `.active` from the integrations that list it. A stale event
/// from an attempt the model replaced or cancelled is dropped. Recovery while live stays the
/// integration's; the app hands the live session back with `sessionEnded()`.
// macOS 14 for Observation; the package keeps macOS 13 for its other products (host tests only).
@available(macOS 14, *)
@MainActor
@Observable
public final class CamerasModel {
    /// A camera one integration sees now.
    public struct Sighting: Hashable, Identifiable {
        public var integration: IntegrationID
        public var camera: NearbyCamera
        public var id: String { camera.id }
    }

    /// The live attempt for one camera.
    public struct Attempt {
        public var target: ConnectTarget
        public var integration: IntegrationID
        /// `nil` until the integration reports its plan.
        public var progress: ConnectionProgress?
        public var prompt: ConnectionPrompt?
        fileprivate var token = UUID()
        fileprivate var task: Task<Void, Never>?

        /// The route this attempt uses, when it is a saved route.
        public var route: ConnectionRouteID? {
            if case .saved(_, let route) = target { return route }
            return nil
        }
    }

    /// How the last attempt for a camera ended, and what retrying it means.
    public struct Failure {
        public var failure: ConnectionFailure
        public var target: ConnectTarget
    }

    /// The saved route a camera's card shows and a tap connects when no attempt or failure names one.
    public enum RoutePolicy: Sendable {
        /// The camera's preferred route, else its first.
        case preferred
        /// The first route a sighting reaches (`NearbyCamera.routeKey`), else `.preferred`.
        case preferReachable
    }

    /// What a failure action asks of the app that the model cannot do itself.
    public enum Request: Equatable {
        case openSettings
        case editRoute(SavedCamera, ConnectionRouteID)
        case pairAgain
        case integration(id: String, camera: String)
    }

    public let entries: [AppIntegration]
    public private(set) var saved: [SavedCamera] = []
    public private(set) var nearby: [Sighting] = []
    /// Keyed by `ConnectTarget.cameraID`.
    public private(set) var attempts: [String: Attempt] = [:]
    /// Keyed by `ConnectTarget.cameraID`; cleared by the next attempt.
    public private(set) var failures: [String: Failure] = [:]
    public private(set) var connected: ConnectedCamera?
    public private(set) var pairing = false
    /// Some integration is discovering.
    public private(set) var scanning = false
    /// A scan has run 20 s without a camera; the pair page then lists what to check (A2-65:
    /// one shared rule instead of a timer per app). The model's scan machinery sets it; tests
    /// and review staging may set it directly, as they do other model states.
    public var scanLooksEmpty = false
    /// The sighting chosen on the pair page.
    public var selection: String?
    /// The current operator decision, retired with its source before admission. The outermost
    /// shared presenter for this model (`AppShell`, or a standalone screen) renders it.
    public let consent = OperatorConsent()
    /// Called once per successful attempt, after the record is saved.
    @ObservationIgnored public var onConnected: (ConnectedCamera) -> Void = { _ in }
    /// The still-looking hint's wait; tests replace it with a manual clock.
    @ObservationIgnored var waitForScanHint: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    /// How long a scan runs without a camera before the still-looking hint shows.
    @ObservationIgnored private static let stillLookingAfter: Duration = .seconds(20)
    @ObservationIgnored private var scanHintTask: Task<Void, Never>?

    @ObservationIgnored private let store: SavedCamerasStore
    @ObservationIgnored private let routePolicy: RoutePolicy
    @ObservationIgnored private var discovery: [Int: (mode: DiscoveryMode, task: Task<Void, Never>)] = [:]
    /// What each run's integration last reported about discovery; absent reads as running.
    @ObservationIgnored private var discoveryRunning: [Int: Bool] = [:]
    @ObservationIgnored private var discoveryRunningTasks: [Int: Task<Void, Never>] = [:]

    public init(integrations: [AppIntegration], store: SavedCamerasStore, routePolicy: RoutePolicy = .preferred) {
        self.entries = integrations
        self.store = store
        self.routePolicy = routePolicy
        store.load()
        saved = store.cameras
        updateDiscovery()
    }

    // MARK: Discovery

    /// The mode an integration discovers in now; `nil` stops it.
    public func discoveryMode(of integration: any CameraIntegration) -> DiscoveryMode? {
        guard connected == nil, attempts.isEmpty else { return nil }
        if pairing, integration.discoveryModes.contains(.active) { return .active }
        return integration.discoveryModes.contains(.passive) ? .passive : nil
    }


    public func beginPairing() {
        pairing = true
        updateDiscovery()
    }

    public func endPairing() {
        pairing = false
        selection = nil
        updateDiscovery()
    }

    private func updateDiscovery() {
        for (index, entry) in entries.enumerated() {
            let wanted = discoveryMode(of: entry.integration)
            guard discovery[index]?.mode != wanted else { continue }
            discovery.removeValue(forKey: index)?.task.cancel()
            discoveryRunningTasks.removeValue(forKey: index)?.cancel()
            guard let wanted else {
                discoveryRunning[index] = nil
                continue
            }
            let lists = entry.integration.discover(wanted)
            let statuses = entry.integration.discoveryRunning
            let id = entry.integration.id
            discovery[index] = (wanted, Task { [weak self] in
                for await list in lists { self?.publish(list, from: id) }
            })
            discoveryRunning[index] = true
            discoveryRunningTasks[index] = Task { [weak self] in
                for await running in statuses {
                    guard let self else { return }
                    // An unchanged report must not re-arm the still-looking wait (Kotlin twin guards too).
                    guard self.discoveryRunning[index] != running else { continue }
                    self.discoveryRunning[index] = running
                    self.updateScanning()
                }
            }
        }
        updateScanning()
    }

    /// A page shows scanning only while a registered run reports it can scan (IA-336).
    private func updateScanning() {
        scanning = !discovery.isEmpty && discovery.keys.contains { discoveryRunning[$0] != false }
        refreshScanHint()
    }

    /// The still-looking hint: armed while a pairing scan runs without a camera, cleared when
    /// the scan's shape changes or pairing ends. The wait runs on the model's injected clock.
    private func refreshScanHint() {
        scanHintTask?.cancel()
        scanHintTask = nil
        guard pairing, scanning, nearby.isEmpty else {
            scanLooksEmpty = false
            return
        }
        scanHintTask = Task { [weak self] in
            guard let self else { return }
            try? await self.waitForScanHint(Self.stillLookingAfter)
            guard !Task.isCancelled else { return }
            if self.scanning, self.nearby.isEmpty { self.scanLooksEmpty = true }
        }
    }

    private func publish(_ list: [NearbyCamera], from integration: IntegrationID) {
        let wasEmpty = nearby.isEmpty
        nearby = nearby.filter { $0.integration != integration }
            + list.map { Sighting(integration: integration, camera: $0) }
        if wasEmpty != nearby.isEmpty { refreshScanHint() }
    }

    // MARK: Connecting

    /// Connects a saved camera over `route`, else its `defaultRoute(of:)`.
    public func connect(_ camera: SavedCamera, route: ConnectionRouteID? = nil) {
        guard let route = route ?? defaultRoute(of: camera) else { return }
        start(.saved(camera, route: route), on: camera.integration)
    }

    /// The route a tap connects, by the app's `RoutePolicy`.
    public func defaultRoute(of camera: SavedCamera) -> ConnectionRouteID? {
        if routePolicy == .preferReachable {
            let reached = Set(nearby.filter { CamerasMapping.matches($0, camera) }.compactMap(\.camera.routeKey))
            if let route = camera.routes.first(where: { reached.contains($0.key) }) { return route.id }
        }
        return camera.preferredRoute ?? camera.routes.first?.id
    }

    public func connect(_ sighting: Sighting) {
        start(.nearby(sighting.camera), on: sighting.integration)
    }

    /// Provisions a new route on a saved camera (from an add-route slot).
    public func addRoute(_ draft: RouteDraft, to camera: SavedCamera) {
        start(.addRoute(camera, draft), on: camera.integration)
    }

    public func cancel(_ cameraID: String) {
        guard let attempt = attempts.removeValue(forKey: cameraID) else { return }
        consent.retire(source: attempt.token)
        attempt.task?.cancel()
        updateDiscovery()
    }

    public func cancelAll() {
        for cameraID in Array(attempts.keys) { cancel(cameraID) }
        consent.retire()
    }

    /// Clears a camera's last failure without connecting (a pair page back to choosing).
    public func dismissFailure(_ cameraID: String) {
        failures[cameraID] = nil
    }

    /// Re-checks every Local Network failure by connecting it again. iOS has no API to read this
    /// permission, so a connect is the check: the shell calls this each time the app becomes
    /// active, after the system prompt or a Settings visit, where the operator may have allowed
    /// it. A denial that still holds fails again at once with the same reason. Other failures and
    /// running attempts are left alone; one integration (one backend) retries one camera, and a
    /// live camera is never replaced. A saved target dials the current record, never a route the
    /// operator forgot since.
    public func retryLocalNetworkFailures() {
        guard connected == nil else { return }
        var retried = Set(attempts.values.map(\.integration))
        for (cameraID, failure) in failures.sorted(by: { $0.key < $1.key })
        where failure.failure.reason == .permission(.localNetwork) {
            guard attempts[cameraID] == nil, let target = current(failure.target),
                let entry = entry(for: target), retried.insert(entry.integration.id).inserted
            else { continue }
            start(target, on: entry.integration.id)
        }
    }

    /// A failure's target against the saved cameras now: `nil` when its camera or route is gone.
    private func current(_ target: ConnectTarget) -> ConnectTarget? {
        switch target {
        case .nearby: return target
        case .saved(let old, let route):
            guard let camera = saved.first(where: { $0.id == old.id }),
                camera.routes.contains(where: { $0.id == route })
            else { return nil }
            return .saved(camera, route: route)
        case .addRoute(let old, let draft):
            return saved.first { $0.id == old.id }.map { .addRoute($0, draft) }
        }
    }

    /// The last failure a pair page shows for `selection`: the keyed one, else one whose target
    /// carries that camera. A post-failure rescan clears the sightings, and the reason must stay
    /// until the operator acts on it (F-PIB-042).
    public func failure(for selection: String?) -> Failure? {
        guard let selection else { return nil }
        if let keyed = failures[selection] { return keyed }
        return failures.values.first { failure in
            switch failure.target {
            case .nearby(let camera): camera.id == selection
            case .saved(let camera, _), .addRoute(let camera, _): camera.id == selection
            }
        }
    }

    /// The app closed the live session, or it ended: discovery resumes.
    public func sessionEnded() {
        connected = nil
        updateDiscovery()
    }

    /// Runs a failure's action; returns what the app must do when the model cannot.
    @discardableResult
    public func perform(_ action: RecoveryAction, for cameraID: String) -> Request? {
        switch action {
        case .retry:
            if let failure = failures[cameraID], let entry = entry(for: failure.target) {
                start(failure.target, on: entry.integration.id)
            }
        case .useRoute(let route):
            if let camera = saved.first(where: { $0.id == cameraID }) { connect(camera, route: route) }
        case .editRoute(let route):
            if let camera = saved.first(where: { $0.id == cameraID }) { return .editRoute(camera, route) }
        case .pairAgain: return .pairAgain
        case .openSettings: return .openSettings
        case .integration(let id, _): return .integration(id: id, camera: cameraID)
        }
        return nil
    }

    private func entry(for target: ConnectTarget) -> AppIntegration? {
        switch target {
        case .saved(let camera, _), .addRoute(let camera, _):
            entries.first { $0.integration.id == camera.integration }
        case .nearby(let camera):
            nearby.first { $0.camera.id == camera.id }.flatMap { sighting in
                entries.first { $0.integration.id == sighting.integration }
            }
        }
    }

    private func start(_ target: ConnectTarget, on integration: IntegrationID) {
        guard let entry = entries.first(where: { $0.integration.id == integration }) else { return }
        let cameraID = target.cameraID
        if let older = attempts.removeValue(forKey: cameraID) {
            consent.retire(source: older.token)
            older.task?.cancel()
        }
        failures[cameraID] = nil
        var attempt = Attempt(target: target, integration: integration)
        let token = attempt.token
        attempts[cameraID] = attempt
        updateDiscovery()
        let events = entry.integration.connect(target)
        attempt.task = Task { [weak self] in
            for await event in events { self?.apply(event, to: cameraID, token: token) }
            self?.finish(cameraID, token: token)
        }
        attempts[cameraID]?.task = attempt.task
    }

    private func apply(_ event: ConnectionEvent, to cameraID: String, token: UUID) {
        guard let attempt = attempts[cameraID], attempt.token == token else { return }
        switch event {
        case .progress(let progress, let prompt):
            attempts[cameraID]?.progress = progress
            attempts[cameraID]?.prompt = prompt
            if case .integration(let value) = prompt,
                let confirmation = value as? any ConfirmationPrompt
            {
                consent.present(confirmation, source: token) { [weak self] in
                    self?.attempts[cameraID]?.token == token
                }
            } else {
                consent.retire(source: token)
            }
        case .connected(let camera):
            consent.retire(source: token)
            attempts[cameraID] = nil
            upsert(camera.saved)
            connected = camera
            onConnected(camera)
            updateDiscovery()
        case .failed(let failure):
            consent.retire(source: token)
            attempts[cameraID] = nil
            failures[cameraID] = Failure(failure: failure, target: attempt.target)
            updateDiscovery()
        }
    }

    /// The stream ended without an outcome (the attempt was cancelled).
    private func finish(_ cameraID: String, token: UUID) {
        guard attempts[cameraID]?.token == token else { return }
        consent.retire(source: token)
        attempts[cameraID] = nil
        updateDiscovery()
    }

    // MARK: Saved cameras

    /// The app wrote its legacy records itself (an integration whose app still saves with its own
    /// rules): merges them into the document now. Call it right after each such write, so a save
    /// from here never patches over it.
    public func reloadSaved() {
        store.load()
        saved = store.cameras
    }

    /// `nil` or a blank name clears the rename.
    public func rename(_ cameraID: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(cameraID) { $0.name = trimmed?.isEmpty == false ? trimmed : nil }
    }

    /// Renames only this setup. `nil` or a blank name restores its default title.
    public func renameRoute(_ route: ConnectionRouteID, of cameraID: String, to name: String?) {
        guard attempts.isEmpty else { return }
        guard
            saved.contains(where: {
                $0.id == cameraID && $0.routes.contains(where: { $0.id == route })
            })
        else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(cameraID) { camera in
            guard let index = camera.routes.firstIndex(where: { $0.id == route }) else { return }
            camera.routes[index].title = trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    /// Asks the integration to drop what it stores for the camera, then removes it.
    public func forget(_ cameraID: String) async {
        guard let camera = saved.first(where: { $0.id == cameraID }) else { return }
        cancel(cameraID)
        if let entry = entries.first(where: { $0.integration.id == camera.integration }) {
            await entry.integration.forget(camera)
        }
        failures[cameraID] = nil
        save(saved.filter { $0.id != cameraID })
    }

    public func forgetRoute(_ route: ConnectionRouteID, of cameraID: String) {
        edit(cameraID) { camera in
            camera.routes.removeAll { $0.id == route }
            if camera.preferredRoute == route { camera.preferredRoute = nil }
        }
    }

    private func edit(_ cameraID: String, _ change: (inout SavedCamera) -> Void) {
        guard let index = saved.firstIndex(where: { $0.id == cameraID }) else { return }
        var cameras = saved
        change(&cameras[index])
        save(cameras)
    }

    /// Saves `camera`, replacing the record with its id or adding it first: what an integration
    /// or its app slot remembers outside a connect (a setup about to move the camera).
    public func upsert(_ camera: SavedCamera) {
        var cameras = saved
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index] = camera
        } else {
            cameras.insert(camera, at: 0)
        }
        save(cameras)
    }

    private func save(_ cameras: [SavedCamera]) {
        store.save(cameras)
        saved = cameras
    }
}
