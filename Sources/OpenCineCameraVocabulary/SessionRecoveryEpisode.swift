import Foundation

/// One finite automatic recovery episode for a dropped camera session. Every app runs this one.
///
/// The monitor keeps the last picture while bounded attempts reconnect through the host's own
/// connection path. An attempt ends recovery only on a source frame and a presented picture that
/// are both newer than its start (`SessionRecoveryPolicy.hasFreshPicture`): a returned control
/// session, a handshake or a repaint of the held frame is not a recovered monitor. Retries follow
/// `SessionRecoveryPolicy.monitor`, the episode stops at
/// `SessionRecoveryPolicy.automaticRecoveryBudgetSeconds` and hands the decision to the operator,
/// and drops that cluster across episodes pause automatic recovery (`SessionDropStormGuard`).
///
/// While the host app is in the background the OS may block its camera network, so an attempt
/// there fails at once without reaching the camera. The host reports that with `pause()` and
/// `resume()`: while paused no attempt dials, an attempt that failed during a pause does not
/// count, and the total budget's clock stops. The held episode continues when the host resumes.
///
/// Transport, credentials, decoders and presentation stay with the host behind `Port`. Each
/// attempt has an identity: a host action that runs on a retired or replaced attempt, or after it
/// lost the connection, cannot publish, clean up or connect for its successor.
@MainActor
public final class SessionRecoveryEpisode {
    /// Where an attempt's transport is, for stage deadlines. Integrations map their own phases.
    public enum Stage: Hashable, Sendable {
        case connecting
        case joiningNetwork
        case openingLink
        case live
    }

    /// How long one attempt may run, declared by the integration that owns the transport.
    public struct AttemptDeadline: Equatable, Sendable {
        /// Ceiling on the whole attempt, counted from the moment `Port.connect` admits it.
        public var attempt: Duration
        /// Ceiling per observed stage, restarted whenever the stage changes. A stage without an
        /// entry has only the attempt ceiling.
        public var stages: [Stage: Duration]

        public init(attempt: Duration, stages: [Stage: Duration] = [:]) {
            self.attempt = attempt
            self.stages = stages
        }

        func ceiling(for stage: Stage?) -> Duration? { stage.flatMap { stages[$0] } }
    }

    /// The attempt's transport as the host sees it.
    public enum Progress: Equatable, Sendable {
        case running
        /// The transport gave up without a picture. The episode counts a failure and backs off.
        case failed
        /// Another connection replaced this attempt's source. The episode stops retrying and the
        /// operator decides; the replacement's picture never proves this attempt.
        case superseded
    }

    /// One reading of the host's transport and picture clocks.
    public struct Observation: Equatable, Sendable {
        /// Explicit transport authority. Unknown (`nil`) refuses like `false`: the episode stops
        /// without publishing or touching the transport.
        public var ownsConnection: Bool?
        public var progress: Progress
        public var stage: Stage?
        /// Last source frame and last presented picture, on `Timing.wallNow`'s clock. A host that
        /// knows a picture cannot be live yet (wrong stage, replaced source) reports `nil`.
        public var sourceAt: TimeInterval?
        public var presentedAt: TimeInterval?

        public init(
            ownsConnection: Bool? = nil, progress: Progress = .running, stage: Stage? = nil,
            sourceAt: TimeInterval? = nil, presentedAt: TimeInterval? = nil
        ) {
            self.ownsConnection = ownsConnection
            self.progress = progress
            self.stage = stage
            self.sourceAt = sourceAt
            self.presentedAt = presentedAt
        }
    }

    /// Everything the host renders: the card, the held-picture badge, the reconnect spinner.
    public struct Snapshot: Equatable, Sendable {
        public var state: SessionRecoveryState
        public var targetID: String?
        public var holdsPicture: Bool
        public var cardGraceElapsed: Bool
        public var reconnecting: Bool

        public init(
            state: SessionRecoveryState = .idle, targetID: String? = nil,
            holdsPicture: Bool = false, cardGraceElapsed: Bool = false, reconnecting: Bool = false
        ) {
            self.state = state
            self.targetID = targetID
            self.holdsPicture = holdsPicture
            self.cardGraceElapsed = cardGraceElapsed
            self.reconnecting = reconnecting
        }
    }

    /// When the host retires native work. The drop itself, a failed attempt, a storm pause and
    /// the spent budget each get one call.
    public enum Cleanup: Equatable, Sendable {
        case initialDrop, failedAttempt, stormPause, budgetExhausted
    }

    /// Monotonic deadlines, storm uptime and wall picture timestamps stay distinct clocks.
    @MainActor
    public struct Timing {
        public var monotonicNow: () -> ContinuousClock.Instant
        public var uptime: () -> TimeInterval
        public var wallNow: () -> TimeInterval
        public var sleep: (Duration) async throws -> Void
        public var jitter: () -> Double

        public init(
            monotonicNow: @escaping () -> ContinuousClock.Instant,
            uptime: @escaping () -> TimeInterval, wallNow: @escaping () -> TimeInterval,
            sleep: @escaping (Duration) async throws -> Void, jitter: @escaping () -> Double
        ) {
            self.monotonicNow = monotonicNow
            self.uptime = uptime
            self.wallNow = wallNow
            self.sleep = sleep
            self.jitter = jitter
        }

        public static var continuous: Self {
            .init(
                monotonicNow: { ContinuousClock().now },
                uptime: { ProcessInfo.processInfo.systemUptime },
                wallNow: { Date.timeIntervalSinceReferenceDate },
                sleep: { try await Task.sleep(for: $0) }, jitter: { .random(in: 0...1) })
        }
    }

    /// The host's transport for this episode.
    @MainActor
    public struct Port {
        public var observe: @MainActor () -> Observation
        public var cleanup: @MainActor (Cleanup, Attempt) -> Void
        /// Starts one attempt through the host's own connection path and returns once the
        /// attempt is admitted. `false` or a thrown error means it could not start (no camera
        /// found, no route) and counts as a failed attempt; `CancellationError` ends the episode
        /// without publishing.
        public var connect: @MainActor (Attempt) async throws -> Bool
        /// The host's current native connection run, for hosts whose attempts replace one.
        /// An attempt stays current only while this equals the run it captured or adopted.
        public var currentRun: @MainActor () -> UUID?
        public var retireRun: @MainActor () -> Void
        /// The device now holding the camera, asked before automatic attempt `n` (1-based)
        /// dials. A body that takes one initiator drops the device holding it when another
        /// connects, so reconnecting would take the camera straight back from it. `nil` when
        /// nobody says so. Never asked on an operator retry: that is the take-back.
        public var holder: @MainActor (Attempt, Int) async -> String?

        public init(
            observe: @escaping @MainActor () -> Observation,
            cleanup: @escaping @MainActor (Cleanup, Attempt) -> Void,
            connect: @escaping @MainActor (Attempt) async throws -> Bool,
            currentRun: @escaping @MainActor () -> UUID? = { nil },
            retireRun: @escaping @MainActor () -> Void = {},
            holder: (@MainActor (Attempt, Int) async -> String?)? = nil
        ) {
            // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
            self.holder = holder ?? { _, _ in nil }
            self.observe = observe
            self.cleanup = cleanup
            self.connect = connect
            self.currentRun = currentRun
            self.retireRun = retireRun
        }
    }

    /// One admitted episode. Host actions check it before touching shared transport state.
    @MainActor
    public final class Attempt {
        public let id = UUID()
        public let targetID: String
        public let trigger: SessionRecoveryTrigger
        public let reason: String
        fileprivate weak var owner: SessionRecoveryEpisode?
        fileprivate var runID: UUID?
        fileprivate var task: Task<Void, Never>?
        fileprivate var graceTask: Task<Void, Never>?
        fileprivate var budgetTask: Task<Void, Never>?
        fileprivate var budgetLeft: Duration = .seconds(
            SessionRecoveryPolicy.automaticRecoveryBudgetSeconds)
        fileprivate var budgetSegmentStart: ContinuousClock.Instant?

        fileprivate init(
            owner: SessionRecoveryEpisode, runID: UUID?, targetID: String,
            trigger: SessionRecoveryTrigger, reason: String
        ) {
            self.owner = owner
            self.runID = runID
            self.targetID = targetID
            self.trigger = trigger
            self.reason = reason
        }

        public var isCurrent: Bool {
            guard let owner else { return false }
            return owner.current === self && owner.port.currentRun() == runID
        }

        /// Native teardown calls this at its own run-retirement point. It cannot retire a
        /// successor's run, even when that successor targets the same camera.
        @discardableResult public func retireCapturedRun() -> Bool {
            guard let owner, isCurrent else { return false }
            owner.port.retireRun()
            runID = owner.port.currentRun()
            return isCurrent
        }

        /// The host replaced its connection run for this attempt inside `Port.connect`.
        public func adoptRun(_ id: UUID?) throws {
            guard let owner, owner.current === self else { throw CancellationError() }
            runID = id
            try owner.check(self)
        }

        /// Throws `CancellationError` once this attempt is retired, replaced or no longer owns
        /// the connection.
        public func checkCurrent() throws {
            guard let owner else { throw CancellationError() }
            try owner.check(self)
        }

        /// `checkCurrent` plus the calling task's cancellation, for code resumed after an await.
        public func checkContinuation() throws {
            guard let owner else { throw CancellationError() }
            try owner.checkContinuation(self)
        }
    }

    /// How long the card waits behind attempt 1. The monitor holds the picture either way.
    public nonisolated static let cardGraceSeconds: Double = 2.5

    private let port: Port
    private let deadline: AttemptDeadline
    private let timing: Timing
    private let changed: (Snapshot, UUID?) -> Void
    private var current: Attempt?
    private var generation: UInt64 = 0
    private var storm = SessionDropStormGuard()
    private var hostActive = true
    private var pauseEpoch: UInt64 = 0
    private var resumeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    public private(set) var snapshot = Snapshot()
    /// The host reported that it cannot reach the camera now (`pause()`).
    public var isPaused: Bool { !hostActive }
    public var currentEpisodeID: UUID? { current?.id }
    public var isRunning: Bool { current?.task != nil }

    public init(
        port: Port, attemptDeadline: AttemptDeadline, timing: Timing = .continuous,
        changed: @escaping (Snapshot, UUID?) -> Void
    ) {
        self.port = port
        self.deadline = attemptDeadline
        self.timing = timing
        self.changed = changed
    }

    /// Admits a drop. `false` when the trigger does not recover, there is no target, an episode
    /// is in flight or waiting for the operator, the host does not own the connection, or a host
    /// callback replaced or cancelled this episode before it was installed.
    @discardableResult
    public func begin(targetID: String?, trigger: SessionRecoveryTrigger, reason: String) -> Bool {
        guard SessionRecoveryPolicy.shouldBegin(trigger), let targetID, current == nil,
            !snapshot.state.isRecovering
        else { return false }
        let observedGeneration = generation
        let observedRun = port.currentRun()
        let context = port.observe()
        guard generation == observedGeneration, port.currentRun() == observedRun,
            context.ownsConnection == true
        else { return false }
        let attempt = Attempt(
            owner: self, runID: observedRun, targetID: targetID, trigger: trigger, reason: reason)
        generation &+= 1
        current = attempt
        snapshot = .init(targetID: targetID, holdsPicture: true)
        changed(snapshot, attempt.id)
        do {
            try cleanup(.initialDrop, attempt: attempt)
            let droppedAt = timing.uptime()
            try check(attempt)
            if storm.noteDrop(now: droppedAt) {
                try cleanup(.stormPause, attempt: attempt)
                var next = snapshot
                next.state = .pausedAfterRepeatedDrops(drops: storm.dropsInWindow)
                next.cardGraceElapsed = true
                try publish(next, attempt: attempt)
                return attempt.isCurrent
            }
            attempt.graceTask = Task { [weak self, attempt] in
                guard let self else { return }
                do {
                    try self.checkContinuation(attempt)
                    try await self.timing.sleep(.seconds(Self.cardGraceSeconds))
                    try self.checkContinuation(attempt)
                    var next = self.snapshot
                    next.cardGraceElapsed = true
                    try self.publish(next, attempt: attempt)
                } catch {}
            }
            if hostActive {
                attempt.budgetTask = Task { [weak self, attempt] in
                    guard let self else { return }
                    await self.waitForBudget(attempt)
                }
            }
            attempt.task = Task { [weak self, attempt] in
                guard let self else { return }
                await self.run(attempt)
                if self.current === attempt { attempt.task = nil }
            }
            // The identity and both tasks exist before the first publication, so a host callback
            // that cancels here cannot be followed by an old task install.
            var next = snapshot
            next.state = SessionRecoveryPolicy.monitor.state(afterFailedAttempts: 0)
            try publish(next, attempt: attempt)
            return attempt.isCurrent
        } catch { return false }
    }

    /// Local retirement only; the host's native disconnect and decoder teardown stay host actions.
    public func cancel(clearHold: Bool = true) {
        let retired = current
        generation &+= 1
        current = nil
        retired?.task?.cancel()
        retired?.graceTask?.cancel()
        retired?.budgetTask?.cancel()
        if let retired, port.currentRun() == retired.runID { port.retireRun() }
        snapshot = .init(
            targetID: clearHold ? nil : snapshot.targetID,
            holdsPicture: clearHold ? false : snapshot.holdsPicture)
        changed(snapshot, nil)
    }

    /// The host went to the background or the OS blocks its camera network. Attempts wait, one
    /// that fails while paused is not counted, and the budget's clock stops until `resume()`.
    /// Lasts across episodes: an episode admitted while paused waits for `resume()` to dial.
    public func pause() {
        guard hostActive else { return }
        hostActive = false
        pauseEpoch &+= 1
        guard let attempt = current, let budget = attempt.budgetTask else { return }
        attempt.budgetTask = nil
        budget.cancel()
        if let started = attempt.budgetSegmentStart {
            let left = attempt.budgetLeft - (timing.monotonicNow() - started)
            attempt.budgetLeft = max(.zero, left)
        }
        attempt.budgetSegmentStart = nil
    }

    /// The host can reach the camera again: a paused episode dials and its budget clock runs.
    public func resume() {
        guard !hostActive else { return }
        hostActive = true
        let waiters = resumeWaiters.values
        resumeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        // A finished run (operator decision, storm pause) has no budget left to spend.
        guard let attempt = current, attempt.task != nil, attempt.budgetTask == nil else { return }
        attempt.budgetTask = Task { [weak self, attempt] in
            guard let self else { return }
            await self.waitForBudget(attempt)
        }
    }

    /// Operator action: a fresh drop ledger. Never called on reconnect success.
    public func resetStorm() { storm.reset() }

    /// Operator retry of the held target: a fresh ledger and a fresh episode.
    @discardableResult public func retry() -> Bool {
        guard let target = snapshot.targetID else { return false }
        let before = generation
        let runID = port.currentRun()
        let context = port.observe()
        guard generation == before, port.currentRun() == runID, context.ownsConnection == true
        else { return false }
        storm.reset()
        cancel(clearHold: false)
        guard generation == before &+ 1, current == nil else { return false }
        return begin(targetID: target, trigger: .operatorRetry, reason: "operator retry")
    }

    fileprivate func check(_ attempt: Attempt) throws {
        guard attempt.isCurrent else { throw CancellationError() }
        let context = port.observe()
        guard attempt.isCurrent, context.ownsConnection == true else { throw CancellationError() }
    }

    /// A synchronous callback may cancel A and admit B while still on A's cancelled task. B's
    /// admission uses its identity; resumed children also check their own cancellation so the
    /// budget race cannot continue its losing child.
    fileprivate func checkContinuation(_ attempt: Attempt) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        try check(attempt)
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private func observe(_ attempt: Attempt) throws -> Observation {
        try check(attempt)
        let value = port.observe()
        try check(attempt)
        return value
    }

    private func now(_ attempt: Attempt) throws -> ContinuousClock.Instant {
        try check(attempt)
        let value = timing.monotonicNow()
        try check(attempt)
        return value
    }

    private func wall(_ attempt: Attempt) throws -> TimeInterval {
        try check(attempt)
        let value = timing.wallNow()
        try check(attempt)
        return value
    }

    private func publish(_ value: Snapshot, attempt: Attempt) throws {
        try check(attempt)
        snapshot = value
        changed(value, attempt.id)
        try check(attempt)
    }

    private func cleanup(_ kind: Cleanup, attempt: Attempt) throws {
        try check(attempt)
        port.cleanup(kind, attempt)
        try check(attempt)
    }

    private func run(_ attempt: Attempt) async {
        defer { attempt.budgetTask?.cancel() }
        await runAttempts(attempt)
    }

    private func waitForBudget(_ attempt: Attempt) async {
        // Publish the handoff on the deadline itself. A native connect may ignore cancellation;
        // joining that task first would let it extend the operator's total recovery budget.
        do {
            try checkContinuation(attempt)
            attempt.budgetSegmentStart = timing.monotonicNow()
            try await timing.sleep(attempt.budgetLeft)
            try checkContinuation(attempt)
            let attempts: Int
            if case .retrying(let number, _) = snapshot.state {
                attempts = number
            } else {
                attempts = 0
            }
            try cleanup(.budgetExhausted, attempt: attempt)
            var next = snapshot
            next.state = .waitingForOperator(attemptsMade: attempts)
            next.cardGraceElapsed = true
            next.reconnecting = false
            try publish(next, attempt: attempt)
            attempt.task?.cancel()
            attempt.graceTask?.cancel()
        } catch {}
    }

    private func runAttempts(_ attempt: Attempt) async {
        let policy = SessionRecoveryPolicy.monitor
        var failures = 0
        do {
            while true {
                try checkContinuation(attempt)
                var next = snapshot
                next.state = policy.state(afterFailedAttempts: failures)
                try publish(next, attempt: attempt)
                guard case .retrying = next.state else { return }
                try await waitWhilePaused(attempt)
                if attempt.trigger != .operatorRetry,
                    let holder = await port.holder(attempt, failures + 1)
                {
                    try checkContinuation(attempt)
                    next = snapshot
                    next.state = .takenOver(holder: holder.isEmpty ? nil : holder)
                    next.reconnecting = false
                    next.cardGraceElapsed = true
                    try publish(next, attempt: attempt)
                    return
                }
                try checkContinuation(attempt)
                // The host may have paused while the holder was asked.
                try await waitWhilePaused(attempt)
                let epoch = pauseEpoch
                let outcome = try await runOneAttempt(attempt)
                try checkContinuation(attempt)
                switch outcome {
                case .recovered:
                    next = snapshot
                    next.state = .idle
                    next.holdsPicture = false
                    next.reconnecting = false
                    next.cardGraceElapsed = false
                    try publish(next, attempt: attempt)
                    attempt.graceTask?.cancel()
                    current = nil
                    generation &+= 1
                    return
                case .superseded:
                    next = snapshot
                    next.state = .waitingForOperator(attemptsMade: failures + 1)
                    next.reconnecting = false
                    next.cardGraceElapsed = true
                    try publish(next, attempt: attempt)
                    return
                case .failed:
                    break
                }
                if pauseEpoch != epoch || !hostActive {
                    // The OS, not the camera, refused this attempt: retire it without counting.
                    try cleanup(.failedAttempt, attempt: attempt)
                    next = snapshot
                    next.reconnecting = false
                    try publish(next, attempt: attempt)
                    continue
                }
                failures += 1
                try cleanup(.failedAttempt, attempt: attempt)
                let jitter = timing.jitter()
                try check(attempt)
                guard
                    case .retry(let wait) = policy.decision(
                        afterFailedAttempts: failures, jitter: jitter)
                else {
                    next = snapshot
                    next.state = policy.state(afterFailedAttempts: failures)
                    try publish(next, attempt: attempt)
                    return
                }
                try await timing.sleep(.seconds(wait))
                try checkContinuation(attempt)
            }
        } catch {}
    }

    private enum Outcome { case recovered, failed, superseded }

    /// Holds a paused run until `resume()`, or ends it when its task is already cancelled.
    private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else if hostActive {
            continuation.resume()
        } else {
            resumeWaiters[id] = continuation
        }
    }

    private func unpark(_ id: UUID) {
        resumeWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func waitWhilePaused(_ attempt: Attempt) async throws {
        guard !hostActive else { return }
        var next = snapshot
        next.reconnecting = false
        try publish(next, attempt: attempt)
        while !hostActive {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    self.park(id, continuation)
                }
            } onCancel: {
                Task { @MainActor in self.unpark(id) }
            }
            try checkContinuation(attempt)
        }
    }

    private func runOneAttempt(_ attempt: Attempt) async throws -> Outcome {
        try checkContinuation(attempt)
        var next = snapshot
        next.reconnecting = true
        try publish(next, attempt: attempt)
        let admitted: Bool
        do {
            admitted = try await port.connect(attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            admitted = false
        }
        try checkContinuation(attempt)
        guard admitted else { return .failed }
        let started = try wall(attempt)
        let attemptEnds = try now(attempt).advanced(by: deadline.attempt)
        var stage = try observe(attempt).stage
        var stageEnds = try deadline.ceiling(for: stage).map { try now(attempt).advanced(by: $0) }
        while true {
            let seen = try observe(attempt)
            // Any picture now belongs to the replacement, never to this attempt.
            if seen.progress == .superseded { return .superseded }
            if seen.stage != stage {
                stage = seen.stage
                stageEnds = try deadline.ceiling(for: stage).map {
                    try now(attempt).advanced(by: $0)
                }
            }
            let currentTime = try now(attempt)
            guard currentTime < attemptEnds, stageEnds.map({ currentTime < $0 }) ?? true else {
                return .failed
            }
            if SessionRecoveryPolicy.hasFreshPicture(
                attemptStartedAt: started, now: try wall(attempt),
                lastSourceFrameAt: seen.sourceAt, lastPresentedAt: seen.presentedAt)
            {
                return .recovered
            }
            if seen.progress == .failed { return .failed }
            try await timing.sleep(.milliseconds(100))
            try checkContinuation(attempt)
        }
    }
}
