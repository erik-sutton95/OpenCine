import Foundation

/// Decisions for one automatic session-recovery loop over `SessionRecoveryPolicy.monitor`.
///
/// The host keeps transport, tasks, logging and the recovery card. This value records when a
/// drop may start, the storm pause, the generation, the card-grace latch, the attempt counter
/// and the budget's operator handoff. A host whose transport stages differ keeps its own episode.
public struct SessionRecoveryDrive: Equatable, Sendable {
    public private(set) var generation: Int = 0
    public var state: SessionRecoveryState = .idle
    public private(set) var holdsPicture: Bool = false
    public private(set) var cardGraceElapsed: Bool = false
    public private(set) var failures: Int = 0
    /// True from a started run until that run's task ends or the host cancels.
    public private(set) var automaticTaskRunning: Bool = false
    private var storm = SessionDropStormGuard()

    /// How long the host waits before the recovery card may show. The monitor stays on the held frame either way.
    public static let cardGraceSeconds: Double = 2.5

    public init() {}

    public enum Begin: Equatable, Sendable {
        /// Trigger, phase, missing target, or a run already in flight. No field changes.
        case ignored
        /// Drops clustered. The host still applies the drop side effects, then shows the pause.
        case paused(drops: Int)
        /// Automatic run. The host starts the grace wait and the attempt task.
        case started
    }

    public enum FailedAttempt: Equatable, Sendable {
        case backoff(seconds: Double)
        case exhausted
    }

    /// Adopts `current` first so a host edit of the published state (a test, a direct assign)
    /// is the phase this call sees.
    public mutating func begin(
        trigger: SessionRecoveryTrigger, hasTarget: Bool, now: Double,
        current: SessionRecoveryState
    ) -> Begin {
        state = current
        guard SessionRecoveryPolicy.shouldBegin(trigger), hasTarget, !automaticTaskRunning else {
            return .ignored
        }
        if case .pausedAfterRepeatedDrops = state { return .ignored }
        if case .waitingForOperator = state { return .ignored }
        if case .takenOver = state { return .ignored }
        holdsPicture = true
        generation += 1
        if storm.noteDrop(now: now) {
            let drops = storm.dropsInWindow
            state = .pausedAfterRepeatedDrops(drops: drops)
            cardGraceElapsed = true
            return .paused(drops: drops)
        }
        failures = 0
        state = SessionRecoveryPolicy.monitor.state(afterFailedAttempts: 0)
        cardGraceElapsed = false
        automaticTaskRunning = true
        return .started
    }

    public mutating func resetStorm() { storm.reset() }

    /// Local retirement. The host cancels its tasks and clears a held target when `clearHold` is set.
    public mutating func cancel(clearHold: Bool) {
        generation += 1
        automaticTaskRunning = false
        state = .idle
        cardGraceElapsed = false
        failures = 0
        if clearHold { holdsPicture = false }
    }

    /// The grace wait finished. A stale generation (cancel or a newer run) leaves the latch alone.
    @discardableResult
    public mutating func noteCardGrace(seenGeneration: Int) -> Bool {
        guard seenGeneration == generation else { return false }
        cardGraceElapsed = true
        return true
    }

    public mutating func beginAttempts() { failures = 0 }

    /// State for the current failure count. The host stops the loop when it is not `.retrying`.
    public mutating func prepareAttempt() -> SessionRecoveryState {
        state = SessionRecoveryPolicy.monitor.state(afterFailedAttempts: failures)
        return state
    }

    /// Failures so far, then idle with the hold cleared.
    public mutating func noteRecovered() -> Int {
        let failed = failures
        state = .idle
        holdsPicture = false
        cardGraceElapsed = false
        failures = 0
        return failed
    }

    public mutating func noteAttemptFailed(jitter: Double) -> FailedAttempt {
        failures += 1
        let decision = SessionRecoveryPolicy.monitor.decision(
            afterFailedAttempts: failures, jitter: jitter)
        if case .retry(let seconds) = decision {
            return .backoff(seconds: seconds)
        }
        state = SessionRecoveryPolicy.monitor.state(afterFailedAttempts: failures)
        return .exhausted
    }

    /// Budget spent while `current` is the published phase. Attempt number comes from a retrying phase.
    public mutating func noteBudgetExhausted(current: SessionRecoveryState) {
        state = current
        let attempts: Int
        if case .retrying(let attempt, _) = state { attempts = attempt } else { attempts = 0 }
        state = .waitingForOperator(attemptsMade: attempts)
        cardGraceElapsed = true
    }

    public mutating func noteAutomaticTaskEnded(seenGeneration: Int) {
        guard seenGeneration == generation else { return }
        automaticTaskRunning = false
    }
}
