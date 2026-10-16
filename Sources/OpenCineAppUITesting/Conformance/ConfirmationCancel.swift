#if os(iOS)
import MonitorPresentation
import XCTest

/// S3: every destructive confirmation can be cancelled however this device presents it, and
/// cancelling changes nothing: the clip stays listed, the player stays on it and still offers
/// Delete. Camera deletion runs where the profile declares `clipDelete`; Clear cache everywhere.
open class ConfirmationCancel: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testCancellingPlaybackDeleteKeepsTheClip() throws {
        try requireClipDelete()
        launch(ReviewLaunch(screen: .playback, source: .camera, connected: true))
        let delete = app.buttons["Delete clip from camera"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: 15), "Connected camera playback offers Delete")
        let title = app.staticTexts["monitor.playback.title"]
        let clipTitle = title.label
        delete.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks for confirmation")
        checkpoint("playback-delete-confirmation")
        dismissConfirmation(confirm)
        XCTAssertEqual(title.label, clipTitle, "Cancelling keeps the player on the same clip")
        XCTAssertTrue(delete.isHittable, "Delete is still offered while connected")
        checkpoint("playback-delete-cancelled")
    }

    func testCancellingGalleryDeleteKeepsTheSelection() throws {
        try requireClipDelete()
        launch(ReviewLaunch(screen: .media, source: .camera, connected: true))
        let gallery = MediaGalleryProbe(app: app)
        XCTAssertTrue(app.scrollViews["monitor.media.gallery"].waitForExistence(timeout: 15))
        guard gallery.settledAnchor() != nil else {
            return XCTFail("The staged camera clips must show")
        }
        guard let pair = gallery.sweepPair() else {
            return XCTFail("Two neighbouring clips wholly in view are required")
        }
        gallery.center(pair.0).press(
            forDuration: 0.4, thenDragTo: gallery.center(pair.1), withVelocity: .slow,
            thenHoldForDuration: 0)
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 5))
        // The clips listed once selected (a sweep near an edge may scroll the gallery): cancelling keeps them.
        let listed = gallery.visibleClips().map(\.id)
        let deleteSelected = app.buttons["Delete selected"]
        XCTAssertTrue(deleteSelected.isEnabled, "Connected camera clips can be deleted")
        deleteSelected.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks for confirmation")
        checkpoint("gallery-delete-confirmation")
        dismissConfirmation(confirm)
        XCTAssertTrue(app.staticTexts["2 selected"].exists, "Cancelling keeps the selection")
        XCTAssertEqual(
            gallery.visibleClips().map(\.id), listed,
            "Cancelling keeps every clip listed")
    }

    func testCancellingClearCacheKeepsStorageSettings() {
        launch(ReviewLaunch(screen: .settings, settingsTab: .storage))
        let clear = app.buttons["Clear"]
        let settings = app.scrollViews.containing(NSPredicate(format: "label == 'Clear'"))
            .firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Storage settings show Clear cache")
        for _ in 0..<6 where !clear.isHittable { settings.swipeUp() }
        clear.tap()
        let title = app.staticTexts["Clear cache?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Clear cache asks for confirmation")
        checkpoint("clear-cache-confirmation")
        dismissConfirmation(title)
        XCTAssertTrue(
            app.buttons["monitor.settings.tab.Storage"].isSelected, "Cancelling stays on Storage")
        XCTAssertTrue(clear.isHittable)
    }

    private func requireClipDelete() throws {
        guard try profile().capabilities.clipDelete else {
            throw XCTSkip("The camera cannot delete clips")
        }
    }
}
#endif
