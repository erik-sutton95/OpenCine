import Foundation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@Suite("Host clock")
struct HostClockTests {
    @Test func liveClockReadsTheSharedHostReferenceAndTheWallClock() async throws {
        let before = MonotonicInstant.now()
        let wallBefore = Date()
        let clock = HostClock.live
        let now = clock.now()
        let date = clock.date()
        #expect(now >= before)
        #expect(date >= wallBefore)
        try await clock.sleep(.milliseconds(1))
        #expect(clock.now() > now)
    }

    @Test func manualClockMovesOnlyWhenAdvanced() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let manual = ManualHostClock(origin: MonotonicInstant(.seconds(5)), date: start)
        let clock = manual.clock
        #expect(clock.now() == MonotonicInstant(.seconds(5)))
        #expect(clock.date() == start)
        manual.advance(by: .milliseconds(2_150))
        #expect(clock.now() == MonotonicInstant(.milliseconds(7_150)))
        #expect(clock.date() == start.addingTimeInterval(2.15))
        #expect(manual.elapsed == .milliseconds(2_150))
    }

    @Test func sleepsResumeInDeadlineOrderOnlyOnceReached() async throws {
        let manual = ManualHostClock()
        let clock = manual.clock
        let woke = Woke()
        let long = Task { try await clock.sleep(.seconds(2)); await woke.append("long") }
        let short = Task { try await clock.sleep(.seconds(1)); await woke.append("short") }
        try await parked(manual, count: 2)

        manual.advance(by: .milliseconds(999))
        #expect(manual.pendingSleeps == 2)
        manual.advance(by: .milliseconds(1))
        try await short.value
        #expect(await woke.names == ["short"])
        #expect(manual.pendingSleeps == 1)

        manual.advance(by: .seconds(5))
        try await long.value
        #expect(await woke.names == ["short", "long"])
        #expect(manual.pendingSleeps == 0)
    }

    @Test func aZeroSleepReturnsWithoutAnAdvance() async throws {
        let manual = ManualHostClock()
        try await manual.clock.sleep(.zero)
        #expect(manual.pendingSleeps == 0)
    }

    @Test func cancellingAParkedSleepThrowsAndUnparksIt() async throws {
        let manual = ManualHostClock()
        let clock = manual.clock
        let sleeper = Task { try await clock.sleep(.seconds(60)) }
        try await parked(manual, count: 1)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(manual.pendingSleeps == 0)
    }

    @Test func aCancelledTaskDoesNotPark() async {
        let manual = ManualHostClock()
        let clock = manual.clock
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(.seconds(60))
        }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(manual.pendingSleeps == 0)
    }

    /// Waits until `count` sleeps are parked; the limit only stops a genuine hang.
    private func parked(_ manual: ManualHostClock, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while manual.pendingSleeps < count {
            try #require(ContinuousClock.now < deadline, "sleeps never parked")
            await Task.yield()
        }
    }
}

private actor Woke {
    var names: [String] = []
    func append(_ name: String) { names.append(name) }
}
