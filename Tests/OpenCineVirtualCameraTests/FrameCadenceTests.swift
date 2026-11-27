import Testing

@testable import OpenCineVirtualCamera

@Test func cadenceKeepsThirtyAndSixtyWithoutRoundingDrift() {
    for rate: UInt64 in [30, 60] {
        var cadence = FrameCadence(framesPerSecond: rate)
        var count = 0
        for tick: UInt64 in 0...1_200 {
            if cadence.isDue(now: tick * 1_000_000) { count += 1 }
        }
        #expect(count == (rate == 30 ? 37 : 73))
        #expect(cadence.skipped == 0)
    }
}

@Test func lateWakeSkipsBacklogInsteadOfBursting() {
    var cadence = FrameCadence(framesPerSecond: 30)
    let first = cadence.isDue(now: 1_000_000_000)
    #expect(first)
    let wake = cadence.isDue(now: 2_000_000_000)
    #expect(wake)
    let burst = cadence.isDue(now: 2_000_000_001)
    #expect(!burst)
    #expect(cadence.skipped == 29)
    cadence.reset(framesPerSecond: 60)
    let reset = cadence.isDue(now: 2_000_000_002)
    #expect(reset)
    let resetBurst = cadence.isDue(now: 2_000_000_003)
    #expect(!resetBurst)
}
