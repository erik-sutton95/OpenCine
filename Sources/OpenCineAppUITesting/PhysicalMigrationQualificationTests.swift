#if os(iOS)
import UIKit
import XCTest

/// Opt-in qualification against one real camera through the production UI.
/// App test bundles subclass this class. No review screen, generated media, remote
/// command endpoint or manufactured camera observation is used.
///
/// The cases are synchronous, like every other shared UI flow. A failed XCUI action interrupts the
/// running case; in an async case XCTest (Xcode 27, iOS 27 devices) then waits forever for the
/// invocation ("failable invocation block completion"), so the run hung and the teardown never
/// restored the camera and app settings. A synchronous case unwinds and runs its teardown.
open class PhysicalMigrationQualificationTests: SharedAppUITestCase {
    @MainActor
    func testPhysicalMigrationConnectionCapturePlaybackAndSavedRelaunch() throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_UI_REVIEW"] == "1" else {
            throw XCTSkip("Requires the opted-in physical migration qualification run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exercise()
        #endif
    }
    @MainActor
    func testPhysicalBackgroundRecoveryAndFreshNativePicture() throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_UI_REVIEW"] == "1" else {
            throw XCTSkip("Requires the opted-in physical migration qualification run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exerciseBackgroundRecoveryAndFreshNativePicture()
        #endif
    }

    @MainActor
    func testPhysicalSettingsRecordingPlaybackReopenAndSavedRelaunch() throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_UI_REVIEW"] == "1" else {
            throw XCTSkip("Requires the opted-in physical migration qualification run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exerciseSettingsRecordingPlaybackReopenAndSavedRelaunch()
        #endif
    }

    @MainActor
    func testPhysicalCameraListDiscovery() throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_ROW_PROBE"] == "1" else {
            throw XCTSkip("Requires the opted-in read-only discovery run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exerciseCameraListDiscovery()
        #endif
    }

    @MainActor
    func testPhysicalStatusRowReadoutsOnLiveCamera() throws {
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_ROW_PROBE"] == "1" else {
            throw XCTSkip("Requires the opted-in read-only status row readout run")
        }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exerciseStatusRowReadouts()
        #endif
    }

    @MainActor
    func testPhysicalCapturedOwnClipQueryOrPlaybackReopenAndSavedRelaunch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPV_PHYSICAL_UI_REVIEW"] == "1",
            let raw = environment["OPV_PHYSICAL_OWNED_CLIP_JSON"], !raw.isEmpty
        else { throw XCTSkip("Requires explicit prior qualification-clip proof and physical opt-in") }
        #if targetEnvironment(simulator)
        throw PhysicalMigrationFailure("Physical qualification cannot run on a simulator")
        #else
        let request = try JSONDecoder().decode(PhysicalOwnedClipRequest.self, from: Data(raw.utf8))
        try request.validate(cameraName: environment["OPV_PHYSICAL_CAMERA_NAME"])
        continueAfterFailure = false
        let run = PhysicalMigrationRun(test: self, bundleIdentifier: request.bundleIdentifier)
        addTeardownBlock { MainActor.assumeIsolated { run.restore() } }
        try run.exerciseCapturedOwnClip(request)
        #endif
    }

}

/// The root configuration must bind this proof to its original run and signed app.
private struct PhysicalOwnedClipRequest: Decodable {
    enum Mode: String, Decodable { case query, playback }
    struct Clip: Decodable {
        let identifier: String
        let before: [String]
        let after: [String]
    }
    let mode: Mode
    let bundleIdentifier: String
    let cameraName: String
    let qualificationClip: Clip

    func validate(cameraName configuredName: String?) throws {
        let before = Set(qualificationClip.before), after = Set(qualificationClip.after)
        let prefix = "monitor.media.clip."
        guard !bundleIdentifier.isEmpty, !cameraName.isEmpty, configuredName == cameraName,
            bundleIdentifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                options: .regularExpression) != nil,
            qualificationClip.identifier.hasPrefix(prefix), qualificationClip.identifier.count > prefix.count,
            !qualificationClip.identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            before.count == qualificationClip.before.count, after.count == qualificationClip.after.count,
            after.count <= 2_000, after.count == before.count + 1, before.isSubset(of: after),
            after.subtracting(before) == Set([qualificationClip.identifier]),
            after.allSatisfy({ $0.hasPrefix(prefix) && $0.count > prefix.count })
        else { throw PhysicalMigrationFailure("Explicit captured own-clip proof, bundle and exact saved camera are required") }
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
    private let app: XCUIApplication
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

    init(test: XCTestCase) {
        self.test = test
        app = XCUIApplication()
    }

    // An explicit scoped target does not change the default target of original runs.
    init(test: XCTestCase, bundleIdentifier: String) {
        self.test = test
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    func exercise() throws {
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
        try connectThroughUI(savedOnly: false)
        let initial = try freshLive("connected", since: launchedAt)
        try reportedRecording(false, source: initial.identity, stage: "connected-idle")
        try wait("Initial raw ISO value or automatic intent", timeout: 12) {
            guard let current = self.observed("live") else { return false }
            if current.cameraISOIsAuto == true { return true }
            return current.cameraISO.map { $0 > 0 } == true
        }
        _ = try advancingLive("connected-source-progress", from: initial)
        try pictureEvidence("connected-picture", role: "live", identity: initial.identity)
        mark("actual-connection-and-live-picture")

        let before = try catalogue("before-recording")
        try returnToLive("before-recording-return")
        try exerciseISO()
        try exerciseAssists()
        try exerciseSettings()
        try exerciseRotation()
        try exerciseBackgroundRecovery()
        try recordShortClip()

        let after = try catalogue("after-recording")
        let added = Set(after.identifiers).subtracting(before.identifiers)
        try require(
            after.count == before.count + 1 && added.count == 1
                && Set(before.identifiers).isSubset(of: Set(after.identifiers)),
            "One confirmed recording must add exactly one catalogue asset without removing originals")
        guard let clipID = added.first else { throw failure("The qualification clip is unidentified") }
        jsonEvidence("qualification-clip", [
            "identifier": clipID, "before": before.identifiers, "after": after.identifiers,
        ])
        try openClip(clipID)
        let item = try readyPlayback("qualification-playback")
        try exercisePlayback(item, stage: "qualification-playback")
        mark("own-clip-native-playback")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try wait("Player must retire on return to media", timeout: 10) {
            !self.app.buttons["monitor.playback.back"].exists
        }
        try openClip(clipID)
        let reopened = try readyPlayback("qualification-playback-reopened")
        try require(reopened.ownerToken != item.ownerToken, "Reopening must admit a fresh playback owner token")
        try exercisePlayback(reopened, stage: "qualification-playback-reopened")
        mark("fresh-playback-item")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try returnToLive("after-playback-return")
        mark("fresh-live-return")
        try exerciseSavedRelaunch(clipID: clipID)
        try restoreHaptics()
        try restorePalette()
        evidence("completed")
        mark("original-settings-restored")
    }

    // Scoped entries stay inside this private runner; original helpers are unchanged.
    func exerciseBackgroundRecoveryAndFreshNativePicture() throws {
        try prepareScopedSavedConnection()
        try exerciseBackgroundRecovery()
        evidence("scoped-background-completed")
    }

    func exerciseSettingsRecordingPlaybackReopenAndSavedRelaunch() throws {
        try prepareScopedSavedConnection()
        try captureOriginalISOReadOnly()
        try exerciseSettings()
        let before = try catalogue("before-recording")
        try returnToLive("before-recording-return")
        try recordShortClip()

        let after = try catalogue("after-recording")
        let added = Set(after.identifiers).subtracting(before.identifiers)
        try require(
            after.count == before.count + 1 && added.count == 1
                && Set(before.identifiers).isSubset(of: Set(after.identifiers)),
            "One confirmed recording must add exactly one catalogue asset without removing originals")
        guard let clipID = added.first else { throw failure("The qualification clip is unidentified") }
        jsonEvidence("qualification-clip", [
            "identifier": clipID, "before": before.identifiers, "after": after.identifiers,
        ])
        try openClip(clipID)
        let item = try readyPlayback("qualification-playback")
        try exercisePlayback(item, stage: "qualification-playback")
        mark("own-clip-native-playback")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try wait("Player must retire on return to media", timeout: 10) {
            !self.app.buttons["monitor.playback.back"].exists
        }
        try openClip(clipID)
        let reopened = try readyPlayback("qualification-playback-reopened")
        try require(reopened.ownerToken != item.ownerToken, "Reopening must admit a fresh playback owner token")
        try exercisePlayback(reopened, stage: "qualification-playback-reopened")
        mark("fresh-playback-item")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try returnToLive("after-playback-return")
        mark("fresh-live-return")
        try exerciseSavedRelaunch(clipID: clipID)
        try restoreHaptics()
        let restored = try freshLive("scoped-settings-restored")
        try reportedRecording(false, source: restored.identity, stage: "scoped-settings-restored-idle")
        try pictureEvidence("scoped-settings-restored-picture", role: "live", identity: restored.identity)
        mark("original-settings-restored")
        evidence("scoped-settings-recording-playback-relaunch-completed")
    }

    // Read-only discovery: what the production cameras page advertises right now.
    // No connect tap, pairing step, camera write or media operation is issued.
    func exerciseCameraListDiscovery() throws {
        let environment = ProcessInfo.processInfo.environment
        try require(
            !environment.keys.contains {
                ($0.hasPrefix("OPV_SIM_") || $0 == "OPV_UI_REVIEW_SCREEN")
                    && environment[$0]?.isEmpty == false
            },
            "Remove simulated-feed and review-screen launch inputs before physical qualification")
        app.launchEnvironment["OPV_PHYSICAL_UI_REVIEW"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        try wait("Production camera list or live monitor", timeout: 20) {
            self.answerConnectionAlerts()
            return self.app.buttons["monitor.system.settings"].isHittable
                || self.app.buttons["cameras.pair"].isHittable
        }
        // Give background discovery (Bluetooth and Wi-Fi scans) a bounded window
        // before the page contents are recorded.
        try condition(timeout: 15) {
            self.answerConnectionAlerts()
            return self.app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                    "Connect ", "Reconnect ")).firstMatch.isHittable
        }
        let connectRows = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Connect ", "Reconnect ")).allElementsBoundByIndex
            .filter { !$0.identifier.hasPrefix("pair.") && !$0.identifier.hasPrefix("cameras.setup.") }
            .map { $0.identifier + "|" + $0.label }
        let pairRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "pair.device."))
            .allElementsBoundByIndex.map { $0.identifier + "|" + $0.label }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "camera-list.ax"; tree.lifetime = .keepAlways; test.add(tree)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "camera-list.screen"; shot.lifetime = .keepAlways; test.add(shot)
        jsonEvidence("camera-list", [
            "at": Date().timeIntervalSince1970,
            "connectRows": connectRows, "pairRows": pairRows,
            "liveMonitor": app.buttons["monitor.system.settings"].isHittable,
        ])
        mark("camera-list-discovery")
        evidence("camera-list-recorded")
        if app.state != .notRunning { app.terminate() }
    }

    // Read-only status row evidence: a saved connection, the live probe and the
    // status row exactly as the operator sees it in each orientation. No camera
    // setting, record or media operation is issued in this exercise.
    func exerciseStatusRowReadouts() throws {
        try prepareScopedSavedConnection()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            let raw = String(orientation.rawValue)
            let source = try freshLive("row-before-" + raw)
            XCUIDevice.shared.orientation = orientation
            var previous: [CGRect] = []
            var stableSince = Date()
            try wait("Rotation must settle with reachable capture controls: " + raw, timeout: 10) {
                let record = self.app.buttons["monitor.system.record"]
                // Mid-rotation the record frame can be empty or outside the window, and XCUI
                // then records a failure instead of answering isHittable: read geometry first.
                guard (self.app.frame.height > self.app.frame.width) == (orientation == .portrait),
                    record.exists, !record.frame.isEmpty, self.app.frame.contains(record.frame),
                    record.isHittable
                else { return false }
                let frames = [self.app.frame, record.frame]
                if frames != previous { previous = frames; stableSince = Date(); return false }
                return Date().timeIntervalSince(stableSince) >= 0.4
            }
            let current = try freshLive("row-live-" + raw)
            try reportedRecording(false, source: current.identity, stage: "row-idle-" + raw)
            let name = "status-row." + raw
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + ".ax"; tree.lifetime = .keepAlways; test.add(tree)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name + ".screen"; shot.lifetime = .keepAlways; test.add(shot)
            jsonEvidence(name, [
                "orientation": orientation.rawValue,
                "at": Date().timeIntervalSince1970,
                "sourceIdentity": current.identity,
                "sourceFrameAt": current.frameAt,
                "cameraISO": current.probe.cameraISO.map { $0 as Any } ?? NSNull(),
                "cameraISOIsAuto": current.probe.cameraISOIsAuto.map { $0 as Any } ?? NSNull(),
                "cameraRecording": current.probe.cameraRecording.map { $0 as Any } ?? NSNull(),
                "nativeDecodeOutputs": current.probe.nativeDecodeOutputs.map { $0 as Any } ?? NSNull(),
                "sourcePresentations": current.probe.sourcePresentations.map { $0 as Any } ?? NSNull(),
            ])
            mark("status-row-" + raw)
        }
        evidence("status-row-readouts-completed")
    }

    // Reuses the original playback/relaunch oracles without acquiring record authority.
    func exerciseCapturedOwnClip(_ request: PhysicalOwnedClipRequest) throws {
        let clipID = request.qualificationClip.identifier
        jsonEvidence("owned-clip-prior-proof", [
            "mode": request.mode.rawValue, "bundleIdentifier": request.bundleIdentifier,
            "cameraName": request.cameraName, "identifier": clipID,
            "before": request.qualificationClip.before, "after": request.qualificationClip.after,
            "originalOrientation": originalOrientation.rawValue,
        ])
        try prepareScopedSavedConnection()
        if request.mode == .playback {
            try captureOriginalISOReadOnly()
            try exerciseSettings()
            guard let originalHaptics, let recordConfirmation, let originalSettingsTab else {
                throw failure("Captured cleanup preferences are required before owned-clip playback")
            }
            // These values were captured before the unchanged settings helper toggled Haptics.
            jsonEvidence("owned-clip-cleanup-baseline", [
                "originalHaptics": originalHaptics, "recordConfirmation": recordConfirmation,
                "originalSettingsTab": originalSettingsTab, "originalOrientation": originalOrientation.rawValue,
                "ISOEvidence": "physical-migration.ISO-original-read-only",
            ])
        }
        try openOwnedClipGallery()
        if request.mode == .query {
            let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", clipID))
            let clip = query.firstMatch
            try require(clip.exists && clip.identifier == clipID,
                "The exact captured clip must resolve through the public identifier query")
            jsonEvidence("owned-clip-exact-query", [
                "requestedIdentifier": clipID, "resolvedIdentifier": clip.identifier,
                "matchedCount": query.count, "clipTapped": false,
            ])
            mark("captured-own-clip-query-only")
            return
        }
        try require(!recordingStartIssued && !isoDirty,
            "Scoped playback must have no recording or ISO mutation authority")
        try openClip(clipID)
        let item = try readyPlayback("qualification-playback")
        try exercisePlayback(item, stage: "qualification-playback")
        mark("own-clip-native-playback")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try wait("Player must retire on return to media", timeout: 10) {
            !self.app.buttons["monitor.playback.back"].exists
        }
        try openClip(clipID)
        let reopened = try readyPlayback("qualification-playback-reopened")
        try require(reopened.ownerToken != item.ownerToken, "Reopening must admit a fresh playback owner token")
        try exercisePlayback(reopened, stage: "qualification-playback-reopened")
        mark("fresh-playback-item")
        try tap(app.buttons["monitor.playback.back"], "Back to media")
        try returnToLive("after-playback-return")
        mark("fresh-live-return")
        try exerciseSavedRelaunch(clipID: clipID)
        try restoreHaptics()
        let restored = try freshLive("scoped-settings-restored")
        try reportedRecording(false, source: restored.identity, stage: "scoped-settings-restored-idle")
        try pictureEvidence("scoped-settings-restored-picture", role: "live", identity: restored.identity)
        mark("original-settings-restored")
        evidence("scoped-owned-clip-playback-relaunch-completed")
    }

    private func openOwnedClipGallery() throws {
        let source = try freshLive("owned-clip-gallery-before")
        try reportedRecording(false, source: source.identity, stage: "owned-clip-gallery-idle")
        try dismissToLive()
        try tap(app.buttons["monitor.system.media"], "Real camera media")
        let gallery = app.scrollViews["monitor.media.gallery"]
        try wait("Production media gallery", timeout: 15) { gallery.exists }
        let categories = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.media.category."))
        try wait("Media categories", timeout: 10) { categories.count > 0 }
        guard let selected = categories.allElementsBoundByIndex.first(where: \.isSelected) else {
            throw failure("Original media category is unknown")
        }
        originalMediaCategory = selected.identifier
        jsonEvidence("owned-clip-media-baseline", ["originalMediaCategory": selected.identifier])
        guard let all = categories.allElementsBoundByIndex.first(where: { $0.label == "Show All media" }) else {
            throw failure("The captured clip requires the public All-media category")
        }
        if !all.isSelected { mediaCategoryDirty = true; try tap(all, "All media") }
        let filter = app.buttons["monitor.media.filter"]
        try require(filter.exists && filter.value as? String == "Off", "Preserved media filters must permit a complete catalogue")
    }

    private func prepareScopedSavedConnection() throws {
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
        try connectThroughUI(savedOnly: true)
        let initial = try freshLive("connected", since: launchedAt)
        try reportedRecording(false, source: initial.identity, stage: "connected-idle")
        try wait("Initial raw ISO value or automatic intent", timeout: 12) {
            guard let current = self.observed("live") else { return false }
            if current.cameraISOIsAuto == true { return true }
            return current.cameraISO.map { $0 > 0 } == true
        }
        _ = try advancingLive("connected-source-progress", from: initial)
        try pictureEvidence("connected-picture", role: "live", identity: initial.identity)
        mark("actual-connection-and-live-picture")
    }

    private func captureOriginalISOReadOnly() throws {
        let source = try freshLive("ISO-baseline-before")
        try reportedRecording(false, source: source.identity, stage: "ISO-baseline-idle")
        try tap(app.buttons["monitor.capture.iso"], "Read original ISO setting")
        let drum = app.descendants(matching: .any)["Value"].firstMatch
        try wait("Reported original ISO detent", timeout: 8) { drum.isHittable }
        let captured: OriginalISO
        if source.probe.cameraISOIsAuto == true {
            guard let label = drum.value as? String, !label.isEmpty, label != "Not set",
                app.buttons["Auto"].firstMatch.isSelected
            else { throw failure("The original reported Auto ISO setting must have a known public drum selection") }
            captured = .automatic(drumLabel: label)
        } else {
            guard let original = source.probe.cameraISO, original > 0 else {
                throw failure("Manual ISO proof requires a positive raw reported ISO")
            }
            try require(
                drum.value as? String == String(original),
                "Original manual ISO detent must match its positive raw camera report")
            captured = .manual(value: original, isAuto: source.probe.cameraISOIsAuto)
        }
        guard let probe = observed("live"), let current = liveSource(probe),
            current.identity == source.identity, probe.cameraRecording == false,
            probe.cameraISOIsAuto == source.probe.cameraISOIsAuto
        else { throw failure("Read-only ISO baseline requires the same fresh idle source and reported mode") }
        switch captured {
        case .manual(let value, _):
            try require(probe.cameraISO == value && drum.value as? String == String(value),
                "Read-only manual ISO baseline must retain its captured raw value and public detent")
        case .automatic(let label):
            try require(probe.cameraISOIsAuto == true && app.buttons["Auto"].firstMatch.isSelected
                && drum.value as? String == label,
                "Read-only Auto ISO baseline must retain its captured mode and exact public selection")
        }
        originalISO = captured
        evidence("ISO-original-read-only")
        try tap(app.buttons["monitor.capture.close"], "Close original ISO setting")
        _ = try advancingLive("ISO-baseline-live-owner", from: source)
        mark("read-only-original-ISO-baseline")
    }

    // Only the start issued here grants stop authority. An unknown report or a
    // different native source never grants permission to stop another recording.
    func restore() {
        // One failed restoration must not prevent attempts to restore the other
        // settings. The main flow still stops at its first failed requirement.
        test.continueAfterFailure = true
        if app.state != .notRunning && app.state != .runningForeground { app.activate() }
        cleanup("recording") {
            guard self.recordingStartIssued else { return }
            try self.dismissToLive()
            guard let captured = self.recordingSourceIdentity,
                let current = self.observed("live"),
                current.sourceIdentity == captured, current.sourceActive == true,
                current.cameraRecording != nil
            else { throw self.failure("Cannot safely stop: the captured recording source/report is unavailable") }
            if current.cameraRecording == true { try self.setRecording(false, source: captured) }
            self.recordingStartIssued = false
        }
        cleanup("ISO") { if self.isoDirty { try self.restoreISO() } }
        for identifier in dirtyAssists.sorted() {
            cleanup(identifier) { try self.restoreAssist(identifier) }
        }
        cleanup("Haptics") { if self.hapticsDirty { try self.restoreHaptics() } }
        cleanup("media category") { if self.mediaCategoryDirty { try self.restoreMediaCategory() } }
        cleanup("assist palette") { try self.restorePalette() }
        jsonEvidence("stage-ledger", ["completedStages": completedStages])
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.orientation = originalOrientation
    }

    private func connectThroughUI(savedOnly: Bool) throws {
        try wait("Production camera list or live monitor", timeout: 20) {
            self.answerConnectionAlerts()
            return self.app.buttons["monitor.system.settings"].isHittable
                || self.app.buttons["cameras.pair"].isHittable
                || self.app.buttons.matching(
                    NSPredicate(
                        format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Connect ", "Reconnect ")
                ).firstMatch.isHittable
        }
        // A launch may reconnect automatically. Exercise the real saved-row
        // action anyway, after confirming idle and explicitly disconnecting.
        if app.buttons["monitor.system.settings"].isHittable {
            let source = try freshLive("auto-reconnected-source")
            try reportedRecording(false, source: source.identity, stage: "auto-reconnected-idle")
            try tap(app.buttons["monitor.system.settings"], "Operator Setup")
            try tap(app.buttons["monitor.system.disconnect"], "Disconnect idle session")
        }
        let configuredName = ProcessInfo.processInfo.environment["OPV_PHYSICAL_CAMERA_NAME"]
        let wanted = selectedCameraName ?? configuredName
        var selected = false
        var openedPairing = false
        var selectedPairDevice = false
        var pairingActions: Set<String> = []
        try wait("Actual saved/pair UI connection", timeout: 90) {
            self.answerConnectionAlerts()
            if selected && self.app.buttons["monitor.system.settings"].isHittable { return true }
            if !selected {
                let rows = self.app.buttons.matching(
                    NSPredicate(
                        format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Connect ", "Reconnect ")
                ).allElementsBoundByIndex.filter {
                    !$0.identifier.hasPrefix("pair.") && !$0.identifier.hasPrefix("cameras.setup.")
                        && $0.isHittable
                        && (wanted == nil || $0.label == "Connect " + wanted!
                            || $0.label == "Reconnect " + wanted!)
                }
                if rows.count == 1, let row = rows.first {
                    let prefix = row.label.hasPrefix("Reconnect ") ? "Reconnect " : "Connect "
                    self.selectedCameraName = String(row.label.dropFirst(prefix.count))
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

    private func exerciseISO() throws {
        let source = try freshLive("ISO-before")
        try reportedRecording(false, source: source.identity, stage: "ISO-idle")
        try tap(app.buttons["monitor.capture.iso"], "ISO control")
        let drum = app.descendants(matching: .any)["Value"].firstMatch
        try wait("Reported ISO detent", timeout: 8) { drum.isHittable }
        isoSourceIdentity = source.identity
        if source.probe.cameraISOIsAuto == true {
            guard let label = drum.value as? String, !label.isEmpty, label != "Not set",
                app.buttons["Auto"].firstMatch.isSelected
            else { throw failure("The original reported Auto ISO setting must have a known public drum selection") }
            originalISO = .automatic(drumLabel: label)
            isoDirty = true
            evidence("ISO-original-automatic")
            try tap(app.buttons["Manual"].firstMatch, "Explicit supported Manual ISO mode")
            try wait("Raw Manual ISO and supported numeric detent", timeout: 12) {
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
        if !(condition(timeout: 2, { drum.value as? String != String(manual) })) {
            direction = -1
            step(drum, direction: direction)
        }
        try wait("Adjacent supported ISO detent", timeout: 5) {
            guard let value = drum.value as? String, let iso = Int(value) else { return false }
            return iso > 0 && iso != manual
        }
        guard let selected = drum.value as? String, let changed = Int(selected) else {
            throw failure("The supported adjacent ISO value is unavailable")
        }
        let manualReport: Bool? = source.probe.cameraISOIsAuto == nil ? nil : false
        try reportedISO(changed, source: source.identity, isAuto: manualReport, stage: "ISO-adjacent-reported")
        evidence("ISO-adjacent")
        step(drum, direction: -direction)
        try wait("Original manual ISO detent restored", timeout: 5) { drum.value as? String == String(manual) }
        try reportedISO(manual, source: source.identity, isAuto: manualReport, stage: "ISO-manual-detent-restored")
        try restoreOriginalISO(drum: drum, source: source.identity)
        try tap(app.buttons["monitor.capture.close"], "Close ISO")
        _ = try advancingLive("ISO-live-owner", from: source)
        mark("supported-ISO-change-and-raw-restoration")
    }

    private func restoreISO() throws {
        try dismissToLive()
        guard originalISO != nil, let captured = isoSourceIdentity,
            let current = observed("live"), current.sourceIdentity == captured,
            current.sourceActive == true, current.cameraRecording == false
        else { throw failure("Original ISO restoration requires its captured idle source") }
        try tap(app.buttons["monitor.capture.iso"], "Restore ISO")
        let drum = app.descendants(matching: .any)["Value"].firstMatch
        try wait("ISO restoration drum", timeout: 8) { drum.isHittable }
        try restoreOriginalISO(drum: drum, source: captured)
        try tap(app.buttons["monitor.capture.close"], "Close restored ISO")
    }

    private func restoreOriginalISO(drum: XCUIElement, source: String) throws {
        guard let originalISO else { throw failure("Original ISO setting was not captured") }
        switch originalISO {
        case .manual(let value, let isAuto):
            if app.buttons["Manual"].firstMatch.exists && !app.buttons["Manual"].firstMatch.isSelected {
                try tap(app.buttons["Manual"].firstMatch, "Restore Manual ISO mode")
            }
            for _ in 0..<64 {
                guard let label = drum.value as? String, let current = Int(label) else {
                    throw failure("ISO restoration encountered an unknown numeric detent")
                }
                if current == value { break }
                step(drum, direction: current < value ? 1 : -1)
                try wait("ISO restoration detent must settle", timeout: 4) { drum.value as? String != label }
            }
            try require(drum.value as? String == String(value), "Original ISO must remain supported")
            try reportedISO(value, source: source, isAuto: isAuto, stage: "ISO-original-reported")
        case .automatic(let label):
            try tap(app.buttons["Auto"].firstMatch, "Restore original Auto ISO intent")
            try wait("Raw original Auto ISO mode", timeout: 12) {
                guard let current = self.observed("live"), current.sourceIdentity == source,
                    current.cameraISOIsAuto == true, current.cameraRecording == false
                else { return false }
                if let iso = current.cameraISO { return iso > 0 }
                return true
            }
            try selectOriginalAutomaticLabel(label, drum: drum)
            let restored = try freshLive("ISO-original-automatic-reported")
            try require(restored.identity == source && restored.probe.cameraISOIsAuto == true,
                "Automatic ISO must be restored by raw report, never a fixed invented numeric value")
        }
        isoDirty = false
        evidence("ISO-original-setting-restored")
    }

    private func selectOriginalAutomaticLabel(_ wanted: String, drum: XCUIElement) throws {
        // Manual selection normally leaves the Auto range untouched. If the
        // camera changes it, find the original in the actual bounded drum.
        for direction in [CGFloat(1), CGFloat(-1)] {
            for _ in 0..<64 {
                guard let current = drum.value as? String, !current.isEmpty, current != "Not set" else {
                    throw failure("Original Auto ISO range cannot be restored from an unknown drum")
                }
                if current == wanted { return }
                step(drum, direction: direction)
                if !(condition(timeout: 2, { drum.value as? String != current })) { break }
            }
        }
        throw failure("Original Auto ISO range is no longer supported: " + wanted)
    }

    private func step(_ drum: XCUIElement, direction: CGFloat) {
        // MonitorValueDrum commits one supported detent on release at 56 points.
        let center = drum.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -direction * 56, dy: 0)))
    }

    private func exerciseAssists() throws {
        try revealPalette()
        for identifier in ["monitor.assist.PEAK", "monitor.assist.FALSE"] {
            let source = try freshLive("assist-before")
            let button = app.buttons[identifier]
            try require(button.isHittable, "Required common assist is unavailable: " + identifier)
            let original = try switchValue(button)
            originalAssists[identifier] = original
            dirtyAssists.insert(identifier)
            button.tap()
            try wait("Assist must toggle through its public control", timeout: 5) {
                button.value as? String == (original == "On" ? "Off" : "On")
            }
            _ = try advancingLive("assist-enabled-owner", from: source)
            try restoreAssist(identifier)
        }
        let source = try freshLive("assist-inspector-before")
        try revealPalette()
        app.buttons["monitor.assist.FALSE"].press(forDuration: 0.6)
        try wait("Common assist inspector", timeout: 5) { self.app.otherElements["monitor.inspector"].exists }
        for title in ["False Color", "Zebra", "Peaking"] {
            try tap(app.buttons[title].firstMatch, "Assist inspector " + title)
            try wait("Inspector close control " + title, timeout: 5) {
                self.app.buttons["Close " + title].isHittable
            }
            evidence("assist-inspector-" + title)
        }
        try tap(app.buttons["Close Peaking"], "Close assist inspector")
        _ = try advancingLive("assist-inspector-owner", from: source)
        mark("operator-assists-and-inspector")
    }

    private func restoreAssist(_ identifier: String) throws {
        try dismissToLive()
        try revealPalette()
        guard let original = originalAssists[identifier] else { return }
        let button = app.buttons[identifier]
        let current = try switchValue(button)
        if current != original { try tap(button, "Restore " + identifier) }
        try wait("Original assist restored", timeout: 5) { button.value as? String == original }
        dirtyAssists.remove(identifier)
    }

    private func revealPalette() throws {
        let button = paletteHandle
        try wait("Assist palette control", timeout: 8) { button.isHittable }
        guard button.label == "Show all View Assist tools" || button.label == "Collapse View Assist tools" else {
            throw failure("Assist expansion state must be explicit")
        }
        if originalPaletteExpanded == nil { originalPaletteExpanded = button.label == "Collapse View Assist tools" }
        if button.label == "Show all View Assist tools" { button.tap() }
        try wait("Expanded assist palette", timeout: 5) { button.label == "Collapse View Assist tools" }
    }

    private func restorePalette() throws {
        guard let originalPaletteExpanded else { return }
        try dismissToLive()
        let button = paletteHandle
        try wait("Palette restoration control", timeout: 8) { button.isHittable }
        let wanted = originalPaletteExpanded ? "Collapse View Assist tools" : "Show all View Assist tools"
        if button.label != wanted { button.tap() }
        try wait("Original palette presentation restored", timeout: 5) { button.label == wanted }
    }

    private var paletteHandle: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["monitor.assists.expand", "monitor.assists.collapse"])).firstMatch
    }

    private func exerciseSettings() throws {
        let source = try freshLive("settings-before")
        try openControlsSettings()
        let haptics = app.buttons["Haptics"].firstMatch
        let original = try switchValue(haptics)
        originalHaptics = original
        recordConfirmation = try switchValue(app.buttons["Record confirmation"].firstMatch) == "On"
        hapticsDirty = true
        try tap(haptics, "Change common Haptics preference")
        try wait("Changed preference", timeout: 5) {
            haptics.value as? String == (original == "On" ? "Off" : "On")
        }
        evidence("settings-changed")
        try closeSettings()
        _ = try advancingLive("settings-preserved-owner", from: source)
        mark("settings-cover-preserves-live-owner")
    }

    private func openControlsSettings() throws {
        try dismissToLive()
        try tap(app.buttons["monitor.system.settings"], "Operator Setup")
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.settings.tab."))
        try wait("Operator settings tabs", timeout: 8) { tabs.count > 0 }
        if originalSettingsTab == nil {
            guard let selected = tabs.allElementsBoundByIndex.first(where: \.isSelected) else {
                throw failure("Original settings tab is unavailable")
            }
            originalSettingsTab = selected.identifier
        }
        let controls = app.buttons["monitor.settings.tab.Controls"]
        try reveal(controls, in: app.scrollViews["monitor.settings.tabs"], horizontal: true)
        try tap(controls, "Controls settings")
        let haptics = app.buttons["Haptics"].firstMatch
        let content = app.scrollViews.allElementsBoundByIndex.first { $0.buttons["Haptics"].exists }
        if let content { try reveal(haptics, in: content, horizontal: false) }
        try require(haptics.isHittable, "Common Haptics setting must be reachable")
    }

    private func closeSettings() throws {
        if let originalSettingsTab {
            let tab = app.buttons[originalSettingsTab]
            try reveal(tab, in: app.scrollViews["monitor.settings.tabs"], horizontal: true)
            try tap(tab, "Restore original settings tab")
        }
        try tap(app.buttons["monitor.page.back"], "Back to live from settings")
    }

    private func restoreHaptics() throws {
        guard hapticsDirty, let originalHaptics else { return }
        try openControlsSettings()
        let button = app.buttons["Haptics"].firstMatch
        if try switchValue(button) != originalHaptics { try tap(button, "Restore Haptics") }
        try wait("Original Haptics restored", timeout: 5) { button.value as? String == originalHaptics }
        hapticsDirty = false
        evidence("settings-original-restored")
        try closeSettings()
    }

    private func exerciseRotation() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            let source = try freshLive("rotation-before")
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            var previous: [CGRect] = []
            var stableSince = Date()
            try wait("Rotation must settle with reachable capture controls", timeout: 10) {
                let appFrame = self.app.frame
                guard (appFrame.height > appFrame.width) == portrait else { return false }
                let record = self.app.buttons["monitor.system.record"]
                guard record.exists else { return false }
                let recordFrame = record.frame
                guard !recordFrame.isEmpty, appFrame.contains(recordFrame) else { return false }
                let frames = [appFrame, recordFrame]
                if frames != previous { previous = frames; stableSince = Date(); return false }
                // XCTest can abort on an invalid activation point while rotation is still laying
                // out. Read hittability only after the expected orientation and frames settle.
                guard Date().timeIntervalSince(stableSince) >= 0.4 else { return false }
                return record.isHittable
            }
            _ = try advancingLive("rotation-owner-" + String(orientation.rawValue), from: source)
            try pictureEvidence("rotation-picture-" + String(orientation.rawValue), role: "live", identity: source.identity)
        }
        mark("rotation-preserves-live-owner")
    }

    private func exerciseBackgroundRecovery() throws {
        let source = try freshLive("background-before")
        evidence("background-before")
        XCUIDevice.shared.press(.home)
        try wait("Actual background lifecycle", timeout: 8) {
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        }
        let foregroundAt = Date().timeIntervalSince1970
        app.activate()
        try wait("Actual foreground lifecycle", timeout: 8) { self.app.state == .runningForeground }
        let recovered = try freshLive("foreground-recovered", since: foregroundAt)
        try require(recovered.frameAt > source.frameAt, "Foreground must not reuse the old source frame date")
        if recovered.identity == source.identity {
            try require(countersAdvanced(recovered.probe, after: source.probe), "Available source counters must advance")
        }
        try reportedRecording(false, source: recovered.identity, stage: "foreground-idle")
        try pictureEvidence("foreground-picture", role: "live", identity: recovered.identity)
        mark("background-and-fresh-source-recovery")
    }

    private func recordShortClip() throws {
        let source = try freshLive("recording-before")
        try reportedRecording(false, source: source.identity, stage: "recording-idle")
        try setRecording(true, source: source.identity)
        let confirmedAt = ProcessInfo.processInfo.systemUptime
        evidence("short-recording-confirmed-by-raw-camera-report")
        var interrupted = false
        try wait("Camera must remain recording for approximately two seconds", timeout: 5) {
            guard let current = self.observed("live"),
                let live = self.liveSource(current), live.identity == source.identity,
                current.cameraRecording == true, live.frameAt > source.frameAt
            else { interrupted = true; return true }
            return ProcessInfo.processInfo.systemUptime - confirmedAt >= 2
        }
        try require(!interrupted, "A lost source or raw recording report invalidates the continuous short recording")
        try setRecording(false, source: source.identity)
        recordingStartIssued = false
        evidence("short-recording-stopped-by-camera-report")
        mark("short-camera-confirmed-recording")
    }

    private func setRecording(_ start: Bool, source: String) throws {
        guard let confirmation = recordConfirmation else { throw failure("Record confirmation preference is unknown") }
        try reportedRecording(!start, source: source, stage: start ? "start-admission" : "stop-admission")
        let button = app.buttons["monitor.system.record"]
        try require(
            button.label == (start ? "Start recording" : "Stop recording"),
            "The public record action must match the raw camera report")
        if start { recordingSourceIdentity = source }
        if start && !confirmation { recordingStartIssued = true }
        try tap(button, start ? "Start recording" : "Stop owned recording")
        if confirmation {
            let confirm = app.buttons[start ? "Start" : "Stop"].firstMatch
            try wait("Public recording confirmation", timeout: 5) { confirm.isHittable }
            try reportedRecording(!start, source: source, stage: "record-confirmation-admission")
            if start { recordingStartIssued = true }
            try tap(confirm, "Confirm recording action")
        }
        try reportedRecording(start, source: source, stage: start ? "recording-confirmed" : "recording-stopped")
    }

    private func catalogue(_ stage: String) throws -> Catalogue {
        try dismissToLive()
        try tap(app.buttons["monitor.system.media"], "Real camera media")
        let gallery = app.scrollViews["monitor.media.gallery"]
        try wait("Production media gallery", timeout: 15) { gallery.exists }
        let categories = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.media.category."))
        try wait("Media categories", timeout: 10) { categories.count > 0 }
        if originalMediaCategory == nil {
            guard let selected = categories.allElementsBoundByIndex.first(where: \.isSelected) else {
                throw failure("Original media category is unknown")
            }
            originalMediaCategory = selected.identifier
        }
        let all = categories.allElementsBoundByIndex.first { $0.label == "Show All media" }
        guard let all else { throw failure("A complete All-media catalogue is required") }
        if !all.isSelected { mediaCategoryDirty = true; try tap(all, "All media") }
        let filter = app.buttons["monitor.media.filter"]
        try require(filter.exists && filter.value as? String == "Off", "Preserved media filters must permit a complete catalogue")
        try scrollGalleryToTop(gallery)
        let loading = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
            "Listing", "Loading", "Scanning")).firstMatch
        var count: Int?
        var previousCount: Int?
        var settledAt = Date()
        try wait("Complete camera catalogue count", timeout: 45) {
            guard !loading.exists else { settledAt = Date(); return false }
            count = self.categoryCount(all)
            if count != previousCount { previousCount = count; settledAt = Date(); return false }
            return count != nil && Date().timeIntervalSince(settledAt) >= 1
        }
        guard let count else { throw failure("All-media count is unknown") }
        try require(count >= 0 && count <= 2_000, "The bounded catalogue inventory supports at most 2,000 assets")
        var identifiers: Set<String> = []
        for _ in 0..<160 {
            // One immutable public hierarchy supplies this page, including offscreen nodes.
            var pageIdentifiers: Set<String> = []
            var pending = try app.snapshot().children
            while let node = pending.popLast() {
                let identifier = node.identifier
                if identifier.hasPrefix("monitor.media.clip.") { pageIdentifiers.insert(identifier) }
                pending.append(contentsOf: node.children)
            }
            if identifiers.isEmpty {
                let queried = Set(mediaCells().map(\.identifier))
                try require(queried == pageIdentifiers, "Public snapshot and original media query must agree before recording")
                encodedEvidence(stage + "-first-page-snapshot-equivalence", [
                    "snapshot": pageIdentifiers.sorted(), "originalQuery": queried.sorted(),
                ])
            }
            identifiers.formUnion(pageIdentifiers)
            if identifiers.count == count { break }
            try require(identifiers.count < count, "Catalogue identifiers exceed its declared All count")
            gallery.swipeUp()
            try settleGallery(gallery)
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

    private func settleGallery(_ gallery: XCUIElement) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var previous = ""
        var stableSince = Date()
        let predicate: @MainActor () -> Bool = {
            guard let signature = self.gallerySettleSignature() else {
                stableSince = Date(); return false
            }
            if signature != previous { previous = signature; stableSince = Date(); return false }
            return gallery.exists && Date().timeIntervalSince(stableSince) >= 0.4
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            let settled = predicate()
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if settled { return }
        }
        throw failure("Native gallery scroll must settle" + (lastProbeFailure.map { ". " + $0 } ?? ""))
    }

    private func gallerySettleSignature() -> String? {
        // Passive scroll observation uses one immutable public snapshot. Native
        // target hittability is still required by the actual action helpers.
        guard let snapshot = try? app.snapshot() else { return nil }
        var pending = snapshot.children.enumerated().reversed().map {
            (node: $0.element, path: [$0.offset], insideGallery: false)
        }
        var gallerySeen = false
        var seen: Set<String> = []
        var projection: [[String: Any]] = []
        while let entry = pending.popLast() {
            let node = entry.node
            let identifier = node.identifier
            let isGallery = identifier == "monitor.media.gallery"
            let isClip = identifier.hasPrefix("monitor.media.clip.")
            if isGallery || isClip {
                let frame = node.frame
                let coordinates = [frame.origin.x, frame.origin.y, frame.width, frame.height]
                guard coordinates.allSatisfy({ $0.isFinite }) else { return nil }
                if isGallery {
                    guard !gallerySeen, node.elementType == .scrollView,
                        [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite }),
                        frame.width > 0, frame.height > 0
                    else { return nil }
                    gallerySeen = true
                } else {
                    guard seen.insert(identifier).inserted else { return nil }
                }
                projection.append([
                    "identifier": identifier,
                    "type": String(node.elementType.rawValue),
                    "frame": coordinates.map(Double.init),
                    "path": entry.path,
                    "insideGallery": entry.insideGallery,
                ])
            }
            for child in node.children.enumerated().reversed() {
                pending.append((
                    node: child.element, path: entry.path + [child.offset],
                    insideGallery: entry.insideGallery || isGallery))
            }
        }
        guard gallerySeen,
            let data = try? JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func openClip(_ identifier: String) throws {
        let gallery = app.scrollViews["monitor.media.gallery"]
        try require(gallery.exists, "Clip selection requires the public camera catalogue")
        let clip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        func artworkTargetIsReachable() -> Bool {
            guard clip.isHittable else { return false }
            let cell = clip.frame, viewport = gallery.frame
            guard [cell.minX, cell.minY, cell.width, cell.height,
                   viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy({ $0.isFinite }),
                cell.width > 0, cell.height > 0, viewport.width > 0, viewport.height > 0
            else { return false }
            // A visible caption can make a clipped cell hittable while its artwork is above the gallery.
            let point = CGPoint(x: cell.minX + cell.width * 0.5, y: cell.minY + cell.height * 0.35)
            return viewport.contains(point)
        }
        for _ in 0..<160 where !artworkTargetIsReachable() { gallery.swipeDown(); try settleGallery(gallery) }
        try require(artworkTargetIsReachable(), "New qualification clip artwork must be publicly reachable in its gallery")
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
        try require(artworkTargetIsReachable(), "The qualification artwork tap must remain inside its gallery")
        clip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        try wait("Native player for the selected qualification filename", timeout: 45) {
            self.app.buttons["monitor.playback.back"].isHittable && self.app.staticTexts[filename].firstMatch.exists
        }
        jsonEvidence("qualification-playback-selection", ["identifier": identifier, "filename": filename])
    }

    private func scrollGalleryToTop(_ gallery: XCUIElement) throws {
        // Restored gallery scroll positions must not hide existing assets from
        // the inventory. A stationary visible signature bounds the top search.
        for _ in 0..<160 {
            let before = gallerySignature()
            gallery.swipeDown()
            try settleGallery(gallery)
            if gallerySignature() == before { return }
        }
        throw failure("The bounded catalogue traversal did not reach its beginning")
    }

    private func gallerySignature() -> String {
        mediaCells().filter(\.isHittable).map {
            $0.identifier + ":" + String(Int($0.frame.minY.rounded()))
        }.joined(separator: "|")
    }

    private func exercisePlayback(_ item: PlaybackSource, stage: String) throws {
        try restartPlayback(item)
        let before = try readyPlayback(stage + "-before", captured: item)
        try wait("Actual native playback position advances", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position > before.position + 0.15
        }
        try pictureEvidence(stage + "-picture", role: "playback", identity: item.identity, ownerToken: item.ownerToken)
        // Reset the short clip before testing transport so reaching its natural
        // end cannot masquerade as a successful Pause command.
        try restartPlayback(item)
        try tap(app.buttons["Pause"].firstMatch, "Pause actual native playback")
        try wait("Pause exposes Play", timeout: 5) { self.app.buttons["Play"].firstMatch.isHittable }
        var anchor: Double?
        var stableSince = ProcessInfo.processInfo.systemUptime
        try wait("Pause must stop actual native position", timeout: 5) {
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
        let paused = try readyPlayback(stage + "-paused", captured: item)
        evidence(stage + "-paused")
        try tap(app.buttons["Play"].firstMatch, "Resume actual native playback")
        try wait("Play must resume actual native position", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position > paused.position + 0.15
        }
        try pictureEvidence(stage + "-resumed-picture", role: "playback", identity: item.identity, ownerToken: item.ownerToken)
    }

    private func restartPlayback(_ item: PlaybackSource) throws {
        _ = try readyPlayback("playback-reset-ready", captured: item)
        // One transport button reads Pause, Play or Restart clip. A short clip can end between
        // reading Pause and tapping it, so tap through a query that matches every label and re-read:
        // a tap that landed on Restart clip plays again and the next pass pauses it.
        let play = app.buttons["Play"].firstMatch, restart = app.buttons["Restart clip"].firstMatch
        let transport = app.buttons.matching(NSPredicate(format: "label IN %@", ["Pause", "Play", "Restart clip"])).firstMatch
        for _ in 0..<3 where !play.isHittable && !restart.isHittable {
            try tap(transport, "Pause or restart the short clip")
            _ = condition(timeout: 3) { play.isHittable }
        }
        try require(play.isHittable || restart.isHittable, "The short clip must be paused or ended before its reset")
        try tap(app.buttons["Back 15 seconds"].firstMatch, "Seek short clip to its beginning")
        try wait("Actual native seek to beginning", timeout: 5) {
            guard let current = self.playbackSource(self.observed("playback")) else { return false }
            return current.matches(item) && current.position <= 0.15
        }
        if restart.isHittable { restart.tap() }
        else { try tap(play, "Play from beginning") }
        // The cheap transport read goes first: on a busy app one probe read takes several seconds,
        // and a failure names the label the transport showed instead.
        try wait("Native player exposes Pause", timeout: 5) {
            guard self.app.buttons["Pause"].firstMatch.isHittable else {
                self.lastProbeFailure = "Transport reads " + (transport.exists ? transport.label : "no transport button")
                return false
            }
            return self.playbackSource(self.observed("playback"))?.matches(item) == true
        }
    }

    private func exerciseSavedRelaunch(clipID: String) throws {
        try require(!recordingStartIssued && !isoDirty, "Recording and ISO must be restored before relaunch")
        app.terminate()
        try wait("Actual app termination", timeout: 8) { self.app.state == .notRunning }
        let relaunchedAt = Date().timeIntervalSince1970
        app.launch()
        try connectThroughUI(savedOnly: true)
        let source = try freshLive("saved-relaunch-live", since: relaunchedAt)
        try reportedRecording(false, source: source.identity, stage: "saved-relaunch-idle")
        guard let originalISO else { throw failure("Original ISO report is unavailable") }
        switch originalISO {
        case .manual(let value, let isAuto):
            try reportedISO(value, source: source.identity, isAuto: isAuto, stage: "saved-relaunch-ISO")
        case .automatic(let label):
            try wait("Saved relaunch must preserve raw Auto ISO mode", timeout: 12) {
                guard let current = self.observed("live"), current.sourceIdentity == source.identity,
                    current.cameraISOIsAuto == true, current.cameraRecording == false
                else { return false }
                if let iso = current.cameraISO { return iso > 0 }
                return true
            }
            try tap(app.buttons["monitor.capture.iso"], "Read saved Auto ISO setting")
            let drum = app.descendants(matching: .any)["Value"].firstMatch
            try wait("Exact saved Auto/range selection", timeout: 8) { drum.value as? String == label }
            evidence("saved-relaunch-Auto-ISO")
            try tap(app.buttons["monitor.capture.close"], "Close saved Auto ISO setting")
        }
        try pictureEvidence("saved-relaunch-picture", role: "live", identity: source.identity)
        try openControlsSettings()
        guard let originalHaptics, let recordConfirmation else {
            throw failure("Original Haptics or record-confirmation preference is unavailable")
        }
        try require(
            try switchValue(app.buttons["Haptics"].firstMatch) == (originalHaptics == "On" ? "Off" : "On"),
            "The changed operator preference must persist across relaunch")
        try require(
            try switchValue(app.buttons["Record confirmation"].firstMatch) == (recordConfirmation ? "On" : "Off"),
            "Record confirmation preference must remain unchanged")
        try closeSettings()
        _ = try advancingLive("saved-relaunch-settings-owner", from: source)
        let persisted = try catalogue("saved-relaunch")
        try require(persisted.identifiers.contains(clipID), "The qualification clip must remain after relaunch")
        try returnToLive("saved-relaunch-return")
        mark("saved-connection-media-and-preference-persistence")
    }

    private func returnToLive(_ stage: String) throws {
        try restoreMediaCategory()
        let closedAt = Date().timeIntervalSince1970
        try tap(app.buttons["monitor.page.back"], "Return from media to live")
        let current = try freshLive(stage, since: closedAt)
        try reportedRecording(false, source: current.identity, stage: stage + "-idle")
        try pictureEvidence(stage + "-picture", role: "live", identity: current.identity)
    }

    private func restoreMediaCategory() throws {
        guard mediaCategoryDirty, let originalMediaCategory else { return }
        if !app.scrollViews["monitor.media.gallery"].exists {
            try dismissToLive()
            try tap(app.buttons["monitor.system.media"], "Restore media category")
        }
        let category = app.buttons[originalMediaCategory]
        try tap(category, "Restore original media category")
        try wait("Original media category restored", timeout: 5) { category.isSelected }
        mediaCategoryDirty = false
    }

    private func dismissToLive() throws {
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
        try wait("Live capture controls", timeout: 20) {
            self.app.buttons["monitor.system.record"].isHittable && self.app.buttons["monitor.system.settings"].isHittable
        }
    }

    private func freshLive(_ stage: String, since: Double? = nil) throws -> LiveSource {
        var result: LiveSource?
        try wait("Fresh active native live source: " + stage, timeout: 25) {
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

    private func advancingLive(_ stage: String, from previous: LiveSource) throws -> LiveSource {
        var result: LiveSource?
        try wait("Live owner and actual source frames must advance: " + stage, timeout: 12) {
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

    private func readyPlayback(_ stage: String, captured: PlaybackSource? = nil) throws -> PlaybackSource {
        var result: PlaybackSource?
        try wait("Actual native playback item and ready picture: " + stage, timeout: 45) {
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

    private func reportedRecording(_ recording: Bool, source: String, stage: String) throws {
        try wait("Raw camera recording report: " + stage, timeout: 15) {
            guard let probe = self.observed("live"), let current = self.liveSource(probe) else { return false }
            return current.identity == source && probe.cameraRecording == recording
        }
    }

    private func reportedISO(_ iso: Int, source: String, isAuto: Bool? = nil, stage: String) throws {
        try wait("Raw camera ISO report: " + stage, timeout: 12) {
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

    private func tap(_ element: XCUIElement, _ action: String) throws {
        try wait("Reachable public action: " + action, timeout: 8) { element.isHittable && element.isEnabled }
        element.tap()
    }

    private func condition(timeout: TimeInterval, _ predicate: @MainActor () -> Bool) -> Bool {
        // ponytail: a main-thread poll; the queries it reads are main-actor XCUI calls anyway.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }

    private func wait(_ message: String, timeout: TimeInterval, _ predicate: @MainActor () -> Bool) throws {
        if !condition(timeout: timeout, predicate) {
            throw failure(message + (lastProbeFailure.map { ". " + $0 } ?? ""))
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private func cleanup(_ name: String, _ action: () throws -> Void) {
        do { try action() }
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
