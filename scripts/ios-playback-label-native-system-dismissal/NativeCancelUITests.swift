import CryptoKit
import MonitorPresentation
import OpenCineHostedTestSupport
import XCTest

// One SIMULATED native operator-input case. No in-process fixture or handler is callable here.
@MainActor
final class NativeCancelUITests: XCTestCase {
    private var lastReceipt: NativeCancelReceipt?
    private var lastData: Data?
    private var receiptURL: URL!
    private var nonce = ""
    private var sourceSeal = ""
    private var simulatorID = ""
    private var bundleID = ""
    private var began: TimeInterval = 0
    private var externalActionObservations: [[String: Any]] = []

    func testCapturedDeletionConfirmationReadsTheSharedCopyAndDismissalCancelsOnlyItsRequest()
        async throws
    {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        nonce = try XCTUnwrap(environment["OPENCINE_NATIVE_UI_NONCE"])
        sourceSeal = try XCTUnwrap(environment["OPENCINE_NATIVE_UI_SOURCE_SEAL"])
        bundleID = try XCTUnwrap(environment["OPENCINE_NATIVE_UI_BUNDLE_ID"])
        try require(
            environment["OPENCINE_NATIVE_UI_MODE"] == "native-system-popover-dismissal",
            "Only the explicitly selected system-popover-dismissal mode is admitted")
        simulatorID = try XCTUnwrap(environment["SIMULATOR_UDID"])
        _ = try XCTUnwrap(UUID(uuidString: nonce))
        _ = try XCTUnwrap(UUID(uuidString: simulatorID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            NativeCancelContract.readerPrefix + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        receiptURL = directory.appendingPathComponent("app-receipt.json")
        // This names only the reader's own inbox. The outer runner validates its private
        // simulator/container and copies app-authored bytes in one direction. No acknowledgement.
        FileHandle.standardOutput.write(
            Data(("SIMULATED_NATIVE_UI_INBOX:" + receiptURL.path + "\n").utf8))
        let app = XCUIApplication(bundleIdentifier: bundleID)
        began = Date().timeIntervalSince1970
        var deleteTapInvoked = false
        var systemDismissalTapInvoked = false
        var preInputAppSequence: UInt64 = 0
        var preInputAppSHA256 = ""
        var eventReadinessElapsedSeconds: Double?
        var deleteDeliveryElapsedSeconds: Double?
        // The last stage entered. A failed case names it in its outcome, so the log says which
        // wait missed even when XCTest reports a later teardown issue instead of the thrown error.
        var stage = "launch"
        var qualified = false
        defer {
            if let lastData {
                let attachment = XCTAttachment(data: lastData, uniformTypeIdentifier: "public.json")
                attachment.name = "SIMULATED app-authored callback and observation receipt"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let externalObservation: [String: Any] = [
                "scope": "SIMULATED read-only external frozen-action observations",
                "nonce": nonce, "sourceSeal": sourceSeal,
                "unreadValuesAreNull": true, "observations": externalActionObservations,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: externalObservation, options: [.sortedKeys])
            {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "SIMULATED exact external frozen-action observations"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            if app.state == .runningForeground {
                // No screenshot. On hosted runners XCUIApplication.screenshot() hangs for minutes
                // (40143225461, 40149233094 after a qualified case; 40195791463 after a failed one),
                // and its "Timed out while requesting screenshot" issue is then the only failure
                // XCTest reports: in 40195791463 it hid the readiness error that failed the case.
                // The app receipts, the stage below and this accessibility tree are the evidence.
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "SIMULATED external native accessibility tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
            let outcome: [String: Any] = [
                "nonce": nonce, "sourceSeal": sourceSeal, "bundleID": bundleID,
                "simulatorID": simulatorID, "qualified": qualified,
                "deleteTapInvoked": deleteTapInvoked, "cancelTapInvoked": false,
                "systemDismissalTapInvoked": systemDismissalTapInvoked,
                "preInputAppSequence": preInputAppSequence,
                "preInputAppSHA256": preInputAppSHA256,
                "eventReadinessElapsedSeconds": eventReadinessElapsedSeconds as Any? ?? NSNull(),
                "deleteDeliveryElapsedSeconds": deleteDeliveryElapsedSeconds as Any? ?? NSNull(),
                "stage": stage,
                "outsideInputImplemented": true, "mode": "native-system-popover-dismissal",
                "sequence": lastReceipt?.sequence ?? 0,
                "appReceiptSHA256": lastData.map {
                    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                } ?? "",
            ]
            let data = try! JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys])
            FileHandle.standardOutput.write(
                Data(
                    ("SIMULATED_NATIVE_UI_OUTCOME:" + String(decoding: data, as: UTF8.self) + "\n")
                        .utf8))
        }
        app.launchEnvironment = [
            "OPENCINE_NATIVE_UI_NONCE": nonce, "OPENCINE_NATIVE_UI_SOURCE_SEAL": sourceSeal,
            "OPENCINE_NATIVE_UI_BUNDLE_ID": bundleID,
            "OPENCINE_NATIVE_UI_MODE": "native-system-popover-dismissal",
        ]
        app.launch()
        stage = "initial"
        let initial = try await receipt { value in
            self.windowReady(value, app: app) && value.captureRequestIDs.isEmpty
                && value.popup == nil
                && value.confirmed.isEmpty && value.cancelled.isEmpty
                && value.activeRequestIDs.isEmpty
                && value.retiredRequestIDs.isEmpty && value.deletedCount == 0
                && self.button(MonitorPlaybackCopy.delete, in: app, inside: value.windowFrame.rect)
                    != nil
        }
        let delete = try XCTUnwrap(
            button(MonitorPlaybackCopy.delete, in: app, inside: initial.windowFrame.rect))
        let initialCurrent = try XCTUnwrap(readReceipt())
        try require(
            windowReady(initialCurrent, app: app) && initialCurrent.popup == nil
                && initialCurrent.captureRequestIDs.isEmpty
                && initialCurrent.requestID == initial.requestID
                && initialCurrent.processID == initial.processID
                && initialCurrent.sceneID == initial.sceneID
                && initialCurrent.windowIdentity == initial.windowIdentity
                && initialCurrent.orientation == initial.orientation
                && initialCurrent.item == initial.item && fresh(initialCurrent),
            "The exact private native app/window must still be ready")
        deleteTapInvoked = true
        stage = "deleteDelivery"
        let deliveryClock = ContinuousClock()
        let deliveryStart = deliveryClock.now
        delete.tap()

        // XCUIElement.tap() returning is not delivery. In nightly 40195791463 the tap returned at
        // 41 s, the app recorded no Delete callback in 66 s of receipts (written every
        // 50 ms), and its capture first appeared at 159 s, so the readiness clock had already run
        // out at 71 s. Readiness starts at the app-authored capture of this exact request, read
        // from the receipt file only (no automation query competes with the delivery). The limit
        // only ends a hang; it is not an expected duration and covers no second input.
        let delivered = await HostedCondition.wait(limit: .seconds(150)) {
            guard let value = self.readReceipt() else { return false }
            return value.processID == initial.processID && value.requestID == initial.requestID
                && value.item == initial.item && value.captureRequestIDs == [initial.requestID]
                && value.capturedItems == [initial.item]
                && value.activeRequestIDs == [initial.requestID]
                && value.cancelled.isEmpty && value.confirmed.isEmpty && value.deletedCount == 0
        }
        let delivery = deliveryStart.duration(to: deliveryClock.now).components
        deleteDeliveryElapsedSeconds =
            Double(delivery.seconds) + Double(delivery.attoseconds) / 1e18
        try require(
            delivered, "The app never recorded the Delete callback for this request; no fallback input")

        stage = "readiness"
        let readinessClock = ContinuousClock()
        let readinessStart = readinessClock.now
        let readinessDeadline = readinessStart.advanced(by: .seconds(30))

        // One thirty-second readiness budget from the delivered Delete callback includes the actual popup, ownership,
        // native hit, external region, coordinate correspondence and a second stable observation.
        // There is no visible-Cancel branch and no alternative dismissal path.
        // The coordinate is the one the accepting (second stable) observation produced. Computing
        // it again costs a third complete external walk: about 9 s on a hosted runner, which ran
        // past this same deadline after readiness had held (nightly 40166387934). The checks below
        // still re-read the receipt and require the exact native point before the sole event.
        var previous: NativeCancelReceipt?
        var readyCoordinate: XCUICoordinate?
        let ready = try await receipt(deadline: readinessDeadline) { value in
            guard self.popupReady(value, initial: initial, app: app),
                let observed = self.dismissalCoordinate(
                    value, app: app, deadline: readinessDeadline)
            else {
                previous = nil
                readyCoordinate = nil
                return false
            }
            defer { previous = value }
            let stable =
                previous.map {
                    value.sequence > $0.sequence && self.samePresentation(value, $0)
                        && value.systemDismissal == $0.systemDismissal
                } ?? false
            readyCoordinate = stable ? observed : nil
            return stable
        }
        let coordinate = try XCTUnwrap(readyCoordinate)
        stage = "finalRead"
        // XCUICoordinate is dynamic. Its final public screenPoint must equal the app-observed
        // native point exactly. The next local read must still attest to the same actual hit.
        try require(
            readinessClock.now < readinessDeadline,
            "Readiness deadline expired before final foreground read")
        let appStillForeground = app.state == .runningForeground
        try require(
            readinessClock.now < readinessDeadline,
            "Readiness deadline expired before final coordinate read")
        let exactPoint = coordinate.screenPoint
        let current = try XCTUnwrap(readReceipt())
        try require(
            current.sequence >= ready.sequence && samePresentation(current, ready)
                && sameRequest(current, initial: initial)
                && current.systemDismissal == ready.systemDismissal
                && nativeDismissalProof(current)
                && exactPoint == current.systemDismissal?.pointOnScreen.point
                && current.foreground && current.keyWindow && current.rootMounted
                && current.rootFillsScene && appStillForeground && fresh(current),
            "A fresh unchanged public ownership/native hit proof and exact native coordinate must precede the sole system event"
        )
        preInputAppSequence = current.sequence
        let preInputData = try XCTUnwrap(lastData)
        preInputAppSHA256 = SHA256.hash(data: preInputData).map { String(format: "%02x", $0) }
            .joined()
        let eventInstant = readinessClock.now
        let elapsed = readinessStart.duration(to: eventInstant).components
        eventReadinessElapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        try require(
            eventInstant < readinessDeadline && readinessClock.now < readinessDeadline,
            "The single original thirty-second monotonic post-Delete deadline expired; no event")
        systemDismissalTapInvoked = true
        stage = "settlement"
        coordinate.tap()

        let settled = try await receipt { value in
            self.windowReady(value, app: app) && value.sequence > current.sequence
                && value.requestID == initial.requestID && value.item == initial.item
                && value.capturedItems == [initial.item]
                && value.captureRequestIDs == [initial.requestID]
                && value.cancelled == [initial.requestID] && value.confirmed.isEmpty
                && value.deletedCount == 0
                && value.activeRequestIDs.isEmpty && value.retiredRequestIDs == [initial.requestID]
                && value.dialogWindowGone && value.presentingControllerGone && value.popup == nil
                && app.staticTexts.matching(
                    NSPredicate(format: "label == %@", NativeCancelContract.title)
                ).count == 0
        }
        XCTAssertEqual(settled.captureRequestIDs, [initial.requestID])
        XCTAssertEqual(settled.capturedItems, [initial.item])
        XCTAssertEqual(settled.cancelled, [initial.requestID])
        XCTAssertEqual(settled.confirmed, [])
        XCTAssertEqual(settled.deletedCount, 0)
        XCTAssertEqual(settled.activeRequestIDs, [])
        XCTAssertEqual(settled.retiredRequestIDs, [initial.requestID])
        XCTAssertTrue(settled.dialogWindowGone && settled.presentingControllerGone)
        stage = "qualified"
        qualified = true
    }

    private func readReceipt() -> NativeCancelReceipt? {
        guard let data = try? Data(contentsOf: receiptURL),
            let value = try? JSONDecoder().decode(NativeCancelReceipt.self, from: data),
            value.schema == 1, value.mode == "native-system-popover-dismissal",
            value.nonce == nonce, value.sourceSeal == sourceSeal,
            value.bundleID == bundleID,
            value.simulatorID.caseInsensitiveCompare(simulatorID) == .orderedSame,
            value.processID > 0, value.observedAt >= began,
            (0...1).contains(Date().timeIntervalSince1970 - value.observedAt),
            value.sequence >= (lastReceipt?.sequence ?? 0)
        else { return nil }
        lastReceipt = value
        lastData = data
        return value
    }

    private func receipt(
        deadline: ContinuousClock.Instant? = nil,
        where predicate: @escaping @MainActor (NativeCancelReceipt) -> Bool
    )
        async throws -> NativeCancelReceipt
    {
        var found: NativeCancelReceipt?
        let ready = await HostedCondition.wait(limit: .seconds(30)) {
            if let deadline, ContinuousClock().now >= deadline { return false }
            guard let value = self.readReceipt(), predicate(value) else { return false }
            if let deadline, ContinuousClock().now >= deadline { return false }
            found = value
            return true
        }
        try require(
            ready,
            "Actual native readiness/settlement did not hold within the original thirty seconds; no fallback input"
        )
        return try XCTUnwrap(found)
    }

    private func windowReady(_ value: NativeCancelReceipt, app: XCUIApplication) -> Bool {
        guard value.foreground, value.keyWindow, value.rootMounted, value.rootFillsScene,
            value.windowFrame.finite, value.screenFrame.finite,
            value.screenFrame.rect.contains(value.windowFrame.rect),
            app.state == .runningForeground,
            value.windows.filter({
                $0.identity == value.windowIdentity && $0.key && !$0.hidden
                    && $0.sceneID == value.sceneID && $0.frame == value.windowFrame
            }).count == 1
        else { return false }
        return actualWindow(value, app: app) != nil
    }

    // AX may expose an empty auxiliary window. Inventory it; select only the unique actual
    // window carrying the real shared-screen marker and native frame. It is never an input target.
    private func actualWindow(_ value: NativeCancelReceipt, app: XCUIApplication) -> XCUIElement? {
        let windows = app.windows.allElementsBoundByIndex
        let matches = windows.filter { window in
            window.exists && window.elementType == .window && window.frame == value.windowFrame.rect
                && window.staticTexts.matching(identifier: "monitor.playback.title").count == 1
                && window.staticTexts.matching(identifier: "monitor.playback.title").element(
                    boundBy: 0
                ).label == "SIMULATED clip"
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func sameRequest(_ value: NativeCancelReceipt, initial: NativeCancelReceipt) -> Bool {
        value.processID == initial.processID && value.sceneID == initial.sceneID
            && value.windowIdentity == initial.windowIdentity
            && value.orientation == initial.orientation
            && value.windowFrame == initial.windowFrame && value.screenFrame == initial.screenFrame
            && value.requestID == initial.requestID && value.item == initial.item
            && value.captureRequestIDs == [initial.requestID]
            && value.capturedItems == [initial.item]
            && value.activeRequestIDs == [initial.requestID] && value.retiredRequestIDs.isEmpty
            && value.cancelled.isEmpty && value.confirmed.isEmpty && value.deletedCount == 0
    }

    private func samePresentation(_ value: NativeCancelReceipt, _ previous: NativeCancelReceipt)
        -> Bool
    {
        value.popup?.identity == previous.popup?.identity && value.popup?.identity != nil
            && value.popup?.mountedInHostWindow == true
            && value.popup?.frame == previous.popup?.frame
            && value.popup?.presentationFrame == previous.popup?.presentationFrame
            && value.popup?.title == previous.popup?.title
            && value.popup?.message == previous.popup?.message
            && value.popup?.actions == previous.popup?.actions
            && value.popup?.renderedStrings == previous.popup?.renderedStrings
            && value.popup?.viewWalkAtLimit == false
    }

    private func nativeDismissalProof(_ value: NativeCancelReceipt) -> Bool {
        guard let proof = value.systemDismissal, value.systemDismissalRejections.isEmpty,
            proof.rejections.isEmpty,
            proof.expectedPresented == value.popup?.identity,
            proof.window == value.windowIdentity, proof.sceneID == value.sceneID,
            proof.sceneWindowIDs == value.windows.map(\.identity).sorted(),
            proof.windowBounds.finite, proof.safeWindowBounds.finite,
            proof.screenBoundsInWindow.finite, proof.containerBoundsInWindow.finite,
            proof.visible.rect
                == proof.safeWindowBounds.rect.intersection(proof.screenBoundsInWindow.rect)
                .intersection(proof.containerBoundsInWindow.rect),
            proof.windowBounds.rect.contains(proof.pointInWindow.point),
            value.screenFrame.rect.contains(proof.pointOnScreen.point),
            proof.popupFrameOnScreen == value.popup?.frame,
            proof.presentationFrameOnScreen == value.popup?.presentationFrame
        else { return false }
        return nativeContractInputRejections(
            proof, item: value.item, windowFrame: value.windowFrame
        ).isEmpty
    }

    // Cross-check every frozen host action against the external automation tree. Native public
    // semantics reject extra/custom/unknown actions; this independently requires exact exposed
    // buttons and adjustable scrubber frames. No hosting-view rectangle is a neutrality oracle.
    private func externalFrozenActions(
        _ proof: NativeSystemDismissalProof, window: XCUIElement, deadline: ContinuousClock.Instant
    ) -> Bool {
        guard let background = proof.neutralBackground else { return false }
        let buttonCount = window.buttons.count
        externalActionObservations.append([
            "stage": "inventory", "appReceiptSequence": lastReceipt?.sequence as Any? ?? NSNull(),
            "buttonCount": buttonCount,
            "expectedButtonCount": NativeCancelContract.mainButtons.count + 1,
        ])
        guard buttonCount == NativeCancelContract.mainButtons.count + 1 else { return false }
        for label in NativeCancelContract.mainButtons.sorted() {
            guard ContinuousClock().now < deadline else { return false }
            let matches = window.buttons.matching(NSPredicate(format: "label == %@", label))
            let native = background.actionables.filter { $0.kind == "button" && $0.label == label }
            let matchCount = matches.count
            var observation: [String: Any] = [
                "stage": "control", "label": label,
                "appReceiptSequence": lastReceipt?.sequence as Any? ?? NSNull(),
                "matchCount": matchCount, "nativeCount": native.count,
                "exists": NSNull(), "buttonType": NSNull(), "exactFrameEqual": NSNull(),
                "pointExcluded": NSNull(),
            ]
            defer { externalActionObservations.append(observation) }
            guard matchCount == 1, native.count == 1 else { return false }
            let element = matches.element(boundBy: 0)
            let exists = element.exists
            observation["exists"] = exists
            guard exists else { return false }
            let buttonType = element.elementType == .button
            observation["buttonType"] = buttonType
            guard buttonType else { return false }
            let comparisonFrame = element.frame
            let exactFrameEqual = comparisonFrame == native[0].frame.rect
            observation["comparisonFrame"] = exactFrameObservation(comparisonFrame)
            observation["nativeFrame"] = exactFrameObservation(native[0].frame.rect)
            observation["exactFrameEqual"] = exactFrameEqual
            let deviceCoordinateEdgesEqual = nativeExternalControlFrameMatches(
                NativeCancelRect(comparisonFrame), native[0].frame, scale: proof.screenScale)
            observation["screenScale"] = proof.screenScale as Any? ?? NSNull()
            observation["deviceCoordinateEdgesEqual"] = deviceCoordinateEdgesEqual
            observation["comparisonFrameExcludesPoint"] = !comparisonFrame.insetBy(dx: -1, dy: -1)
                .contains(proof.pointOnScreen.point)
            guard deviceCoordinateEdgesEqual else { return false }
            let exclusionFrame = element.frame
            let pointExcluded = !exclusionFrame.insetBy(dx: -1, dy: -1).contains(
                proof.pointOnScreen.point)
            observation["exclusionFrame"] = exactFrameObservation(exclusionFrame)
            observation["pointExcluded"] = pointExcluded
            guard pointExcluded else { return false }
        }
        let scrubbers = window.otherElements.matching(
            NSPredicate(format: "label == %@", NativeCancelContract.scrubber))
        guard scrubbers.count == 1,
            let native = background.actionables.first(where: { $0.kind == "adjustable" }),
            scrubbers.element(boundBy: 0).exists,
            nativeExternalControlFrameMatches(
                NativeCancelRect(scrubbers.element(boundBy: 0).frame), native.frame,
                scale: proof.screenScale)
        else { return false }
        let unexpected: Set<XCUIElement.ElementType> = [
            .switch, .slider, .textField, .secureTextField, .textView, .link,
            .picker, .pickerWheel, .segmentedControl, .stepper, .cell,
        ]
        guard let descendants = descendantSnapshots(of: window) else { return false }
        for element in descendants where unexpected.contains(element.elementType) {
            guard ContinuousClock().now < deadline else { return false }
            if !proof.presentationFrameOnScreen.rect.contains(element.frame) { return false }
        }
        return ContinuousClock().now < deadline
    }

    // Walk one atomic automation-tree snapshot. Resolving descendants by index costs an AX round
    // trip per element (beyond the thirty-second budget on hosted runners) and fails outright
    // when the tree shrinks between indices. Every snapshotted element is checked; none is skipped.
    private func descendantSnapshots(of window: XCUIElement) -> [XCUIElementSnapshot]? {
        guard let root = try? window.snapshot() else { return nil }
        var pending = root.children, result: [XCUIElementSnapshot] = []
        while let next = pending.popLast() {
            result.append(next)
            pending += next.children
        }
        return result
    }

    private func exactFrameObservation(_ frame: CGRect) -> [String: Any] {
        let components = [
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "width": Double(frame.size.width), "height": Double(frame.size.height),
        ]
        return components.mapValues { value -> [String: Any] in
            [
                "value": value.isFinite ? value as Any : NSNull(),
                "ieee754Binary64": "0x" + String(value.bitPattern, radix: 16),
            ]
        }
    }

    private func dismissalCoordinate(
        _ value: NativeCancelReceipt, app: XCUIApplication, deadline: ContinuousClock.Instant
    )
        -> XCUICoordinate?
    {
        guard ContinuousClock().now < deadline, nativeDismissalProof(value),
            let proof = value.systemDismissal,
            let window = actualWindow(value, app: app),
            window.sheets.matching(NSPredicate(format: "label == %@", NativeCancelContract.title))
                .count == 1
        else { return nil }
        let popovers = window.descendants(matching: .popover)
        guard popovers.count == 1, app.descendants(matching: .popover).count == 1,
            popovers.element(boundBy: 0).exists,
            popovers.element(boundBy: 0).frame == proof.presentationFrameOnScreen.rect,
            popovers.element(boundBy: 0).sheets.matching(
                NSPredicate(format: "label == %@", NativeCancelContract.title)
            ).count == 1,
            externalFrozenActions(proof, window: window, deadline: deadline)
        else { return nil }
        let regions = window.otherElements.matching(identifier: "PopoverDismissRegion")
        guard regions.count == 1,
            app.otherElements.matching(identifier: "PopoverDismissRegion").count == 1
        else { return nil }
        let region = regions.element(boundBy: 0)
        guard region.exists, region.elementType == .other, region.label == "dismiss popup",
            region.isEnabled, region.isHittable, region.frame == proof.regions[0].frame.rect,
            region.frame.contains(proof.pointOnScreen.point)
        else { return nil }
        let controls: Set<XCUIElement.ElementType> = [
            .button, .switch, .slider, .textField, .secureTextField, .textView, .link,
            .picker, .pickerWheel, .segmentedControl, .stepper,
        ]
        guard let descendants = descendantSnapshots(of: window) else { return nil }
        for element in descendants where controls.contains(element.elementType) {
            guard ContinuousClock().now < deadline else { return nil }
            if element.frame.contains(proof.pointOnScreen.point) { return nil }
        }
        let coordinate = region.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(
                dx: proof.pointOnScreen.x - region.frame.minX,
                dy: proof.pointOnScreen.y - region.frame.minY))
        let point = coordinate.screenPoint
        guard let current = readReceipt(), point == proof.pointOnScreen.point,
            current.systemDismissal == proof, samePresentation(current, value),
            sameRequest(current, initial: value), nativeDismissalProof(current), fresh(current),
            ContinuousClock().now < deadline
        else { return nil }
        return coordinate
    }

    private func fresh(_ value: NativeCancelReceipt) -> Bool {
        (0...1).contains(Date().timeIntervalSince1970 - value.observedAt)
    }

    private func popupReady(
        _ value: NativeCancelReceipt, initial: NativeCancelReceipt, app: XCUIApplication
    ) -> Bool {
        guard windowReady(value, app: app), value.processID == initial.processID,
            value.sceneID == initial.sceneID, value.windowIdentity == initial.windowIdentity,
            value.orientation == initial.orientation, value.requestID == initial.requestID,
            value.item == initial.item,
            value.captureRequestIDs == [initial.requestID], value.capturedItems == [initial.item],
            value.activeRequestIDs == [initial.requestID], value.retiredRequestIDs.isEmpty,
            value.cancelled.isEmpty, value.confirmed.isEmpty, value.deletedCount == 0,
            let popup = value.popup, let window = actualWindow(value, app: app),
            window.sheets.matching(NSPredicate(format: "label == %@", NativeCancelContract.title))
                .count == 1,
            popup.mountedInHostWindow, popup.frame.finite,
            popup.presentationFrame.finite,
            value.windowFrame.rect.contains(popup.frame.rect),
            value.windowFrame.rect.contains(popup.presentationFrame.rect),
            popup.title == NativeCancelContract.title,
            popup.message == NativeCancelContract.message,
            popup.actions.count == 2,
            popup.actions.filter({
                $0 == NativeCancelAction(title: MonitorPlaybackCopy.deleteConfirm, style: 2)
            }).count == 1,
            popup.actions.filter({
                $0 == NativeCancelAction(title: MonitorPlaybackCopy.deleteCancel, style: 1)
            }).count == 1,
            !popup.viewWalkAtLimit
        else { return false }
        for label in [NativeCancelContract.title, NativeCancelContract.message] {
            let matches = window.staticTexts.matching(NSPredicate(format: "label == %@", label))
            guard matches.count == 1, matches.element(boundBy: 0).exists,
                popup.frame.rect.contains(matches.element(boundBy: 0).frame)
            else { return false }
        }
        return button(MonitorPlaybackCopy.deleteConfirm, in: window, inside: popup.frame.rect)
            != nil
    }

    private func button(_ label: String, in app: XCUIElement, inside frame: CGRect)
        -> XCUIElement?
    {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        guard matches.count == 1 else { return nil }
        let control = matches.element(boundBy: 0)
        let actual = NativeCancelRect(control.frame)
        guard control.exists, control.elementType == .button, control.label == label,
            control.isEnabled, control.isHittable, actual.finite, frame.contains(actual.rect)
        else { return nil }
        return control
    }

    private func require(_ value: Bool, _ message: String) throws {
        guard value else {
            throw NSError(
                domain: "SIMULATED.NativeCancel.NoInputGuard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
