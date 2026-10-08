import Foundation
import OpenCineCore
import OpenCineMotion
import Testing

/// Kotlin AppKit MotionProgramSessionTest mirrors these scenarios over its real coroutine owner.
@Suite @MainActor struct MotionProgramSessionTests {
    private let timing = MotionProgramTiming(countdown: .seconds(3), targetInterval: .milliseconds(33))
    private func program(_ offset: Double = 0, loop: Bool = false) -> GimbalProgram {
        .init(a: .init(yawDeg: offset, pitchDeg: 0, zoom: 1),
            b: .init(yawDeg: offset + 20, pitchDeg: 0, zoom: 1), durationAB: 2, loop: loop)
    }
    private func owner(_ clock: ProgramClock) -> MotionProgramSession {
        MotionProgramSession(now: { clock.instant }, sleep: { await clock.sleep($0) })
    }
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @Test func countdownCancelHasNoFutureTargetOrStopCommand() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { true }), timing: timing))
        #expect(await settle { motion.moves.count == 1 && clock.pending == 1 })
        #expect(move.state.progress.countdown == 3 && move.state.operation != nil)
        move.cancel(); clock.advance(.seconds(100))
        #expect(await settle { clock.pending == 0 })
        #expect(motion.moves.count == 1 && motion.stops == 0)
        #expect(move.state == .init())
    }

    @Test func disconnectDuringMoveRetiresItsBudget() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion(); let source = ProgramAvailability()
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { source.current }), timing: timing))
        #expect(await settle { motion.moves.count == 1 && clock.pending == 1 })
        clock.advance(.seconds(3))
        #expect(await settle { move.state.progress.canPause && motion.moves.count == 2 && clock.pending == 1 })
        source.current = false
        let count = motion.moves.count; clock.advance(.milliseconds(33))
        #expect(await settle { !move.state.progress.running })
        #expect(motion.moves.count == count && motion.stops == 0 && move.state.operation == nil)
    }

    @Test func backgroundForegroundDoesNotRestartRetiredTake() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion(); let source = ProgramAvailability()
        let binding = MotionProgramSession.Source(motion: motion, isCurrent: { source.current })
        #expect(move.start(program(), source: binding, timing: timing))
        #expect(await settle { motion.moves.count == 1 && clock.pending == 1 })
        source.current = false; clock.advance(.milliseconds(33))
        #expect(await settle { move.state.operation == nil })
        source.current = true; clock.advance(.seconds(100))
        #expect(!move.state.progress.running && motion.moves.count == 1 && motion.stops == 0)
        #expect(move.start(program(), source: binding, timing: timing))
        #expect(await settle { motion.moves.count == 2 && clock.pending == 1 })
        move.cancel(); clock.advance(.seconds(100))
    }

    @Test func pauseResumeBudgetExcludesPausedWallTime() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { true }), timing: timing))
        #expect(await settle { motion.moves.count == 1 && clock.pending == 1 })
        #expect(!move.pause())
        clock.advance(.seconds(3)); #expect(await settle { motion.moves.count == 2 && clock.pending == 1 })
        clock.advance(.milliseconds(500)); #expect(await settle { motion.moves.count == 3 && clock.pending == 1 })
        #expect(move.pause()); #expect(abs(move.state.progress.elapsed - 0.5) < 1e-9)
        let count = motion.moves.count; clock.advance(.seconds(100))
        #expect(await settle { clock.pending == 1 })
        #expect(motion.moves.count == count && move.state.progress.paused)
        #expect(move.resume()); clock.advance(.milliseconds(250))
        #expect(await settle { motion.moves.count == count + 1 && clock.pending == 1 })
        #expect(abs(move.state.progress.elapsed - 0.75) < 1e-9)
        clock.advance(.milliseconds(1300)); #expect(await settle { move.state.operation == nil })
        #expect(motion.moves.last?.yawDeg == 20 && !move.state.progress.running)
        #expect(motion.moves.filter { $0.yawDeg == 20 }.count == 1)
    }

    @Test func loopEndAndLateTickKeepTheDeclaredDirection() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        #expect(move.start(program(loop: true), source: .init(motion: motion, isCurrent: { true }), timing: timing))
        #expect(await settle { motion.moves.count == 1 && clock.pending == 1 })
        clock.advance(.seconds(5)); #expect(await settle { motion.moves.count == 2 && clock.pending == 1 })
        #expect(motion.moves.last?.yawDeg == 20 && move.state.progress.reversing)
        clock.advance(.seconds(2)); #expect(await settle { motion.moves.count == 3 && clock.pending == 1 })
        #expect(motion.moves.last?.yawDeg == 0 && !move.state.progress.reversing)
        clock.advance(.seconds(5)); #expect(await settle { motion.moves.count == 4 && clock.pending == 1 })
        #expect(motion.moves.last?.yawDeg == 10 && !move.state.progress.reversing)
        move.cancel(); clock.advance(.seconds(100))
    }

    @Test func replacementRejectsOldReplyAndQueuedTarget() async {
        let clock = ProgramClock(); let move = owner(clock); let old = ProgramMotion(); let next = ProgramMotion()
        old.delaysReplies = true
        let source = ProgramAvailability()
        #expect(move.start(program(loop: true), source: .init(motion: old, isCurrent: { source.current }), timing: timing))
        #expect(await settle { old.pending == 1 && clock.pending == 1 })
        let first = move.state.operation
        source.current = false
        #expect(move.start(program(40), source: .init(motion: next, isCurrent: { true }), timing: timing))
        #expect(await settle { next.moves.count == 1 && clock.pending == 2 })
        let successor = move.state.operation
        #expect(first != successor)
        old.reply(false)
        #expect(await settle { old.returned == 1 })
        clock.advance(.seconds(3))
        #expect(await settle { next.moves.count == 2 && clock.pending == 1 })
        #expect(move.state.operation == successor && move.state.failure == nil)
        #expect(old.moves.count == 1 && next.moves.allSatisfy { $0.yawDeg >= 40 })
        move.cancel(); clock.advance(.seconds(100))
    }

    @Test func repeatedStartCannotCompleteTheSuccessor() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        motion.delaysReplies = true
        let source = MotionProgramSession.Source(motion: motion, isCurrent: { true })
        #expect(move.start(program(), source: source, timing: timing))
        #expect(await settle { motion.pending == 1 && clock.pending == 1 })
        let first = move.state.operation
        #expect(move.start(program(40), source: source, timing: timing))
        #expect(await settle { motion.pending == 2 && clock.pending == 2 })
        let successor = move.state.operation
        motion.reply(false)
        #expect(await settle { motion.returned == 1 })
        #expect(first != successor && move.state.operation == successor && move.state.failure == nil)
        move.cancel(); motion.reply(true); clock.advance(.seconds(100))
    }

    @Test func sameSourceReentryIgnoresOldReply() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion(); let source = ProgramAvailability()
        motion.delaysReplies = true
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { source.epoch == 1 }), timing: timing))
        #expect(await settle { motion.pending == 1 && clock.pending == 1 })
        source.epoch = 2
        #expect(move.start(program(40), source: .init(motion: motion, isCurrent: { source.epoch == 2 }), timing: timing))
        #expect(await settle { motion.pending == 2 && clock.pending == 2 })
        let successor = move.state.operation
        motion.reply(false); #expect(await settle { motion.returned == 1 })
        #expect(move.state.operation == successor && move.state.failure == nil)
        move.cancel(); motion.reply(true); clock.advance(.seconds(100))
    }

    @Test func reentrantPresentationCanReplaceBeforeFirstDispatch() async {
        let clock = ProgramClock(); let move = owner(clock); let old = ProgramMotion(); let next = ProgramMotion()
        var replaced = false
        move.onChange = { state in
            if !replaced, state.operation != nil {
                replaced = true
                _ = move.start(program(40), source: .init(motion: next, isCurrent: { true }), timing: timing)
            }
        }
        #expect(move.start(program(), source: .init(motion: old, isCurrent: { true }), timing: timing))
        #expect(await settle { next.moves.count == 1 && clock.pending == 1 })
        #expect(old.moves.isEmpty && next.moves[0].yawDeg == 40)
        move.cancel(); clock.advance(.seconds(100))
    }

    @Test func targetRepliesDoNotThrottleTheDeclaredCadence() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        motion.delaysReplies = true
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { true }), timing: timing))
        #expect(await settle { motion.pending == 1 && clock.pending == 1 })
        clock.advance(.seconds(3)); #expect(await settle { motion.pending == 2 && clock.pending == 1 })
        for count in 3...7 {
            clock.advance(.milliseconds(33))
            #expect(await settle { motion.pending == count && clock.pending == 1 })
        }
        #expect(abs(move.state.progress.elapsed - 0.165) < 1e-9)
        move.cancel(); while motion.pending > 0 { motion.reply(true) }; clock.advance(.seconds(100))
    }

    @Test func rejectedTargetIsVisibleAndStopsFutureDispatch() async {
        let clock = ProgramClock(); let move = owner(clock); let motion = ProgramMotion()
        motion.accepts = false
        #expect(move.start(program(), source: .init(motion: motion, isCurrent: { true }), timing: timing))
        #expect(await settle { move.state.failure == .commandRejected })
        clock.advance(.seconds(100)); #expect(await settle { clock.pending == 0 })
        #expect(motion.moves.count == 1 && !move.state.progress.running && move.state.operation == nil)
    }
    @Test func sourcePredicateReplacementDuringPulseReturningFalse() async {
        await predicateReplacementDuringPulse(returning: false)
    }
    @Test func sourcePredicateReplacementDuringPulseReturningTrue() async {
        await predicateReplacementDuringPulse(returning: true)
    }
    @Test func sourcePredicateReplacementDuringReplyReturningFalse() async {
        await predicateReplacementDuringReply(returning: false)
    }
    @Test func sourcePredicateReplacementDuringReplyReturningTrue() async {
        await predicateReplacementDuringReply(returning: true)
    }

    private func predicateReplacementDuringPulse(returning allowed: Bool) async {
        let clock = ProgramClock(); let move = owner(clock); let old = ProgramMotion(); let next = ProgramMotion()
        var replaceOnCheck = false
        var successor: OperationID?
        var successorStarted = false
        var publications: [OperationID?] = []
        move.onChange = { publications.append($0.operation) }
        let source = MotionProgramSession.Source(motion: old, isCurrent: {
            guard replaceOnCheck else { return true }
            replaceOnCheck = false
            successorStarted = move.start(program(40), source: .init(motion: next, isCurrent: { true }), timing: timing)
            successor = move.state.operation
            return allowed
        })
        #expect(move.start(program(loop: true), source: source, timing: timing))
        #expect(await settle { old.moves.count == 1 && clock.pending == 1 })
        let previous = move.state.operation
        publications.removeAll(); replaceOnCheck = true
        clock.advance(.milliseconds(33))
        #expect(await settle { !replaceOnCheck })
        #expect(await settle { next.moves.count == 1 || !move.state.progress.running })
        #expect(successorStarted && successor != nil && successor != previous)
        #expect(move.state.operation == successor && move.state.progress.running && move.state.failure == nil)
        #expect(publications.allSatisfy { $0 == successor })
        #expect(old.moves.count == 1 && old.stops == 0 && next.moves.first?.yawDeg == 40)
        clock.advance(.seconds(3))
        #expect(await settle { next.moves.count == 2 || !move.state.progress.running })
        #expect(next.moves.count == 2 && move.state.operation == successor)
        move.cancel(); clock.advance(.seconds(100))
    }

    private func predicateReplacementDuringReply(returning allowed: Bool) async {
        let clock = ProgramClock(); let move = owner(clock); let old = ProgramMotion(); let next = ProgramMotion()
        old.delaysReplies = true
        var replaceOnCheck = false
        var successor: OperationID?
        var successorStarted = false
        var publications: [OperationID?] = []
        move.onChange = { publications.append($0.operation) }
        let source = MotionProgramSession.Source(motion: old, isCurrent: {
            guard replaceOnCheck else { return true }
            replaceOnCheck = false
            successorStarted = move.start(program(40), source: .init(motion: next, isCurrent: { true }), timing: timing)
            successor = move.state.operation
            return allowed
        })
        #expect(move.start(program(loop: true), source: source, timing: timing))
        #expect(await settle { old.pending == 1 && clock.pending == 1 })
        let previous = move.state.operation
        publications.removeAll(); replaceOnCheck = true
        old.reply(false)
        #expect(await settle { old.returned == 1 && !replaceOnCheck })
        #expect(await settle { next.moves.count == 1 || !move.state.progress.running })
        #expect(successorStarted && successor != nil && successor != previous)
        #expect(move.state.operation == successor && move.state.progress.running && move.state.failure == nil)
        #expect(publications.allSatisfy { $0 == successor })
        #expect(old.moves.count == 1 && old.stops == 0 && next.moves.first?.yawDeg == 40)
        clock.advance(.seconds(3))
        #expect(await settle { next.moves.count == 2 || !move.state.progress.running })
        #expect(next.moves.count == 2 && move.state.operation == successor)
        move.cancel(); clock.advance(.seconds(100))
    }
}

@MainActor private final class ProgramAvailability { var current = true; var epoch = 1 }

@MainActor private final class ProgramClock {
    private(set) var instant = MonotonicInstant.zero
    private var sleepers: [(MonotonicInstant, CheckedContinuation<Void, Never>)] = []
    var pending: Int { sleepers.count }
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleepers.append((instant + duration, $0)) }
    }
    func advance(_ duration: Duration) {
        instant = instant + duration
        let due = sleepers.filter { $0.0 <= instant }
        sleepers.removeAll { $0.0 <= instant }
        for sleeper in due { sleeper.1.resume() }
    }
}

@MainActor private final class ProgramMotion: MotionService {
    nonisolated let capabilities = MotionCapabilities.testGimbal
    var moves: [GimbalWaypoint] = []
    var stops = 0
    var accepts = true
    var delaysReplies = false
    var returned = 0
    private var replies: [CheckedContinuation<Bool, Never>] = []
    var pending: Int { replies.count }
    func move(to target: MotionTarget, over duration: Duration?) async -> Bool {
        #expect(duration == nil)
        moves.append(target.pose)
        if delaysReplies {
            let result = await withCheckedContinuation { replies.append($0) }
            returned += 1
            return result
        }
        return accepts
    }
    func reply(_ accepted: Bool) { replies.removeFirst().resume(returning: accepted) }
    func stick(pan: Double, tilt: Double) async -> Bool { true }
    func recenter() async -> Bool { true }
    func stop() async -> Bool { stops += 1; return true }
    func poses() async -> AsyncStream<ObservedValue<GimbalWaypoint>> {
        AsyncStream { $0.yield(.unknown); $0.finish() }
    }
}
