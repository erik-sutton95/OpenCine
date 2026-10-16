import MonitorPresentation
import Testing

struct MonitorLaunchLayoutTests {
    @Test func launchGeometryPreservesLandscapePortraitCompactAndSquareLayouts() {
        let wide = MonitorLaunchLayout(width: 874, height: 402)
        #expect(wide.landscape && wide.logoSize == 96 && wide.wordmarkSize == 34)
        #expect(wide.spacing == 874 * 0.06 && wide.horizontalInset == 874 * 0.08)
        let portrait = MonitorLaunchLayout(width: 402, height: 874)
        #expect(!portrait.landscape && portrait.logoSize == 96 && portrait.wordmarkSize == 30)
        #expect(portrait.spacing == 24 && portrait.horizontalInset == 0)
        let compact = MonitorLaunchLayout(width: 300, height: 300, compact: true)
        #expect(compact.landscape && compact.logoSize == 48 && compact.wordmarkSize == 28)
        #expect(compact.spacing == 32 && compact.horizontalInset == 32)
        let compactPortrait = MonitorLaunchLayout(width: 402, height: 874, compact: true)
        #expect(compactPortrait.logoSize == 72 && compactPortrait.wordmarkSize == 30)
    }
    @Test func launchTimingMatchesBothNativeShells() {
        #expect(MonitorLaunchTiming.visibleDuration == .milliseconds(2_250))
        #expect(MonitorLaunchTiming.fadeOutDuration == 0.35)
    }
}
