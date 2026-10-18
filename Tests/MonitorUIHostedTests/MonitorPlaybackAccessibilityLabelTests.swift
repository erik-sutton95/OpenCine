#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineHostedAccessibility
    import OpenCineHostedTestSupport
    import OpenCineMedia
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED values mount the actual shared playback screen and read what VoiceOver reads.
    /// Every expected string comes from `MonitorPlaybackCopy`, which `Fixtures/playback-copy.tsv`
    /// ties to the Compose twin; `MonitorPlaybackAccessibilityLabelTest` (monitor-ui androidTest)
    /// reads the same strings from the Compose screen. No file, camera or media is touched.
    @MainActor
    final class MonitorPlaybackAccessibilityLabelTests: XCTestCase {
        private typealias Copy = MonitorPlaybackCopy

        override func setUp() async throws {
            let live = await HostedAccessibility.awaitRuntime()
            XCTAssertTrue(live, "The hosted accessibility runtime must be live before the walk")
        }

        func testChromeTransportScrubberAndInfoReadTheSharedCopy() async throws {
            let fixture = try PlaybackLabelFixture(actions: PlaybackLabelActions())
            defer { fixture.close() }
            for label in [
                Copy.backToMedia, Copy.favorite, Copy.clipInformation, Copy.share, Copy.delete,
                Copy.backFifteen, Copy.transport(reachedEnd: false, playing: false),
                Copy.forwardFifteen,
                Copy.conformPreview, Copy.muteToggle(muted: false), Copy.loop, Copy.hideControls,
                Copy.previousClip, Copy.nextClip, Copy.position,
            ] {
                _ = try await fixture.element(label: label)
            }
            let loop = try await fixture.element(label: Copy.loop)
            XCTAssertEqual(loop.accessibilityValue, Copy.toggleValue(true))
            let position = try await fixture.element(label: Copy.position)
            XCTAssertEqual(position.accessibilityValue, Copy.positionValue(seconds: 7.9))
            let hide = try await fixture.element(label: Copy.hideControls)
            XCTAssertEqual(hide.accessibilityHint, Copy.hideControlsHint)

            try await fixture.activate(label: Copy.conformPreview)
            _ = try await fixture.element(label: Copy.conformTitle, button: false)
            _ = try await fixture.element(
                label: Copy.conformSubtitle(captureRate: 60), button: false)
            try await fixture.activate(label: Copy.closeConformPreview)
            let conformClosed = await HostedCondition.wait {
                !fixture.labels.contains(Copy.conformTitle)
            }
            XCTAssertTrue(conformClosed, "Closing the conform panel must remove it")

            try await fixture.activate(label: Copy.clipInformation)
            _ = try await fixture.element(label: Copy.closeClipInformation)
            _ = try await fixture.element(label: Copy.clipInformationTitle, button: false)
            try await fixture.activate(label: Copy.closeClipInformation)
            let closed = await HostedCondition.wait {
                !fixture.labels.contains(Copy.closeClipInformation)
            }
            XCTAssertTrue(closed, "Closing the sheet must remove it")

            try await fixture.activate(label: Copy.hideControls)
            _ = try await fixture.element(label: Copy.showControls)
            let clean = await HostedCondition.wait { !fixture.labels.contains(Copy.favorite) }
            XCTAssertTrue(clean, "Clean view hides the header chrome")
        }

        // A real application scene mounts UIKit's confirmation. Read the rendered dialog and
        // send its actual native popover dismissal input before observing the captured request settle.
        func testCapturedDeletionConfirmationReadsTheSharedCopyAndDismissalCancelsOnlyItsRequest()
            async throws
        {
            let actions = PlaybackLabelActions()
            let copy = MonitorPlaybackDeletionConfirmation(
                title: "Remove this SIMULATED clip?",
                message: "Its camera master and backup copies are removed too.")
            actions.captured = copy
            let fixture = try PlaybackLabelFixture(
                actions: actions, typedDeletion: true, geometry: .nativeScene)
            defer { fixture.close() }

            try await fixture.activate(label: Copy.delete)
            let dialog = try await fixture.presentedDialog()
            XCTAssertEqual(dialog.title, copy.title)
            XCTAssertEqual(dialog.message, copy.message)
            XCTAssertEqual(
                dialog.actions.first { $0.style == .destructive }?.title, Copy.deleteConfirm)
            XCTAssertEqual(dialog.actions.first { $0.style == .cancel }?.title, Copy.deleteCancel)
            XCTAssertEqual(dialog.actions.count, 2)
            XCTAssertEqual(actions.captures, 1)
            XCTAssertEqual(actions.capturedItems, [fixture.item])
            XCTAssertEqual(actions.captured?.id, copy.id)

            _ = try await fixture.dialogElement(dialog, label: copy.title, button: false)
            _ = try await fixture.dialogElement(
                dialog, label: try XCTUnwrap(copy.message), button: false)
            _ = try await fixture.dialogElement(dialog, label: Copy.deleteConfirm)
            let diagnostic: URL?
            let qualifier = ProcessInfo.processInfo.environment["OPENCINE_TYPED_CANCEL_QUALIFIER"]
            let nonce =
                ProcessInfo.processInfo.environment["OPENCINE_TYPED_CANCEL_DIAGNOSTIC"] ?? qualifier
            var admitted = true
            if let nonce {
                diagnostic = try fixture.recordNativeCancelDiagnostic(
                    dialog, request: copy.id, nonce: nonce)
                if qualifier != nil {
                    admitted = try await fixture.cancelVisible(
                        dialog, screenshotDirectory: diagnostic)
                }
            } else {
                diagnostic = nil
                admitted = try await fixture.cancelVisible(dialog)
            }
            let settled: @MainActor @Sendable () -> Bool = {
                actions.cancelled == [copy.id] && dialog.presentingViewController == nil
                    && dialog.view.window == nil
            }
            let cancelled = admitted ? await HostedCondition.wait(until: settled) : settled()
            XCTAssertTrue(cancelled, "Dismissing must cancel the captured request")
            XCTAssertEqual(actions.confirmed, [])
            XCTAssertEqual(actions.deleted, [])
            XCTAssertEqual(actions.captures, 1)
            XCTAssertEqual(actions.capturedItems, [fixture.item])
            XCTAssertEqual(actions.captured?.id, copy.id)
            if let diagnostic {
                let outcome: [String: Any] = [
                    "cancelled": actions.cancelled.map(\.uuidString),
                    "confirmed": actions.confirmed.map(\.uuidString),
                    "deleteCount": actions.deleted.count, "captureCount": actions.captures,
                    "sameCapturedID": actions.captured?.id == copy.id,
                    "sameCapturedItem": actions.capturedItems == [fixture.item],
                    "dialogWindowGone": dialog.view.window == nil,
                    "presentingControllerGone": dialog.presentingViewController == nil,
                ]
                try JSONSerialization.data(
                    withJSONObject: outcome, options: [.prettyPrinted, .sortedKeys]
                )
                .write(to: diagnostic.appendingPathComponent("outcome.json"), options: .atomic)
            }
        }

        func testUntypedDeletionConfirmationFallsBackToTheSharedTitle() async throws {
            let actions = PlaybackLabelActions()
            let fixture = try PlaybackLabelFixture(actions: actions, geometry: .nativeScene)
            defer { fixture.close() }
            try await fixture.activate(label: Copy.delete)
            let dialog = try await fixture.presentedDialog()
            XCTAssertEqual(dialog.title, Copy.deleteConfirmationTitle)
            XCTAssertEqual(
                dialog.actions.first { $0.style == .destructive }?.title, Copy.deleteConfirm)
            XCTAssertEqual(dialog.actions.first { $0.style == .cancel }?.title, Copy.deleteCancel)
            _ = try await fixture.dialogElement(
                dialog, label: Copy.deleteConfirmationTitle, button: false)
            _ = try await fixture.dialogElement(dialog, label: Copy.deleteConfirm)
            try await fixture.cancel(dialog)
            let dismissed = await HostedCondition.wait {
                fixture.host.presentedViewController == nil
            }
            XCTAssertTrue(dismissed)
            XCTAssertEqual(actions.deleted, [], "Dismissing must not delete")
        }
    }

    @MainActor
    private final class PlaybackLabelActions {
        var captured: MonitorPlaybackDeletionConfirmation?
        var captures = 0
        var capturedItems: [MonitorPlaybackItemToken] = []
        var confirmed: [UUID] = []
        var cancelled: [UUID] = []
        var deleted: [MonitorPlaybackItemToken] = []
    }

    private enum PlaybackLabelGeometry {
        case synthetic(CGSize)
        case nativeScene
    }

    @MainActor
    private final class PlaybackLabelFixture {
        let item = MonitorPlaybackItemToken(owner: UUID(), revision: 1)
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let nativeSceneGeometry: Bool
        private let recorder: PlaybackLabelActions
        private let nativeGeometry = LegacyPlaybackGeometry()
        private weak var previousKeyWindow: UIWindow?
        private struct OtherWindowState {
            let hidden: Bool
            let alpha: CGFloat
        }
        private var hiddenOtherWindows: [UIWindow: OtherWindowState] = [:]

        init(
            actions recorder: PlaybackLabelActions, typedDeletion: Bool = false,
            geometry: PlaybackLabelGeometry = .synthetic(CGSize(width: 900, height: 420))
        ) throws {
            self.recorder = recorder
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive },
                "Playback label contracts require a real foreground application scene")
            let value = MonitorPlaybackPresentation(
                item: item, title: "SIMULATED clip", subtitle: "SIMULATED detail", source: nil,
                metadata: [MonitorMetadataRow("Codec", "SIMULATED")], aspect: 16.0 / 9.0,
                ready: true,
                position: 7.9, duration: 30, positionLabel: "00:07", durationLabel: "00:30",
                playing: false, reachedEnd: false, scrubbing: false, muted: false, looping: true,
                previous: true, next: true, favorite: false, conform: .init(captureRate: 60),
                conformTarget: nil, haptics: false)
            var actions = MonitorPlaybackActions(
                back: {}, play: { _, _ in }, restart: { _ in }, seekBy: { _, _ in },
                mute: { _, _ in },
                loop: { _, _ in }, conform: { _, _ in }, adjacent: { _, _ in }, favorite: { _ in },
                share: { _ in }, delete: typedDeletion ? nil : { recorder.deleted.append($0) },
                beginScrub: { _ in nil }, updateScrub: { _, _ in },
                updateFrameScrub: { _, _, _ in },
                commitScrub: { _ in }, cancelScrub: { _, _ in })
            if typedDeletion {
                actions.deletionConfirmation = MonitorPlaybackDeletionActions(
                    capture: { item in
                        recorder.captures += 1
                        recorder.capturedItems.append(item)
                        return recorder.captured
                    },
                    isCurrent: { $0 == recorder.captured?.id },
                    confirm: { recorder.confirmed.append($0) },
                    cancel: { recorder.cancelled.append($0) })
            }
            let screen = MonitorPlaybackScreen(
                value: value, actions: actions,
                onGeometry: { [nativeGeometry] in nativeGeometry.value = $0 },
                picture: { Color.black },
                feedAssists: { _ in EmptyView() },
                canvasAssists: { _, _ in EmptyView() }, tools: { _ in EmptyView() }
            ).environment(\.scenePhase, .active)
            let root: AnyView
            let frame: CGRect
            switch geometry {
            case .synthetic(let size):
                nativeSceneGeometry = false
                root = AnyView(screen.frame(width: size.width, height: size.height))
                frame = CGRect(origin: .zero, size: size)
            case .nativeScene:
                nativeSceneGeometry = true
                root = AnyView(screen.frame(maxWidth: .infinity, maxHeight: .infinity))
                frame = scene.coordinateSpace.bounds
            }
            host = UIHostingController(rootView: root)
            window = UIWindow(windowScene: scene)
            window.frame = frame
            previousKeyWindow = scene.keyWindow
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            hideOtherWindows()
        }

        // A covering scene window takes the native tap even when its hit test at the point is
        // nil, so the fixture owns every other window while its own window is visible. The
        // accessibility runtime probe (HostedAccessibility.awaitRuntime) is ordered visible
        // again by a later window transaction, so alpha zero keeps it non-interactive as well
        // as hidden. Prior state is kept so close() hands the windows back unchanged.
        private func hideOtherWindows() {
            guard let scene = window.windowScene else { return }
            for other in scene.windows where other !== window {
                if hiddenOtherWindows[other] == nil {
                    hiddenOtherWindows[other] = OtherWindowState(
                        hidden: other.isHidden, alpha: other.alpha)
                }
                other.isHidden = true
                other.alpha = 0
            }
        }

        func close() {
            host.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            for (other, state) in hiddenOtherWindows {
                other.isHidden = state.hidden
                other.alpha = state.alpha
            }
            hiddenOtherWindows = [:]
            if let previousKeyWindow, !previousKeyWindow.isHidden,
                previousKeyWindow.windowScene === window.windowScene
            {
                previousKeyWindow.makeKeyAndVisible()
            }
        }

        func layout() {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        var labels: [String] {
            layout()
            return Self.leaves(host.view).compactMap(\.accessibilityLabel)
        }

        func element(label: String, button: Bool = true) async throws -> NSObject {
            let matches: (NSObject) -> Bool = {
                $0.accessibilityLabel == label
                    && (!button || $0.accessibilityTraits.contains(.button)
                        || $0.accessibilityTraits.contains(.adjustable))
            }
            let mounted = await HostedCondition.wait { [self] in
                layout()
                return Self.leaves(host.view).contains(where: matches)
            }
            XCTAssertTrue(mounted, "The actual playback element must be mounted: " + label)
            return try XCTUnwrap(
                Self.leaves(host.view).first(where: matches),
                "The actual playback element must be mounted: " + label)
        }

        func activate(label: String) async throws {
            let target = try await element(label: label)
            XCTAssertTrue(target.accessibilityActivate(), "Activation refused: " + label)
        }

        func presentedDialog() async throws -> UIAlertController {
            var dialog: UIAlertController?
            _ = await HostedCondition.wait { [self] in
                layout()
                var current: UIViewController? = host
                while let value = current, dialog == nil {
                    if let candidate = value as? UIAlertController,
                        candidate.viewIfLoaded?.window?.windowScene === window.windowScene,
                        candidate.viewIfLoaded?.window != nil,
                        candidate.presentationController?.containerView?.window?.windowScene
                            === window.windowScene,
                        window.windowScene?.activationState == .foregroundActive,
                        !candidate.isBeingPresented
                    {
                        dialog = candidate
                    }
                    current = value.presentedViewController
                }
                return dialog != nil
            }
            return try XCTUnwrap(dialog, "The real deletion confirmation did not present")
        }

        func dialogElement(_ dialog: UIAlertController, label: String, button: Bool = true)
            async throws -> NSObject
        {
            let container = try XCTUnwrap(
                dialog.presentationController?.containerView,
                "The actual native dialog requires its mounted presentation container")
            XCTAssertNotNil(container.window)
            XCTAssertTrue(container.window?.windowScene === window.windowScene)
            XCTAssertTrue(dialog.view.window?.windowScene === window.windowScene)
            XCTAssertEqual(window.windowScene?.activationState, .foregroundActive)
            func elements() -> [NSObject] { Self.leaves(container) }
            let matches: (NSObject) -> Bool = {
                $0.accessibilityLabel == label
                    && (!button || $0.accessibilityTraits.contains(.button))
            }
            let mounted = await HostedCondition.wait {
                dialog.view.layoutIfNeeded()
                return elements().contains(where: matches)
            }
            let evidence = XCTAttachment(
                string: "SIMULATED mounted dialog: style=\(dialog.modalPresentationStyle.rawValue) "
                    + "window=\(dialog.view.window != nil) "
                    + "sameScene=\(dialog.view.window?.windowScene === window.windowScene) "
                    + "foreground=\(window.windowScene?.activationState == .foregroundActive) "
                    + "containerWindow=\(container.window != nil) "
                    + "labels=\(elements().compactMap(\.accessibilityLabel))"
            )
            evidence.name = "mounted-playback-confirmation"
            evidence.lifetime = .keepAlways
            XCTContext.runActivity(named: "Actual playback confirmation accessibility tree") {
                $0.add(evidence)
            }
            XCTAssertTrue(mounted, "The actual native dialog element must be mounted: " + label)
            return try XCTUnwrap(
                elements().first(where: matches), "Missing native dialog element: " + label)
        }

        func cancel(_ dialog: UIAlertController) async throws {
            let settled = try await cancelVisible(dialog)
            XCTAssertTrue(settled, "The actual native popover input must settle without deletion")
        }

        // This scene presents a native popover, whose cancel action is outside input rather
        // than a mounted Cancel button. The separate reader sends one guarded native event.
        // This app only publishes observations; no handler, dismissal or binding is callable.
        func cancelVisible(_ dialog: UIAlertController, screenshotDirectory: URL? = nil)
            async throws -> Bool
        {
            // A window created after init could come forward mid-test; hide the scene's other
            // windows again before the reader sends its one native event.
            hideOtherWindows()
            let observer = try LegacyHostedNativeInput(
                host: host, window: window, item: item, geometry: nativeGeometry,
                request: recorder.captured?.id,
                capturedItems: { self.recorder.capturedItems },
                captures: { self.recorder.captures },
                currentRequest: { self.recorder.captured?.id },
                confirmed: { self.recorder.confirmed }, cancelled: { self.recorder.cancelled },
                deleted: { self.recorder.deleted })
            defer { observer.stop() }
            let settled = await HostedCondition.wait {
                dialog.presentingViewController == nil && dialog.view.window == nil
                    && (self.recorder.captured.map { self.recorder.cancelled == [$0.id] } ?? true)
            }
            // Freeze the actual pre-teardown observation. The driver's receipt never supplies
            // cancellation state, and ordinary fixture close cannot create this evidence.
            observer.observe()
            XCTAssertTrue(settled, "The sole native popover input must settle within thirty seconds")
            return settled
        }

        // Opt-in SIMULATED diagnostic only. Records measured facts and requests external native
        // input; it never sends an event, calls a handler or changes presentation/model state.
        func recordNativeCancelDiagnostic(_ dialog: UIAlertController, request: UUID, nonce: String)
            throws -> URL
        {
            _ = try XCTUnwrap(UUID(uuidString: nonce))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SIMULATED-typed-cancel-" + nonce, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            func identity(_ object: AnyObject?) -> String? {
                object.map { String(describing: ObjectIdentifier($0)) }
            }
            func jsonIdentity(_ object: AnyObject?) -> Any { identity(object) as Any? ?? NSNull() }
            func number(_ value: CGFloat) -> Any { value.isFinite ? value as Any : NSNull() }
            func rect(_ value: CGRect) -> [String: Any] {
                [
                    "description": NSCoder.string(for: value), "x": number(value.minX),
                    "y": number(value.minY),
                    "width": number(value.width), "height": number(value.height),
                ]
            }
            func traits(_ value: UITraitCollection) -> [String: Int] {
                [
                    "idiom": value.userInterfaceIdiom.rawValue,
                    "horizontal": value.horizontalSizeClass.rawValue,
                    "vertical": value.verticalSizeClass.rawValue,
                ]
            }
            func node(_ object: NSObject) -> [String: Any] {
                var value: [String: Any] = [
                    "identity": jsonIdentity(object), "type": String(describing: type(of: object)),
                    "label": object.accessibilityLabel as Any? ?? NSNull(),
                    "value": object.accessibilityValue as Any? ?? NSNull(),
                    "identifier": HostedAccessibility.identifier(object) as Any? ?? NSNull(),
                    "isAXElement": object.isAccessibilityElement,
                    "AXHidden": object.accessibilityElementsHidden,
                    "AXTraits": object.accessibilityTraits.rawValue,
                    "AXFrame": rect(object.accessibilityFrame),
                    "customActions": object.accessibilityCustomActions?.map(\.name) ?? [],
                ]
                if let view = object as? UIView {
                    value["hidden"] = view.isHidden
                    value["alpha"] = view.alpha
                    value["frame"] = rect(view.frame)
                    value["bounds"] = rect(view.bounds)
                    value["window"] = jsonIdentity(view.window)
                    value["traits"] = traits(view.traitCollection)
                }
                return value
            }
            func rawViews(_ root: UIView) -> [[String: Any]] {
                var values: [[String: Any]] = []
                func visit(_ view: UIView, depth: Int, parentVisible: Bool) {
                    let visible = parentVisible && !view.isHidden && view.alpha >= 0.01
                    var value = node(view)
                    value["depth"] = depth
                    value["visibleInHierarchy"] = visible
                    if let label = view as? UILabel {
                        value["text"] = label.text as Any? ?? NSNull()
                    }
                    values.append(value)
                    for child in view.subviews {
                        visit(child, depth: depth + 1, parentVisible: visible)
                    }
                }
                visit(root, depth: 0, parentVisible: true)
                return values
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            var roots: [(String, NSObject)] = [
                ("application", UIApplication.shared), ("host", host.view),
            ]
            if let view = dialog.viewIfLoaded { roots.append(("dialog", view)) }
            if let container = dialog.presentationController?.containerView {
                roots.append(("container", container))
            }
            var sceneFacts: [[String: Any]] = []
            for scene in scenes {
                let active = scene.activationState == .foregroundActive
                sceneFacts.append([
                    "identity": jsonIdentity(scene),
                    "persistentID": scene.session.persistentIdentifier,
                    "state": scene.activationState.rawValue,
                    "orientation": scene.interfaceOrientation.rawValue,
                    "windows": scene.windows.map { value in
                        [
                            "identity": jsonIdentity(value), "key": value.isKeyWindow,
                            "hidden": value.isHidden, "bounds": rect(value.bounds),
                            "frame": rect(value.frame),
                            "screenBounds": rect(value.screen.bounds),
                            "screenNativeBounds": rect(value.screen.nativeBounds),
                            "screenScale": value.screen.scale,
                            "traits": traits(value.traitCollection),
                        ] as [String: Any]
                    },
                ])
                if active {
                    for value in scene.windows {
                        roots.append(("foreground-window-" + (identity(value) ?? "nil"), value))
                    }
                }
            }
            var axRoots: [[String: Any]] = []
            var cancelAX: [[String: Any]] = []
            var cancelViews: [[String: Any]] = []
            for (name, root) in roots {
                let objects = HostedAccessibility.elements(in: root)
                let views = (root as? UIView).map(rawViews) ?? []
                let cancels = objects.filter {
                    $0.isAccessibilityElement
                        && $0.accessibilityLabel == MonitorPlaybackCopy.deleteCancel
                }
                cancelAX += cancels.map { ["root": name, "node": node($0)] }
                cancelViews += views.filter {
                    ($0["visibleInHierarchy"] as? Bool) == true
                        && (($0["label"] as? String) == MonitorPlaybackCopy.deleteCancel
                            || ($0["text"] as? String) == MonitorPlaybackCopy.deleteCancel)
                }.map { ["root": name, "node": $0] }
                axRoots.append([
                    "name": name, "identity": jsonIdentity(root), "count": objects.count,
                    "atWalkLimit": objects.count == 5_000, "allAXObjects": objects.map(node),
                    "reachableAXObjects": HostedAccessibility.reachable(in: root).map(node),
                    "nativeViews": views,
                ])
            }
            let presentation = try XCTUnwrap(dialog.presentationController)
            let container = try XCTUnwrap(presentation.containerView)
            let dialogWindow = try XCTUnwrap(dialog.view.window)
            let popupFrame = container.convert(
                presentation.frameOfPresentedViewInContainerView, to: dialogWindow)
            let visible = dialogWindow.bounds.inset(by: dialogWindow.safeAreaInsets)
                .intersection(
                    dialogWindow.convert(
                        dialogWindow.screen.bounds, from: dialogWindow.screen.coordinateSpace)
                )
                .intersection(container.convert(container.bounds, to: dialogWindow))
            let point = CGPoint(x: visible.minX + 16, y: visible.maxY - 16)
            let hit = visible.isNull ? nil : dialogWindow.hitTest(point, with: nil)
            var hitChain: [UIView] = []
            var current = hit
            while let value = current {
                hitChain.append(value)
                current = value.superview
            }
            let dimming = hitChain.contains { $0.accessibilityIdentifier == "PopoverDismissRegion" }
            let localEligible =
                dialog.modalPresentationStyle == .popover && cancelAX.isEmpty && cancelViews.isEmpty
                && !visible.isNull && visible.width > 40 && visible.height > 40
                && visible.contains(point)
                && !popupFrame.insetBy(dx: -1, dy: -1).contains(point) && dimming
                && !(hit?.isDescendant(of: dialog.view) ?? true)
                && !dialog.isModalInPresentation
            let screenPoint = dialogWindow.convert(point, to: dialogWindow.screen.coordinateSpace)
            let snapshot: [String: Any] = [
                "nonce": nonce, "requestID": request.uuidString,
                "itemOwner": item.owner.uuidString, "itemRevision": item.revision,
                "createdAt": Date().timeIntervalSince1970, "settlementBudgetSeconds": 30,
                "processID": ProcessInfo.processInfo.processIdentifier,
                "deviceIdiom": UIDevice.current.userInterfaceIdiom.rawValue,
                "locale": Locale.current.identifier,
                "preferredLanguages": Locale.preferredLanguages,
                "requestedGeometry": nativeSceneGeometry ? NSNull() : [900, 420] as Any,
                "geometryMode": nativeSceneGeometry ? "native-scene" : "synthetic-900x420",
                "dialog": node(dialog),
                "dialogStyle": dialog.modalPresentationStyle.rawValue,
                "dialogTraits": traits(dialog.traitCollection),
                "dialogWindow": jsonIdentity(dialogWindow),
                "presentationClass": String(describing: type(of: presentation)),
                "adaptiveStyle": presentation.adaptivePresentationStyle.rawValue,
                "isModalInPresentation": dialog.isModalInPresentation,
                "passthroughViews": dialog.popoverPresentationController?.passthroughViews?
                    .compactMap(identity) as Any? ?? NSNull(),
                "popoverFrameInDialogWindow": rect(popupFrame),
                "visibleWindowRegion": rect(visible),
                "candidateWindowPoint": ["x": point.x, "y": point.y],
                "candidateScreenPoint": ["x": screenPoint.x, "y": screenPoint.y],
                "hitChain": hitChain.map(node), "hitIsDimmingRegion": dimming,
                "nativeCandidateEligible": localEligible, "cancelAXNodes": cancelAX,
                "visibleNativeCancelViews": cancelViews, "scenes": sceneFacts, "roots": axRoots,
                "actions": dialog.actions.map {
                    ["title": $0.title as Any? ?? NSNull(), "style": $0.style.rawValue]
                },
            ]
            let data = try JSONSerialization.data(
                withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "SIMULATED full foreground typed cancellation snapshot"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "SIMULATED full foreground cancellation data") {
                $0.add(attachment)
            }
            let marker =
                "SIMULATED_TYPED_CANCEL_REQUEST:"
                + directory.appendingPathComponent("request.json").path + "\n"
            FileHandle.standardOutput.write(Data(marker.utf8))
            return directory
        }

        private static func leaves(_ object: NSObject) -> [NSObject] {
            HostedAccessibility.elements(in: object).filter(\.isAccessibilityElement)
        }
    }
#endif
