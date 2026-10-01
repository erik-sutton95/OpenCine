import Testing

@testable import OpenCineMedia

@Suite struct FramingTests {
    @Test func feedAspectUsesRasterAndFallsBack() {
        #expect(abs(FeedRaster.aspect(width: 1920, height: 1080) - 16.0 / 9.0) < 0.001)
        #expect(abs(FeedRaster.aspect(width: 1080, height: 1920) - 9.0 / 16.0) < 0.001)
        #expect(FeedRaster.aspect(width: 0, height: 1080) == 16.0 / 9.0)
        #expect(FeedRaster.aspect(width: 0, height: 0, fallback: 0.5) == 0.5)
    }

    @Test func verticalRasterIsAScreenFlip() {
        #expect(FeedRaster.isVertical(width: 1080, height: 1920))
        #expect(!FeedRaster.isVertical(width: 1920, height: 1080))
        #expect(!FeedRaster.isVertical(width: 0, height: 1920))
    }

    /// Stored in user settings: renaming a raw value loses the operator's choice.
    @Test func portraitAspectRawValuesArePersisted() {
        #expect(PortraitFeedAspect.fit16x9.rawValue == "fit16x9")
        #expect(PortraitFeedAspect.fill.rawValue == "fill")
    }
}
