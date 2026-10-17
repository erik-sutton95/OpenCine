#if os(iOS)
import XCTest

/// A single saved camera setup on the shared page. Main has no legal links on the cameras
/// pages, so the app passes none (ui-tests-2 lane).
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

    /// Whether the app's shell renames setups (`ShellBrand.renamesSetups`). Main's does not.
    open var renamesSetups: Bool { false }

    /// The setup menu offers Rename setup exactly when the app's shell renames setups (a single
    /// camera Wi-Fi setup has no Forget either).
    func testASetupOffersRenameOnlyWhereTheShellRenamesSetups() {
        app.launch()
        let chip = app.buttons.matching(
            NSPredicate(format: "label == %@", "Connect Travel camera over Camera Wi-Fi")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.press(forDuration: 0.8)
        XCTAssertEqual(app.buttons["Rename setup"].waitForExistence(timeout: 2), renamesSetups)
        capture("single-setup-menu")
    }
}
#endif
