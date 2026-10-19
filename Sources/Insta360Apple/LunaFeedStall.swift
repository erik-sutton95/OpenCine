import Foundation

/// Luna live video is TCP: no loss, but the encoder can pause (a format or lens change, a busy
/// body) while the control socket stays up. The ladder asks for keyframes, then restarts live at
/// most `maximumRestarts` times, one at a time and `restartSpacing` apart, then gives the stall to
/// bounded session recovery. A 1 Hz restart loop with no end kept a reconfiguring body from
/// settling and left the operator on Reconnecting for good (owner, 2026-10-19). The Kotlin twin is
/// `LunaFeedStall` in `:insta360-luna`.
public struct LunaFeedStall: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case requestKeyframe
        case restartLive
        /// Video did not return after the bounded restarts: hand off to session recovery.
        case escalate
    }

    public static let keyframeAfter: TimeInterval = 2
    public static let restartAfter: TimeInterval = 6
    public static let restartSpacing: TimeInterval = 8
    public static let maximumRestarts = 2
    /// The hard ceiling, also when a restart is still waiting on the camera.
    public static let escalateAfter: TimeInterval = 30

    public private(set) var restarts = 0
    public private(set) var restartInFlight = false
    private var lastRestartAt: TimeInterval?
    private var escalated = false

    public init() {}

    /// One watchdog tick. `silence` is the time since the last video unit; `now` is monotonic.
    public mutating func tick(silence: TimeInterval, now: TimeInterval) -> Action {
        guard silence > Self.keyframeAfter else {
            self = Self()
            return .none
        }
        guard !escalated else { return .none }
        let spaced = lastRestartAt.map { now - $0 >= Self.restartSpacing } ?? true
        if silence > Self.escalateAfter
            || (restarts >= Self.maximumRestarts && spaced && !restartInFlight)
        {
            escalated = true
            return .escalate
        }
        guard silence > Self.restartAfter else { return .requestKeyframe }
        guard !restartInFlight, restarts < Self.maximumRestarts, spaced else { return .none }
        restarts += 1
        restartInFlight = true
        lastRestartAt = now
        return .restartLive
    }

    /// The restart's commands returned (answered or failed); the next one may follow when spaced.
    public mutating func restartFinished() {
        restartInFlight = false
    }
}
