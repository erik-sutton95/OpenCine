#if os(iOS)
import MonitorPresentation
import XCTest

/// The screenshot matrix (A7 increment 5; Kotlin twin `ScreenMatrix`): each key screen in light and
/// dark, portrait and landscape, with the checkpoint geometry invariants and one screenshot per cell
/// (`<app>-<device>-<orientation>-ScreenMatrix-<screen>-<appearance>`). The device cell (phone or
/// tablet) is the destination the run picks; the adaptive layout sweeps (V1 iOS, V2 Android) read it.
open class ScreenMatrix: SharedAppUITestCase {
    private var appearance: XCUIDevice.Appearance = .light

    override open func setUp() {
        // Every cell is captured even when an earlier one breaks an invariant.
        continueAfterFailure = true
        appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.appearance = appearance
        XCUIDevice.shared.orientation = .portrait
    }

    func testCameras() { matrix("cameras", ReviewLaunch(screen: .cameras)) { $0.buttons.firstMatch } }

    func testPairing() { matrix("pairing", ReviewLaunch(screen: .pair)) { $0.buttons.firstMatch } }

    func testLive() { matrix("live", ReviewLaunch(screen: .live)) { $0.buttons["monitor.system.record"] } }

    func testGallery() {
        matrix("gallery", ReviewLaunch(screen: .media)) {
            $0.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'monitor.media.clip.'")).firstMatch
        }
    }

    func testPlayer() { matrix("player", ReviewLaunch(screen: .playback)) { $0.buttons["monitor.playback.back"] } }

    func testSettings() {
        matrix("settings", ReviewLaunch(screen: .settings, settingsTab: .display)) {
            $0.buttons["monitor.settings.tab.Display"]
        }
    }

    private func matrix(_ screen: String, _ review: ReviewLaunch, shown: (XCUIApplication) -> XCUIElement) {
        for (name, appearance) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = appearance
            launch(review)
            let anchor = shown(app)
            guard anchor.waitForExistence(timeout: 20) else {
                XCTFail("\(screen) is not staged")
                app.terminate()
                continue
            }
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                rotate(orientation, settling: anchor)
                checkpoint("\(screen)-\(name)", safeArea: true)
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }
}
#endif
