#if os(iOS)
import MonitorPresentation
import XCTest

/// S1: the gallery is where the operator left it after playback opens and closes: same clip at the
/// same place, same layout and category, in both orientations and both layouts. A presentation that
/// gives the gallery a new identity (an `if/else` modifier toggled by playback) fails here.
open class GalleryRoundTrip: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testGridGalleryReturnsFromPlaybackWhereItWas() { roundTrip(.grid) }

    func testListGalleryReturnsFromPlaybackWhereItWas() { roundTrip(.list) }

    private func roundTrip(_ layout: MonitorMediaLayout) {
        launch(ReviewLaunch(screen: .media, layout: layout))
        // The review stages the clips before it opens the gallery; a loaded host takes seconds.
        XCTAssertTrue(
            app.scrollViews["monitor.media.gallery"].waitForExistence(timeout: 20), "The gallery is staged")
        let gallery = MediaGalleryProbe(app: app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation, settling: app.scrollViews["monitor.media.gallery"])
            gallery.scrollTwoScreens()
            guard let anchor = gallery.settledAnchor() else {
                return XCTFail("No visible clip to return to")
            }
            let layoutBefore = gallery.selected("layout")
            let categoryBefore = gallery.selected("category")
            XCTAssertEqual(layoutBefore, "monitor.media.layout.\(layout.rawValue)")
            gallery.center(anchor).tap()
            let back = app.buttons["monitor.playback.back"]
            var backBudget = TransitionBudget(seconds: 10)
            XCTAssertTrue(back.waitForExistence(timeout: 10), "The clip must open in playback")
            backBudget.excluding { checkpoint("playback") }
            guard tapWhenReady(back, in: app, deadline: backBudget.deadline) else { return }
            XCTAssertTrue(back.waitForNonExistence(timeout: 10))
            let returned = gallery.settledAnchor()
            XCTAssertEqual(returned?.id, anchor.id, "The gallery must return to the clip it opened")
            XCTAssertEqual(returned?.frame.minY ?? .nan, anchor.frame.minY, accuracy: 1)
            XCTAssertEqual(gallery.selected("layout"), layoutBefore)
            XCTAssertEqual(gallery.selected("category"), categoryBefore)
            checkpoint("after-return")
        }
    }
}
#endif
