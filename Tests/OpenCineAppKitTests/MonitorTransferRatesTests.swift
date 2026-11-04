import Foundation
import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineMedia
import Testing

// Mirrored by Android `MonitorTransferRatesTest`. Time moves only on the manual clock.

@MainActor @Suite struct MonitorTransferRatesTests {
    /// Until the rate owner's tick has parked on the clock again (it read the new time).
    private func parked(_ clock: ManualHostClock) async -> Bool {
        for _ in 0..<4000 {
            if clock.pendingSleeps == 1 { return true }
            await Task.yield()
        }
        return clock.pendingSleeps == 1
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// `seconds` of a steady download, a 50 ms chunk at a time, letting each tick read.
    private func stream(
        _ rates: MonitorTransferRates<String>, _ key: String, clock: ManualHostClock,
        bytesPerSecond: UInt64, for milliseconds: Int, from total: UInt64 = 0
    ) async -> UInt64 {
        var total = total
        for _ in 0..<(milliseconds / 50) {
            #expect(await parked(clock))
            clock.advance(by: .milliseconds(50))
            total += bytesPerSecond / 20
            rates.record(key, totalBytes: total)
        }
        #expect(await parked(clock))
        return total
    }

    @Test func aRunningDownloadReadsItsSpeedAndThenStalled() async {
        let clock = ManualHostClock()
        let rates = MonitorTransferRates<String>(clock: clock.clock)
        rates.begin("clip")
        #expect(rates.rate("clip") == .measuring)
        #expect(rates.rate("clip")?.label == nil)

        _ = await stream(rates, "clip", clock: clock, bytesPerSecond: 42_000_000, for: 2000)
        #expect(rates.rate("clip")?.label == "42 MB/s")

        // No byte for three seconds: the tick alone turns the reading into Stalled.
        for _ in 0..<6 {
            #expect(await parked(clock))
            clock.advance(by: MonitorTransferRates<String>.tick)
        }
        #expect(await eventually { rates.rate("clip")?.label == "Stalled" })
        // A quiet download keeps no timer running; its next byte wakes the reading again.
        #expect(await eventually { clock.pendingSleeps == 0 })
        rates.record("clip", totalBytes: 100_000_000)
        #expect(await parked(clock))
    }

    @Test func anEndedDownloadHasNoReadingAndStopsTheTick() async {
        let clock = ManualHostClock()
        let rates = MonitorTransferRates<String>(clock: clock.clock)
        rates.begin("a")
        rates.begin("b")
        _ = await stream(rates, "a", clock: clock, bytesPerSecond: 5_000_000, for: 1000)
        rates.end("a")
        #expect(rates.rate("a") == nil)
        #expect(rates.rate("b") != nil)
        rates.retain([])
        #expect(rates.rates.isEmpty)
        for _ in 0..<4000 where clock.pendingSleeps > 0 { await Task.yield() }
        #expect(clock.pendingSleeps == 0)
    }

    @Test func aResumedDownloadDoesNotCountItsOffsetAsSpeed() async {
        let clock = ManualHostClock()
        let rates = MonitorTransferRates<String>(clock: clock.clock)
        rates.begin("clip", bytes: 900_000_000)
        _ = await stream(
            rates, "clip", clock: clock, bytesPerSecond: 3_000_000, for: 1000, from: 900_000_000)
        #expect(rates.rate("clip")?.label == "3.0 MB/s")
    }
}
