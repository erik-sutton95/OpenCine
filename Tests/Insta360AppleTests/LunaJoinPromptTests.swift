import Foundation
import OpenCineCore
import Testing
@testable import Insta360Apple

/// Device cell 7c (DEF-Z3FIX-7C-SECOND-PROMPT): the operator answers the system Join alert
/// after the attempt timeout. iOS withholds the apply completion while that alert is up.
@MainActor @Suite struct LunaJoinPromptTests {
    static let fast = LunaJoinAttempts.Timing(
        attempt: .milliseconds(200), pause: .milliseconds(10), tick: .milliseconds(10))

    @MainActor final class Probe {
        var joins = 0
        var onNetwork = false
        var leaves = 0
        var lines: [String] = []
    }

    /// The native request ignores cancellation, as the shared hotspot owner does for Luna
    /// (`awaitNativeCompletion`): only iOS answering releases it.
    static func answerLate(after delay: Duration) async {
        let until = ContinuousClock.now.advanced(by: delay)
        while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(5)) }
    }

    static func run(_ probe: Probe, budget: Duration = .seconds(5),
        join: @escaping @MainActor (Bool, LunaJoinPrompt) async throws -> Void) async throws {
        try await LunaJoinAttempts.run(
            budget: budget, timing: fast,
            onCameraNetwork: { probe.onNetwork },
            validate: {},
            log: { probe.lines.append($0) },
            leave: { probe.leaves += 1 },
            join: { once, prompt in
                probe.joins += 1
                try await join(once, prompt)
            })
    }

    /// A Join answered after the attempt timeout joins on that answer: no give-up, no leave,
    /// no second system request (which iOS shows as a second Join alert).
    @Test func lateJoinAnswerHoldsTheAttempt() async throws {
        let probe = Probe()
        try await Self.run(probe) { _, prompt in
            if probe.joins > 1 { probe.onNetwork = true; return }
            prompt.begin()
            await Self.answerLate(after: .milliseconds(600))
            prompt.end()
            // The address wait after the answer, cancellable like the real one.
            try await Task.sleep(for: .milliseconds(30))
            probe.onNetwork = true
        }
        #expect(probe.joins == 1)
        #expect(probe.leaves == 0)
        #expect(probe.lines.isEmpty)
        #expect(probe.onNetwork)
    }

    /// The prompt pauses the attempt clock; it does not switch it off. A join that hangs
    /// after iOS answered still times out.
    @Test func timeAfterTheAnswerStillCounts() async throws {
        let probe = Probe()
        let started = ContinuousClock.now
        await #expect(throws: LunaJoinAttempts.timeoutFailure) {
            try await Self.run(probe, budget: .zero) { _, prompt in
                prompt.begin()
                await Self.answerLate(after: .milliseconds(400))
                prompt.end()
                try await Task.sleep(for: .seconds(30))
            }
        }
        #expect(probe.joins == 1)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Without a pending system request the attempt keeps its timeout and the retry loop.
    @Test func aJoinWithoutPromptTimesOutAndRetries() async throws {
        let probe = Probe()
        try await Self.run(probe) { _, _ in
            if probe.joins > 1 { probe.onNetwork = true; return }
            try await Task.sleep(for: .seconds(30))
        }
        #expect(probe.joins == 2)
        #expect(probe.leaves == 1)
        #expect(probe.lines.count == 1)
        #expect(probe.lines.first?.contains("did not come up") == true)
    }

    /// Answering Cancel (iOS reports userDenied) fails the attempt as before.
    @Test func cancelledPromptFailsTheAttempt() async throws {
        let probe = Probe()
        let refused = ConnectionFailure.luna(.joinFailed, "wifi.join-refused", "refused", phase: .joiningNetwork)
        await #expect(throws: refused) {
            try await Self.run(probe, budget: .zero) { _, prompt in
                prompt.begin()
                defer { prompt.end() }
                await Self.answerLate(after: .milliseconds(300))
                throw refused
            }
        }
        #expect(probe.joins == 1)
    }
}
