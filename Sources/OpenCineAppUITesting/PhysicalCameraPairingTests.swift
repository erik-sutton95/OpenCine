#if os(iOS)
import XCTest

/// The first-pair wizard on real hardware (Z3 items 1, 2, 3 and 5): which system prompts each path
/// raises, and when. Every case starts on the camera list or the wizard of a freshly installed app
/// (the runner deletes the app first, which resets its privacy answers) and records every system
/// alert it meets. Only the Z app subclasses this class: its wizard is the one these cases drive.
///
/// The system accessory picker of item 4 is not reached here: no production caller asks for it
/// (every camera access point join goes through the hotspot join, whose Cancel item 8 covers).
///
/// Inputs (test runner environment), besides `OPV_PHYSICAL_NETWORK_PROBE=1`: the camera access
/// point case reads `OPV_PHYSICAL_AP_SSID` and `OPV_PHYSICAL_AP_KEY` (copied from the camera's
/// screen); `OPV_PHYSICAL_PAIR_SECONDS` bounds a pairing that waits on the camera (default 240).
open class PhysicalCameraPairingTests: PhysicalNetworkUITestCase {

    // MARK: Z3 item 1: Wi-Fi router pairing, permission order

    /// Fresh install, Wireless > Wi-Fi: nothing asks before the path is chosen, Local Network is
    /// asked exactly once (from the permissions step), the phone camera never, and the pairing
    /// reaches the live monitor with a camera in "connect to smart device" mode on the same Wi-Fi.
    @MainActor
    public func testWiFiPairingAsksLocalNetworkOnceAfterTransportChoice() throws {
        try openWizard()
        if strictPrompts { XCTAssertEqual(alerts, [], "No system prompt before the connection path is chosen") }
        try choose(card: "Wireless", option: "Wi-Fi")
        let asked = try allowLocalNetworkOnPermissionsStep()
        try continueToDiscovery()
        try pairFirstDiscoveredCamera()
        assertAlerts(localNetwork: asked ? 1 : nil, camera: strictPrompts ? 0 : nil)
    }

    // MARK: First-run pairing on the shared pair page

    /// A first install opens on the shared "Find your camera" page: the nearby camera (in "connect
    /// to smart device" mode on the same Wi-Fi) is picked there and paired to live, answering every
    /// system prompt as an operator who wants the camera. This saves the camera, which the wizard
    /// cases need while a fresh install cannot reach the wizard (DEF-Z-FIRSTRUN-WIZARD). Every prompt
    /// is recorded.
    @MainActor
    public func testFirstRunPairsNearbyCameraOnSharedPage() throws {
        launchApp()
        try continueToDiscovery()
        try pairFirstDiscoveredCamera()
        assertAlerts(localNetwork: nil, camera: nil)
    }

    // MARK: Z3 item 2: cable paths ask no Local Network

    /// USB-C: no permissions step, no Local Network alert; the only system prompt is the camera
    /// control request of the USB connection itself. The camera must be cabled to the device.
    @MainActor
    public func testUSBPairingAsksNoLocalNetwork() throws {
        try openWizard()
        try choose(card: "Cable Link", option: "USB-C")
        XCTAssertFalse(railHasStep("Allow permissions"), "A cable path has no permissions step")
        try continueToDiscovery()
        try pairFirstDiscoveredCamera()
        assertAlerts(localNetwork: 0, camera: nil)
        XCTAssertLessThanOrEqual(alerts.count, 1, "USB-C raises only its own control request: \(alerts)")
    }

    /// HDMI capture (iPad): no permissions step, no Local Network alert; the only system prompt is
    /// the capture device's video request. Skipped when no capture device is attached.
    @MainActor
    public func testHDMIMonitoringAsksNoLocalNetwork() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("HDMI capture is an iPad path")
        }
        try openWizard()
        try choose(card: "Cable Link", option: "HDMI")
        XCTAssertFalse(railHasStep("Allow permissions"), "A cable path has no permissions step")
        try continueToDiscovery(until: { self.app.buttons["Start monitoring"].exists })
        let ready = app.staticTexts["Capture device ready"]
        guard ready.waitForExistence(timeout: 20) else {
            screenshot("hdmi-no-capture-device")
            throw XCTSkip("No HDMI capture device attached; the HDMI half is not run")
        }
        app.buttons["Start monitoring"].tap()
        try wait("Live monitor over HDMI", timeout: 60) {
            self.recordAlerts(answer: true)
            return self.app.buttons["monitor.system.settings"].isHittable
        }
        screenshot("hdmi-live")
        assertAlerts(localNetwork: 0, camera: nil)
        XCTAssertLessThanOrEqual(alerts.count, 1, "HDMI raises only its own video request: \(alerts)")
    }

    // MARK: Z3 item 3: camera access point, manual credentials, camera asked only by the scanner

    /// Fresh install, Wireless > Camera AP: no phone-camera prompt through the steps; opening the
    /// credential scanner ("Connect my camera") asks for the camera exactly once. The operator
    /// declines it (the camera stays off) and types the camera's SSID and key instead, which must
    /// still join and reach the live monitor.
    @MainActor
    public func testCameraAccessPointManualPairingWithCameraOff() throws {
        let ssid = try required("OPV_PHYSICAL_AP_SSID")
        let key = try required("OPV_PHYSICAL_AP_KEY")
        try openWizard()
        try choose(card: "Wireless", option: "Camera AP")
        let asked = try allowLocalNetworkOnPermissionsStep()
        try continueToDiscovery(until: { self.app.buttons["Connect my camera"].isHittable })
        assertAlerts(localNetwork: asked ? 1 : nil, camera: strictPrompts ? 0 : nil)
        app.buttons["Connect my camera"].tap()

        var cameraAlert: XCUIElement?
        let end = Date().addingTimeInterval(20)
        while cameraAlert == nil && Date() < end {
            cameraAlert = springboard.alerts.allElementsBoundByIndex.first { Self.isCameraAlert(self.text(of: $0)) }
            if cameraAlert == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        if let cameraAlert {
            alerts.append(text(of: cameraAlert))
            decline(cameraAlert)
            screenshot("scanner-camera-declined")
        } else {
            attach("scanner-camera", "no Camera prompt when the scanner opened (already answered)")
            if strictPrompts { XCTFail("The scanner asks for the camera exactly once") }
        }

        let manual = app.buttons["Enter manually"]
        try wait("Enter manually", timeout: 10) { manual.isHittable }
        manual.tap()
        let ssidField = app.textFields["Camera Wi-Fi SSID"]
        try wait("The SSID field", timeout: 10) { ssidField.isHittable }
        ssidField.tap()
        ssidField.typeText(ssid)
        let keyField = app.secureTextFields["Camera Wi-Fi key"]
        keyField.tap()
        keyField.typeText(key)
        app.buttons["Use These Details"].tap()

        let connect = app.buttons["Connect"]
        try wait("Connect on the join card", timeout: 15) { connect.isHittable }
        connect.tap()
        try waitForLive(timeout: 120)
        assertAlerts(localNetwork: asked ? 1 : nil, camera: strictPrompts ? 1 : nil)
    }

    // MARK: Z3 item 5: Local Network denied, then allowed in Settings, on the same step

    /// Fresh install: Don't Allow on the Local Network prompt turns the row to Settings; its tap
    /// opens the app's Settings page; Local Network on and back: the row reads Allowed and the
    /// wizard is still on the permissions step, with no other navigation.
    @MainActor
    public func testLocalNetworkDeniedThenAllowedOnPermissionsStep() throws {
        try openWizard()
        try choose(card: "Wireless", option: "Wi-Fi")
        let row = localNetworkRow()
        try wait("The permissions step", timeout: 15) { self.stepTitle("Allow permissions") && row.isHittable }
        row.tap()
        try answerLocalNetworkPrompt(allow: false)
        try wait("The row reads Settings after Don't Allow", timeout: 20) { row.label.contains("Settings") }
        screenshot("permissions-denied")

        row.tap()
        try wait("Settings opened on the app's page", timeout: 15) {
            self.settings.state == .runningForeground && self.settings.switches["Local Network"].exists
        }
        let toggle = settings.switches["Local Network"].firstMatch
        try wait("The app's Local Network switch", timeout: 10) {
            if toggle.isHittable { return true }
            self.settings.swipeUp()
            return false
        }
        try flip(toggle, on: true)
        screenshot("settings-local-network-on")

        // Back to the app as the operator does (iOS may have ended the app on the switch flip).
        app.activate()
        let back = localNetworkRow()
        try wait("The row reads Allowed on the same step", timeout: 30) {
            back.exists && back.label.contains("Allowed")
        }
        screenshot("permissions-allowed")
        XCTAssertTrue(stepTitle("Allow permissions"), "The wizard stays on the permissions step")
        attach("row", back.label)
    }

    // MARK: The wizard

    private func openWizard() throws {
        launchApp()
        let pair = app.buttons["cameras.pair"]
        let title = app.staticTexts["Choose how to connect"]
        try wait("The camera list or the wizard", timeout: 20) {
            self.recordAlerts(answer: false)
            return title.exists || pair.isHittable
        }
        // A tap that lands while the just-launched list is still settling can be lost: tap again,
        // at most 3 times, and record each attempt.
        var attempt = 0
        while !title.exists && attempt < 3 {
            attempt += 1
            pair.tap()
            attach("pair-tap", "attempt=\(attempt)")
            _ = title.waitForExistence(timeout: 6)
        }
        try wait("The wizard's first step", timeout: 1) { title.exists }
        screenshot("wizard-choose")
    }

    /// The transport cards are tap surfaces; their option pills are buttons labelled with the
    /// option's title first. Tapping a pill advances.
    private func choose(card: String, option: String) throws {
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", option)).firstMatch
        if !pill.isHittable {
            let surface = app.staticTexts[card].firstMatch
            try wait("The \(card) card", timeout: 10) { surface.isHittable }
            surface.tap()
        }
        try wait("The \(option) option", timeout: 10) { pill.isHittable }
        recordAlerts(answer: false)
        attach("transport", "\(card) > \(option); alerts before the choice: \(alerts)")
        pill.tap()
        try wait("The step after the transport choice", timeout: 15) {
            !self.stepTitle("Choose how to connect")
        }
    }

    private func localNetworkRow() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local Network")).firstMatch
    }

    /// `OPV_PHYSICAL_STRICT_PROMPTS=0` records the prompt counts without asserting them: for runs
    /// on an install that already answered them (a camera saved first, so the wizard is reachable).
    private var strictPrompts: Bool {
        ProcessInfo.processInfo.environment["OPV_PHYSICAL_STRICT_PROMPTS"] != "0"
    }

    /// Allows Local Network from the permissions step; false when the wizard skipped that step (a
    /// camera is already saved), which only a non-strict run accepts.
    @discardableResult
    private func allowLocalNetworkOnPermissionsStep() throws -> Bool {
        let row = localNetworkRow()
        let end = Date().addingTimeInterval(15)
        while !(stepTitle("Allow permissions") && row.isHittable) && Date() < end {
            if !strictPrompts && stepTitle("Prepare your camera") {
                attach("permissions-step", "skipped (a camera is already saved)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        try wait("The permissions step", timeout: 1) { self.stepTitle("Allow permissions") && row.isHittable }
        row.tap()
        try answerLocalNetworkPrompt(allow: true)
        try wait("The row reads Allowed", timeout: 30) { row.label.contains("Allowed") }
        screenshot("permissions-allowed")
        app.buttons["Continue"].tap()
        return true
    }

    private func answerLocalNetworkPrompt(allow: Bool) throws {
        var prompt: XCUIElement?
        try wait("The Local Network prompt", timeout: 20) {
            prompt = self.springboard.alerts.allElementsBoundByIndex.first { Self.isLocalNetworkAlert(self.text(of: $0)) }
            return prompt != nil
        }
        alerts.append(text(of: prompt!))
        if allow { prompt!.buttons["Allow"].tap() } else { decline(prompt!) }
    }

    /// iOS spells the button with a typographic apostrophe; either spelling is accepted.
    private func decline(_ alert: XCUIElement) {
        let curly = alert.buttons["Don\u{2019}t Allow"]
        if curly.exists { curly.tap() } else { alert.buttons["Don't Allow"].tap() }
    }

    /// Continue through the steps that only instruct, until `done` (by default: a discovered camera
    /// or the step's own join button). Every alert met on the way is recorded and allowed.
    private func continueToDiscovery(until done: (() -> Bool)? = nil) throws {
        let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pair.device.")).firstMatch
        let finished = done ?? { found.exists }
        let seconds = Double(ProcessInfo.processInfo.environment["OPV_PHYSICAL_PAIR_SECONDS"] ?? "") ?? 240
        try wait("The pairing step", timeout: seconds) {
            self.recordAlerts(answer: true)
            if finished() { return true }
            // The network step's primary reads "Connect my camera" (on the camera access point path
            // it opens the scanner, so that case stops before it with its own `until`).
            for title in ["Continue", "Connect my camera"] {
                let next = self.app.buttons[title]
                if next.isHittable && next.isEnabled { next.tap(); break }
            }
            return false
        }
        screenshot("discovery")
    }

    /// Selects the first camera found and pairs it, answering the app's own pairing confirmation.
    private func pairFirstDiscoveredCamera() throws {
        let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pair.device.")).firstMatch
        attach("discovered", found.label)
        found.tap()
        let action = ["Pair camera", "Connect camera", "Continue"].lazy.map { self.app.buttons[$0] }
            .first { $0.waitForExistence(timeout: 5) && $0.isEnabled }
        try XCTUnwrap(action, "A pair or connect action for the selected camera").tap()
        try waitForLive(timeout: Double(ProcessInfo.processInfo.environment["OPV_PHYSICAL_PAIR_SECONDS"] ?? "") ?? 240)
    }

    private func waitForLive(timeout: TimeInterval) throws {
        try wait("The live monitor", timeout: timeout) {
            self.recordAlerts(answer: true)
            self.joinIfAsked()
            let confirm = self.app.alerts["Pair with camera?"]
            if confirm.exists { confirm.buttons["Pair"].tap() }
            return self.app.buttons["monitor.system.settings"].isHittable
        }
        screenshot("live")
    }

    private func stepTitle(_ title: String) -> Bool { app.staticTexts[title].exists }

    private func railHasStep(_ title: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Step ' AND label CONTAINS %@", title))
            .count > 0
    }

    private func flip(_ toggle: XCUIElement, on: Bool) throws {
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            if control.exists && control.isHittable { control.tap() }
            else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() }
        }
        try wait("Local Network \(on ? "on" : "off")", timeout: 5) { (toggle.value as? String == "1") == on }
    }

    // MARK: Alert accounting

    static func isLocalNetworkAlert(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("local network")
    }

    static func isCameraAlert(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("access the camera")
    }

    /// Counts the recorded system alerts by kind; `nil` skips a kind.
    private func assertAlerts(localNetwork: Int?, camera: Int?, file: StaticString = #filePath, line: UInt = #line) {
        let ln = alerts.filter(Self.isLocalNetworkAlert).count
        let cam = alerts.filter(Self.isCameraAlert).count
        attach("alert-count", "localNetwork=\(ln) camera=\(cam)\n" + alerts.joined(separator: "\n"))
        if let localNetwork {
            XCTAssertEqual(ln, localNetwork, "Local Network alerts: \(alerts)", file: file, line: line)
        }
        if let camera {
            XCTAssertEqual(cam, camera, "Camera alerts: \(alerts)", file: file, line: line)
        }
    }
}
#endif
