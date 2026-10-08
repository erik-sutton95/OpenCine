#if os(iOS)
import UIKit
import XCTest

/// Opt-in qualification against one real camera through the production UI.
/// App test bundles subclass this class. No review screen, generated media, remote
/// command endpoint or manufactured camera observation is used.
open class PhysicalMigrationQualificationTests: SharedAppUITestCase {
    @MainActor
    func testPhysicalMigrationConnectionCapturePlaybackAndSavedRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_UI_REVIEW"] == "1" else {
            throw XCTSkip("Requires the opted-in physical migration qualification run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { await run.restore() }
        try await run.exercise()
        #endif
    }
}

private struct PhysicalMigrationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Decodes only the developer probe's accessibility JSON. The UI test target has
/// no dependency on a camera integration or native runtime.
private struct PhysicalMigrationProbe: Decodable {
    let simulated: Bool
    let role: String?
    let sourceIdentity: String?
    let sourceActive: Bool?
    let sourceFrameAt: Double?
    let sourcePresentations: Int?
    let nativeDecodeOutputs: Int?
    let cameraRecording: Bool?
    let cameraISO: Int?
    let cameraISOIsAuto: Bool?
    let playbackOwnerToken: String?
    let playbackItemIdentity: String?
    let playbackPosition: Double?
    let nativePictureReady: Bool?
    let pictureBounds: [Double]?
}

@MainActor private final class PhysicalMigrationRun {
    private enum OriginalISO {
        case manual(value: Int, isAuto: Bool?)
        case automatic(drumLabel: String)
    }
    private struct LiveSource {
        let probe: PhysicalMigrationProbe
        let identity: String
        let frameAt: Double
    }
    private struct PlaybackSource {
        let probe: PhysicalMigrationProbe
        let ownerToken: String
        let identity: String
        let position: Double

        func matches(_ captured: PlaybackSource) -> Bool {
            ownerToken == captured.ownerToken && identity == captured.identity
        }
    }
    private struct Catalogue: Encodable {
        let count: Int
        let identifiers: [String]
    }
    private struct PixelEvidence: Encodable {
        let samples: Int
        let nonblackSamples: Int
        let nonblackSamplesByQuadrant: [Int]
        let meanLuminance: Double
        let brightestChannel: Int
    }

    private unowned let test: XCTestCase
    private let app = XCUIApplication()
    private let originalOrientation = XCUIDevice.shared.orientation
    private var selectedCameraName: String?
    private var originalISO: OriginalISO?
    private var isoDirty = false
    private var isoSourceIdentity: String?
    private var originalHaptics: String?
    private var hapticsDirty = false
    private var recordConfirmation: Bool?
    private var recordingSourceIdentity: String?
    private var recordingStartIssued = false
    private var originalAssists: [String: String] = [:]
    private var dirtyAssists: Set<String> = []
    private var originalPaletteExpanded: Bool?
    private var originalSettingsTab: String?
    private var originalMediaCategory: String?
    private var mediaCategoryDirty = false
    private var qualificationClipFilename: String?
    private var completedStages: [String] = []
    private var lastProbeFailure: String?

    init(test: XCTestCase) { self.test = test }

    func exercise() async throws {
        let environment = ProcessInfo.processInfo.environment
        try require(
            !environment.keys.contains {
                ($0.hasPrefix("OPV_SIM_") || $0 == "OPV_UI_REVIEW_SCREEN")
                    && environment[$0]?.isEmpty == false
            },
            "Remove simulated-feed and review-screen launch inputs before physical qualification")
        app.launchEnvironment["OPV_PHYSICAL_UI_REVIEW"] = "1"
        XCUIDevice.shared.orientation = .portrait
        let launchedAt = Date().timeIntervalSince1970
        app.launch()
        try await connectThroughUI(savedOnly: false)
        let initial = try await freshLive("connected", since: launchedAt)
        try await reportedRecording(false, source: initial.identity, stage: "connected-idle")
        try await wait("Initial raw ISO value or automatic intent", timeout: 12) {
            guard let current = self.observed("live") else { return false }
            if current.cameraISOIsAuto == true { return true }
            return current.cameraISO.map { $0 > 0 } == true
        }
        _ = try await advancingLive("connected-source-progress", from: initial)
        try pictureEvidence("connected-picture", role: "live", identity: initial.identity)
        mark("actual-connection-and-live-picture")

        let before = try await catalogue("before-recording")
        try await returnToLive("before-recording-return")
        try await exerciseISO()
        try await exerciseAssists()
        try await exerciseSettings()
        try await exerciseRotation()
        try await exerciseBackgroundRecovery()
        try await recordShortClip()

        let after = try await catalogue("after-recording")
        let added = Set(after.identifiers).subtracting(before.identifiers)
        try require(
            after.count == before.count + 1 && added.count == 1
                && Set(before.identifiers).isSubset(of: Set(after.identifiers)),
            "One confirmed recording must add exactly one catalogue asset without removing originals")
        guard let clipID = added.first else { throw failure("The qualification clip is unidentified") }
        jsonEvidence("qualification-clip", [
            "identifier": clipID, "before": before.identifiers, "after": after.identifiers,
        ])
        try await openClip(clipID)
        let item = try await readyPlayback("qualification-playback")
        try await exercisePlayback(item, stage: "qualification-playback")
        mark("own-clip-native-playback")
        try await tap(app.buttons["monitor.playback.back"], "Back to media")
        try await wait("Player must retire on return to media", timeout: 10) {
            !self.app.buttons["monitor.playback.back"].exists
        }
        try await openClip(clipID)
        let reopened = try await readyPlayback("qualification-playback-reopened")
        try require(reopened.ownerToken != item.ownerToken, "Reopening must admit a fresh playback owner token")
        try await exercisePlayback(reopened, stage: "qualification-playback-reopened")
        mark("fresh-playback-item")
        try await tap(app.buttons["monitor.playback.back"], "Back to media")
        try await returnToLive("after-playback-return")
        mark("fresh-live-return")
        try await exerciseSavedRelaunch(clipID: clipID)
        try await restoreHaptics()
        try await restorePalette()
        evidence("completed")
        mark("original-settings-restored")
    }

    // Only the start issued here grants stop authority. An unknown report or a
    // different native source never grants permission to stop another recording.
    func restore() async {
        // One failed restoration must not prevent attempts to restore the other
        // settings. The main flow still stops at its first failed requirement.
        test.continueAfterFailure = true
        if app.state != .notRunning && app.state != .runningForeground { app.activate() }
        await cleanup("recording") {
            guard self.recordingStartIssued else { return }
            try await self.dismissToLive()
            guard let captured = self.recordingSourceIdentity,
                let current = self.observed("live"),
                current.sourceIdentity == captured, current.sourceActive == true,
                current.cameraRecording != nil
            else { throw self.failure("Cannot safely stop: the captured recording source/report is unavailable") }
            if current.cameraRecording == true { try await self.setRecording(false, source: captured) }
            self.recordingStartIssued = false
        }
        await cleanup("ISO") { if self.isoDirty { try await self.restoreISO() } }
        for identifier in dirtyAssists.sorted() {
            await cleanup(identifier) { try await self.restoreAssist(identifier) }
        }
        await cleanup("Haptics") { if self.hapticsDirty { try await self.restoreHaptics() } }
        await cleanup("media category") { if self.mediaCategoryDirty { try await self.restoreMediaCategory() } }
        await cleanup("assist palette") { try await self.restorePalette() }
        jsonEvidence("stage-ledger", ["completedStages": completedStages])
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.orientation = originalOrientation
    }

    private func connectThroughUI(savedOnly: Bool) async throws {
        try await wait("Production camera list or live monitor", timeout: 20) {
            self.answerConnectionAlerts()
            return self.app.buttons["monitor.system.settings"].isHittable
                || self.app.buttons["cameras.pair"].isHittable
                || self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connect ")).firstMatch.isHittable
        }
        // A launch may reconnect automatically. Exercise the real saved-row
        // action anyway, after confirming idle and explicitly disconnecting.
        if app.buttons["monitor.system.settings"].isHittable {
            let source = try await freshLive("auto-reconnected-source")
            try await reportedRecording(false, source: source.identity, stage: "auto-reconnected-idle")
            try await tap(app.buttons["monitor.system.settings"], "Operator Setup")
            try await tap(app.buttons["monitor.system.disconnect"], "Disconnect idle session")
        }
        let configuredName = ProcessInfo.processInfo.environment["OPV_PHYSICAL_CAMERA_NAME"]
        let wanted = selectedCameraName ?? configuredName
        var selected = false
        var openedPairing = false
        var selectedPairDevice = false
        var pairingActions: Set<String> = []
        try await wait("Actual saved/pair UI connection", timeout: 90) {
            self.answerConnectionAlerts()
            if selected && self.app.buttons["monitor.system.settings"].isHittable { return true }
            if !selected {
                let rows = self.app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Connect ")
                ).allElementsBoundByIndex.filter {
                    !$0.identifier.hasPrefix("pair.") && !$0.identifier.hasPrefix("cameras.setup.")
                        && $0.isHittable && (wanted == nil || $0.label == "Connect " + wanted!)
                }
                if rows.count == 1, let row = rows.first {
                    self.selectedCameraName = String(row.label.dropFirst("Connect ".count))
                    self.evidence(savedOnly ? "saved-connect-action" : "connect-action")
                    row.tap()
                    selected = true
                } else if rows.count > 1 {
                    self.lastProbeFailure = "Multiple cameras: supply OPV_PHYSICAL_CAMERA_NAME"
                } else if !savedOnly && !openedPairing && self.app.buttons["cameras.pair"].isHittable {
                    self.app.buttons["cameras.pair"].tap()
                    openedPairing = true
                }
            }
            if openedPairing && !selectedPairDevice {
                let devices = self.app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "pair.device.")
                ).allElementsBoundByIndex.filter {
                    $0.isHittable && (wanted == nil || $0.label == "Connect " + wanted!)
                }
                if devices.count == 1, let row = devices.first {
                    self.selectedCameraName = String(row.label.dropFirst("Connect ".count))
                    self.evidence("pair-device-action")
                    row.tap()
                    selectedPairDevice = true
                    selected = true
                } else if devices.count > 1 {
                    self.lastProbeFailure = "Multiple pair targets: supply OPV_PHYSICAL_CAMERA_NAME"
                }
            }
            if openedPairing && selectedPairDevice && self.app.buttons["pair.reportProblem"].exists {
                for title in ["Continue", "Connect", "Pair"] {
                    let button = self.app.buttons[title].firstMatch
                    let step = self.app.staticTexts.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "STEP ")
                    ).firstMatch.label
                    let key = step + "/" + title
                    if button.isHittable && button.isEnabled && !pairingActions.contains(key) {
                        pairingActions.insert(key)
                        button.tap()
                        break
                    }
                }
            }
            return false
        }
        evidence(savedOnly ? "saved-ui-connected" : "actual-ui-connected")
    }

    private func answerConnectionAlerts() {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alert in board.alerts.allElementsBoundByIndex {
            let join = alert.buttons["Join"]
            if join.isHittable { join.tap(); return }
            let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            if ["Bluetooth", "Local Network", "local network", "Wi-Fi"].contains(where: text.contains) {
                for title in ["Allow", "OK"] {
                    let button = alert.buttons[title]
                    if button.isHittable { button.tap(); return }
                }
            }
        }
    }

    private func exerciseISO() async throws {
        let source = try await freshLive("ISO-before")
        try await reportedRecording(false, source: source.identity, stage: "ISO-idle")
        try await tap(app.buttons["monitor.capture.iso"], "ISO control")
        let drum = app.descendants(matching: .any)["Value"].firstMatch
        try await wait("Reported ISO detent", timeout: 8) { drum.isHittable }
        isoSourceIdentity = source.identity
        if source.probe.cameraISOIsAuto == true {
            guard let label = drum.value as? String, !label.isEmpty, label != "Not set",
                app.buttons["Auto"].firstMatch.isSelected
            else { throw failure("The original reported Auto ISO setting must have a known public drum selection") }
            originalISO = .automatic(drumLabel: label)
            isoDirty = true
            evidence("ISO-original-automatic")
            try await tap(app.buttons["Manual"].firstMatch, "Explicit supported Manual ISO mode")
            try await wait("Raw Manual ISO and supported numeric detent", timeout: 12) {
                guard let current = self.observed("live"),
                    current.sourceIdentity == source.identity, current.cameraISOIsAuto == false,
                    let label = drum.value as? String, let value = Int(label), value > 0
                else { return false }
                return current.cameraISO == value && current.cameraRecording == false
            }
        } else {
            guard let original = source.probe.cameraISO, original > 0 else {
                throw failure("Manual ISO proof requires a positive raw reported ISO")
            }
            try require(
                drum.value as? String == String(original),
                "Original manual ISO detent must match its positive raw camera report")
            originalISO = .manual(value: original, isAuto: source.probe.cameraISOIsAuto)
            isoDirty = true
        }
        guard let label = drum.value as? String, let manual = Int(label), manual > 0 else {
            throw failure("A supported numeric Manual ISO selection is required")
        }
        evidence("ISO-original")
        var direction: CGFloat = 1
        step(drum, direction: direction)
        if !(await condition(timeout: 2, { drum.value as? String != String(manual) })) {
            direction = -1
            step(drum, direction: direction)
        }
        try await wait("Adjacent supported ISO detent", timeout: 5) {
            guard let value = drum.value as? String, let iso = Int(value) else { return false }
            return iso > 0 && iso != manual
        }
        guard let selected = drum.value as? String, let changed = Int(selected) else {
            throw failure("The supported adjacent ISO value is unavailable")
        }
        let manualReport: Bool? = source.probe.cameraISOIsAuto == nil ? nil : false
        try await reportedISO(changed, source: source.identity, isAuto: manualReport, stage: "ISO-adjacent-reported")
        evidence("ISO-adjacent")
        step(drum, direction: -direction)
        try await wait("Original manual ISO detent restored", timeout: 5) { drum.value as? String == String(manual) }
        try await reportedISO(manual, source: source.identity, isAuto: manualReport, stage: "ISO-manual-detent-restored")
        try await restoreOriginalISO(drum: drum, source: source.identity)
        try await tap(app.buttons["monitor.capture.close"], "Close ISO")
        _ = try await advancingLive("ISO-live-owner", from: source)
        mark("supported-ISO-change-and-raw-restoration")
    }

    private func restoreISO() async throws {
        try await dismissToLive()
        guard originalISO != nil, let captured = isoSourceIdentity,
            let current = observed("live"), current.sourceIdentity == captured,
            current.sourceActive == true, current.cameraRecording == false
        else { throw failure("Original ISO restoration requires its captured idle source") }
        try await tap(app.buttons["monitor.capture.iso"], "Restore ISO")
        let drum = app.descendants(matching: .any)["Value"].firstMatch
        try await wait("ISO restoration drum", timeout: 8) { drum.isHittable }
        try await restoreOriginalISO(drum: drum, source: captured)
        try await tap(app.buttons["monitor.capture.close"], "Close restored ISO")
    }

    private func restoreOriginalISO(drum: XCUIElement, source: String) async throws {
        guard let originalISO else { throw failure("Original ISO setting was not captured") }
        switch originalISO {
        case .manual(let value, let isAuto):
            if app.buttons["Manual"].firstMatch.exists && !app.buttons["Manual"].firstMatch.isSelected {
                try await tap(app.buttons["Manual"].firstMatch, "Restore Manual ISO mode")
            }
            for _ in 0..<64 {
                guard let label = drum.value as? String, let current = Int(label) else {
                    throw failure("ISO restoration encountered an unknown numeric detent")
                }
                if current == value { break }
                step(drum, direction: current < value ? 1 : -1)
                try await wait("ISO restoration detent must settle", timeout: 4) { drum.value as? String != label }
            }
            try require(drum.value as? String == String(value), "Original ISO must remain supported")
            try await reportedISO(value, source: source, isAuto: isAuto, stage: "ISO-original-reported")
        case .automatic(let label):
            try await tap(app.buttons["Auto"].firstMatch, "Restore original Auto ISO intent")
            try await wait("Raw original Auto ISO mode", timeout: 12) {
                guard let current = self.observed("live"), current.sourceIdentity == source,
                    current.cameraISOIsAuto == true, current.cameraRecording == false
                else { return false }
                if let iso = current.cameraISO { return iso > 0 }
                return true
            }
            try await selectOriginalAutomaticLabel(label, drum: drum)
            let restored = try await freshLive("ISO-original-automatic-reported")
            try require(restored.identity == source && restored.probe.cameraISOIsAuto == true,
                "Automatic ISO must be restored by raw report, never a fixed invented numeric value")
        }
        isoDirty = false
        evidence("ISO-original-setting-restored")
    }

    private func selectOriginalAutomaticLabel(_ wanted: String, drum: XCUIElement) async throws {
        // Manual selection normally leaves the Auto range untouched. If the
        // camera changes it, find the original in the actual bounded drum.
        for direction in [CGFloat(1), CGFloat(-1)] {
            for _ in 0..<64 {
                guard let current = drum.value as? String, !current.isEmpty, current != "Not set" else {
                    throw failure("Original Auto ISO range cannot be restored from an unknown drum")
                }
                if current == wanted { return }
                step(drum, direction: direction)
                if !(await condition(timeout: 2, { drum.value as? String != current })) { break }
            }
        }
        throw failure("Original Auto ISO range is no longer supported: " + wanted)
    }

    private func step(_ drum: XCUIElement, direction: CGFloat) {
        // MonitorValueDrum commits one supported detent on release at 56 points.
        let center = drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -direction * 56, dy: 0)))
    }

    private func exerciseAssists() async throws {
        try await revealPalette()
        for identifier in ["monitor.assist.PEAK", "monitor.assist.FALSE"] {
            let source = try await freshLive("assist-before")
            let button = app.buttons[identifier]
            try require(button.isHittable, "Required common assist is unavailable: " + identifier)
            let original = try switchValue(button)
            originalAssists[identifier] = original
            dirtyAssists.insert(identifier)
            button.tap()
            try await wait("Assist must toggle through its public control", timeout: 5) {
                button.value as? String == (original == "On" ? "Off" : "On")
            }
            _ = try await advancingLive("assist-enabled-owner", from: source)
            try await restoreAssist(identifier)
        }
        let source = try await freshLive("assist-inspector-before")
        try await revealPalette()
        app.buttons["monitor.assist.FALSE"].press(forDuration: 0.6)
        try await wait("Common assist inspector", timeout: 5) { self.app.otherElements["monitor.inspector"].exists }
        for title in ["False Color", "Zebra", "Peaking"] {
            try await tap(app.buttons[title].firstMatch, "Assist inspector " + title)
            try await wait("Inspector close control " + title, timeout: 5) {
                self.app.buttons["Close " + title].isHittable
            }
            evidence("assist-inspector-" + title)
        }
        try await tap(app.buttons["Close Peaking"], "Close assist inspector")
        _ = try await advancingLive("assist-inspector-owner", from: source)
        mark("operator-assists-and-inspector")
    }

    private func restoreAssist(_ identifier: String) async throws {
        try await dismissToLive()
        try await revealPalette()
        guard let original = originalAssists[identifier] else { return }
        let button = app.buttons[identifier]
        let current = try switchValue(button)
        if current != original { try await tap(button, "Restore " + identifier) }
        try await wait("Original assist restored", timeout: 5) { button.value as? String == original }
        dirtyAssists.remove(identifier)
    }

    private func revealPalette() async throws {
        let button = paletteHandle
        try await wait("Assist palette control", timeout: 8) { button.isHittable }
        guard button.label == "Show all View Assist tools" || button.label == "Collapse View Assist tools" else {
            throw failure("Assist expansion state must be explicit")
        }
        if originalPaletteExpanded == nil { originalPaletteExpanded = button.label == "Collapse View Assist tools" }
        if button.label == "Show all View Assist tools" { button.tap() }
        try await wait("Expanded assist palette", timeout: 5) { button.label == "Collapse View Assist tools" }
    }

    private func restorePalette() async throws {
        guard let originalPaletteExpanded else { return }
        try await dismissToLive()
        let button = paletteHandle
        try await wait("Palette restoration control", timeout: 8) { button.isHittable }
        let wanted = originalPaletteExpanded ? "Collapse View Assist tools" : "Show all View Assist tools"
        if button.label != wanted { button.tap() }
        try await wait("Original palette presentation restored", timeout: 5) { button.label == wanted }
    }

    private var paletteHandle: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["monitor.assists.expand", "monitor.assists.collapse"])).firstMatch
    }

    private func exerciseSettings() async throws {
        let source = try await freshLive("settings-before")
        try await openControlsSettings()
        let haptics = app.buttons["Haptics"].firstMatch
        let original = try switchValue(haptics)
        originalHaptics = original
        recordConfirmation = try switchValue(app.buttons["Record confirmation"].firstMatch) == "On"
        hapticsDirty = true
        try await tap(haptics, "Change common Haptics preference")
        try await wait("Changed preference", timeout: 5) {
            haptics.value as? String == (original == "On" ? "Off" : "On")
        }
        evidence("settings-changed")
        try await closeSettings()
        _ = try await advancingLive("settings-preserved-owner", from: source)
        mark("settings-cover-preserves-live-owner")
    }

    private func openControlsSettings() async throws {
        try await dismissToLive()
        try await tap(app.buttons["monitor.system.settings"], "Operator Setup")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.settings.tab."))
        try await wait("Operator settings tabs", timeout: 8) { tabs.count > 0 }
        if originalSettingsTab == nil {
            guard let selected = tabs.allElementsBoundByIndex.first(where: \.isSelected) else {
                throw failure("Original settings tab is unavailable")
            }
            originalSettingsTab = selected.identifier
        }
        let controls = app.buttons["monitor.settings.tab.Controls"]
        try reveal(controls, in: app.scrollViews["monitor.settings.tabs"], horizontal: true)
        try await tap(controls, "Controls settings")
        let haptics = app.buttons["Haptics"].firstMatch
        let content = app.scrollViews.allElementsBoundByIndex.first { $0.buttons["Haptics"].exists }
        if let content { try reveal(haptics, in: content, horizontal: false) }
        try require(haptics.isHittable, "Common Haptics setting must be reachable")
    }

    private func closeSettings() async throws {
        if let originalSettingsTab {
            let tab = app.buttons[originalSettingsTab]
            try reveal(tab, in: app.scrollViews["monitor.settings.tabs"], horizontal: true)
            try await tap(tab, "Restore original settings tab")
        }
        try await tap(app.buttons["monitor.page.back"], "Back to live from settings")
    }

    private func restoreHaptics() async throws {
        guard hapticsDirty, let originalHaptics else { return }
        try await openControlsSettings()
        let button = app.buttons["Haptics"].firstMatch
        if try switchValue(button) != originalHaptics { try await tap(button, "Restore Haptics") }
        try await wait("Original Haptics restored", timeout: 5) { button.value as? String == originalHaptics }
        hapticsDirty = false
        evidence("settings-original-restored")
        try await closeSettings()
    }

    private func exerciseRotation() async throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            let source = try await freshLive("rotation-before")
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            var previous: [CGRect] = []
            var stableSince = Date()
            try await wait("Rotation must settle with reachable capture controls", timeout: 10) {
                let record = self.app.buttons["monitor.system.record"]
                guard record.isHittable, self.app.frame.contains(record.frame),
                    (self.app.frame.height > self.app.frame.width) == portrait
                else { return false }
                let frames = [self.app.frame, record.frame]
                if frames != previous { previous = frames; stableSince = Date(); return false }
                return Date().timeIntervalSince(stableSince) >= 0.4
            }
            _ = try await advancingLive("rotation-owner-" + String(orientation.rawValue), from: source)
            try pictureEvidence("rotation-picture-" + String(orientation.rawValue), role: "live", identity: source.identity)
        }
        mark("rotation-preserves-live-owner")
    }

    private func exerciseBackgroundRecovery() async throws {
        let source = try await freshLive("background-before")
        evidence("background-before")
        XCUIDevice.shared.press(.home)
        try await wait("Actual background lifecycle", timeout: 8) {
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        }
        let foregroundAt = Date().timeIntervalSince1970
        app.activate()
        try await wait("Actual foreground lifecycle", timeout: 8) { self.app.state == .runningForeground }
        let recovered = try await freshLive("foreground-recovered", since: foregroundAt)
        try require(recovered.frameAt > source.frameAt, "Foreground must not reuse the old source frame date")
        if recovered.identity == source.identity {
            try require(countersAdvanced(recovered.probe, after: source.probe), "Available source counters must advance")
        }
        try await reportedRecording(false, source: recovered.identity, stage: "foreground-idle")
        try pictureEvidence("foreground-picture", role: "live", identity: recovered.identity)
        mark("background-and-fresh-source-recovery")
    }

    private func recordShortClip() async throws {
        let source = try await freshLive("recording-before")
        try await reportedRecording(false, source: source.identity, stage: "recording-idle")
        try await setRecording(true, source: source.identity)
        let confirmedAt = ProcessInfo.processInfo.systemUptime
        evidence("short-recording-confirmed-by-raw-camera-report")
        var interrupted = false
        try await wait("Camera must remain recording for approximately two seconds", timeout: 5) {
            guard let current = self.observed("live"),
                let live = self.liveSource(current), live.identity == source.identity,
                current.cameraRecording == true, live.frameAt > source.frameAt
            else { interrupted = true; return true }
            return ProcessInfo.processInfo.systemUptime - confirmedAt >= 2
        }
        try require(!interrupted, "A lost source or raw recording report invalidates the continuous short recording")
        try await setRecording(false, source: source.identity)
        recordingStartIssued = false
        evidence("short-recording-stopped-by-camera-report")
        mark("short-camera-confirmed-recording")
    }

    private func setRecording(_ start: Bool, source: String) async throws {
        guard let confirmation = recordConfirmation else { throw failure("Record confirmation preference is unknown") }
        try await reportedRecording(!start, source: source, stage: start ? "start-admission" : "stop-admission")
        let button = app.buttons["monitor.system.record"]
        try require(
            button.label == (start ? "Start recording" : "Stop recording"),
            "The public record action must match the raw camera report")
        if start { recordingSourceIdentity = source }
        if start && !confirmation { recordingStartIssued = true }
        try await tap(button, start ? "Start recording" : "Stop owned recording")
        if confirmation {
            let confirm = app.buttons[start ? "Start" : "Stop"].firstMatch
            try await wait("Public recording confirmation", timeout: 5) { confirm.isHittable }
            try await reportedRecording(!start, source: source, stage: "record-confirmation-admission")
            if start { recordingStartIssued = true }
            try await tap(confirm, "Confirm recording action")
        }
        try await reportedRecording(start, source: source, stage: start ? "recording-confirmed" : "recording-stopped")
    }

    private func catalogue(_ stage: String) async throws -> Catalogue {
        try await dismissToLive()
        try await tap(app.buttons["monitor.system.media"], "Real camera media")
        let gallery = app.scrollViews["monitor.media.gallery"]
        try await wait("Production media gallery", timeout: 15) { gallery.exists }
        let categories = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.media.category."))
        try await wait("Media categories", timeout: 10) { categories.count > 0 }
        if originalMediaCategory == nil {
            guard let selected = categories.allElementsBoundByIndex.first(where: \.isSelected) else {
                throw failure("Original media category is unknown")
            }
            originalMediaCategory = selected.identifier
        }
        let all = categories.allElementsBoundByIndex.first { $0.label == "Show All media" }
        guard let all else { throw failure("A complete All-media catalogue is required") }
        if !all.isSelected { mediaCategoryDirty = true; try await tap(all, "All media") }
        let filter = app.buttons["monitor.media.filter"]
        try require(filter.exists && filter.value as? String == "Off", "Preserved media filters must permit a complete catalogue")
        try await scrollGalleryToTop(gallery)
        let loading = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
            "Listing", "Loading", "Scanning")).firstMatch
        var count: Int?
        var previousCount: Int?
        var settledAt = Date()
        try await wait("Complete camera catalogue count", timeout: 45) {
            guard !loading.exists else { settledAt = Date(); return false }
            count = self.categoryCount(all)
            if count != previousCount { previousCount = count; settledAt = Date(); return false }
            return count != nil && Date().timeIntervalSince(settledAt) >= 1
        }
        guard let count else { throw failure("All-media count is unknown") }
        try require(count >= 0 && count <= 2_000, "The bounded catalogue inventory supports at most 2,000 assets")
        var identifiers: Set<String> = []
        for _ in 0..<160 {
            let cells = mediaCells()
            identifiers.formUnion(cells.map(\.identifier))
            if identifiers.count == count { break }
            try require(identifiers.count < count, "Catalogue identifiers exceed its declared All count")
            gallery.swipeUp()
            try await settleGallery(gallery)
        }
        try require(identifiers.count == count, "Every pre-existing asset must be inventoried; a partial screen is insufficient")
        try require(categoryCount(all) == count, "Catalogue must remain stable during its inventory")
        let snapshot = Catalogue(count: count, identifiers: identifiers.sorted())
        encodedEvidence(stage + "-catalogue", snapshot)
        evidence(stage + "-catalogue")
        return snapshot
    }

    private func categoryCount(_ button: XCUIElement) -> Int? {
        let counts = button.staticTexts.allElementsBoundByIndex.compactMap { Int($0.label) }
        if counts.count == 1 { return counts[0] }
        if let value = button.value as? String { return Int(value) }
        return nil
    }

    private func mediaCells() -> [XCUIElement] {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "monitor.media.clip.")
        ).allElementsBoundByIndex.filter(\.exists)
    }

    private func settleGallery(_ gallery: XCUIElement) async throws {
        var previous = ""
        var stableSince = Date()
        try await wait("Native gallery scroll must settle", timeout: 5) {
            let signature = self.mediaCells().filter(\.isHittable).map {
                $0.identifier + ":" + String(Int($0.frame.minY.rounded()))
            }.joined(separator: "|")
            if signature != previous { previous = signature; stableSince = Date(); return false }
            return gallery.exists && Date().timeIntervalSince(stableSince) >= 0.4
        }
    }

    private func openClip(_ identifier: String) async throws {
        let gallery = app.scrollViews["monitor.media.gallery"]
        try require(gallery.exists, "Clip selection requires the public camera catalogue")
        let clip = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<160 where !clip.isHittable { gallery.swipeDown(); try await settleGallery(gallery) }
        try require(clip.isHittable, "New qualification clip must be publicly reachable")
        let filenames = Set(clip.staticTexts.allElementsBoundByIndex.map(\.label).filter {
            $0.range(of: #"^.+\.[A-Za-z][A-Za-z0-9]{1,7}$"#, options: .regularExpression) != nil
        })
        guard filenames.count == 1, let filename = filenames.first else {
            throw failure("The qualification asset must expose one actual filename in its public cell")
        }
        if let original = qualificationClipFilename {
            try require(filename == original, "Reopening the qualification asset must retain its filename")
        }
        qualificationClipFilename = filename
        evidence("qualification-clip-selected")
        clip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        try await wait("Native player for the selected qualification filename", timeout: 45) {
            self.app.buttons["monitor.playback.back"].isHittable && self.app.staticTexts[filename].firstMatch.exists
        }
        jsonEvidence("qualification-playback-selection", ["identifier": identifier, "filename": filename])
    }

    private func scrollGalleryToTop(_ gallery: XCUIElement) async throws {
        // Restored gallery scroll positions must not hide existing assets from
        // the inventory. A stationary visible signature bounds the top search.
        for _ in 0..<160 {
            let before = gallerySignature()
            gallery.swipeDown()
            try await settleGallery(gallery)
            if gallerySignature() == before { return }
        }
        throw failure("The bounded catalogue traversal did not reach its beginning")
    }

    private func gallerySignature() -> String {
        mediaCells().filter(\.isHittable).map {
            $0.identifier + ":" + String(Int($0.frame.minY.rounded()))
        }.joined(separator: "|")
    }

    private func exercisePlayback(_ item: PlaybackSource, stage: String) async throws {
        try await restartPlayback(item)
        let before = try await readyPlayback(stage + "-before", captured: item)
        try await wait("Actual native playback position advances", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position > before.position + 0.15
        }
        try pictureEvidence(stage + "-picture", role: "playback", identity: item.identity, ownerToken: item.ownerToken)
        // Reset the short clip before testing transport so reaching its natural
        // end cannot masquerade as a successful Pause command.
        try await restartPlayback(item)
        try await tap(app.buttons["Pause"].firstMatch, "Pause actual native playback")
        try await wait("Pause exposes Play", timeout: 5) { self.app.buttons["Play"].firstMatch.isHittable }
        var anchor: Double?
        var stableSince = ProcessInfo.processInfo.systemUptime
        try await wait("Pause must stop actual native position", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")),
                current.matches(item), self.app.buttons["Play"].firstMatch.isHittable
            else { return false }
            if let origin = anchor, abs(current.position - origin) > 0.05 {
                stableSince = ProcessInfo.processInfo.systemUptime
                anchor = current.position
                self.lastProbeFailure = "Native position continued advancing after Pause"
            }
            if anchor == nil {
                stableSince = ProcessInfo.processInfo.systemUptime
                anchor = current.position
            }
            return ProcessInfo.processInfo.systemUptime - stableSince >= 1
        }
        let paused = try await readyPlayback(stage + "-paused", captured: item)
        evidence(stage + "-paused")
        try await tap(app.buttons["Play"].firstMatch, "Resume actual native playback")
        try await wait("Play must resume actual native position", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position > paused.position + 0.15
        }
        try pictureEvidence(stage + "-resumed-picture", role: "playback", identity: item.identity, ownerToken: item.ownerToken)
    }

    private func restartPlayback(_ item: PlaybackSource) async throws {
        _ = try await readyPlayback("playback-reset-ready", captured: item)
        let pause = app.buttons["Pause"].firstMatch
        if pause.isHittable {
            pause.tap()
            try await wait("Pause before resetting a short clip", timeout: 5) { self.app.buttons["Play"].firstMatch.isHittable }
        }
        try await tap(app.buttons["Back 15 seconds"].firstMatch, "Seek short clip to its beginning")
        try await wait("Actual native seek to beginning", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position <= 0.15
        }
        let restart = app.buttons["Restart clip"].firstMatch
        if restart.isHittable { restart.tap() }
        else { try await tap(app.buttons["Play"].firstMatch, "Play from beginning") }
        try await wait("Native player exposes Pause", timeout: 5) {
            self.playbackSource(self.observed("playback"))?.matches(item) == true
                && self.app.buttons["Pause"].firstMatch.isHittable
        }
    }

    private func exerciseSavedRelaunch(clipID: String) async throws {
        try require(!recordingStartIssued && !isoDirty, "Recording and ISO must be restored before relaunch")
        app.terminate()
        try await wait("Actual app termination", timeout: 8) { self.app.state == .notRunning }
        let relaunchedAt = Date().timeIntervalSince1970
        app.launch()
        try await connectThroughUI(savedOnly: true)
        let source = try await freshLive("saved-relaunch-live", since: relaunchedAt)
        try await reportedRecording(false, source: source.identity, stage: "saved-relaunch-idle")
        guard let originalISO else { throw failure("Original ISO report is unavailable") }
        switch originalISO {
        case .manual(let value, let isAuto):
            try await reportedISO(value, source: source.identity, isAuto: isAuto, stage: "saved-relaunch-ISO")
        case .automatic(let label):
            try await wait("Saved relaunch must preserve raw Auto ISO mode", timeout: 12) {
                guard let current = self.observed("live"), current.sourceIdentity == source.identity,
                    current.cameraISOIsAuto == true, current.cameraRecording == false
                else { return false }
                if let iso = current.cameraISO { return iso > 0 }
                return true
            }
            try await tap(app.buttons["monitor.capture.iso"], "Read saved Auto ISO setting")
            let drum = app.descendants(matching: .any)["Value"].firstMatch
            try await wait("Exact saved Auto/range selection", timeout: 8) { drum.value as? String == label }
            evidence("saved-relaunch-Auto-ISO")
            try await tap(app.buttons["monitor.capture.close"], "Close saved Auto ISO setting")
        }
        try pictureEvidence("saved-relaunch-picture", role: "live", identity: source.identity)
        try await openControlsSettings()
        guard let originalHaptics, let recordConfirmation else {
            throw failure("Original Haptics or record-confirmation preference is unavailable")
        }
        try require(
            try switchValue(app.buttons["Haptics"].firstMatch) == (originalHaptics == "On" ? "Off" : "On"),
            "The changed operator preference must persist across relaunch")
        try require(
            try switchValue(app.buttons["Record confirmation"].firstMatch) == (recordConfirmation ? "On" : "Off"),
            "Record confirmation preference must remain unchanged")
        try await closeSettings()
        _ = try await advancingLive("saved-relaunch-settings-owner", from: source)
        let persisted = try await catalogue("saved-relaunch")
        try require(persisted.identifiers.contains(clipID), "The qualification clip must remain after relaunch")
        try await returnToLive("saved-relaunch-return")
        mark("saved-connection-media-and-preference-persistence")
    }

    private func returnToLive(_ stage: String) async throws {
        try await restoreMediaCategory()
        let closedAt = Date().timeIntervalSince1970
        try await tap(app.buttons["monitor.page.back"], "Return from media to live")
        let current = try await freshLive(stage, since: closedAt)
        try await reportedRecording(false, source: current.identity, stage: stage + "-idle")
        try pictureEvidence(stage + "-picture", role: "live", identity: current.identity)
    }

    private func restoreMediaCategory() async throws {
        guard mediaCategoryDirty, let originalMediaCategory else { return }
        if !app.scrollViews["monitor.media.gallery"].exists {
            try await dismissToLive()
            try await tap(app.buttons["monitor.system.media"], "Restore media category")
        }
        let category = app.buttons[originalMediaCategory]
        try await tap(category, "Restore original media category")
        try await wait("Original media category restored", timeout: 5) { category.isSelected }
        mediaCategoryDirty = false
    }

    private func dismissToLive() async throws {
        for _ in 0..<8 {
            if app.buttons["monitor.capture.close"].isHittable { app.buttons["monitor.capture.close"].tap(); continue }
            if app.buttons["Close clip information"].isHittable { app.buttons["Close clip information"].tap(); continue }
            if app.otherElements["monitor.inspector"].exists {
                let close = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close ")).allElementsBoundByIndex.first { $0.isHittable }
                guard let close else { throw failure("Current inspector has no public close control") }
                close.tap(); continue
            }
            if app.buttons["monitor.playback.back"].isHittable { app.buttons["monitor.playback.back"].tap(); continue }
            if app.buttons["monitor.page.back"].isHittable { app.buttons["monitor.page.back"].tap(); continue }
            if app.buttons["Cancel"].firstMatch.isHittable { app.buttons["Cancel"].firstMatch.tap(); continue }
            break
        }
        try await wait("Live capture controls", timeout: 20) {
            self.app.buttons["monitor.system.record"].isHittable && self.app.buttons["monitor.system.settings"].isHittable
        }
    }

    private func freshLive(_ stage: String, since: Double? = nil) async throws -> LiveSource {
        var result: LiveSource?
        try await wait("Fresh active native live source: " + stage, timeout: 25) {
            guard let probe = self.observed("live"), let current = self.liveSource(probe),
                since == nil || current.frameAt >= since!
            else { return false }
            result = current
            return true
        }
        guard let result else { throw failure("Native live facts are unavailable") }
        evidence(stage)
        return result
    }

    private func advancingLive(_ stage: String, from previous: LiveSource) async throws -> LiveSource {
        var result: LiveSource?
        try await wait("Live owner and actual source frames must advance: " + stage, timeout: 12) {
            guard let probe = self.observed("live"), let current = self.liveSource(probe),
                current.identity == previous.identity, current.frameAt > previous.frameAt + 0.15,
                self.countersAdvanced(current.probe, after: previous.probe)
            else { return false }
            result = current
            return true
        }
        guard let result else { throw failure("Advancing source facts are unavailable") }
        evidence(stage)
        return result
    }

    private func liveSource(_ probe: PhysicalMigrationProbe) -> LiveSource? {
        guard !probe.simulated, probe.role == "live", probe.sourceActive == true,
            let identity = probe.sourceIdentity, !identity.isEmpty,
            let frameAt = probe.sourceFrameAt, frameAt.isFinite,
            Date().timeIntervalSince1970 - frameAt >= -2,
            Date().timeIntervalSince1970 - frameAt <= 5
        else { return nil }
        if let counter = probe.sourcePresentations, counter <= 0 { return nil }
        if let counter = probe.nativeDecodeOutputs, counter <= 0 { return nil }
        return LiveSource(probe: probe, identity: identity, frameAt: frameAt)
    }

    private func countersAdvanced(_ current: PhysicalMigrationProbe, after previous: PhysicalMigrationProbe) -> Bool {
        if let old = previous.sourcePresentations {
            guard let count = current.sourcePresentations, count > old else { return false }
        }
        if let old = previous.nativeDecodeOutputs {
            guard let count = current.nativeDecodeOutputs, count > old else { return false }
        }
        return true
    }

    private func readyPlayback(_ stage: String, captured: PlaybackSource? = nil) async throws -> PlaybackSource {
        var result: PlaybackSource?
        try await wait("Actual native playback item and ready picture: " + stage, timeout: 45) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            if let captured, !current.matches(captured) { return false }
            result = current
            return true
        }
        guard let result else { throw failure("Actual playback facts are unavailable") }
        evidence(stage)
        return result
    }

    private func playbackSource(_ probe: PhysicalMigrationProbe?) -> PlaybackSource? {
        guard let probe, !probe.simulated, probe.role == "playback", probe.nativePictureReady == true,
            let ownerToken = probe.playbackOwnerToken, !ownerToken.isEmpty,
            let identity = probe.playbackItemIdentity, !identity.isEmpty,
            let position = probe.playbackPosition, position.isFinite, position >= 0
        else { return nil }
        return PlaybackSource(probe: probe, ownerToken: ownerToken, identity: identity, position: position)
    }

    private func reportedRecording(_ recording: Bool, source: String, stage: String) async throws {
        try await wait("Raw camera recording report: " + stage, timeout: 15) {
            guard let probe = self.observed("live"), let current = self.liveSource(probe) else { return false }
            return current.identity == source && probe.cameraRecording == recording
        }
    }

    private func reportedISO(_ iso: Int, source: String, isAuto: Bool? = nil, stage: String) async throws {
        try await wait("Raw camera ISO report: " + stage, timeout: 12) {
            guard let probe = self.observed("live"), let current = self.liveSource(probe) else { return false }
            return current.identity == source && probe.cameraISO == iso && probe.cameraRecording == false
                && (isAuto == nil || probe.cameraISOIsAuto == isAuto)
        }
    }

    private func observed(_ role: String) -> PhysicalMigrationProbe? {
        do {
            let elements = app.descendants(matching: .any).matching(identifier: "opencine.native.qualification")
            let decoded = try elements.allElementsBoundByIndex.compactMap { element -> PhysicalMigrationProbe? in
                guard element.exists, let raw = element.value as? String else { return nil }
                let probe = try JSONDecoder().decode(PhysicalMigrationProbe.self, from: Data(raw.utf8))
                return probe.role == role ? probe : nil
            }
            guard decoded.count == 1 else {
                throw PhysicalMigrationFailure("Expected one actual " + role + " probe; found " + String(decoded.count))
            }
            return decoded[0]
        } catch {
            lastProbeFailure = String(describing: error)
            return nil
        }
    }

    private func pictureEvidence(_ stage: String, role: String, identity: String, ownerToken: String? = nil) throws {
        guard let probe = observed(role), !probe.simulated else { throw failure("Actual native picture probe is missing") }
        let reportedIdentity = role == "live" ? probe.sourceIdentity : probe.playbackItemIdentity
        try require(reportedIdentity == identity, "Picture and captured native source/item must agree")
        if role == "playback" {
            try require(ownerToken != nil && probe.playbackOwnerToken == ownerToken,
                "Playback pixels must belong to the captured real playback owner token")
        }
        guard let values = probe.pictureBounds, values.count == 4, values.allSatisfy(\.isFinite),
            values[2] >= 80, values[3] >= 80
        else { throw failure("Actual native picture bounds are unavailable") }
        let nativeBounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let pictures = app.descendants(matching: .any).matching(identifier: "monitor.native.picture").allElementsBoundByIndex.filter {
            let frame = $0.frame
            return $0.exists && abs(frame.minX - nativeBounds.minX) <= 1 && abs(frame.minY - nativeBounds.minY) <= 1
                && abs(frame.width - nativeBounds.width) <= 1 && abs(frame.height - nativeBounds.height) <= 1
        }
        let screenshot: XCUIScreenshot
        let bounds: CGRect
        if pictures.count == 1, let picture = pictures.first {
            screenshot = picture.screenshot()
            bounds = CGRect(origin: .zero, size: screenshot.image.size)
        } else {
            screenshot = XCUIScreen.main.screenshot()
            bounds = nativeBounds
        }
        guard let image = screenshot.image.cgImage else { throw failure("Native picture screenshot has no pixel image") }
        let screen = CGRect(origin: .zero, size: screenshot.image.size)
        let visible = screen.intersection(bounds)
        try require(!visible.isNull && visible.width >= 80 && visible.height >= 80
            && visible.width * visible.height >= bounds.width * bounds.height * 0.95,
            "The actual native picture must be visible within the screen")
        // The inner half excludes chrome, letterbox edges and the tiny probe.
        let sample = visible.insetBy(dx: visible.width * 0.25, dy: visible.height * 0.25)
        let scaleX = CGFloat(image.width) / screen.width
        let scaleY = CGFloat(image.height) / screen.height
        let pixels = CGRect(x: sample.minX * scaleX, y: sample.minY * scaleY,
            width: sample.width * scaleX, height: sample.height * scaleY).integral
        guard let cropped = image.cropping(to: pixels) else { throw failure("Native picture crop could not be sampled") }
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        try require(drawn, "Native bounded pixel sampling must succeed")
        var nonblack = 0
        var quadrants = [Int](repeating: 0, count: 4)
        var luminance = 0.0
        var brightest = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            let maximum = max(red, green, blue)
            if maximum >= 12 {
                nonblack += 1
                let pixel = offset / 4
                let column = pixel % side, row = pixel / side
                quadrants[(row >= side / 2 ? 2 : 0) + (column >= side / 2 ? 1 : 0)] += 1
            }
            brightest = max(brightest, maximum)
            luminance += 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        }
        let stats = PixelEvidence(samples: side * side, nonblackSamples: nonblack,
            nonblackSamplesByQuadrant: quadrants,
            meanLuminance: luminance / Double(side * side), brightestChannel: brightest)
        encodedEvidence(stage + "-pixels", stats)
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "physical-migration." + stage + "-native-picture"; shot.lifetime = .keepAlways; test.add(shot)
        let crop = XCTAttachment(image: UIImage(cgImage: cropped))
        crop.name = "physical-migration." + stage + "-bounded-crop"; crop.lifetime = .keepAlways; test.add(crop)
        evidence(stage)
        // Require area, not just a bright crosshair or text over a black layer.
        let litQuadrants = quadrants.filter { $0 >= side * side / 4 / 10 }.count
        try require(nonblack >= side * side / 10 && litQuadrants >= 3
            && stats.meanLuminance >= 3 && brightest >= 24,
            "Actual native picture lacks distributed nonblack pixels in the bounded centre crop; use a lit qualification scene")
        guard let after = observed(role) else { throw failure("Native picture source disappeared during sampling") }
        let current = role == "live" ? liveSource(after)?.identity : playbackSource(after)?.identity
        try require(current == identity && (role != "playback" || after.playbackOwnerToken == ownerToken),
            "A successor cannot inherit the prior native picture evidence")
    }

    private func switchValue(_ button: XCUIElement) throws -> String {
        try require(button.exists, "Required public switch is missing: " + button.label)
        guard let value = button.value as? String, value == "On" || value == "Off" else {
            throw failure("Required public switch value is unknown: " + button.label)
        }
        return value
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, horizontal: Bool) throws {
        for _ in 0..<10 where !element.isHittable {
            try require(scroll.exists, "A public scroll container is required to reach " + element.label)
            if horizontal {
                if element.frame.midX < scroll.frame.minX { scroll.swipeRight() } else { scroll.swipeLeft() }
            } else {
                if element.frame.midY < scroll.frame.minY { scroll.swipeDown() } else { scroll.swipeUp() }
            }
        }
        try require(element.isHittable, "Public control is unreachable: " + element.label)
    }

    private func tap(_ element: XCUIElement, _ action: String) async throws {
        try await wait("Reachable public action: " + action, timeout: 8) { element.isHittable && element.isEnabled }
        element.tap()
    }

    @MainActor private final class PredicateRead {
        let predicate: @MainActor () -> Bool
        init(_ predicate: @escaping @MainActor () -> Bool) { self.predicate = predicate }
    }

    private func condition(timeout: TimeInterval, _ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        // XCTest evaluates expectation(for:) predicates on MainActor when awaited
        // with fulfillment(of:), as documented by the installed XCTest SDK.
        let read = PredicateRead(predicate)
        let expectation = test.expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated { read.predicate() }
        }, evaluatedWith: nil, handler: nil)
        return await XCTWaiter.fulfillment(of: [expectation], timeout: timeout) == .completed
    }

    private func wait(_ message: String, timeout: TimeInterval, _ predicate: @escaping @MainActor () -> Bool) async throws {
        if !(await condition(timeout: timeout, predicate)) {
            throw failure(message + (lastProbeFailure.map { ". " + $0 } ?? ""))
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private func cleanup(_ name: String, _ action: @MainActor () async throws -> Void) async {
        do { try await action() }
        catch { evidence("teardown-" + name + "-failed"); XCTFail("Qualification cleanup failed for " + name + ": " + String(describing: error)) }
    }

    private func failure(_ message: String) -> PhysicalMigrationFailure {
        evidence("failure")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "physical-migration.failure-tree"; tree.lifetime = .keepAlways; test.add(tree)
        return PhysicalMigrationFailure(message)
    }

    private func mark(_ stage: String) { completedStages.append(stage) }

    private func evidence(_ stage: String) {
        let probes = app.descendants(matching: .any).matching(identifier: "opencine.native.qualification")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
        let decoded = probes.compactMap { try? JSONDecoder().decode(PhysicalMigrationProbe.self, from: Data($0.utf8)) }
        let probe = decoded.first { $0.role == "playback" } ?? decoded.first { $0.role == "live" }
        jsonEvidence(stage, [
            "stage": stage, "at": Date().timeIntervalSince1970, "rawProbeJSON": probes,
            "sourcePresentations": probe?.sourcePresentations.map { $0 as Any } ?? NSNull(),
            "nativeDecodeOutputs": probe?.nativeDecodeOutputs.map { $0 as Any } ?? NSNull(),
            "cameraRecording": probe?.cameraRecording.map { $0 as Any } ?? NSNull(),
            "cameraISO": probe?.cameraISO.map { $0 as Any } ?? NSNull(),
            "cameraISOIsAuto": probe?.cameraISOIsAuto.map { $0 as Any } ?? NSNull(),
            "playbackOwnerToken": probe?.playbackOwnerToken.map { $0 as Any } ?? NSNull(),
            "playbackItemIdentity": probe?.playbackItemIdentity.map { $0 as Any } ?? NSNull(),
            "lastProbeFailure": lastProbeFailure.map { $0 as Any } ?? NSNull(),
        ])
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "physical-migration." + stage; shot.lifetime = .keepAlways; test.add(shot)
    }

    private func jsonEvidence(_ name: String, _ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "physical-migration." + name + ".json"; attachment.lifetime = .keepAlways; test.add(attachment)
        }
    }

    private func encodedEvidence<Value: Encodable>(_ name: String, _ value: Value) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "physical-migration." + name + ".json"; attachment.lifetime = .keepAlways; test.add(attachment)
        }
    }
}
#endif
