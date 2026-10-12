#if os(iOS)
import MonitorPresentation
import XCTest

/// S2: the gallery and the player survive the share and delivery presentations: the selection
/// share leaves the gallery's position, selection and selection mode alone, and the clip share
/// leaves the same clip playing with Loop still on, then Back returns to the same gallery place.
/// Never asserts a delivery destination that depends on credentials.
open class ShareRoundTrip: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testGalleryAndPlayerSurviveShareAndDelivery() {
        launch(ReviewLaunch(screen: .media))
        let gallery = MediaGalleryProbe(app: app)
        gallery.scrollTwoScreens()
        let visible = gallery.visibleClips()
        guard let anchor = gallery.settledAnchor(), visible.count > 1 else {
            return XCTFail("Two visible clips are required")
        }

        // Two clips selected by the shared drag, then the selection share opened and closed.
        gallery.center(visible[0]).press(
            forDuration: 0.4, thenDragTo: gallery.center(visible[1]), withVelocity: .slow,
            thenHoldForDuration: 0)
        let count = app.staticTexts["2 selected"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "Dragging across two clips selects both")
        app.buttons["Share selected"].tap()
        let close = app.buttons["monitor.share.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The selection share must open")
        checkpoint("selection-share")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(
            gallery.settledAnchor()?.id, anchor.id, "The selection share must not move the gallery")
        XCTAssertTrue(count.exists, "The selection share must keep the selection")
        XCTAssertTrue(
            app.buttons["Clear selection"].exists, "The selection share must keep selection mode")
        app.buttons["Clear selection"].tap()

        // The clip share from playback, with Loop on, then back to the gallery.
        guard let opened = gallery.settledAnchor() else {
            return XCTFail("No visible clip to open")
        }
        gallery.center(opened).tap()
        let back = app.buttons["monitor.playback.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The clip must open in playback")
        let title = app.staticTexts["monitor.playback.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let clipTitle = title.label
        let loop = app.buttons["Loop playback"]
        if loop.value as? String != "On" { loop.tap() }
        XCTAssertEqual(loop.value as? String, "On")
        app.buttons["Share clip"].tap()
        let destination = app.buttons["monitor.share.destination.nativeShare"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.isEnabled, "A cached staged clip can be shared")
        destination.tap()
        XCTAssertTrue(app.staticTexts["monitor.share.summary"].waitForExistence(timeout: 5))
        checkpoint("clip-share-summary")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(title.label, clipTitle, "Closing the share must keep the same clip")
        XCTAssertEqual(
            loop.value as? String, "On", "Closing the share must keep the player's state")
        checkpoint("after-share")
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 10))
        XCTAssertEqual(
            gallery.settledAnchor()?.id, opened.id, "Back must return to the same gallery place")
    }
}
#endif
