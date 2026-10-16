#if os(iOS)
import UIKit
import XCTest

/// Opt-in driver for the vendor reference app during a phone RVI capture.
/// `OPV_REFERENCE_TAPS` is a `|`-separated list of accessibility labels (or
/// `@x,y` normalized coordinates) tapped in order; `OPV_REFERENCE_DWELL` is how
/// long to stay afterwards. Each run attaches the element tree and screenshots.
/// `OPV_REFERENCE_ORIENTATION` optionally selects portrait or either landscape;
/// the driver's original device orientation is restored after the capture.
open class PhysicalReferenceAppTests: SharedAppUITestCase {
    /// Explicit cleanup after an interrupted owned run, separate from qualification.
    func testRestoreOwnedDeviceOrientation() throws {
        guard let requested = ProcessInfo.processInfo.environment["OPV_OWNED_RESTORE_ORIENTATION"] else {
            throw XCTSkip("Requires an explicitly recorded owned orientation to restore")
        }
        let orientation: UIDeviceOrientation
        switch requested {
        case "portrait": orientation = .portrait
        case "portrait-upside-down": orientation = .portraitUpsideDown
        case "landscape-left": orientation = .landscapeLeft
        case "landscape-right": orientation = .landscapeRight
        default:
            XCTFail("Unsupported owned restore orientation")
            return
        }
        XCUIDevice.shared.orientation = orientation
        XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "owned-device-orientation-restored-\(requested)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Restores explicitly captured local assist preferences after an interrupted owned run.
    /// This cleanup is separate from qualification and never starts a camera operation.
    func testRestoreOwnedMonitorOptions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["OPV_OWNED_RESTORE_MONITOR_OPTIONS_JSON"] else {
            throw XCTSkip("Requires explicitly captured owned monitor settings")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Owned monitor cleanup requires the physical camera and device")
        #endif
        let state = try JSONDecoder().decode(OwnedMonitorOptionsState.self, from: Data(raw.utf8))
        guard let bundle = env["OPV_REFERENCE_BUNDLE"], !bundle.isEmpty,
            let orientation = UIDeviceOrientation(rawValue: state.orientation),
            [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(orientation),
            [state.falseColor, state.mirror, state.horizontal, state.vertical, state.referenceDisplay]
                .allSatisfy({ ["On", "Off"].contains($0) }),
            ["CineStop", "Video", "IRE", "Limits"].contains(state.scale),
            ["LOG", "709"].contains(state.read) else {
            throw ReferenceOptionsFailure("Captured monitor cleanup state is invalid")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchEnvironment["OPV_PHYSICAL_UI_REVIEW"] = "1"
        var cleanupSourceIdentity: String?
        defer {
            do { try optionsClose(app) } catch { XCTFail("Owned inspector cleanup failed: \(error)") }
            if let identity = cleanupSourceIdentity {
                do {
                    guard try optionsLiveProbe(app).sourceIdentity == identity else {
                        throw ReferenceOptionsFailure("Owned palette cleanup source was retired")
                    }
                    try optionsRestorePalette(app, expanded: state.paletteExpanded)
                } catch {
                    XCTFail("Owned palette cleanup failed: \(error)")
                }
            }
            XCUIDevice.shared.orientation = orientation
            XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
            snapshot(app, "owned-monitor-options-restoration")
        }
        // This explicit cleanup uses the horizontal palette, then restores the captured orientation.
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        if let label = env["OPV_OWNED_RESTORE_CONNECT_LABEL"] {
            let connect = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if connect.waitForExistence(timeout: 10) { tapWhenReady(connect, in: app) }
        }
        waitForLaunchSplash(in: app)
        let source = try optionsLiveProbe(app)
        guard let identity = source.sourceIdentity else {
            throw ReferenceOptionsFailure("Owned monitor cleanup requires a native source identity")
        }
        cleanupSourceIdentity = identity
        try optionsOpen(app, tool: "FALSE")
        try optionsSelect(app, label: state.scale)
        try optionsSelect(app, label: state.read)
        try optionsSet(app, label: "Reference Display", value: state.referenceDisplay)
        try optionsClose(app)
        guard try optionsLiveProbe(app).sourceIdentity == identity else {
            throw ReferenceOptionsFailure("Owned cleanup source was retired")
        }
        try optionsOpen(app, tool: "MIRROR")
        try optionsSet(app, identifier: "mirror.horizontal", value: state.horizontal)
        try optionsSet(app, identifier: "mirror.vertical", value: state.vertical)
        try optionsClose(app)
        try optionsSetTool(app, tool: "FALSE", value: state.falseColor)
        try optionsSetTool(app, tool: "MIRROR", value: state.mirror)
        try optionsRestorePalette(app, expanded: state.paletteExpanded)
        guard try optionsLiveProbe(app).sourceIdentity == identity else {
            throw ReferenceOptionsFailure("Owned cleanup did not finish on its fresh idle source")
        }
        let probe = app.descendants(matching: .any).matching(identifier: "opencine.native.qualification")
            .allElementsBoundByIndex.compactMap { $0.value as? String }.joined(separator: "\n")
        let evidence = XCTAttachment(string: probe)
        evidence.name = "owned-monitor-options-restored-native-probe"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testDriveReferenceApp() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundle = env["OPV_REFERENCE_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("Requires the opted-in reference capture run")
        }
        let originalOrientation = XCUIDevice.shared.orientation
        let requestedOrientation = env["OPV_REFERENCE_ORIENTATION"]
        defer {
            if requestedOrientation != nil { XCUIDevice.shared.orientation = originalOrientation }
        }
        if let requestedOrientation {
            switch requestedOrientation {
            case "portrait": XCUIDevice.shared.orientation = .portrait
            case "landscape-left": XCUIDevice.shared.orientation = .landscapeLeft
            case "landscape-right": XCUIDevice.shared.orientation = .landscapeRight
            default:
                XCTFail("Unsupported reference capture orientation")
                return
            }
        }
        let verifyMonitorOptions = env["OPV_REFERENCE_MONITOR_OPTIONS"] == "1"
        if verifyMonitorOptions {
            guard env["OPV_REFERENCE_LAUNCH"] == "1" else {
                throw ReferenceOptionsFailure("Monitor option verification requires an owned fresh launch")
            }
            #if targetEnvironment(simulator)
            throw XCTSkip("Monitor option verification requires a physical camera and device")
            #endif
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        if verifyMonitorOptions { app.launchEnvironment["OPV_PHYSICAL_UI_REVIEW"] = "1" }
        if env["OPV_REFERENCE_LAUNCH"] == "1" { app.launch() } else { app.activate() }
        waitForLaunchSplash(in: app)
        snapshot(app, "start")
        let taps = (env["OPV_REFERENCE_TAPS"] ?? "").split(separator: "|").map(String.init)
        for (index, entry) in taps.enumerated() {
            // `?label` is optional: a system prompt that may or may not appear.
            let optional = entry.hasPrefix("?")
            let target = optional ? String(entry.dropFirst()) : entry
            if target.hasPrefix("@") {
                let parts = target.dropFirst().split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                app.coordinate(withNormalizedOffset: CGVector(dx: parts[0], dy: parts[1])).tap()
            } else if target.hasPrefix("cc:") {
                // Control Center makes the scene inactive without backgrounding.
                let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.001))
                    .press(forDuration: 0.1, thenDragTo:
                        board.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
                Thread.sleep(forTimeInterval: Double(target.dropFirst(3)) ?? 10)
                snapshot(app, "control-center-\(index)")
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
                    .press(forDuration: 0.1, thenDragTo:
                        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            } else if target.hasPrefix("bt:") {
                // Bluetooth off in Control Center drops the camera BLE link.
                let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.001))
                    .press(forDuration: 0.1, thenDragTo:
                        board.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
                Thread.sleep(forTimeInterval: 1.5)
                let toggle = board.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.47))
                toggle.tap()
                snapshot(app, "bt-off-\(index)")
                Thread.sleep(forTimeInterval: Double(target.dropFirst(3)) ?? 5)
                toggle.tap()
                Thread.sleep(forTimeInterval: 1)
                snapshot(app, "bt-on-\(index)")
                board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
                    .press(forDuration: 0.1, thenDragTo:
                        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            } else if target.hasPrefix("bg:") {
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: Double(target.dropFirst(3)) ?? 5)
                app.activate()
            } else if target.hasPrefix("~") {
                Thread.sleep(forTimeInterval: Double(target.dropFirst()) ?? 1)
                continue
            } else {
                // System prompts (Wi-Fi join, permissions) live in SpringBoard.
                let match = NSPredicate(format: "label == %@ OR identifier == %@", target, target)
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let inApp = app.descendants(matching: .any).matching(match).firstMatch
                let inSystem = springboard.descendants(matching: .any).matching(match).firstMatch
                let found = NSPredicate { _, _ in inApp.exists || inSystem.exists }
                let waited = XCTNSPredicateExpectation(predicate: found, object: nil)
                let element = XCTWaiter.wait(for: [waited], timeout: 10) == .completed
                    ? (inSystem.exists ? inSystem : inApp) : inApp
                guard element.exists else {
                    if optional { continue }
                    snapshot(app, "missing-\(index)")
                    XCTFail("no element \(target)")
                    return
                }
                if element.exists { element.tap() }
            }
            Thread.sleep(forTimeInterval: 2)
            snapshot(app, "after-\(index)")
        }
        if verifyMonitorOptions {
            try verifyCanonicalMonitorOptions(app)
            snapshot(app, "end")
            return
        }
        let dwell = Double(env["OPV_REFERENCE_DWELL"] ?? "0") ?? 0
        let end = Date().addingTimeInterval(dwell)
        var shot = 0
        while Date() < end {
            Thread.sleep(forTimeInterval: min(60, max(0, end.timeIntervalSinceNow)))
            shot += 1
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "dwell-\(shot)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        snapshot(app, "end")
    }


    private struct ReferenceOptionsFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct OwnedMonitorOptionsState: Decodable {
        let falseColor: String
        let horizontal: String
        let mirror: String
        let orientation: Int
        let paletteExpanded: Bool
        let read: String
        let referenceDisplay: String
        let scale: String
        let vertical: String
    }

    // A subset of the existing native qualification JSON, with no integration import.
    private struct ReferenceOptionsProbe: Decodable {
        let simulated: Bool
        let role: String?
        let sourceIdentity: String?
        let sourceActive: Bool?
        let sourceFrameAt: Double?
        let sourcePresentations: Int?
        let nativeDecodeOutputs: Int?
        let cameraRecording: Bool?
        let pictureBounds: [Double]?
    }

    private func verifyCanonicalMonitorOptions(_ app: XCUIApplication) throws {
        let scales = ["CineStop", "Video", "IRE", "Limits"]
        let reads = ["LOG", "709"]
        let originalOrientation = XCUIDevice.shared.orientation
        let knownOrientations: [UIDeviceOrientation] = [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
        guard knownOrientations.contains(originalOrientation) else {
            throw ReferenceOptionsFailure("Original device orientation is unknown")
        }
        let source = try optionsLiveProbe(app)
        guard let identity = source.sourceIdentity else {
            throw ReferenceOptionsFailure("Native live source identity is unavailable")
        }
        guard optionsInspectorQuery(app).count == 0 else {
            throw ReferenceOptionsFailure("An inspector is already presented")
        }
        let handle = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["monitor.assists.expand", "monitor.assists.collapse"])).firstMatch
        try optionsWait("Actual palette state is unavailable") {
            handle.exists && handle.isHittable
                && ["monitor.assists.expand", "monitor.assists.collapse"].contains(handle.identifier)
        }
        let originalExpanded = handle.identifier == "monitor.assists.collapse"
        var originalFalse: String?
        var originalMirror: String?
        var originalScale: String?
        var originalRead: String?
        var originalReference: String?
        var originalHorizontal: String?
        var originalVertical: String?
        var completed: [String] = []

        // Every captured value is restored even if a later selection or capture throws.
        defer {
            var restorationFailures = 0
            func attempt(_ body: () throws -> Void) {
                do { try body() } catch {
                    restorationFailures += 1
                    XCTFail("Monitor option restoration failed: \(error)")
                }
            }
            attempt { try optionsClose(app) }
            attempt {
                let current = try optionsLiveProbe(app)
                guard current.sourceIdentity == identity else {
                    throw ReferenceOptionsFailure("Original native source was retired; assist restoration withheld")
                }
                if let originalScale, let originalRead, let originalReference {
                    try optionsOpen(app, tool: "FALSE")
                    defer { try? optionsClose(app) }
                    attempt { try optionsSelect(app, label: originalScale) }
                    attempt { try optionsSelect(app, label: originalRead) }
                    attempt { try optionsSet(app, label: "Reference Display", value: originalReference) }
                }
            }
            attempt {
                guard try optionsLiveProbe(app).sourceIdentity == identity else {
                    throw ReferenceOptionsFailure("Original native source was retired; mirror restoration withheld")
                }
                if let originalHorizontal, let originalVertical {
                    try optionsOpen(app, tool: "MIRROR")
                    defer { try? optionsClose(app) }
                    attempt { try optionsSet(app, identifier: "mirror.horizontal", value: originalHorizontal) }
                    attempt { try optionsSet(app, identifier: "mirror.vertical", value: originalVertical) }
                }
            }
            attempt { try optionsClose(app) }
            attempt {
                guard try optionsLiveProbe(app).sourceIdentity == identity else {
                    throw ReferenceOptionsFailure("Original native source was retired; tool restoration withheld")
                }
                if let originalFalse { attempt { try optionsSetTool(app, tool: "FALSE", value: originalFalse) } }
                if let originalMirror { attempt { try optionsSetTool(app, tool: "MIRROR", value: originalMirror) } }
                let current = app.buttons[originalExpanded ? "monitor.assists.collapse" : "monitor.assists.expand"]
                if !current.exists {
                    let other = app.buttons[originalExpanded ? "monitor.assists.expand" : "monitor.assists.collapse"]
                    try optionsWait("Palette restoration control is unavailable") { other.isHittable }
                    other.tap()
                }
                try optionsWait("Original palette expansion was not restored") { current.exists }
            }
            XCUIDevice.shared.orientation = originalOrientation
            attempt {
                try optionsWait("Original orientation was not restored") {
                    XCUIDevice.shared.orientation == originalOrientation
                }
            }
            snapshot(app, "monitor-options-restoration-attempt")
            let outcome: [String: Any] = ["completed": completed, "restorationFailures": restorationFailures]
            if let data = try? JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys]) {
                let result = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                result.name = "monitor-options-outcome"; result.lifetime = .keepAlways; add(result)
            } else { XCTFail("Monitor option outcome could not be attached") }
        }

        let falseTool = try optionsTool(app, tool: "FALSE")
        originalFalse = try optionsBoolean(falseTool)
        try optionsOpen(app, tool: "FALSE")
        originalScale = try optionsSelected(app, labels: scales)
        originalRead = try optionsSelected(app, labels: reads)
        originalReference = try optionsBoolean(try optionsButton(app, label: "Reference Display"))
        try optionsClose(app)
        let mirrorTool = try optionsTool(app, tool: "MIRROR")
        originalMirror = try optionsBoolean(mirrorTool)
        try optionsOpen(app, tool: "MIRROR")
        originalHorizontal = try optionsBoolean(try optionsButton(app, identifier: "mirror.horizontal"))
        originalVertical = try optionsBoolean(try optionsButton(app, identifier: "mirror.vertical"))
        try optionsClose(app)
        guard let capturedFalse = originalFalse, let capturedMirror = originalMirror,
            let capturedScale = originalScale, let capturedRead = originalRead,
            let capturedReference = originalReference, let capturedHorizontal = originalHorizontal,
            let capturedVertical = originalVertical else {
            throw ReferenceOptionsFailure("Original monitor options were not fully captured")
        }
        let ledger: [String: Any] = ["paletteExpanded": originalExpanded,
            "falseColor": capturedFalse, "mirror": capturedMirror, "scale": capturedScale,
            "read": capturedRead, "referenceDisplay": capturedReference,
            "horizontal": capturedHorizontal, "vertical": capturedVertical,
            "orientation": originalOrientation.rawValue]
        let original = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        original.name = "monitor-options-original-state"; original.lifetime = .keepAlways; add(original)

        try optionsSetTool(app, tool: "FALSE", value: "On")
        for scale in scales {
            for read in reads {
                let before = try optionsLiveProbe(app)
                try optionsOpen(app, tool: "FALSE")
                try optionsSelect(app, label: scale)
                try optionsSelect(app, label: read)
                snapshot(app, "monitor-options-false-\(scale)-\(read)-menu")
                try optionsClose(app)
                try optionsAdvanced(app, after: before, identity: identity)
                snapshot(app, "monitor-options-false-\(scale)-\(read)-live")
                completed.append("false-\(scale)-\(read)")
            }
        }
        // Isolate the mirror pictures from the preceding false-color presentation.
        try optionsSetTool(app, tool: "FALSE", value: "Off")
        try optionsSetTool(app, tool: "MIRROR", value: "On")
        for axes in [("Off", "Off"), ("On", "Off"), ("Off", "On"), ("On", "On")] {
            let before = try optionsLiveProbe(app)
            try optionsOpen(app, tool: "MIRROR")
            try optionsSet(app, identifier: "mirror.horizontal", value: axes.0)
            try optionsSet(app, identifier: "mirror.vertical", value: axes.1)
            snapshot(app, "monitor-options-mirror-\(axes.0)-\(axes.1)-menu")
            try optionsClose(app)
            try optionsAdvanced(app, after: before, identity: identity)
            snapshot(app, "monitor-options-mirror-\(axes.0)-\(axes.1)-live")
            completed.append("mirror-\(axes.0)-\(axes.1)")
        }
        for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "left"), (.landscapeRight, "right")] {
            let before = try optionsLiveProbe(app)
            XCUIDevice.shared.orientation = orientation
            try optionsWait("Landscape orientation was not reached") { XCUIDevice.shared.orientation == orientation }
            try optionsAdvanced(app, after: before, identity: identity)
            let record = app.buttons["monitor.system.record"]
            try optionsWait("Landscape monitor viewport and record target did not settle") {
                let viewport = app.frame
                return viewport.width > viewport.height && record.isHittable && viewport.contains(record.frame)
            }
            try optionsNativePicture(app, identity: identity, name: "landscape-" + name)
            snapshot(app, "monitor-options-landscape-\(name)")
            completed.append("landscape-\(name)")
        }
    }

    // Match the established whole-workflow native view screenshot and clipping contract.
    // An intentionally cropped/desqueezed raster need not fit inside screen coordinates.
    private func optionsNativePicture(_ app: XCUIApplication, identity: String, name: String) throws {
        let probe = try optionsLiveProbe(app)
        guard probe.sourceIdentity == identity, let values = probe.pictureBounds,
            values.count == 4, values.allSatisfy(\.isFinite), values[2] >= 80, values[3] >= 80 else {
            throw ReferenceOptionsFailure("Actual native picture bounds or source are unavailable")
        }
        let nativeBounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let pictures = app.descendants(matching: .any).matching(identifier: "monitor.native.picture")
            .allElementsBoundByIndex.filter {
                let frame = $0.frame
                return $0.exists && abs(frame.minX - nativeBounds.minX) <= 1
                    && abs(frame.minY - nativeBounds.minY) <= 1
                    && abs(frame.width - nativeBounds.width) <= 1
                    && abs(frame.height - nativeBounds.height) <= 1
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
        let screen = CGRect(origin: .zero, size: screenshot.image.size)
        let visible = screen.intersection(bounds)
        guard !visible.isNull, visible.width >= 80, visible.height >= 80,
            visible.width * visible.height >= bounds.width * bounds.height * 0.95 else {
            throw ReferenceOptionsFailure("The actual native picture crop is not visible within the screenshot")
        }
        guard try optionsLiveProbe(app).sourceIdentity == identity else {
            throw ReferenceOptionsFailure("A successor cannot inherit the native picture screenshot")
        }
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "monitor-options-" + name + "-native-picture"; shot.lifetime = .keepAlways; add(shot)
    }

    private func optionsInspectorQuery(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "monitor.inspector")
    }

    private func optionsWait(_ message: String, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 12) == .completed else {
            throw ReferenceOptionsFailure(message)
        }
    }

    private func optionsLiveProbe(_ app: XCUIApplication) throws -> ReferenceOptionsProbe {
        let rawProbes = app.descendants(matching: .any).matching(identifier: "opencine.native.qualification")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
        func rejection(_ message: String) -> ReferenceOptionsFailure {
            let evidence = XCTAttachment(string: rawProbes.joined(separator: "\n"))
            evidence.name = "monitor-options-rejected-native-probe"
            evidence.lifetime = .keepAlways
            add(evidence)
            return ReferenceOptionsFailure(message)
        }
        let probes = rawProbes.compactMap { raw -> ReferenceOptionsProbe? in
                guard let value = try? JSONDecoder().decode(ReferenceOptionsProbe.self, from: Data(raw.utf8)),
                    value.role == "live" else { return nil }
                return value
            }
        guard probes.count == 1 else { throw rejection("Expected one actual native live probe") }
        let value = probes[0]
        guard !value.simulated, value.sourceActive == true, value.cameraRecording == false,
            let identity = value.sourceIdentity, !identity.isEmpty,
            let frame = value.sourceFrameAt, frame.isFinite,
            (-2 ... 5).contains(Date().timeIntervalSince1970 - frame) else {
            throw rejection("A fresh idle real-camera source is required")
        }
        if let count = value.sourcePresentations, count <= 0 {
            throw rejection("Native source presentations are not positive")
        }
        if let count = value.nativeDecodeOutputs, count <= 0 {
            throw rejection("Native decode outputs are not positive")
        }
        return value
    }

    private func optionsAdvanced(_ app: XCUIApplication, after before: ReferenceOptionsProbe, identity: String) throws {
        try optionsWait("The captured native source did not advance after the option change") {
            guard let value = try? self.optionsLiveProbe(app), value.sourceIdentity == identity,
                let previous = before.sourceFrameAt, let current = value.sourceFrameAt,
                current > previous + 0.15 else { return false }
            if let previous = before.sourcePresentations {
                guard let current = value.sourcePresentations, current > previous else { return false }
            }
            if let previous = before.nativeDecodeOutputs {
                guard let current = value.nativeDecodeOutputs, current > previous else { return false }
            }
            return true
        }
    }

    private func optionsTool(_ app: XCUIApplication, tool: String) throws -> XCUIElement {
        let expand = app.buttons["monitor.assists.expand"]
        if expand.exists { expand.tap() }
        let item = app.buttons["monitor.assist." + tool]
        for direction in [true, false] {
            for _ in 0 ..< 5 {
                if item.exists && item.isHittable { return item }
                let palettes = app.scrollViews.allElementsBoundByIndex.filter {
                    $0.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "monitor.assist.")).count > 0
                }
                guard palettes.count == 1 else { throw ReferenceOptionsFailure("The real tool palette is ambiguous") }
                if direction { palettes[0].swipeLeft() } else { palettes[0].swipeRight() }
            }
        }
        guard item.exists && item.isHittable else { throw ReferenceOptionsFailure("The requested tool is not hittable") }
        return item
    }

    private func optionsOpen(_ app: XCUIApplication, tool: String) throws {
        try optionsClose(app)
        let item = try optionsTool(app, tool: tool)
        item.press(forDuration: 0.6)
        try optionsWait("The actual tool inspector did not open") {
            let query = self.optionsInspectorQuery(app)
            return query.count == 1
                && query.element(boundBy: 0).buttons["monitor.assist.options." + tool].isSelected
        }
    }

    private func optionsClose(_ app: XCUIApplication) throws {
        let query = optionsInspectorQuery(app)
        guard query.count > 0 else { return }
        guard query.count == 1 else { throw ReferenceOptionsFailure("The actual inspector is ambiguous") }
        let inspector = query.element(boundBy: 0)
        let close = inspector.buttons["monitor.assist.close"]
        try optionsWait("The inspector Close control is not hittable") { close.exists && close.isHittable }
        close.tap()
        try optionsWait("The inspector did not close") { !inspector.exists }
    }

    private func optionsButton(_ app: XCUIApplication, label: String? = nil, identifier: String? = nil) throws -> XCUIElement {
        let query = optionsInspectorQuery(app)
        guard query.count == 1 else { throw ReferenceOptionsFailure("The actual inspector is absent or ambiguous") }
        let inspector = query.element(boundBy: 0)
        let matches = identifier.map { inspector.buttons.matching(identifier: $0) }
            ?? inspector.buttons.matching(NSPredicate(format: "label == %@", label ?? ""))
        guard matches.count == 1 else { throw ReferenceOptionsFailure("An actual inspector option is absent or ambiguous") }
        let element = matches.element(boundBy: 0)
        try optionsWait("The actual inspector option is not hittable") { element.exists && element.isHittable }
        return element
    }

    private func optionsBoolean(_ element: XCUIElement) throws -> String {
        guard let value = element.value as? String, ["On", "Off"].contains(value) else {
            throw ReferenceOptionsFailure("The actual option Boolean state is unknown")
        }
        return value
    }

    private func optionsSelected(_ app: XCUIApplication, labels: [String]) throws -> String {
        let choices = try labels.map { (label: $0, element: try optionsButton(app, label: $0)) }
        let selected = choices.filter { $0.element.isSelected }
        guard selected.count == 1 else { throw ReferenceOptionsFailure("Expected one actual selected menu choice") }
        return selected[0].label
    }

    private func optionsSelect(_ app: XCUIApplication, label: String) throws {
        let button = try optionsButton(app, label: label)
        if !button.isSelected { button.tap() }
        try optionsWait("The actual menu choice was not selected") { button.isSelected }
    }

    private func optionsSet(_ app: XCUIApplication, label: String? = nil, identifier: String? = nil, value: String) throws {
        let button = try optionsButton(app, label: label, identifier: identifier)
        if try optionsBoolean(button) != value { button.tap() }
        try optionsWait("The actual Boolean option was not restored or selected") {
            (try? self.optionsBoolean(button)) == value
        }
    }

    private func optionsSetTool(_ app: XCUIApplication, tool: String, value: String) throws {
        let button = try optionsTool(app, tool: tool)
        if try optionsBoolean(button) != value { button.tap() }
        try optionsWait("The actual tool enablement was not restored or selected") {
            (try? self.optionsBoolean(button)) == value
        }
    }

    private func optionsRestorePalette(_ app: XCUIApplication, expanded: Bool) throws {
        let desired = app.buttons[expanded ? "monitor.assists.collapse" : "monitor.assists.expand"]
        if !desired.exists {
            let other = app.buttons[expanded ? "monitor.assists.expand" : "monitor.assists.collapse"]
            try optionsWait("Owned palette cleanup control is unavailable") { other.isHittable }
            other.tap()
        }
        try optionsWait("Captured palette state was not restored") { desired.exists }
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
#endif
