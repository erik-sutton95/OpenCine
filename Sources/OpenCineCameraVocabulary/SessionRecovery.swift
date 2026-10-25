import Foundation
import OpenCineMedia

/// Whether an interrupted camera session is being recovered, and how the operator is told.
///
/// The monitor stays up on the last frame, automatic retries run bounded, and when the
/// budget is spent the operator decides what happens next.
public enum SessionRecoveryState: Equatable, Sendable {
    case idle
    /// An automatic reconnect is running (or waiting out its backoff). `attempt` is 1-based.
    case retrying(attempt: Int, maxAttempts: Int)
    /// The automatic budget is spent. The operator chooses: retry, or leave the monitor.
    case waitingForOperator(attemptsMade: Int)
    /// Reconnects kept succeeding but the session kept dying young.
    case pausedAfterRepeatedDrops(drops: Int)
    /// Another device now holds the camera (`holder`, when it names itself). Reconnecting would
    /// take the camera back from it, so automatic recovery stops and the operator decides.
    case takenOver(holder: String?)

    public var isRecovering: Bool { self != .idle }

    /// An automatic reconnect is actually running. The "Reconnecting" pill follows this, not
    /// `isRecovering`: a taken-over, paused or spent recovery waits for the operator and must not
    /// tell them it is reconnecting (hardware pass 4.1 showed both at once).
    public var isReconnecting: Bool {
        if case .retrying = self { return true }
        return false
    }

    /// Whether this device may still tell other devices it holds the camera (the presence answer
    /// and the in-use shield). A live session and a running reconnect keep the claim; a device
    /// that stopped reconnecting has given the camera up. A stale claim made the device that
    /// took the camera read its own later drop as "taken over" by the phone it had replaced, so
    /// both phones ended on "Camera taken over" (hardware pass 4.1).
    public var claimsCamera: Bool {
        switch self {
        case .idle, .retrying: true
        case .waitingForOperator, .pausedAfterRepeatedDrops, .takenOver: false
        }
    }
}

/// Cross-run damping for sessions that reconnect cleanly but keep dying.
///
/// A recovery run that succeeds resets its budget, so a periodic external killer (another device
/// probing the camera, an unanswered body-side liveness probe) becomes an unbounded storm of
/// instant reconnects, and some bodies stop accepting connections under that churn. The guard
/// counts drops across runs; when they cluster, automatic recovery pauses. Reset it on operator
/// action, never on reconnect success.
public struct SessionDropStormGuard: Sendable, Equatable {
    private var dropTimesSeconds: [Double] = []

    public init() {}

    public static let windowSeconds: Double = 120
    public static let pauseAfterDrops = 3

    public mutating func noteDrop(now: Double) -> Bool {
        dropTimesSeconds.append(now)
        dropTimesSeconds.removeAll { now - $0 > Self.windowSeconds }
        return dropTimesSeconds.count >= Self.pauseAfterDrops
    }

    public var dropsInWindow: Int { dropTimesSeconds.count }

    public mutating func reset() { dropTimesSeconds.removeAll() }
}

public enum SessionRecoveryDecision: Equatable, Sendable {
    case retry(afterSeconds: Double)
    case stop
}

/// What started bounded session recovery. Feed stall / SET timeout / first
/// picture are handled by `FeedWatchdog`; starting recovery there interrupts live video.
public enum SessionRecoveryTrigger: Equatable, Sendable {
    case bleDropped
    case softAPLost
    /// The watchdog's last rung (new handshake) missed while SoftAP was still
    /// up. Without this the shell sat on a nil datalink in Reconnecting.
    case datalinkLost
    case operatorRetry
    case feedWatchdogStall
    case commandTimeout
    case firstPicture
}

/// Shared reconnect rule: when to retry a dropped camera session, how long to back off,
/// and when to stop and ask the operator.
public struct SessionRecoveryPolicy: Sendable, Equatable {
    public var backoff: ReconnectBackoff
    public var maxAutomaticAttempts: Int

    public init(
        backoff: ReconnectBackoff = ReconnectBackoff(baseSeconds: 0.5, maxSeconds: 8),
        maxAutomaticAttempts: Int = 8
    ) {
        self.backoff = backoff
        self.maxAutomaticAttempts = max(0, maxAutomaticAttempts)
    }

    /// Retry at once, then 0.5s → 8s jittered, giving up after 8 attempts.
    /// Long enough to ride out a camera power cycle; short enough that a
    /// camera that is gone stops burning the radio.
    public static let monitor = SessionRecoveryPolicy()
    /// Total elapsed budget including discovery, joins and retry backoff.
    /// Per-stage deadlines must not multiply into an indefinite recovery screen.
    public static let automaticRecoveryBudgetSeconds: Double = 180

    /// A handshake, old held image, or GPU redraw alone cannot finish recovery.
    /// Shell timestamps share one clock and describe source and display progress.
    public static func hasFreshPicture(
        attemptStartedAt: Double, now: Double,
        lastSourceFrameAt: Double?, lastPresentedAt: Double?, maxAge: Double = 2
    ) -> Bool {
        guard attemptStartedAt.isFinite, now.isFinite, maxAge.isFinite, maxAge >= 0,
            now >= attemptStartedAt,
            let source = lastSourceFrameAt, let presented = lastPresentedAt
        else { return false }
        return [source, presented].allSatisfy {
            $0.isFinite && $0 > attemptStartedAt && $0 <= now && now - $0 <= maxAge
        }
    }

    public static func shouldBegin(_ trigger: SessionRecoveryTrigger) -> Bool {
        switch trigger {
        case .bleDropped, .softAPLost, .datalinkLost, .operatorRetry: true
        case .feedWatchdogStall, .commandTimeout, .firstPicture: false
        }
    }

    public func decision(afterFailedAttempts failures: Int, jitter: Double)
        -> SessionRecoveryDecision
    {
        let failed = max(0, failures)
        guard failed < maxAutomaticAttempts else { return .stop }
        guard failed > 0 else { return .retry(afterSeconds: 0) }
        return .retry(afterSeconds: backoff.delaySeconds(forAttempt: failed - 1, jitter: jitter))
    }

    public func state(afterFailedAttempts failures: Int) -> SessionRecoveryState {
        let failed = max(0, failures)
        guard failed < maxAutomaticAttempts else {
            return .waitingForOperator(attemptsMade: failed)
        }
        return .retrying(attempt: failed + 1, maxAttempts: maxAutomaticAttempts)
    }
}

/// A likely cause the operator can act on when a session keeps dropping.
public enum SessionDropSuspect: String, CaseIterable, Equatable, Sendable {
    /// Another device scanning for cameras can knock the session over each time it probes.
    case otherDeviceScanning
}

/// Operator-facing recovery copy. Never names a sister app or another brand.
public enum SessionRecoveryCopy {
    public static func title(_ state: SessionRecoveryState) -> String {
        switch state {
        case .idle: return ""
        case .retrying: return "Reconnecting…"
        case .waitingForOperator: return "Camera disconnected"
        case .pausedAfterRepeatedDrops: return "Connection keeps dropping"
        case .takenOver: return "Camera taken over"
        }
    }

    /// The supporting line. `dropSuspect` names a likely cause on the paused state.
    public static func detail(
        _ state: SessionRecoveryState, deviceName: String,
        dropSuspect: SessionDropSuspect? = nil
    ) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let camera = name.isEmpty ? "The camera" : name
        switch state {
        case .idle:
            return ""
        case .retrying(let attempt, _):
            // The episode ends on its time budget, usually before `maxAttempts`: "attempt 1 of 8"
            // followed by "after 3 tries" read as two machines (hardware pass 5.1).
            let minutes = Int(SessionRecoveryPolicy.automaticRecoveryBudgetSeconds / 60)
            return
                "\(camera) dropped off. Holding the last frame, attempt \(attempt). Reconnecting for up to \(minutes) minutes."
        case .waitingForOperator(let attemptsMade):
            let tries = attemptsMade == 1 ? "1 try" : "\(attemptsMade) tries"
            return "\(camera) didn't come back after \(tries). Turn the camera off and on, then tap Retry. The frame below is held, not live."
        case .pausedAfterRepeatedDrops(let drops):
            let paused =
                switch dropSuspect {
                case nil: "paused to protect the camera."
                case .otherDeviceScanning:
                    "paused to protect the camera, since another device may be scanning for cameras."
                }
            return
                "\(camera) reconnected but dropped \(drops) times in quick succession. Automatic retries are \(paused) The frame below is held, not live."
        case .takenOver(let holder):
            let other = holder.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Another device"
            return
                "\(other) connected to \(name.isEmpty ? "the camera" : name), so this device stopped reconnecting. Retry takes the camera back. The frame below is held, not live."
        }
    }

    public static let heldFrameBadge = "NO LINK"
}
