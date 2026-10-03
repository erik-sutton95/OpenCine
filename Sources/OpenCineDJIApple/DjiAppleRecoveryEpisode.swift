import Foundation
import OpenCineDJI

/// Varying native discovery only; saved-identity enrichment remains the host's policy.
@MainActor
public struct DjiAppleRecoveryDiscovery {
    public var waitUntilPoweredOn: () async -> Bool
    public var scan: () -> AsyncStream<DJISighting>
    public var stopScan: () -> Void
    public var enrich: (DJISighting) -> DJISighting

    public init(waitUntilPoweredOn: @escaping () async -> Bool,
        scan: @escaping () -> AsyncStream<DJISighting>, stopScan: @escaping () -> Void,
        enrich: @escaping (DJISighting) -> DJISighting) {
        self.waitUntilPoweredOn = waitUntilPoweredOn; self.scan = scan
        self.stopScan = stopScan; self.enrich = enrich
    }
}

/// Original monotonic deadlines, storm uptime and wall source timestamps stay distinct.
@MainActor
public struct DjiAppleRecoveryTiming {
    public var monotonicNow: () -> ContinuousClock.Instant
    public var uptime: () -> TimeInterval
    public var wallNow: () -> TimeInterval
    public var sleep: (Duration) async throws -> Void
    public var jitter: () -> Double

    public init(monotonicNow: @escaping () -> ContinuousClock.Instant,
        uptime: @escaping () -> TimeInterval, wallNow: @escaping () -> TimeInterval,
        sleep: @escaping (Duration) async throws -> Void, jitter: @escaping () -> Double) {
        self.monotonicNow = monotonicNow; self.uptime = uptime; self.wallNow = wallNow
        self.sleep = sleep; self.jitter = jitter
    }
    public static var continuous: Self {
        .init(monotonicNow: { ContinuousClock().now },
            uptime: { ProcessInfo.processInfo.systemUptime },
            wallNow: { Date.timeIntervalSinceReferenceDate },
            sleep: { try await Task.sleep(for: $0) }, jitter: { .random(in: 0...1) })
    }
}

/// One finite automatic recovery episode over the actual connection owner. Native source,
/// credentials, permissions, motion teardown and picture publication remain typed host actions.
@MainActor
public final class DjiAppleRecoveryEpisode {
    public enum Stage: Equatable, Sendable { case joiningWiFi, openingDatalink, live, other }
    public struct Context: Sendable {
        /// Explicit transport authority, independent of decoder ownership. Unknown refuses.
        public var ownsConnection: Bool?
        public var stage: Stage?
        public var sourceAt: TimeInterval?
        public var presentedAt: TimeInterval?
        public init(ownsConnection: Bool? = nil, stage: Stage? = nil,
            sourceAt: TimeInterval? = nil, presentedAt: TimeInterval? = nil) {
            self.ownsConnection = ownsConnection; self.stage = stage
            self.sourceAt = sourceAt; self.presentedAt = presentedAt
        }
    }
    public struct Snapshot: Equatable, Sendable {
        public var state: SessionRecoveryState
        public var targetID: String?
        public var holdsPicture: Bool
        public var cardGraceElapsed: Bool
        public var reconnecting: Bool
        public init(state: SessionRecoveryState = .idle, targetID: String? = nil,
            holdsPicture: Bool = false, cardGraceElapsed: Bool = false, reconnecting: Bool = false) {
            self.state = state; self.targetID = targetID; self.holdsPicture = holdsPicture
            self.cardGraceElapsed = cardGraceElapsed; self.reconnecting = reconnecting
        }
    }
    public enum Cleanup { case initialDrop, failedAttempt, stormPause, budgetExhausted }
    @MainActor public struct NativeActions {
        public var observe: () -> Context
        public var cleanup: (Cleanup, Attempt) -> Void
        public var scanning: (Attempt) -> Void
        /// Performs native preparation, never the pairing/AP/station/handshake workflow.
        public var prepare: (DJISighting, Attempt) -> DJIConnectionRoute?
        public init(observe: @escaping () -> Context,
            cleanup: @escaping (Cleanup, Attempt) -> Void, scanning: @escaping (Attempt) -> Void,
            prepare: @escaping (DJISighting, Attempt) -> DJIConnectionRoute?) {
            self.observe = observe; self.cleanup = cleanup; self.scanning = scanning
            self.prepare = prepare
        }
    }
    @MainActor public final class Attempt {
        public let id = UUID()
        public let trigger: SessionRecoveryTrigger
        public let reason: String
        fileprivate weak var owner: DjiAppleRecoveryEpisode?
        fileprivate var runID: UUID?
        fileprivate var task: Task<Void, Never>?
        fileprivate var graceTask: Task<Void, Never>?
        fileprivate init(owner: DjiAppleRecoveryEpisode, runID: UUID?,
            trigger: SessionRecoveryTrigger, reason: String) {
            self.owner = owner; self.runID = runID
            self.trigger = trigger; self.reason = reason
        }
        public var isCurrent: Bool {
            owner?.current === self && owner?.connectionRun.currentRunID == runID
        }
        /// Native teardown calls this at its original run-retirement point. It cannot
        /// retire a successor, even if that successor is connected to the same camera.
        @discardableResult public func retireCapturedConnectionRun() -> Bool {
            guard let owner, isCurrent else { return false }
            owner.connectionRun.retire()
            runID = owner.connectionRun.currentRunID
            return isCurrent
        }
    }
    private let connectionRun: DjiAppleConnectionRun
    private let discovery: DjiAppleRecoveryDiscovery
    private let native: NativeActions
    private let timing: DjiAppleRecoveryTiming
    private let changed: (Snapshot, UUID?) -> Void
    private var current: Attempt?
    private var generation: UInt64 = 0
    private var storm = SessionDropStormGuard()
    public private(set) var snapshot = Snapshot()
    public var currentEpisodeID: UUID? { current?.id }
    public var isRunning: Bool { current?.task != nil }

    public init(connectionRun: DjiAppleConnectionRun, discovery: DjiAppleRecoveryDiscovery,
        native: NativeActions, timing: DjiAppleRecoveryTiming = .continuous,
        changed: @escaping (Snapshot, UUID?) -> Void) {
        self.connectionRun = connectionRun; self.discovery = discovery; self.native = native
        self.timing = timing; self.changed = changed
    }

    @discardableResult
    public func begin(targetID: String?, trigger: SessionRecoveryTrigger, reason: String) -> Bool {
        guard SessionRecoveryPolicy.shouldBegin(trigger), let targetID, current == nil,
            !snapshot.state.isRecovering else { return false }
        let observedGeneration = generation
        let observedRun = connectionRun.currentRunID
        let context = native.observe()
        guard generation == observedGeneration, connectionRun.currentRunID == observedRun,
            context.ownsConnection == true else { return false }
        let attempt = Attempt(owner: self, runID: observedRun, trigger: trigger, reason: reason)
        generation &+= 1
        current = attempt
        snapshot = .init(targetID: targetID, holdsPicture: true)
        changed(snapshot, attempt.id)
        do {
            try cleanup(.initialDrop, attempt: attempt)
            let droppedAt = timing.uptime(); try check(attempt)
            if storm.noteDrop(now: droppedAt) {
                try cleanup(.stormPause, attempt: attempt)
                var next = snapshot; next.state = .pausedAfterRepeatedDrops(drops: storm.dropsInWindow)
                next.cardGraceElapsed = true
                try publish(next, attempt: attempt)
                return attempt.isCurrent
            }
            attempt.graceTask = Task { [weak self, attempt] in
                guard let self else { return }
                do {
                    try self.checkContinuation(attempt)
                    try await self.timing.sleep(.seconds(2.5))
                    try self.checkContinuation(attempt)
                    var next = self.snapshot; next.cardGraceElapsed = true
                    try self.publish(next, attempt: attempt)
                } catch {}
            }
            attempt.task = Task { [weak self, attempt] in
                guard let self else { return }
                await self.run(attempt)
                if self.current === attempt { attempt.task = nil }
            }
            // The identity and both owned tasks precede synchronous publication. Cancel
            // inside the callback therefore cannot be followed by an old task install.
            var next = snapshot; next.state = SessionRecoveryPolicy.monitor.state(afterFailedAttempts: 0)
            try publish(next, attempt: attempt)
            return attempt.isCurrent
        } catch { return false }
    }

    /// Local retirement only; native disconnect/decoder teardown remains the host action.
    public func cancel(clearHold: Bool = true) {
        let retired = current
        generation &+= 1; current = nil
        retired?.task?.cancel(); retired?.graceTask?.cancel()
        if let retired, connectionRun.currentRunID == retired.runID { connectionRun.retire() }
        snapshot = .init(targetID: clearHold ? nil : snapshot.targetID,
            holdsPicture: clearHold ? false : snapshot.holdsPicture)
        changed(snapshot, nil)
    }

    @discardableResult public func retry() -> Bool {
        guard let target = snapshot.targetID else { return false }
        let before = generation
        let runID = connectionRun.currentRunID
        let context = native.observe()
        guard generation == before, connectionRun.currentRunID == runID,
            context.ownsConnection == true else { return false }
        storm.reset()
        cancel(clearHold: false)
        guard generation == before &+ 1, current == nil else { return false }
        return begin(targetID: target, trigger: .operatorRetry, reason: "operator retry")
    }

    private func check(_ attempt: Attempt) throws {
        guard attempt.isCurrent else { throw CancellationError() }
        let context = native.observe()
        guard attempt.isCurrent, context.ownsConnection == true
        else { throw CancellationError() }
    }
    /// A synchronous callback may cancel A and admit B while still executing on A's
    /// canceled task. B's admission uses its identity; resumed asynchronous children also
    /// check their own cancellation so the budget race cannot continue its losing child.
    private func checkContinuation(_ attempt: Attempt) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        try check(attempt)
        guard !Task.isCancelled else { throw CancellationError() }
    }
    private func observe(_ attempt: Attempt) throws -> Context {
        try check(attempt); let value = native.observe(); try check(attempt); return value
    }
    private func now(_ attempt: Attempt) throws -> ContinuousClock.Instant {
        try check(attempt); let value = timing.monotonicNow(); try check(attempt); return value
    }
    private func wall(_ attempt: Attempt) throws -> TimeInterval {
        try check(attempt); let value = timing.wallNow(); try check(attempt); return value
    }
    private func publish(_ value: Snapshot, attempt: Attempt) throws {
        try check(attempt); snapshot = value; changed(value, attempt.id); try check(attempt)
    }
    private func cleanup(_ kind: Cleanup, attempt: Attempt) throws {
        try check(attempt); native.cleanup(kind, attempt); try check(attempt)
    }
    private func stopScan(_ attempt: Attempt) throws {
        try check(attempt); discovery.stopScan(); try check(attempt)
    }

    private func run(_ attempt: Attempt) async {
        // Preserve the donor's race and cancellation-join behavior. Deliberately late
        // native waits may finish later, but their continuation has no stale authority.
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                await self?.runAttempts(attempt); return false
            }
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                guard let self else { return false }
                do {
                    try self.checkContinuation(attempt)
                    try await self.timing.sleep(.seconds(SessionRecoveryPolicy.automaticRecoveryBudgetSeconds))
                    try self.checkContinuation(attempt); return true
                } catch { return false }
            }
            let first = await group.next() ?? false; group.cancelAll(); return first
        }
        guard timedOut else { return }
        do {
            try checkContinuation(attempt)
            let attempts: Int
            if case .retrying(let number, _) = snapshot.state { attempts = number } else { attempts = 0 }
            try cleanup(.budgetExhausted, attempt: attempt)
            try stopScan(attempt)
            var next = snapshot; next.state = .waitingForOperator(attemptsMade: attempts)
            next.cardGraceElapsed = true
            try publish(next, attempt: attempt)
        } catch {}
    }

    private func runAttempts(_ attempt: Attempt) async {
        let policy = SessionRecoveryPolicy.monitor
        var failures = 0
        do {
            while true {
                try checkContinuation(attempt)
                var next = snapshot; next.state = policy.state(afterFailedAttempts: failures)
                try publish(next, attempt: attempt)
                guard case .retrying = next.state else { return }
                let recovered = try await connect(attempt)
                try checkContinuation(attempt)
                if recovered {
                    next = snapshot; next.state = .idle; next.holdsPicture = false
                    next.reconnecting = false; next.cardGraceElapsed = false
                    try publish(next, attempt: attempt)
                    attempt.graceTask?.cancel()
                    current = nil; generation &+= 1
                    return
                }
                failures += 1
                try cleanup(.failedAttempt, attempt: attempt)
                try stopScan(attempt)
                let jitter = timing.jitter(); try check(attempt)
                guard case .retry(let wait) = policy.decision(afterFailedAttempts: failures, jitter: jitter) else {
                    next = snapshot; next.state = policy.state(afterFailedAttempts: failures)
                    try publish(next, attempt: attempt); return
                }
                try await timing.sleep(.seconds(wait)); try checkContinuation(attempt)
            }
        } catch {}
    }

    private func connect(_ attempt: Attempt) async throws -> Bool {
        try checkContinuation(attempt)
        guard let target = snapshot.targetID else { return false }
        var next = snapshot; next.reconnecting = true
        try publish(next, attempt: attempt)
        native.scanning(attempt); try check(attempt)
        guard let sighting = try await advertisement(targetID: target, attempt: attempt) else { return false }
        try checkContinuation(attempt)
        let started = try wall(attempt)
        let deadline = try now(attempt).advanced(by: .seconds(180))
        // The donor samples saved identity again at connect admission. Use that exact
        // target/model, and fence a synchronous replacement before native preparation.
        let admitted = discovery.enrich(sighting); try check(attempt)
        guard let route = native.prepare(admitted, attempt) else { try check(attempt); return false }
        try check(attempt)
        let runID = connectionRun.replace(target: admitted, route: route, preservingSource: true)
        guard current === attempt else { throw CancellationError() }
        attempt.runID = runID; try check(attempt)
        var previous = try observe(attempt).stage
        var stageDeadline = try now(attempt).advanced(by: Self.deadline(for: previous))
        while true {
            let context = try observe(attempt)
            if context.stage != previous {
                previous = context.stage
                stageDeadline = try now(attempt).advanced(by: Self.deadline(for: previous))
            }
            let currentTime = try now(attempt)
            guard currentTime < deadline, currentTime < stageDeadline else { return false }
            if context.stage == .live, SessionRecoveryPolicy.hasFreshPicture(
                attemptStartedAt: started, now: try wall(attempt),
                lastSourceFrameAt: context.sourceAt, lastPresentedAt: context.presentedAt) { return true }
            if !connectionRun.isRunning, context.stage != .live { return false }
            try await timing.sleep(.milliseconds(100)); try checkContinuation(attempt)
        }
    }

    public static func deadline(for stage: Stage?) -> Duration {
        switch stage {
        case .joiningWiFi: .seconds(CameraSoftAPSwitch.joinDeadlineSeconds + 15)
        case .openingDatalink: .seconds(50)
        case .live: .seconds(2 * CameraSoftAP.foregroundPictureGrace)
        case .other, nil: .seconds(30)
        }
    }

    private func advertisement(targetID: String, attempt: Attempt) async throws -> DJISighting? {
        try checkContinuation(attempt)
        let powered = await discovery.waitUntilPoweredOn(); try checkContinuation(attempt)
        guard powered else { return nil }
        let found = await withTaskGroup(of: DJISighting?.self) { group in
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                guard let self else { return nil }
                do {
                    try self.checkContinuation(attempt)
                    let stream = self.discovery.scan(); try self.check(attempt)
                    for await sighting in stream {
                        try self.checkContinuation(attempt)
                        let saved = self.discovery.enrich(sighting); try self.check(attempt)
                        if saved.id == targetID { return saved }
                    }
                } catch {}
                return nil
            }
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                guard let self else { return nil }
                do {
                    try self.checkContinuation(attempt)
                    try await self.timing.sleep(.seconds(30)); try self.checkContinuation(attempt)
                } catch {}
                return nil
            }
            let first = await group.next() ?? nil; group.cancelAll(); return first
        }
        try checkContinuation(attempt)
        // A matching camera needs the next advertisement for GATT; retain its scanner.
        if found == nil { try stopScan(attempt) }
        return found
    }
}
