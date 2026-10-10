import Foundation
import OpenCineCore

/// Preparation and target pacing declared by a streamed motion adapter.
public struct MotionProgramTiming: Equatable, Sendable {
    public var countdown: Duration
    public var targetInterval: Duration

    public init(countdown: Duration, targetInterval: Duration) {
        self.countdown = countdown
        self.targetInterval = targetInterval
    }
}

/// The pure clock of a streamed program. Path shape stays in `GimbalProgram.pose(at:)`;
/// camera-native timed moves retain their separate `GimbalMoveEngine` execution contract.
public struct GimbalProgramPlayback: Equatable, Sendable {
    public struct State: Equatable, Sendable {
        public var running: Bool
        public var paused: Bool
        public var countdown: Int?
        /// Time within the current pass, increasing in either direction.
        public var elapsed: TimeInterval
        public var reversing: Bool
        public var canPause: Bool { running && countdown == nil }

        public init(running: Bool = false, paused: Bool = false, countdown: Int? = nil,
            elapsed: TimeInterval = 0, reversing: Bool = false) {
            self.running = running; self.paused = paused; self.countdown = countdown
            self.elapsed = elapsed; self.reversing = reversing
        }

        public static let idle = Self()
    }

    public struct Output: Equatable, Sendable {
        public var target: GimbalWaypoint?
        public var finished: Bool

        public init(target: GimbalWaypoint? = nil, finished: Bool = false) {
            self.target = target; self.finished = finished
        }
    }

    public let program: GimbalProgram
    public private(set) var state: State
    private let preparationEnd: MonotonicInstant
    private var last: MonotonicInstant
    private var activeElapsed: TimeInterval = 0
    private var initialTargetPending = true

    /// No target is issued for missing, unreachable or malformed plans. A zoom change
    /// requires the service's zoom axis, just as it does for native programmed moves.
    public init?(program: GimbalProgram, capabilities: MotionCapabilities,
        countdown: Duration, at now: MonotonicInstant) {
        guard countdown >= .zero, program.canRun, program.durationAB.isFinite,
            (GimbalProgram.minDuration...GimbalProgram.maxDuration).contains(program.durationAB),
            program.c == nil || (program.durationBC.isFinite &&
                (GimbalProgram.minDuration...GimbalProgram.maxDuration).contains(program.durationBC)),
            program.smoothness.isFinite, (0...1).contains(program.smoothness),
            capabilities.admits(program) else { return nil }
        self.program = program
        preparationEnd = now + countdown
        last = now
        state = State(running: true, countdown: countdown > .zero ? Self.remaining(countdown) : nil)
    }

    /// Uses absolute monotonic instants. Late ticks cross any number of complete loop passes;
    /// a finite take emits its exact last point once. A backwards clock never consumes budget.
    public mutating func step(at now: MonotonicInstant) -> Output {
        guard state.running else { return Output() }
        let now = max(now, last)
        let initial = initialTargetPending
        initialTargetPending = false
        guard now >= preparationEnd else {
            last = now
            state.countdown = Self.remaining(preparationEnd - now)
            return Output(target: initial ? program.a : nil)
        }
        advance(to: now)
        state.countdown = nil
        guard !state.paused else { return Output() }
        updatePosition()
        if !program.loop, activeElapsed >= program.duration {
            state.running = false
            return Output(target: program.pose(at: program.duration), finished: true)
        }
        return Output(target: initial ? program.a : program.pose(
            at: state.reversing ? program.duration - state.elapsed : state.elapsed))
    }

    /// Pause consumes time up to the operator's tap; later wall time contributes nothing.
    /// It sends no GET pose or replacement target, so a settling head does not step backwards.
    @discardableResult
    public mutating func pause(at now: MonotonicInstant) -> Bool {
        guard state.canPause, !state.paused else { return false }
        let now = max(now, last)
        let next = activeElapsed + Self.seconds(now - max(last, preparationEnd))
        guard program.loop || next < program.duration else { return false }
        advance(to: now)
        updatePosition()
        state.paused = true
        return true
    }

    @discardableResult
    public mutating func resume(at now: MonotonicInstant) -> Bool {
        guard state.running, state.paused else { return false }
        last = max(now, last)
        state.paused = false
        return true
    }

    public mutating func cancel() {
        state = .idle
        initialTargetPending = false
    }

    /// Preparation ends on its exact deadline even when the target cadence does not divide it.
    public func nextDelay(upTo interval: Duration) -> Duration {
        state.countdown != nil && last < preparationEnd ? min(interval, preparationEnd - last) : interval
    }

    private mutating func advance(to now: MonotonicInstant) {
        if !state.paused { activeElapsed += Self.seconds(now - max(last, preparationEnd)) }
        last = now
    }

    private mutating func updatePosition() {
        if program.loop {
            let position = activeElapsed.truncatingRemainder(dividingBy: 2 * program.duration)
            state.reversing = position >= program.duration
            state.elapsed = state.reversing ? position - program.duration : position
        } else {
            state.elapsed = min(activeElapsed, program.duration)
            state.reversing = false
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func remaining(_ duration: Duration) -> Int {
        Int(ceil(seconds(duration)))
    }
}
