import MonitorPresentation
import Testing

/// Kotlin twin: `MonitorInstantReviewLayoutTest` in monitor-ui.
struct MonitorInstantReviewLayoutTests {
    @Test func wideStillPillarboxesNothingAndLetterboxesATallContainer() {
        let frame = MonitorInstantReviewLayout.imageFrame(
            imageWidth: 6000, imageHeight: 4000, containerWidth: 390, containerHeight: 844)
        #expect(frame == MonitorRect(x: 0, y: 292, width: 390, height: 260))
    }

    @Test func tallStillPillarboxesInALandscapeContainer() {
        let frame = MonitorInstantReviewLayout.imageFrame(
            imageWidth: 4000, imageHeight: 6000, containerWidth: 844, containerHeight: 390)
        #expect(frame == MonitorRect(x: 292, y: 0, width: 260, height: 390))
    }

    @Test func degenerateSizesDrawNothing() {
        #expect(
            MonitorInstantReviewLayout.imageFrame(
                imageWidth: 0, imageHeight: 10, containerWidth: 100, containerHeight: 100)
                == MonitorRect())
        #expect(
            MonitorInstantReviewLayout.imageFrame(
                imageWidth: 10, imageHeight: 10, containerWidth: 100, containerHeight: 0)
                == MonitorRect())
    }

    @Test func closeSitsInTheTopTrailingCorner() {
        #expect(
            MonitorInstantReviewLayout.closeFrame(containerWidth: 844)
                == MonitorRect(x: 796, y: 14, width: 34, height: 34))
    }

    @Test func favoriteStacksCentredOverTheSettingsLine() {
        #expect(
            MonitorInstantReviewLayout.favoriteFrame(
                containerWidth: 844, containerHeight: 390, infoHeight: 30)
                == MonitorRect(x: 401, y: 294, width: 42, height: 42))
        // Without the settings line the star drops to the bottom inset.
        #expect(
            MonitorInstantReviewLayout.favoriteFrame(
                containerWidth: 844, containerHeight: 390, infoHeight: nil)
                == MonitorRect(x: 401, y: 334, width: 42, height: 42))
    }

    @Test func chromeMetricsMatchTheKotlinTwin() {
        #expect(MonitorInstantReviewLayout.closeSize == 34)
        #expect(MonitorInstantReviewLayout.closeInset == 14)
        #expect(MonitorInstantReviewLayout.favoriteSize == 42)
        #expect(MonitorInstantReviewLayout.favoriteGlyphSize == 19)
        #expect(MonitorInstantReviewLayout.stackSpacing == 10)
        #expect(MonitorInstantReviewLayout.bottomInset == 14)
        #expect(MonitorInstantReviewLayout.infoFontSize == 13)
        #expect(MonitorInstantReviewLayout.standInBlur == 14)
    }
}
