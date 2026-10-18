#if os(iOS)
import MonitorPresentation
import XCTest

/// S4: the chrome editor's Done returns to Display settings with the edited section in view, and
/// closing Settings returns to a working monitor that kept the edit.
open class ChromeEditReturn: SharedAppUITestCase {
    override open func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override open func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testDoneReturnsToDisplaySettingsAndCloseToTheMonitor() {
        launch(ReviewLaunch(screen: .live))
        XCTAssertTrue(app.buttons["monitor.system.record"].waitForExistence(timeout: 15))
        guard tapWhenReady(app.buttons["monitor.system.settings"], in: app) else { return }
        let display = app.buttons["monitor.settings.tab.Display"]
        reveal(display, in: app.scrollViews["monitor.settings.tabs"])
        guard tapWhenReady(display, in: app, timeout: 5) else { return }
        let edit = editButton()
        XCTAssertTrue(
            edit.exists || edit.waitForExistence(timeout: 5),
            "Display settings offer Edit view")
        let editID = edit.identifier
        reveal(
            edit,
            in: app.scrollViews.containing(NSPredicate(format: "identifier == %@", editID))
                .firstMatch)
        guard tapWhenReady(edit, in: app, timeout: 5) else { return }

        let done = app.buttons["monitor.chromeEdit.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Edit view opens the chrome editor")
        // The editor makes the monitor inert (no touch reaches it); only its badges and Done work.
        checkpoint("editing", operable: "monitor.chromeEdit.")
        // Rail eyes would hide the very controls the return is checked with.
        let eyes = app.buttons.matching(
            NSPredicate(
                format: """
                    identifier BEGINSWITH 'monitor.chromeEdit.' AND identifier != 'monitor.chromeEdit.done' \
                    AND NOT (identifier CONTAINS[c] 'rail')
                    """))
        guard let eye = eyes.allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("The editor shows an eye for each element")
        }
        let eyeID = eye.identifier
        let before = eye.value as? String
        guard tapWhenReady(eye, in: app, timeout: 5) else { return }
        let after = app.buttons[eyeID].value as? String
        XCTAssertNotEqual(after, before, "The eye toggles its element")
        guard tapWhenReady(done, in: app, timeout: 5) else { return }

        XCTAssertTrue(display.waitForExistence(timeout: 5), "Done returns to Settings")
        XCTAssertTrue(display.isSelected, "Done returns to the Display tab")
        XCTAssertTrue(
            app.buttons[editID].waitForExistence(timeout: 5), "The edited section is in view")
        checkpoint("after-done")
        guard tapWhenReady(app.buttons["monitor.page.back"], in: app, timeout: 10) else {
            return
        }

        let record = app.buttons["monitor.system.record"]
        XCTAssertTrue(
            waitUntilReady(record, in: app, timeout: 10), "Closing Settings returns to the monitor")
        XCTAssertTrue(app.buttons["monitor.system.settings"].isHittable)
        checkpoint("monitor")
        guard tapWhenReady(app.buttons["monitor.system.settings"], in: app) else { return }
        reveal(display, in: app.scrollViews["monitor.settings.tabs"])
        guard tapWhenReady(display, in: app, timeout: 5) else { return }
        let reopenedEdit = editButton(editID)
        reveal(
            reopenedEdit,
            in: app.scrollViews.containing(NSPredicate(format: "identifier == %@", editID))
                .firstMatch)
        guard tapWhenReady(reopenedEdit, in: app, timeout: 5) else { return }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[eyeID].value as? String, after, "The edit persists")
        // The edit outlives the app: undo it, or every later suite on this device inherits it.
        guard tapWhenReady(app.buttons[eyeID], in: app, timeout: 5) else { return }
        XCTAssertEqual(app.buttons[eyeID].value as? String, before)
        guard tapWhenReady(done, in: app, timeout: 5) else { return }
    }

    /// A Display section's Edit view (`id`, else the first). Apps that fold each mode's section
    /// show it once the section is opened, the way an operator reaches it.
    private func editButton(_ id: String? = nil) -> XCUIElement {
        let prefix = "monitor.settings.display.edit."
        let edit = id.map { app.buttons[$0] } ?? firstButton(prefix: prefix)
        if !edit.exists && !edit.waitForExistence(timeout: 2) {
            let sections = app.descendants(matching: .any)
            let section =
                id.map {
                    sections["monitor.settings.display.section." + $0.dropFirst(prefix.count)]
                }
                ?? sections.matching(
                    NSPredicate(format: "identifier BEGINSWITH 'monitor.settings.display.section.'")
                ).firstMatch
            // A folded card is its header alone.
            if section.exists {
                guard tapWhenReady(section.buttons.firstMatch, in: app, timeout: 2) else {
                    return edit
                }
            }
        }
        return edit
    }

    private func firstButton(prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<6 where !element.isHittable && scroll.exists {
            if scroll.frame.width > scroll.frame.height {
                element.frame.minX < scroll.frame.minX ? scroll.swipeRight() : scroll.swipeLeft()
            } else {
                element.frame.minY < scroll.frame.minY ? scroll.swipeDown() : scroll.swipeUp()
            }
        }
    }
}
#endif
