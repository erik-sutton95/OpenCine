import Testing

@testable import OpenCineNikon

@Suite("Still shutter: one press")
struct StillShutterHoldTests {
    @Test func aQuickTapInContinuousDriveKeepsItsOneFrame() {
        var hold = StillShutterHold(continuousDrive: true)
        #expect(hold.nextRelease == .singleFrame)
        // Finger-up before the first release completed: nothing to cancel or terminate.
        let up = hold.fingerUp()
        #expect(up == .letReleaseFinish)
        let chains = hold.releaseCompleted()
        #expect(!chains)
        #expect(hold.burstRuns == 0)
    }

    @Test func aHoldInContinuousDriveChainsBurstRunsThatFingerUpEnds() {
        var hold = StillShutterHold(continuousDrive: true)
        let first = hold.releaseCompleted()
        #expect(first)
        #expect(hold.nextRelease == .burstRun)
        let second = hold.releaseCompleted()
        #expect(second)
        let up = hold.fingerUp()
        #expect(up == .endBurst)
        let more = hold.releaseCompleted()
        #expect(!more)
        #expect(hold.burstRuns == 2)
    }

    @Test func singleDriveNeverChainsOrEnds() {
        var hold = StillShutterHold(continuousDrive: false)
        let chains = hold.releaseCompleted()
        #expect(!chains)
        #expect(hold.nextRelease == .singleFrame)
        let up = hold.fingerUp()
        #expect(up == .letReleaseFinish)
    }

    @Test func aSwallowedFingerUpStopsAtTheCap() {
        var hold = StillShutterHold(continuousDrive: true)
        var runs = 0
        while hold.releaseCompleted() { runs += 1 }
        #expect(runs == StillShutterHold.maximumBurstRuns)
        let up = hold.fingerUp()
        #expect(up == .endBurst)
    }

    @Test func aSecondFingerUpDoesNothing() {
        var hold = StillShutterHold(continuousDrive: true)
        _ = hold.releaseCompleted()
        let first = hold.fingerUp()
        let second = hold.fingerUp()
        #expect(first == .endBurst)
        #expect(second == .letReleaseFinish)
    }
}
