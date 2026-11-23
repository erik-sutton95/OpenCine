import Foundation

/// Luna live video is TCP: no loss, but the encoder can pause (a format or lens change, a busy
/// body) while the control socket stays up. The ladder asks for keyframes, then restarts live at
/// most `maximumRestarts` times, one at a time and `restartSpacing` apart, then gives the stall to
/// bounded session recovery. A 1 Hz restart loop with no end kept a reconfiguring body from
/// settling and left the operator on Reconnecting for good (owner, 2026-10-19).
///
/// While the camera records, the ladder only asks for keyframes until video has been gone
/// `recordingRestartAfter`. With Color Recovery on (I-Log graded into the preview) starting a
/// recording can pause the preview encoder for seconds, and a live restart (stop live, the
/// shooting-view file state, start live) or session recovery during the take ended it: the picture
/// froze and the camera dropped back to monitoring (OPENINSTACINE-IOS-S). A frozen monitor costs
/// the operator a few seconds of picture; a stopped take costs the shot. So the take is left alone
/// until the silence outlasts `escalateAfter`, the longest the normal ladder ever waits before it
/// declares the link lost: no encoder pause seen on a Luna lasts that long, so by then video has
/// truly gone and the ordinary repair runs, shifted by that bound (restarts, then session recovery
/// at `recordingEscalateAfter` at the latest). Once the recording stops the normal ladder resumes.
/// The Kotlin twin is `LunaFeedStall` in `:insta360-luna`.
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
    /// While recording: no live restart and no session recovery before video has been gone this
    /// long, only keyframe requests (see the type's documentation).
    public static let recordingRestartAfter: TimeInterval = escalateAfter
    /// While recording: the hard ceiling, the normal one shifted by `recordingRestartAfter`.
    public static let recordingEscalateAfter: TimeInterval = recordingRestartAfter + escalateAfter

    public private(set) var restarts = 0
    public private(set) var restartInFlight = false
    private var lastRestartAt: TimeInterval?
    private var escalated = false

    public init() {}

    /// One watchdog tick. `silence` is the time since the last video unit; `now` is monotonic;
    /// `recording` is whether the camera is recording (or a record start or stop is in flight).
    public mutating func tick(
        silence: TimeInterval, now: TimeInterval, recording: Bool = false
    ) -> Action {
        guard silence > Self.keyframeAfter else {
            self = Self()
            return .none
        }
        guard !escalated else { return .none }
        if recording, silence <= Self.recordingRestartAfter { return .requestKeyframe }
        let ceiling = recording ? Self.recordingEscalateAfter : Self.escalateAfter
        let restartAt = recording ? Self.recordingRestartAfter : Self.restartAfter
        let spaced = lastRestartAt.map { now - $0 >= Self.restartSpacing } ?? true
        if silence > ceiling
            || (restarts >= Self.maximumRestarts && spaced && !restartInFlight)
        {
            escalated = true
            return .escalate
        }
        guard silence > restartAt else { return .requestKeyframe }
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
