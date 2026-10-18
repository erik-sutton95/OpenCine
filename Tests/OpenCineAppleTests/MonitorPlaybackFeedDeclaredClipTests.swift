#if canImport(UIKit) && canImport(AVFoundation)
    import AVFoundation
    import OpenCineMedia
    import XCTest

    @testable import OpenCineApple

    /// SIMULATED feed and bus; no player item decodes. A source that states its clip outright
    /// (for example from the recording codec and ISO) must reach every playback publication the
    /// feed opens, because the shared engine stamps zebra, false colour and scope clips from it.
    @MainActor final class MonitorPlaybackFeedDeclaredClipTests: XCTestCase {
        func testSourceDeclaredClipReachesEveryPlaybackSource() {
            var declared = 180
            let feed = MonitorPlaybackFeedSession(
                configuration: .init(), hdrDisplay: { false },
                declaredClip: { transfer in transfer == .nlog ? declared : nil })
            defer { feed.shutdown() }
            let bus = LiveFrameSampleBus()
            var effects = MonitorFrameEffects()
            effects.transfer = .nlog
            feed.setEffects(effects, transfer: .nlog, sampleBus: bus)
            XCTAssertTrue(bus.usesPlaybackSource)
            XCTAssertEqual(bus.exposureCeiling.clipByte(transfer: .nlog), 180)

            feed.beginSourceChange()
            XCTAssertEqual(
                bus.exposureCeiling.clipByte(transfer: .nlog), 180,
                "the next clip's publication carries the same declaration")

            declared = 200
            feed.setEffects(effects, transfer: .nlog, sampleBus: bus)
            XCTAssertEqual(bus.exposureCeiling.clipByte(transfer: .nlog), 200)
        }

        func testUndeclaredSourceKeepsTheMeasuredCeiling() {
            let feed = MonitorPlaybackFeedSession(configuration: .init(), hdrDisplay: { false })
            defer { feed.shutdown() }
            let bus = LiveFrameSampleBus()
            let reference = ScopeExposureCeiling().clipByte(transfer: .nlog)
            var effects = MonitorFrameEffects()
            effects.transfer = .nlog
            feed.setEffects(effects, transfer: .nlog, sampleBus: bus)
            XCTAssertEqual(bus.exposureCeiling.clipByte(transfer: .nlog), reference)
        }
    }
#endif
