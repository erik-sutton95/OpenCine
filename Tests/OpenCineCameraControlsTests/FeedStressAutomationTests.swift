import OpenCineCameraVocabulary
import Testing

@testable import OpenCineCameraControls

/// The shared debug feed-stress seam: fault plan parsing, the reconnect record and the settings
/// baseline the teardown restores. The runtime itself is iOS DEBUG only and has no clock seam.
@Suite struct FeedStressAutomationTests {
    @Test func emptyPlanIsNotConfigured() {
        #expect(FeedStressPlan.parse("") == FeedStressPlan())
        #expect(!FeedStressPlan.parse("").configured)
    }

    @Test func planParsesEveryFault() {
        let plan = FeedStressPlan.parse("loss:0.05,burst:6:120,outputSilenceMs:900")
        #expect(plan.configured)
        #expect(plan.lossProbability == 0.05)
        #expect(plan.burstDropCount == 6)
        #expect(plan.burstEveryN == 120)
        #expect(plan.outputSilenceMs == 900)
    }

    @Test func planClampsToTheSafeEnvelope() {
        let plan = FeedStressPlan.parse("loss:0.9,burst:99:9999,outputSilenceMs:60000")
        #expect(plan.lossProbability == 0.5)
        #expect(plan.burstDropCount == 24)
        #expect(plan.burstEveryN == 400)
        #expect(plan.outputSilenceMs == 4_000)
        let negative = FeedStressPlan.parse("loss:-1,burst:-3:-4,outputSilenceMs:-5")
        #expect(negative.lossProbability == 0)
        #expect(negative.burstDropCount == 0)
        #expect(negative.burstEveryN == 0)
        #expect(negative.outputSilenceMs == 0)
    }

    @Test func unknownOrMalformedFaultsAreIgnoredButStillConfigure() {
        let plan = FeedStressPlan.parse("jitter:5,loss:abc")
        #expect(plan.configured)
        #expect(plan.lossProbability == 0)
        #expect(plan.burstDropCount == 0)
    }

    @Test func reconnectRecordTokens() {
        #expect(FeedStressReconnect.observed(isLive: true) == .live)
        #expect(FeedStressReconnect.observed(isLive: false) == .none)
        #expect(FeedStressReconnect.live.rawValue == "live")
        #expect(FeedStressReconnect.none.rawValue == "none")
        #expect(FeedStressReconnect.ambiguous.rawValue == "ambiguous")
        #expect(FeedStressReconnect.requested.rawValue == "requested")
    }

    @Test func baselineFillsOnlyMissingFields() {
        var baseline = FeedStressBaseline(captured: true, isoIndex: .iso100)
        var status = CameraStatus()
        status.isoIndex = .iso200
        status.isoLimit = .max1600
        status.whiteBalance = .custom(kelvin: 5_600, tint: 3)
        baseline.fill(from: status)
        #expect(baseline.isoIndex == .iso100)
        #expect(baseline.isoLimit == .max1600)
        #expect(baseline.whiteBalance == .custom(kelvin: 5_600, tint: 3))
    }

    @Test func baselineReadinessNeedsTheLimitOnlyWhenAutoIsOffered() {
        var baseline = FeedStressBaseline(captured: true)
        #expect(!baseline.isReady(needsLimit: false))
        baseline.isoIndex = .iso100
        baseline.whiteBalance = .auto
        #expect(baseline.isReady(needsLimit: false))
        #expect(!baseline.isReady(needsLimit: true))
        baseline.isoLimit = .max1600
        #expect(baseline.isReady(needsLimit: true))
    }
}
