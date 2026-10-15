#if os(iOS)
import XCTest

/// Opt-in camera-network checks on real hardware (the Z3 physical list): Local Network denial and
/// recovery on a saved camera, cancelling the system Wi-Fi join and retrying, and answering a join
/// late. App test bundles subclass this class in one line. Permissions are changed only through the
/// Settings app, as an operator changes them (hardware has no privacy reset), and every switch the
/// case turns is turned back in its teardown. No camera setting, record or media action is issued.
///
/// Inputs (test runner environment): `OPV_PHYSICAL_NETWORK_PROBE=1` opts in,
/// `OPV_PHYSICAL_CAMERA_NAME` names the saved camera row, `OPV_PHYSICAL_CAMERA_SSID` names the camera's
/// Wi-Fi for the join cases, `OPV_PHYSICAL_DENIAL_MAX_SECONDS` bounds the typed denial (default 60).
open class PhysicalCameraNetworkTests: SharedAppUITestCase {
    private var restoreLocalNetwork: Bool?
    private var alerts: [String] = []
    private var appName: String?

    override open func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_NETWORK_PROBE"] == "1" else {
            throw XCTSkip("Requires the opted-in physical camera-network run")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Camera-network checks need a physical device")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        #endif
    }

    override open func tearDownWithError() throws {
        if let original = restoreLocalNetwork {
            restoreLocalNetwork = nil
            if app.state != .notRunning { app.terminate() }
            try setLocalNetwork(original)
        }
        attach("system-alerts", alerts.joined(separator: "\n"))
        try super.tearDownWithError()
    }

    // MARK: Z3 item 6 and 7a: denied, then allowed

    /// Local Network off: connecting the saved camera ends in a typed Local Network failure within the
    /// deadline (no stall, no live picture). Local Network on again: the same saved row reaches the
    /// live monitor without asking for the camera Wi-Fi password again.
    @MainActor
    public func testLocalNetworkDeniedThenAllowedOnSavedCamera() throws {
        let camera = try required("OPV_PHYSICAL_CAMERA_NAME")
        let deadline = Double(ProcessInfo.processInfo.environment["OPV_PHYSICAL_DENIAL_MAX_SECONDS"] ?? "") ?? 60
        launchApp()
        let original = try localNetworkSetting()
        restoreLocalNetwork = original
        try setLocalNetwork(false)

        launchApp()
        let started = Date()
        try tapSavedRow(camera)
        var denial: String?
        try wait("A typed Local Network failure", timeout: deadline) {
            self.recordAlerts(answer: false)
            self.joinIfAsked()
            if self.app.buttons["monitor.system.settings"].isHittable {
                XCTFail("The camera went live while Local Network was off")
                return true
            }
            denial = self.app.staticTexts.allElementsBoundByIndex.map(\.label)
                .first { $0.localizedCaseInsensitiveContains("local network") }
            return denial != nil
        }
        let seconds = Date().timeIntervalSince(started)
        attach("denial", "seconds=\(String(format: "%.1f", seconds))\nmessage=\(denial ?? "")")
        screenshot("local-network-denied")
        XCTAssertFalse(app.buttons["monitor.system.settings"].exists, "No live monitor while denied")

        try setLocalNetwork(true)
        launchApp()
        try tapSavedRow(camera)
        var askedForPassword = false
        try wait("Live monitor after Local Network is allowed", timeout: 90) {
            self.recordAlerts(answer: true)
            self.joinIfAsked()
            if self.app.secureTextFields.firstMatch.exists { askedForPassword = true }
            return self.app.buttons["monitor.system.settings"].isHittable
        }
        screenshot("local-network-allowed-live")
        XCTAssertFalse(askedForPassword, "The saved camera Wi-Fi password must be kept")
        attach("allowed", "live=true askedForPassword=\(askedForPassword)")
    }

    // MARK: Z3 item 8: cancel the system join, retry at once

    /// With the camera's Wi-Fi forgotten, the saved connect asks iOS to join; Cancel on that alert,
    /// then the same row again at once. The retry must not report a false success or failure for the
    /// cancelled join, and must reach live once iOS answers its own join.
    @MainActor
    public func testCancelSystemJoinThenRetry() throws {
        let camera = try required("OPV_PHYSICAL_CAMERA_NAME")
        let ssid = try required("OPV_PHYSICAL_CAMERA_SSID")
        try forgetWiFi(ssid)
        launchApp()
        try disconnectIfLive()
        try tapSavedRow(camera)
        var cancelled = false
        do {
            try wait("The system Join alert", timeout: 60) {
                if self.app.buttons["monitor.system.settings"].isHittable { return true }
                if let alert = self.joinAlert() {
                self.alerts.append("join: " + self.text(of: alert))
                    alert.buttons["Cancel"].tap()
                    cancelled = true
                }
                return cancelled
            }
        }
        try requireJoinPrompt(cancelled)
        screenshot("join-cancelled")
        // Retry at once: the saved row again if the app is idle, otherwise the app's own join retry.
        // Either way iOS gets at most one more join prompt, and no error may be shown for the retry.
        var joins = 0
        var retried = false
        var errors: [String] = []
        try wait("Live monitor after the retried join", timeout: 120) {
            if let alert = self.joinAlert() {
                joins += 1
                self.alerts.append("retry join: " + self.text(of: alert))
                alert.buttons["Join"].tap()
            }
            self.recordAlerts(answer: true)
            if !retried {
                for title in ["Reconnect " + camera, "Connect " + camera] {
                    let row = self.app.buttons[title].firstMatch
                    if row.exists && row.isHittable { row.tap(); retried = true; break }
                }
            }
            // One snapshot of the tree (element-by-element reads race the changing connection UI).
            for line in self.app.debugDescription.split(separator: "\n")
            where line.contains("StaticText") && (line.contains("Couldn") || line.contains("failed")) {
                let text = String(line)
                if !errors.contains(text) { errors.append(text) }
            }
            return self.app.buttons["monitor.system.settings"].isHittable
        }
        screenshot("join-retried-live")
        attach("retry", "joins=\(joins) rowRetried=\(retried) errors=\(errors)")
        XCTAssertLessThanOrEqual(joins, 1, "One system join prompt for the retry")
        XCTAssertTrue(errors.isEmpty, "No error for the retried join: \(errors)")
    }

    // MARK: Z3 item 7c: answer the join late

    /// The first join's system alert answered after 35 seconds still connects, and no second join
    /// prompt appears.
    @MainActor
    public func testJoinAnsweredLateConnectsWithoutSecondPrompt() throws {
        let camera = try required("OPV_PHYSICAL_CAMERA_NAME")
        let ssid = try required("OPV_PHYSICAL_CAMERA_SSID")
        try forgetWiFi(ssid)
        launchApp()
        try disconnectIfLive()
        try tapSavedRow(camera)
        var shownAt: Date?
        try wait("The system Join alert", timeout: 60) {
            if self.joinAlert() != nil { shownAt = Date() }
            return shownAt != nil || self.app.buttons["monitor.system.settings"].isHittable
        }
        try requireJoinPrompt(shownAt != nil)
        // Leave the alert up past the 35 s join group, as an operator who looks away does.
        while Date().timeIntervalSince(shownAt!) < 36 { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        guard let first = joinAlert() else { return XCTFail("The first join alert disappeared on its own") }
        alerts.append("late join: " + text(of: first))
        first.buttons["Join"].tap()
        var second = 0
        try wait("Live monitor after the late join", timeout: 90) {
            if let again = self.joinAlert() {
                second += 1
                self.alerts.append("second join: " + self.text(of: again))
                again.buttons["Join"].tap()
            }
            self.recordAlerts(answer: true)
            return self.app.buttons["monitor.system.settings"].isHittable
        }
        screenshot("late-join-live")
        XCTAssertEqual(second, 0, "No second join prompt after a late answer")
    }

    // MARK: The app

    private func launchApp() {
        if app.state != .notRunning { app.terminate() }
        app.launchEnvironment["OPV_PHYSICAL_UI_REVIEW"] = "1"
        app.launch()
        if appName == nil, !app.label.isEmpty { appName = app.label }
    }

    /// The join cases need iOS to ask: a live session is disconnected through Operator Setup first,
    /// which makes the app leave the camera Wi-Fi and drop its hotspot configuration.
    private func disconnectIfLive() throws {
        let settingsButton = app.buttons["monitor.system.settings"]
        guard settingsButton.waitForExistence(timeout: 8), settingsButton.isHittable else { return }
        settingsButton.tap()
        let disconnect = app.buttons["monitor.system.disconnect"]
        try wait("Disconnect in Operator Setup", timeout: 10) { disconnect.isHittable }
        disconnect.tap()
        try wait("Camera list after disconnect", timeout: 20) { !self.app.buttons["monitor.system.settings"].exists }
        attach("precondition", "disconnected a live session before the join case")
    }

    /// No join prompt means iOS still had this app's configuration for the camera Wi-Fi: the case
    /// cannot exercise the join, so it is recorded as not run rather than passed.
    private func requireJoinPrompt(_ shown: Bool) throws {
        if !shown && app.buttons["monitor.system.settings"].isHittable {
            screenshot("no-join-prompt")
            throw XCTSkip("iOS joined without asking (configuration still installed); join case not exercised")
        }
    }

    private func tapSavedRow(_ camera: String, settle: TimeInterval = 0) throws {
        if settle > 0 { RunLoop.current.run(until: Date().addingTimeInterval(settle)) }
        var row: XCUIElement?
        try wait("Saved row for \(camera)", timeout: 30) {
            self.recordAlerts(answer: true)
            row = ["Reconnect " + camera, "Connect " + camera].lazy
                .map { self.app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
            return row != nil
        }
        // A tap that lands while the screen is still settling (just launched, or just handed back by
        // Settings) can be lost: the row must leave its idle state, else it is tapped again (at most 3).
        let label = row!.label
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for attempt in 1...3 {
            let current = app.buttons[label].firstMatch
            guard current.exists, current.isHittable else { return }
            let frame = current.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            attach("connect-tap", "\(label) attempt=\(attempt)")
            let started = Date()
            while Date().timeIntervalSince(started) < 5 {
                let again = app.buttons[label].firstMatch
                if !again.exists || !again.isHittable || app.buttons["Cancel"].exists
                    || app.buttons["monitor.system.settings"].exists || springboard.alerts.count > 0 { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
    }

    // MARK: Settings (the operator's only way to change a permission on hardware)

    private lazy var settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    /// The app's own page in Settings, found through Settings search by the app's display name (the
    /// same on iPhone and in the iPad sidebar, where Apps sits far below the first screen).
    private func openAppSettings() throws {
        let name = try appName ?? required("OPV_PHYSICAL_APP_NAME")
        settings.terminate()
        settings.activate()
        let search = settings.searchFields.firstMatch
        try wait("Settings search", timeout: 10) {
            if search.isHittable { return true }
            self.settings.swipeDown()
            return false
        }
        search.tap()
        search.typeText(name)
        let result = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                name, XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue,
                XCUIElement.ElementType.staticText.rawValue))
            .firstMatch
        try wait("Settings search result \(name)", timeout: 10) { result.isHittable }
        result.tap()
        attach("settings-page", name)
    }

    private func localNetworkSwitch() throws -> XCUIElement {
        try openAppSettings()
        let toggle = settings.switches["Local Network"].firstMatch
        try wait("The app's Local Network switch", timeout: 10) {
            if toggle.isHittable { return true }
            self.settings.swipeUp()
            return false
        }
        return toggle
    }

    private func localNetworkSetting() throws -> Bool {
        let on = try localNetworkSwitch().value as? String == "1"
        attach("local-network-original", on ? "on" : "off")
        return on
    }

    private func setLocalNetwork(_ on: Bool) throws {
        let toggle = try localNetworkSwitch()
        if (toggle.value as? String == "1") != on {
            // The labelled row spans the width; its control is the inner switch at the trailing edge.
            let control = toggle.switches.firstMatch
            if control.exists && control.isHittable { control.tap() }
            else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() }
        }
        try wait("Local Network \(on ? "on" : "off")", timeout: 5) { (toggle.value as? String == "1") == on }
        screenshot("settings-local-network-" + (on ? "on" : "off"))
    }

    /// Settings > Wi-Fi > the network's info button > Forget This Network. A network that is not
    /// listed is already unknown to the device.
    private func forgetWiFi(_ ssid: String) throws {
        settings.terminate()
        settings.activate()
        let wifi = settings.cells.staticTexts["Wi-Fi"].firstMatch
        try wait("Settings > Wi-Fi", timeout: 10) { wifi.isHittable }
        wifi.tap()
        let edit = settings.navigationBars.buttons["Edit"].firstMatch
        if edit.waitForExistence(timeout: 3) {
            // Known networks: Wi-Fi > Edit lists every remembered network with a delete control.
            edit.tap()
            let entry = settings.cells.containing(.staticText, identifier: ssid).firstMatch
            if entry.waitForExistence(timeout: 5) {
                entry.buttons.firstMatch.tap()
                let delete = settings.buttons["Delete"].firstMatch
                if delete.waitForExistence(timeout: 3) { delete.tap() }
                let confirm = settings.alerts.buttons["Remove"].firstMatch
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
                attach("wifi-forgotten", ssid)
            } else {
                attach("wifi-forgotten", ssid + " was not remembered")
            }
            let done = settings.navigationBars.buttons["Done"].firstMatch
            if done.exists { done.tap() }
        }
        screenshot("settings-wifi-forget")
    }

    // MARK: System alerts

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// The operator joins the camera Wi-Fi when iOS asks (the denial and recovery cases own no join).
    private func joinIfAsked() {
        guard let alert = joinAlert() else { return }
        alerts.append("join: " + text(of: alert))
        alert.buttons["Join"].tap()
    }

    private func joinAlert() -> XCUIElement? {
        springboard.alerts.allElementsBoundByIndex.first { $0.buttons["Join"].exists }
    }

    /// Records every system alert; with `answer`, allows Bluetooth and Local Network as an operator
    /// who wants the camera would. Join alerts are left to the case that owns them.
    private func recordAlerts(answer: Bool) {
        for alert in springboard.alerts.allElementsBoundByIndex where !alert.buttons["Join"].exists {
            let line = text(of: alert)
            if alerts.last != line { alerts.append(line) }
            guard answer else { continue }
            for title in ["Allow", "OK"] where alert.buttons[title].isHittable {
                alert.buttons[title].tap()
                break
            }
        }
    }

    private func text(of alert: XCUIElement) -> String {
        (alert.staticTexts.allElementsBoundByIndex.map(\.label)
            + alert.buttons.allElementsBoundByIndex.map { "[" + $0.label + "]" }).joined(separator: " ")
    }

    // MARK: Evidence and waiting

    private func required(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("Requires \(key)")
        }
        return value
    }

    private func wait(_ what: String, timeout: TimeInterval, _ done: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if done() { return }
        screenshot("failure")
        attach("failure-tree", app.debugDescription)
        if settings.state == .runningForeground { attach("failure-settings-tree", settings.debugDescription) }
        throw PhysicalNetworkFailure(what + " did not happen within \(Int(timeout)) s")
    }

    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "camera-network." + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func attach(_ name: String, _ text: String) {
        let item = XCTAttachment(string: text)
        item.name = "camera-network." + name
        item.lifetime = .keepAlways
        add(item)
    }
}

struct PhysicalNetworkFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
