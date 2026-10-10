import Foundation
import OpenCineDJI

/// Local host repair admission, independent of picture observation.
public struct DjiApplePictureRecoveryContext {
    public var rebuilding: Bool
    public var ownsConnection: Bool?
    public var endpointIdentity: ObjectIdentifier?
    public var pictureIntent: Int?
    public var browsingMedia: Bool
    public var holdsMonitor: Bool
    public var sessionRecovering: Bool
    public init(rebuilding: Bool = false, endpointIdentity: ObjectIdentifier? = nil,
        pictureIntent: Int? = nil, browsingMedia: Bool = false,
        holdsMonitor: Bool = false, sessionRecovering: Bool = false, ownsConnection: Bool? = nil) {
        self.rebuilding = rebuilding
        self.ownsConnection = ownsConnection
        self.endpointIdentity = endpointIdentity
        self.pictureIntent = pictureIntent
        self.browsingMedia = browsingMedia
        self.holdsMonitor = holdsMonitor
        self.sessionRecovering = sessionRecovering
    }
}

/// Observations from one real endpoint; absent receive time is unknown.
public struct DjiApplePictureRecoveryTransport {
    public var closed: Bool
    public var lastVideoPacketAt: TimeInterval?
    public init(closed: Bool = false, lastVideoPacketAt: TimeInterval? = nil) {
        self.closed = closed
        self.lastVideoPacketAt = lastVideoPacketAt
    }
}

@MainActor public struct DjiApplePictureRecoveryEndpoint {
    public let identity: ObjectIdentifier
    public var negotiate: (String) async throws -> Void
    public var transport: () -> DjiApplePictureRecoveryTransport
    public init(identity: ObjectIdentifier, negotiate: @escaping (String) async throws -> Void,
        transport: @escaping () -> DjiApplePictureRecoveryTransport) {
        self.identity = identity
        self.negotiate = negotiate
        self.transport = transport
    }
}

/// The freshness predicate is derived by the native host from real source and presentation.
public struct DjiAppleRecoveryPicture {
    public var fresh: Bool
    public var lastPresentedAt: TimeInterval?
    public init(fresh: Bool = false, lastPresentedAt: TimeInterval? = nil) {
        self.fresh = fresh
        self.lastPresentedAt = lastPresentedAt
    }
}

@MainActor public struct DjiApplePictureRecoveryNative {
    public var prepare: () -> TimeInterval
    public var prepareScoped: ((DjiAppleLiveViewScope) -> TimeInterval)?
    public var enable: () -> Void
    public var probe: () -> Void
    public var picture: (TimeInterval, TimeInterval) -> DjiAppleRecoveryPicture
    public init(prepare: @escaping () -> TimeInterval, enable: @escaping () -> Void,
        probe: @escaping () -> Void,
        picture: @escaping (TimeInterval, TimeInterval) -> DjiAppleRecoveryPicture) {
        self.prepare = prepare
        self.prepareScoped = nil
        self.enable = enable
        self.probe = probe
        self.picture = picture
    }
    /// Additive scoped preparation; the legacy projection remains available to
    /// older owner composition, while bound mode always uses the captured scope.
    public init(prepare: @escaping () -> TimeInterval,
        prepareScoped: @escaping (DjiAppleLiveViewScope) -> TimeInterval,
        enable: @escaping () -> Void, probe: @escaping () -> Void,
        picture: @escaping (TimeInterval, TimeInterval) -> DjiAppleRecoveryPicture) {
        self.init(prepare: prepare, enable: enable, probe: probe, picture: picture)
        self.prepareScoped = prepareScoped
    }
}

/// Source observation uses wall time; the bounded wait uses monotonic time.
@MainActor public struct DjiApplePictureRecoveryTiming {
    public var wallNow: () -> TimeInterval
    public var monotonicNow: () -> TimeInterval
    public var wait: (Duration) async throws -> Void
    public init(wallNow: @escaping () -> TimeInterval,
        monotonicNow: @escaping () -> TimeInterval,
        wait: @escaping (Duration) async throws -> Void) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        self.wait = wait
    }
    public static var continuous: Self {
        .init(wallNow: { Date.timeIntervalSinceReferenceDate },
            monotonicNow: { ProcessInfo.processInfo.systemUptime },
            wait: { try await Task.sleep(for: $0) })
    }
}

/// One session's serialized repair lifetime. Retirement never sends a camera command.
@MainActor
public final class DjiApplePictureRecovery {
    public enum Result: Equatable { case restored, superseded, exhausted }
    public enum Event: Equatable {
        case admitted, released, restored, holdForWatchdog(cycles: Int)
        /// Legacy watchdog-reset boundary after the initial policy call, including
        /// local refusal. This is neither a wire receipt nor camera evidence.
        case endpointInitialPolicyCompleted
        case escalateSession, negotiationFailed(reason: String), endpointRepairRequested(requests: Int)
    }
    @MainActor public final class Attempt {
        fileprivate weak var owner: DjiApplePictureRecovery?
        fileprivate let generation: UInt64
        fileprivate let source: DjiAppleLiveViewScope?
        fileprivate var binding: UUID?
        fileprivate init(owner: DjiApplePictureRecovery, generation: UInt64,
            source: DjiAppleLiveViewScope?) {
            self.owner = owner
            self.generation = generation
            self.source = source
            self.binding = owner.liveViewBinding
        }
        public var isCurrent: Bool { owner?.isCurrent(self) == true }
        public func prepareReplacementEndpoint() -> TimeInterval? {
            owner?.prepareReplacementEndpoint(self)
        }
        @discardableResult
        public func bindReplacementLiveView(_ endpoint: any DjiAppleLiveViewEndpoint,
            recovery: DjiApplePictureRecoveryEndpoint) -> Bool {
            guard let owner, owner.isCurrent(self), let source else { return false }
            let scope = DjiAppleLiveViewScope(owner: owner, run: source.run, source: source.source,
                kind: .repair(generation), binding: binding)
            guard owner.bindLiveView(endpoint: endpoint, recovery: recovery, scope: scope) else { return false }
            binding = owner.liveViewBinding
            return owner.isCurrent(self)
        }
        public func repairNativeOutput(referenceLossOnly: Bool,
            pictureIntent: Int) async -> DjiAppleNativeOutputResult {
            guard let owner else { return .superseded }
            return await owner.repairNativeOutput(self,
                referenceLossOnly: referenceLossOnly, pictureIntent: pictureIntent)
        }
        public func repairEndpoint(_ endpoint: DjiApplePictureRecoveryEndpoint,
            reason: String, pictureIntent: Int, timeout: Duration) async -> Result {
            guard let owner, owner.isEndpointCurrent(self, endpoint: endpoint),
                let native = owner.native else { return .superseded }
            let started: TimeInterval
            if owner.connectionRun != nil {
                guard let prepared = prepareReplacementEndpoint() else { return .superseded }
                started = prepared
            } else { started = native.prepare() }
            guard owner.isEndpointCurrent(self, endpoint: endpoint) else { return .superseded }
            do {
                try await endpoint.negotiate(reason)
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                if owner.connectionRun != nil {
                    _ = owner.requestLiveView(.initial(pathProven: true, displayAttached: false), reason: reason)
                    guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                    else { return .superseded }
                    // The donor native.enable projection ignored local acceptance
                    // and reset its watchdog even for uncaptured/overlap refusal.
                    owner.emit(.endpointInitialPolicyCompleted, attempt: self)
                    guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                    else { return .superseded }
                } else { native.enable() }
                return await waitForPicture(endpoint, since: started,
                    pictureIntent: pictureIntent, timeout: timeout)
            } catch is CancellationError {
                return .superseded
            } catch {
                // A cover retires picture intent, not a genuine transport failure.
                guard owner.isEndpointCurrent(self, endpoint: endpoint) else { return .superseded }
                owner.emit(.negotiationFailed(reason: reason), attempt: self)
                return owner.isEndpointCurrent(self, endpoint: endpoint) ? .exhausted : .superseded
            }
        }
        public func waitForPicture(_ endpoint: DjiApplePictureRecoveryEndpoint,
            since started: TimeInterval, pictureIntent: Int, timeout: Duration) async -> Result {
            guard let owner, let native = owner.native else { return .superseded }
            let c = timeout.components
            let deadline = owner.timing.monotonicNow()
                + Double(c.seconds) + Double(c.attoseconds) / 1e18
            var picture = DjiAppleRecoveryPicture()
            while owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent) {
                picture = native.picture(started, owner.timing.wallNow())
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                if picture.fresh {
                    owner.emit(.restored, attempt: self)
                    return owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                        ? .restored : .superseded
                }
                guard owner.timing.monotonicNow() < deadline else { break }
                native.probe()
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                do { try await owner.timing.wait(.milliseconds(100)) }
                catch { return .superseded }
            }
            guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
            else { return .superseded }
            let now = owner.timing.wallNow()
            let transport = endpoint.transport()
            // Injected observations can synchronously retire or replace the attempt.
            guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent,
                transport: transport) else { return .superseded }
            let pictureSinceLastHold = owner.lastSessionHoldAt.map { held in
                picture.lastPresentedAt.map { $0 > held } ?? false
            } ?? false
            owner.sessionHoldCycles = FeedWatchdog.nextSessionHoldCycles(
                lastVideoPacketAge: transport.lastVideoPacketAt.map { now - $0 },
                previousCycles: owner.sessionHoldCycles, pictureSinceLastCycle: pictureSinceLastHold)
            owner.lastSessionHoldAt = now
            owner.emit(owner.sessionHoldCycles > 0
                ? .holdForWatchdog(cycles: owner.sessionHoldCycles) : .escalateSession, attempt: self)
            return owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                ? .exhausted : .superseded
        }
    }
    public var isBusy: Bool { task != nil }
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    // Preserve the donor's per-session history across local cancellation/reset.
    private var sessionHoldCycles = 0
    private var lastSessionHoldAt: TimeInterval?
    private let context: () -> DjiApplePictureRecoveryContext
    private let native: DjiApplePictureRecoveryNative?
    private let event: (Event) -> Void
    private let timing: DjiApplePictureRecoveryTiming
    private var connectionRun: DjiAppleConnectionRun?
    private var liveViewNative: DjiAppleLiveViewNative?
    private var scopedEvent: ((Event, DjiAppleLiveViewScope) -> Void)?
    private var liveViewSource: DjiAppleLiveViewScope?
    private var liveViewRecipe: DjiAppleLiveViewRecipe?
    private var liveViewEndpoint: (any DjiAppleLiveViewEndpoint)?
    private var liveViewBinding: UUID?
    private var liveViewRecoveryEndpoint: DjiApplePictureRecoveryEndpoint?
    private var liveViewGate: UUID?
    private var liveViewOperations: Set<UUID> = []
    private var liveViewHistoryValue = DjiAppleLiveViewHistory()
    public var liveViewHistory: DjiAppleLiveViewHistory {
        .init(initialAccepted: liveViewHistoryValue.initialAccepted,
            locallyAcceptedEnables: liveViewHistoryValue.locallyAcceptedEnables,
            lastAcceptedEnableWallTime: liveViewHistoryValue.lastAcceptedEnableWallTime,
            idrHoldEnableCount: liveViewHistoryValue.idrHoldEnableCount,
            gateInFlight: liveViewGate != nil)
    }
    public init(context: @escaping () -> DjiApplePictureRecoveryContext,
        native: DjiApplePictureRecoveryNative? = nil,
        timing: DjiApplePictureRecoveryTiming = .continuous,
        event: @escaping (Event) -> Void = { _ in }) {
        self.context = context
        self.native = native
        self.event = event
        self.timing = timing
    }
    /// Bound mode uses the actual connection workflow as transport authority.
    public convenience init(connectionRun: DjiAppleConnectionRun,
        context: @escaping () -> DjiApplePictureRecoveryContext,
        native: DjiApplePictureRecoveryNative, liveViewNative: DjiAppleLiveViewNative,
        timing: DjiApplePictureRecoveryTiming = .continuous,
        event: @escaping (Event, DjiAppleLiveViewScope) -> Void = { _, _ in }) {
        self.init(context: context, native: native, timing: timing)
        self.connectionRun = connectionRun; self.liveViewNative = liveViewNative
        self.scopedEvent = event
    }
    @discardableResult
    public func prepareLiveViewSource(run: DjiAppleConnectionRun.Attempt,
        recipe: DjiAppleLiveViewRecipe) -> DjiAppleLiveViewScope? {
        guard let connectionRun, run.isCurrent, connectionRun.currentRunID == run.id else { return nil }
        let current = context()
        guard run.isCurrent, connectionRun.currentRunID == run.id,
            current.ownsConnection == true else { return nil }
        cancel()
        let scope = DjiAppleLiveViewScope(owner: self, run: run, source: UUID())
        liveViewSource = scope; liveViewRecipe = recipe
        liveViewEndpoint = nil; liveViewBinding = nil; liveViewRecoveryEndpoint = nil; liveViewHistoryValue = .init()
        return scope
    }
    @discardableResult
    public func bindLiveView(_ endpoint: any DjiAppleLiveViewEndpoint,
        scope: DjiAppleLiveViewScope) -> Bool {
        guard isLiveViewScopeCurrent(scope) else { return false }
        let current = context()
        guard isLiveViewScopeCurrent(scope), current.endpointIdentity == ObjectIdentifier(endpoint)
        else { return false }
        cancel()
        liveViewEndpoint = endpoint; liveViewRecoveryEndpoint = nil; liveViewBinding = UUID()
        return true
    }
    /// Capture the real endpoint and its existing negotiation/transport descriptor
    /// atomically. A descriptor for another endpoint cannot authorize repair.
    @discardableResult
    public func bindLiveView(endpoint: any DjiAppleLiveViewEndpoint,
        recovery: DjiApplePictureRecoveryEndpoint, scope: DjiAppleLiveViewScope) -> Bool {
        guard recovery.identity == ObjectIdentifier(endpoint), isLiveViewScopeCurrent(scope) else { return false }
        let current = context()
        guard isLiveViewScopeCurrent(scope), current.endpointIdentity == recovery.identity else { return false }
        if case .source = scope.kind { cancel() }
        liveViewEndpoint = endpoint; liveViewRecoveryEndpoint = recovery; liveViewBinding = UUID()
        return true
    }
    public func retireLiveView(scope: DjiAppleLiveViewScope) {
        // Local retirement must also work after the actual run retires. Only the
        // captured source may be cleared; this grants no transport/effect authority.
        guard case .source = scope.kind, scope.owner === self, liveViewSource?.source == scope.source,
            liveViewSource?.run === scope.run else { return }
        let wall = liveViewHistoryValue.lastAcceptedEnableWallTime
        cancel(); liveViewSource = nil; liveViewRecipe = nil
        liveViewEndpoint = nil; liveViewBinding = nil; liveViewRecoveryEndpoint = nil
        liveViewHistoryValue = .init(lastAcceptedEnableWallTime: wall)
    }
    public func notePresentedSource(scope: DjiAppleLiveViewScope) {
        guard isLiveViewScopeCurrent(scope) else { return }
        liveViewHistoryValue = .init(initialAccepted: liveViewHistoryValue.initialAccepted,
            locallyAcceptedEnables: liveViewHistoryValue.locallyAcceptedEnables,
            lastAcceptedEnableWallTime: liveViewHistoryValue.lastAcceptedEnableWallTime)
    }
    internal func isLiveViewScopeCurrent(_ scope: DjiAppleLiveViewScope) -> Bool {
        guard isLiveViewScopeIdentityCurrent(scope) else { return false }
        let current = context()
        return current.ownsConnection == true && isLiveViewScopeIdentityCurrent(scope)
    }
    private func isLiveViewScopeIdentityCurrent(_ scope: DjiAppleLiveViewScope) -> Bool {
        guard scope.owner === self, liveViewSource?.source == scope.source,
            liveViewSource?.run === scope.run, scope.run.isCurrent,
            connectionRun?.currentRunID == scope.run.id else { return false }
        switch scope.kind {
        case .source: return true
        case .gate(let operation): return liveViewOperations.contains(operation) && scope.binding == liveViewBinding
        case .repair(let operation): return generation == operation && isBusy && !Task.isCancelled && scope.binding == liveViewBinding
        case .completion(let operation): return generation == operation && !Task.isCancelled && scope.binding == liveViewBinding
        }
    }
    private func liveViewEffectScope(_ kind: DjiAppleLiveViewScope.Kind) -> DjiAppleLiveViewScope? {
        guard let source = liveViewSource, isLiveViewScopeCurrent(source) else { return nil }
        return .init(owner: self, run: source.run, source: source.source, kind: kind, binding: liveViewBinding)
    }
    private func liveViewEndpointCurrent(_ scope: DjiAppleLiveViewScope, binding: UUID) -> Bool {
        guard isLiveViewScopeCurrent(scope), liveViewBinding == binding,
            let endpoint = liveViewEndpoint else { return false }
        let current = context()
        return current.endpointIdentity == ObjectIdentifier(endpoint)
            && liveViewBinding == binding && isLiveViewScopeCurrent(scope)
    }
    private func outputObservation(_ scope: DjiAppleLiveViewScope,
        since: TimeInterval) -> DjiAppleNativeOutputObservation? {
        guard isLiveViewScopeCurrent(scope), let liveViewNative else { return nil }
        let now = timing.wallNow()
        guard isLiveViewScopeCurrent(scope) else { return nil }
        let value = liveViewNative.observeOutput(since, now)
        return isLiveViewScopeCurrent(scope) ? value : nil
    }
    public func requestLiveView(_ purpose: DjiAppleLiveViewPurpose,
        reason: String) -> DjiAppleLiveViewOutcome {
        guard let source = liveViewSource else { return .blocked(.unavailableBinding) }
        guard isLiveViewScopeCurrent(source) else {
            return isLiveViewScopeIdentityCurrent(source) ? .blocked(.unavailableOwnership) : .superseded
        }
        guard let endpoint = liveViewEndpoint, let binding = liveViewBinding,
            let recipe = liveViewRecipe, let liveViewNative else { return .blocked(.unavailableBinding) }
        // Recover policy and native cleanup preceded the donor's wire gate.
        // A nested policy operation owns its own identity without retiring the
        // already-admitted wire operation or clearing its gate on refusal.
        let operation = UUID(); liveViewOperations.insert(operation)
        defer {
            liveViewOperations.remove(operation)
            if liveViewGate == operation { liveViewGate = nil }
        }
        guard let scope = liveViewEffectScope(.gate(operation)),
            liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        if case .recover = purpose {
            liveViewNative.perform(.prepareRecover, scope)
            guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        }
        let current = context()
        guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        if current.browsingMedia && purpose != .mediaReturn && purpose != .capturedMediaReturnRecipe { return finishLiveView(.blocked(.mediaBrowsing), purpose: purpose, reason: reason, scope: scope, binding: binding) }
        if case .mediaReturn = purpose {
            let closed = endpoint.isClosed
            guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
            if closed { return finishLiveView(.blocked(.unavailableBinding), purpose: purpose, reason: reason, scope: scope, binding: binding) }
        }
        switch purpose {
        case .initial(let pathProven, _):
            if liveViewHistoryValue.initialAccepted { return finishLiveView(.blocked(.alreadyAccepted), purpose: purpose, reason: reason, scope: scope, binding: binding) }
            if !pathProven {
                guard let observation = outputObservation(scope,
                    since: liveViewHistoryValue.lastAcceptedEnableWallTime.timeIntervalSinceReferenceDate)
                else { return .superseded }
                guard observation.pathReady else { return finishLiveView(.blocked(.pathNotReady), purpose: purpose, reason: reason, scope: scope, binding: binding) }
            }
            // Both the normal display-ready branch and the donor's display-wait
            // fallback send once when path is ready; a proven handshake bypasses layout.
        case .recover(let force):
            guard let observation = outputObservation(scope,
                since: liveViewHistoryValue.lastAcceptedEnableWallTime.timeIntervalSinceReferenceDate)
            else { return .superseded }
            if observation.playbackBlocked {
                liveViewNative.perform(.exitPlayback, scope)
                return finishLiveView(.blocked(.playback), purpose: purpose, reason: reason, scope: scope, binding: binding)
            }
            if !observation.pathReady { return finishLiveView(.blocked(.pathNotReady), purpose: purpose, reason: reason, scope: scope, binding: binding) }
            if !observation.presentationReady { return finishLiveView(.blocked(.presentationNotReady), purpose: purpose, reason: reason, scope: scope, binding: binding) }
            if !force {
                let now = timing.wallNow()
                guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
                if now - liveViewHistoryValue.lastAcceptedEnableWallTime.timeIntervalSinceReferenceDate
                    < FeedWatchdog.escalateAfter { return finishLiveView(.blocked(.cooldown), purpose: purpose, reason: reason, scope: scope, binding: binding) }
            }
        default: break
        }
        guard liveViewGate == nil else {
            return finishLiveView(.blocked(.overlap), purpose: purpose, reason: reason, scope: scope, binding: binding)
        }
        liveViewGate = operation
        guard recipe != .uncaptured else { return finishLiveView(.blocked(.uncaptured), purpose: purpose, reason: reason, scope: scope, binding: binding) }
        if recipe == .gated {
            endpoint.send(Commands.nanoLiveViewGate(start: true))
            guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        }
        if recipe == .prepared || recipe == .legacyUnresolved {
            endpoint.send(Commands.liveViewPrepare())
            guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        }
        endpoint.startLiveView(receiver: recipe == .gated || recipe == .direct ? 0x41 : 0x08)
        guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        if purpose == .capturedRecipe || purpose == .capturedMediaReturnRecipe { return finishLiveView(.locallyAccepted(liveViewHistoryValue), purpose: purpose, reason: reason, scope: scope, binding: binding) }
        if purpose == .mediaReturn {
            liveViewNative.perform(.prepareMediaReturn, scope)
            guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        }
        let now = timing.wallNow()
        guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        let initial: Bool
        let holdCount: Int
        switch purpose {
        case .initial, .mediaReturn:
            initial = true; holdCount = 1
        default:
            guard let observation = outputObservation(scope, since: now) else { return .superseded }
            initial = liveViewHistoryValue.initialAccepted
            holdCount = observation.awaitingIDR ? liveViewHistoryValue.idrHoldEnableCount : 0
        }
        liveViewHistoryValue = .init(initialAccepted: initial,
            locallyAcceptedEnables: liveViewHistoryValue.locallyAcceptedEnables + 1,
            lastAcceptedEnableWallTime: Date(timeIntervalSinceReferenceDate: now),
            idrHoldEnableCount: holdCount)
        liveViewNative.perform(.holdPicture(always: purpose == .mediaReturn), scope)
        guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        switch purpose {
        case .initial, .mediaReturn: break
        default:
            liveViewHistoryValue = .init(initialAccepted: liveViewHistoryValue.initialAccepted,
                locallyAcceptedEnables: liveViewHistoryValue.locallyAcceptedEnables,
                lastAcceptedEnableWallTime: liveViewHistoryValue.lastAcceptedEnableWallTime,
                idrHoldEnableCount: liveViewHistoryValue.idrHoldEnableCount + 1)
        }
        return finishLiveView(.locallyAccepted(liveViewHistoryValue), purpose: purpose, reason: reason, scope: scope, binding: binding)
    }
    private func finishLiveView(_ result: DjiAppleLiveViewOutcome,
        purpose: DjiAppleLiveViewPurpose, reason: String, scope: DjiAppleLiveViewScope,
        binding: UUID) -> DjiAppleLiveViewOutcome {
        guard liveViewEndpointCurrent(scope, binding: binding) else { return .superseded }
        liveViewNative?.perform(.requestFinished(purpose: purpose, reason: reason, outcome: result), scope)
        return liveViewEndpointCurrent(scope, binding: binding) ? result : .superseded
    }
    @discardableResult
    public func start(_ work: @escaping @MainActor (Attempt) async -> Void) -> Bool {
        let source = liveViewSource
        if connectionRun != nil {
            guard let source, isLiveViewScopeCurrent(source) else { return false }
        }
        let current = context()
        guard FeedWatchdog.shouldStartFeedRecovery(rebuildInFlight: isBusy || current.rebuilding) else { return false }
        if connectionRun != nil {
            guard let source, isLiveViewScopeCurrent(source) else { return false }
        }
        generation &+= 1
        let attempt = Attempt(owner: self, generation: generation, source: source)
        task = Task { @MainActor in
            guard self.isCurrent(attempt) else { return }
            await work(attempt)
            guard self.isCurrent(attempt) else { return }
            self.task = nil
            self.emit(.released, attempt: attempt, completion: true)
        }
        emit(.admitted, attempt: attempt)
        return true
    }
    public func cancel() {
        liveViewGate = nil; liveViewOperations.removeAll()
        generation &+= 1
        task?.cancel()
        task = nil
    }
    /// Media return yields to a current repair, including a replacement's nil-driver gap.
    @discardableResult
    public func claim(pictureIntent: Int,
        work: @escaping @MainActor (Attempt) async -> Void) async -> Bool {
        while canClaim(pictureIntent), isBusy || context().rebuilding {
            do { try await timing.wait(.milliseconds(100)) }
            catch { return false }
        }
        guard canClaim(pictureIntent) else { return false }
        return start(work)
    }
    private func canClaim(_ intent: Int) -> Bool {
        let current = context()
        return !Task.isCancelled && current.pictureIntent == intent && !current.browsingMedia
            && !current.holdsMonitor && !current.sessionRecovering
    }
    private func isCurrent(_ attempt: Attempt) -> Bool {
        guard attempt.owner === self, generation == attempt.generation, isBusy, !Task.isCancelled else { return false }
        if connectionRun != nil {
            guard let source = attempt.source, attempt.binding == liveViewBinding,
                isLiveViewScopeCurrent(source) else { return false }
            return generation == attempt.generation && isBusy && !Task.isCancelled
        }
        return true
    }
    private func emit(_ value: Event, attempt: Attempt, completion: Bool = false) {
        if let scopedEvent {
            guard let source = attempt.source else { return }
            let scope = DjiAppleLiveViewScope(owner: self, run: source.run, source: source.source,
                kind: completion ? .completion(attempt.generation) : .repair(attempt.generation), binding: attempt.binding)
            guard isLiveViewScopeCurrent(scope) else { return }
            scopedEvent(value, scope)
        } else { event(value) }
    }
    private func prepareReplacementEndpoint(_ attempt: Attempt) -> TimeInterval? {
        guard isCurrent(attempt), let native, let source = attempt.source,
            let scope = liveViewEffectScope(.repair(attempt.generation)) else { return nil }
        guard let prepare = native.prepareScoped else { return nil }
        let started = prepare(scope)
        guard isCurrent(attempt), isLiveViewScopeCurrent(source), isLiveViewScopeCurrent(scope) else { return nil }
        // Native endpoint preparation resets counters but keeps the old wall sample.
        liveViewGate = nil
        liveViewHistoryValue = .init(lastAcceptedEnableWallTime: liveViewHistoryValue.lastAcceptedEnableWallTime)
        return started
    }
    private func nativeOutputCurrent(_ attempt: Attempt, pictureIntent: Int) -> Bool {
        guard isCurrent(attempt) else { return false }
        let current = context()
        return current.pictureIntent == pictureIntent && !current.browsingMedia
            && current.endpointIdentity == liveViewRecoveryEndpoint?.identity
            && liveViewRecoveryEndpoint != nil && isCurrent(attempt)
    }
    private func repairNativeOutput(_ attempt: Attempt, referenceLossOnly: Bool,
        pictureIntent: Int) async -> DjiAppleNativeOutputResult {
        guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent), let liveViewNative,
            let scope = liveViewEffectScope(.repair(attempt.generation)) else { return .superseded }
        let started = timing.wallNow()
        guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
        let spent = liveViewNative.rebuildOutput(referenceLossOnly, scope)
        guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
        if !spent { return .unspent }
        var sent = false
        while nativeOutputCurrent(attempt, pictureIntent: pictureIntent) {
            let now = timing.wallNow()
            guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
            guard now - started < FeedWatchdog.decoderRepairDeadline else { break }
            guard let observation = outputObservation(scope, since: started) else { return .superseded }
            if observation.presentationReady && observation.pathReady && !observation.playbackBlocked
                && liveViewGate == nil {
                if case .locallyAccepted = requestLiveView(.recover(force: true), reason: "watchdog decoder") {
                    sent = true
                }
                guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
                if sent { break }
            }
            // The donor ignores a readiness wait error, then tests cancellation/authority.
            try? await timing.wait(.milliseconds(250))
        }
        guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
        guard sent else { return .blockedReadiness }
        var keyframeRequests = 1
        var restored = false
        repair: while nativeOutputCurrent(attempt, pictureIntent: pictureIntent) {
            guard let observation = outputObservation(scope, since: started) else { return .superseded }
            if observation.picture.fresh { restored = true; break }
            let now = timing.wallNow()
            guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
            switch FeedWatchdog.decoderRepairStep(secondsSinceRepairStart: now - started,
                secondsSinceLastEnable: now - liveViewHistoryValue.lastAcceptedEnableWallTime.timeIntervalSinceReferenceDate,
                secondsSinceLastIrap: observation.lastIrapWallTime.map { now - $0 },
                keyframeRequests: keyframeRequests) {
            case .wait: break
            case .resendKeyframe:
                if observation.presentationReady && observation.pathReady && !observation.playbackBlocked
                    && liveViewGate == nil {
                    if case .locallyAccepted = requestLiveView(.recover(force: true), reason: "watchdog keyframe resend") {
                        keyframeRequests += 1
                    }
                    guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
                }
            case .rebuildEndpoint:
                emit(.endpointRepairRequested(requests: keyframeRequests), attempt: attempt)
                guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent),
                    let endpoint = liveViewRecoveryEndpoint else { return .superseded }
                let result = await attempt.repairEndpoint(endpoint, reason: "keyframe unanswered",
                    pictureIntent: pictureIntent, timeout: .seconds(2 * CameraSoftAP.foregroundPictureGrace))
                return .endpointRepair(result)
            case .deadline: break repair
            }
            do { try await timing.wait(.milliseconds(100)) } catch { return .superseded }
        }
        guard nativeOutputCurrent(attempt, pictureIntent: pictureIntent) else { return .superseded }
        if restored { return .restored }
        guard let observation = outputObservation(scope, since: started) else { return .superseded }
        if observation.nativeOutputExpected,
            (observation.nativeOutputAge ?? .infinity) < FeedWatchdog.stallThreshold { return .presentationOnly }
        return .fullRejoinRequired
    }
    private func isEndpointCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint) -> Bool {
        guard isCurrent(attempt) else { return false }
        let current = context()
        return current.endpointIdentity == endpoint.identity && isCurrent(attempt)
    }
    private func isPictureCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint, intent: Int) -> Bool {
        guard isCurrent(attempt) else { return false }
        let transport = endpoint.transport()
        return isPictureCurrent(attempt, endpoint: endpoint, intent: intent, transport: transport)
    }
    private func isPictureCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint, intent: Int,
        transport: DjiApplePictureRecoveryTransport) -> Bool {
        let current = context()
        return current.endpointIdentity == endpoint.identity && !transport.closed
            && current.pictureIntent == intent && !current.browsingMedia && isCurrent(attempt)
    }
}

#if os(iOS)
extension DjiApplePictureRecoveryEndpoint {
    public init(datalink: DjiAppleDatalink) {
        self.init(identity: ObjectIdentifier(datalink), negotiate: { [weak datalink] reason in
            guard let datalink else { throw CancellationError() }
            try await datalink.rebuildUDP(reason: reason)
        }, transport: { [weak datalink] in
            .init(closed: datalink?.isClosed ?? true,
                lastVideoPacketAt: datalink?.lastVideoPacketAt?.timeIntervalSinceReferenceDate)
        })
    }
}
#endif
