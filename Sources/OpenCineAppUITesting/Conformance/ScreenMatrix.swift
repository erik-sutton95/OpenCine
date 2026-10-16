#if os(iOS)
import MonitorPresentation
import XCTest

/// The screenshot matrix (A7 increment 5; Kotlin twin `ScreenMatrix`): each key screen in both
/// orientations with the checkpoint geometry invariants plus page content inside the page safe
/// area, and one screenshot per cell
/// (`<app>-<device>-<orientation>-ScreenMatrix-<screen>-<appearance>`). The device cell (phone
/// or tablet) is the destination the run picks, and the appearance is the simulator's (a test
/// cannot switch it; the matrix runner runs once light and once dark).
open class ScreenMatrix: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testCameras() { matrix("cameras", ReviewLaunch(screen: .cameras)) { $0.buttons.firstMatch } }

    func testPairing() { matrix("pairing", ReviewLaunch(screen: .pair)) { $0.buttons.firstMatch } }

    func testLive() {
        matrix("live", ReviewLaunch(screen: .live)) { $0.buttons["monitor.system.record"] }
    }

    func testGallery() {
        matrix("gallery", ReviewLaunch(screen: .media)) {
            $0.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "monitor.media.clip.")
            ).firstMatch
        }
    }

    func testPlayer() {
        matrix("player", ReviewLaunch(screen: .playback)) { $0.buttons["monitor.playback.back"] }
    }

    func testSettings() {
        matrix("settings", ReviewLaunch(screen: .settings, settingsTab: .display)) {
            $0.buttons["monitor.settings.tab.Display"]
        }
    }

    /// The shared pages' own content, which lays out inside the page safe area.
    static let pageContent = ["monitor.media.", "monitor.settings."]

    private func matrix(
        _ screen: String, _ review: ReviewLaunch, shown: (XCUIApplication) -> XCUIElement
    ) {
        let appearance =
            UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
        launch(review)
        XCTAssertTrue(shown(app).waitForExistence(timeout: 20), "\(screen) staged")
        // Every cell is captured even when an earlier one breaks an invariant.
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation, settling: shown(app))
            checkpoint("\(screen)-\(appearance)", safeContent: Self.pageContent)
        }
    }
}
#endif
