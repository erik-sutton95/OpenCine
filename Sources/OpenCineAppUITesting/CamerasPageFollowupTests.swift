#if os(iOS)
import XCTest

/// A single saved camera setup on the shared page. Every app's cameras page is the same
/// composition: a setup never offers Rename setup and the pages carry no legal links (A2-62;
/// the options were per-app flags on `ShellBrand` and `ShellActions`).
open class CamerasPageFollowupTests: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["OPV_UI_REVIEW_SCREEN"] = "cameras"
    }

    override open func tearDown() {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    /// The setup menu offers Forget-style entries only; Rename setup is gone in every app,
    /// and the cameras page renders no legal links.
    func testASetupNeverOffersRenameAndThePageHasNoLegalLinks() {
        app.launch()
        let chip = app.buttons.matching(
            NSPredicate(format: "label == %@", "Connect Travel camera over Camera Wi-Fi")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.press(forDuration: 0.8)
        XCTAssertFalse(app.buttons["Rename setup"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["legal.privacy"].exists)
        XCTAssertFalse(app.buttons["legal.terms"].exists)
        capture("single-setup-menu")
    }
}
#endif
