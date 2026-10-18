import Foundation
import OpenCineCore

/// Owns a streamed take, its pacing and pending replies. A source captures one connection and
/// control epoch; its predicate retires that connection rather than looking up a successor.
/// Cancelling a take retires its targets and never sends a camera stop or recenter command.
@MainActor
public final class MotionProgramSession {
    public struct Source {
        public let motion: any MotionService
        public let isCurrent: @MainActor () -> Bool

        public init(motion: any MotionService, isCurrent: @escaping @MainActor () -> Bool) {
            self.motion = motion; self.isCurrent = isCurrent
        }
    }

    public enum Failure: Equatable, Sendable {
        case invalidProgram
        case commandRejected
    }

    public struct State: Equatable, Sendable {
        public var progress: GimbalProgramPlayback.State
        public var operation: OperationID?
        public var failure: Failure?

        public init(progress: GimbalProgramPlayback.State = .idle, operation: OperationID? = nil,
            failure: Failure? = nil) {
            self.progress = progress; self.operation = operation; self.failure = failure
        }
    }

    public private(set) var state = State()
    public var onChange: (@MainActor (State) -> Void)?

    private final class Run {
        let operation = OperationID()
        let source: Source
        let timing: MotionProgramTiming
        var playback: GimbalProgramPlayback
        var scheduler: Task<Void, Never>?
        var commands: [UUID: Task<Void, Never>] = [:]
        var commandRevision: UInt64 = 0
        var finalCommandPending = false

        init(source: Source, timing: MotionProgramTiming, playback: GimbalProgramPlayback) {
            self.source = source; self.timing = timing; self.playback = playback
        }
    }

    private var active: Run?
    private var lifecycleRevision: UInt64 = 0
    private let now: @MainActor () -> MonotonicInstant
    private let sleep: @MainActor (Duration) async throws -> Void

    public init(now: @escaping @MainActor () -> MonotonicInstant = MonotonicInstant.now,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)) {
        self.now = now; self.sleep = sleep
    }

    /// An explicit new start replaces the old take. Its late timers and replies cannot publish
    /// progress or command the new source, even when the same camera reconnects.
    @discardableResult
    public func start(_ program: GimbalProgram, source: Source, timing: MotionProgramTiming) -> Bool {
        let revision = lifecycleRevision
        guard source.isCurrent(), lifecycleRevision == revision else { return false }
        let playback = timing.targetInterval > .zero
            ? GimbalProgramPlayback(program: program, capabilities: source.motion.capabilities,
                countdown: timing.countdown, at: now()) : nil
        guard lifecycleRevision == revision else { return false }
        guard let playback else {
            if active == nil { publish(State(failure: .invalidProgram)) }
            return false
        }
        retireTasks()
        let run = Run(source: source, timing: timing, playback: playback)
        active = run
        publish(State(progress: playback.state, operation: run.operation))
        guard active === run else { return true }
        let sleep = sleep
        run.scheduler = Task { @MainActor [weak self, weak run] in
            while !Task.isCancelled {
                guard let self, let run, let interval = self.pulse(run) else { return }
                do { try await sleep(interval) } catch {
                    if self.active === run { self.cancel() }
                    return
                }
            }
        }
        return true
    }

    @discardableResult
    public func pause() -> Bool {
        guard let run = currentRun(), !run.finalCommandPending else { return false }
        let instant = now()
        guard active === run, run.playback.pause(at: instant) else { return false }
        retireCommands(run)
        publish(State(progress: run.playback.state, operation: run.operation))
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        guard let run = currentRun() else { return false }
        let instant = now()
        guard active === run, run.playback.resume(at: instant) else { return false }
        publish(State(progress: run.playback.state, operation: run.operation))
        return true
    }

    public func cancel() {
        retireTasks()
        publish(State())
    }

    private func currentRun() -> Run? {
        guard let run = active else { return nil }
        return admits(run) ? run : nil
    }

    /// A source callback may synchronously replace the take. Its answer applies only to this run.
    private func admits(_ run: Run) -> Bool {
        guard active === run else { return false }
        let current = run.source.isCurrent()
        guard active === run else { return false }
        guard current else { cancel(); return false }
        return true
    }

    private func pulse(_ run: Run) -> Duration? {
        guard admits(run) else { return nil }
        let instant = now()
        guard active === run else { return nil }
        let output = run.playback.step(at: instant)
        run.finalCommandPending = output.finished
        publish(State(progress: run.playback.state, operation: run.operation))
        // A presentation callback may itself start, pause or cancel a take.
        guard admits(run) else { return nil }
        guard !run.playback.state.paused else { return run.playback.nextDelay(upTo: run.timing.targetInterval) }
        if let pose = output.target {
            let target = run.source.motion.capabilities.target(pose)
            guard active === run else { return nil }
            guard let target else {
                finish(run, failure: .invalidProgram)
                return nil
            }
            dispatch(target, final: output.finished, run: run)
        }
        return output.finished ? nil : run.playback.nextDelay(upTo: run.timing.targetInterval)
    }

    private func dispatch(_ target: MotionTarget, final: Bool, run: Run) {
        let command = UUID()
        let revision = run.commandRevision
        // Replies can take seconds; awaiting them here would replace the declared target cadence.
        run.commands[command] = Task { @MainActor [weak self, weak run] in
            guard let self, let run, self.active === run, !Task.isCancelled,
                run.commandRevision == revision, !run.playback.state.paused, self.admits(run),
                !Task.isCancelled, run.commandRevision == revision, !run.playback.state.paused else { return }
            let accepted = await run.source.motion.move(to: target, over: nil)
            guard !Task.isCancelled, self.active === run, run.commandRevision == revision else { return }
            run.commands.removeValue(forKey: command)
            guard self.admits(run), !Task.isCancelled, run.commandRevision == revision else { return }
            if !accepted { self.finish(run, failure: .commandRejected) }
            else if final { self.finish(run, failure: nil) }
        }
    }

    private func finish(_ run: Run, failure: Failure?) {
        guard active === run else { return }
        let progress = failure == nil ? run.playback.state : .idle
        retireTasks()
        publish(State(progress: progress, failure: failure))
    }

    private func retireCommands(_ run: Run) {
        run.commandRevision &+= 1
        let commands = Array(run.commands.values)
        run.commands.removeAll()
        for command in commands { command.cancel() }
    }

    private func retireTasks() {
        lifecycleRevision &+= 1
        guard let run = active else { return }
        active = nil
        run.scheduler?.cancel(); run.scheduler = nil
        retireCommands(run)
        run.playback.cancel()
    }

    private func publish(_ next: State) {
        guard state != next else { return }
        state = next
        onChange?(next)
    }
}
