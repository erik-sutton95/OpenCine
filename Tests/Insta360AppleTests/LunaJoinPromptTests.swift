import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing
@testable import Insta360Apple

/// Device cell 7c (DEF-Z3FIX-7C-SECOND-PROMPT): the operator answers the system Join alert
/// after the attempt timeout. iOS withholds the apply completion while that alert is up. The
/// attempts run on a manual clock: time moves only when a test advances it.
@MainActor @Suite struct LunaJoinPromptTests {
    static let fast = LunaJoinAttempts.Timing(
        attempt: .milliseconds(200), pause: .milliseconds(10), tick: .milliseconds(10))
    /// Ticks in one attempt: the attempt times out after this many unprompted ticks.
    static let ticksPerAttempt = 20

    @MainActor final class Probe {
        var joins = 0
        var onNetwork = false
        var leaves = 0
        var lines: [String] = []
        /// Opens once the attempt shows the system Join alert.
        let prompted = Gate()
        /// The operator's answer to the alert.
        let answered = Gate()
        /// Opens once the join has seen the answer.
        let resumed = Gate()
    }

    /// A one-shot signal between the test and the scripted join.
    @MainActor final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let ready = waiters
            waiters = []
            for waiter in ready { waiter.resume() }
        }
    }

    /// A join that never completes on its own (iOS keeps the request): only cancellation (the
    /// attempt timing out, the connect ending) ends it, never the wall clock.
    static func hang() async throws {
        try await Task.sleep(for: .seconds(86_400))
    }

    static func run(_ probe: Probe, clock: ManualHostClock, budget: Duration = .seconds(5),
        join: @escaping @MainActor (Bool, LunaJoinPrompt) async throws -> Void) async throws {
        try await LunaJoinAttempts.run(
            budget: budget, timing: fast, clock: clock.clock,
            onCameraNetwork: { probe.onNetwork },
            validate: {},
            log: { probe.lines.append($0) },
            leave: { probe.leaves += 1 },
            join: { once, prompt in
                probe.joins += 1
                try await join(once, prompt)
            })
    }

    /// Moves `clock` one tick at a time, `ticks` times, each once the attempt's timer has parked.
    static func tick(_ clock: ManualHostClock, _ ticks: Int) async throws {
        for _ in 0..<ticks {
            try await clock.waitForSleeps(1)
            clock.advance(by: fast.tick)
        }
    }

    /// A Join answered after the attempt timeout joins on that answer: no give-up, no leave,
    /// no second system request (which iOS shows as a second Join alert).
    @Test(.timeLimit(.minutes(1)))
    func lateJoinAnswerHoldsTheAttempt() async throws {
        let probe = Probe()
        let clock = ManualHostClock()
        let run = Task { @MainActor in
            try await Self.run(probe, clock: clock) { _, prompt in
                if probe.joins > 1 { probe.onNetwork = true; return }
                prompt.begin()
                probe.prompted.open()
                await probe.answered.wait()
                prompt.end()
                probe.onNetwork = true
            }
        }
        await probe.prompted.wait()
        // Three attempts' worth of time with the alert up.
        try await Self.tick(clock, Self.ticksPerAttempt * 3)
        probe.answered.open()
        try await run.value
        #expect(probe.joins == 1)
        #expect(probe.leaves == 0)
        #expect(probe.lines.isEmpty)
        #expect(probe.onNetwork)
    }

    /// The prompt pauses the attempt clock; it does not switch it off. A join that hangs
    /// after iOS answered still times out, a full attempt after the answer.
    @Test(.timeLimit(.minutes(1)))
    func timeAfterTheAnswerStillCounts() async throws {
        let probe = Probe()
        let clock = ManualHostClock()
        let run = Task { @MainActor in
            try await Self.run(probe, clock: clock, budget: .zero) { _, prompt in
                prompt.begin()
                probe.prompted.open()
                await probe.answered.wait()
                prompt.end()
                probe.resumed.open()
                try await Self.hang()
            }
        }
        await probe.prompted.wait()
        try await Self.tick(clock, 5)
        // The timer has looked at the prompt for the last tick and waits for the next one.
        try await clock.waitForSleeps(1)
        probe.answered.open()
        await probe.resumed.wait()
        try await Self.tick(clock, Self.ticksPerAttempt)
        await #expect(throws: LunaJoinAttempts.timeoutFailure) { try await run.value }
        #expect(probe.joins == 1)
        #expect(clock.elapsed == Self.fast.tick * (5 + Self.ticksPerAttempt))
    }

    /// Without a pending system request the attempt keeps its timeout and the retry loop.
    @Test(.timeLimit(.minutes(1)))
    func aJoinWithoutPromptTimesOutAndRetries() async throws {
        let probe = Probe()
        let clock = ManualHostClock()
        let run = Task { @MainActor in
            try await Self.run(probe, clock: clock) { _, _ in
                if probe.joins > 1 { probe.onNetwork = true; return }
                try await Self.hang()
            }
        }
        try await Self.tick(clock, Self.ticksPerAttempt)
        // The pause before the next attempt.
        try await clock.waitForSleeps(1)
        clock.advance(by: Self.fast.pause)
        try await run.value
        #expect(probe.joins == 2)
        #expect(probe.leaves == 1)
        #expect(probe.lines.count == 1)
        #expect(probe.lines.first?.contains("did not come up") == true)
    }

    /// Answering Cancel (iOS reports userDenied) fails the attempt as before.
    @Test(.timeLimit(.minutes(1)))
    func cancelledPromptFailsTheAttempt() async throws {
        let probe = Probe()
        let clock = ManualHostClock()
        let refused = ConnectionFailure.luna(.joinFailed, "wifi.join-refused", "refused", phase: .joiningNetwork)
        let run = Task { @MainActor in
            try await Self.run(probe, clock: clock, budget: .zero) { _, prompt in
                prompt.begin()
                defer { prompt.end() }
                probe.prompted.open()
                await probe.answered.wait()
                throw refused
            }
        }
        await probe.prompted.wait()
        try await Self.tick(clock, Self.ticksPerAttempt * 2)
        probe.answered.open()
        await #expect(throws: refused) { try await run.value }
        #expect(probe.joins == 1)
    }
}
