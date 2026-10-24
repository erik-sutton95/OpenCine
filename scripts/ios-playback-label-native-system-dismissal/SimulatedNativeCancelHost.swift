import MonitorPresentation
import MonitorUI
import OpenCineMedia
import SwiftUI
import UIKit

@main
@MainActor
final class SimulatedNativeCancelApp: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "SIMULATED native system dismissal", sessionRole: session.role)
        configuration.delegateClass = SimulatedNativeCancelScene.self
        return configuration
    }
}

@MainActor
final class SimulatedNativeCancelScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var scenario: SimulatedNativeCancelScenario?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let scenario = SimulatedNativeCancelScenario(scene: scene)
        self.scenario = scenario
        window = scenario.window
    }
}

// Owns the same actual shared screen, frozen values and typed action recorder as the original
// fixture. Nothing opens media or connects a deletion service. Only native UI can open/dismiss it.
@MainActor
private final class SimulatedNativeCancelScenario: NSObject {
    let item = MonitorPlaybackItemToken(owner: UUID(), revision: 1)
    let request = MonitorPlaybackDeletionConfirmation(
        title: NativeCancelContract.title, message: NativeCancelContract.message)
    let nonce: String
    let sourceSeal: String
    let simulatorID: String
    let receiptURL: URL
    let window: UIWindow
    private var host: UIHostingController<AnyView>!
    private var observedGeometry: MonitorPlaybackPictureGeometry?
    private var observedDialog: UIAlertController?
    private var timer: Timer?
    private var sequence: UInt64 = 0
    private var capturedItems: [MonitorPlaybackItemToken] = []
    private var captureRequestIDs: [UUID] = []
    private var confirmed: [UUID] = []
    private var cancelled: [UUID] = []
    private var deleted: [MonitorPlaybackItemToken] = []
    private var active: [UUID] = []
    private var retired: [UUID] = []

    init(scene: UIWindowScene) {
        #if !targetEnvironment(simulator)
            fatalError("SIMULATED developer host requires its private simulator")
        #endif
        let environment = ProcessInfo.processInfo.environment
        nonce = environment["OPENCINE_NATIVE_UI_NONCE"] ?? ""
        sourceSeal = environment["OPENCINE_NATIVE_UI_SOURCE_SEAL"] ?? ""
        simulatorID = environment["SIMULATOR_UDID"] ?? ""
        precondition(UUID(uuidString: nonce) != nil && UUID(uuidString: simulatorID) != nil)
        precondition(sourceSeal.count == 64)
        precondition(Bundle.main.bundleIdentifier == environment["OPENCINE_NATIVE_UI_BUNDLE_ID"])
        precondition(environment["OPENCINE_NATIVE_UI_MODE"] == "native-system-popover-dismissal")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            NativeCancelContract.receiptPrefix + nonce, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        receiptURL = directory.appendingPathComponent("app-receipt.json")
        window = UIWindow(windowScene: scene)
        super.init()
        let value = MonitorPlaybackPresentation(
            item: item, title: "SIMULATED clip", subtitle: "SIMULATED detail", source: nil,
            metadata: [MonitorMetadataRow("Codec", "SIMULATED")], aspect: 16.0 / 9.0,
            ready: true, position: 7.9, duration: 30, positionLabel: "00:07",
            durationLabel: "00:30",
            playing: false, reachedEnd: false, scrubbing: false, muted: false, looping: true,
            previous: true, next: true, favorite: false, conform: .init(captureRate: 60),
            conformTarget: nil, haptics: false)
        var actions = MonitorPlaybackActions(
            back: {}, play: { _, _ in }, restart: { _ in }, seekBy: { _, _ in }, mute: { _, _ in },
            loop: { _, _ in }, conform: { _, _ in }, adjacent: { _, _ in }, favorite: { _ in },
            share: { _ in }, delete: nil, beginScrub: { _ in nil }, updateScrub: { _, _ in },
            updateFrameScrub: { _, _, _ in }, commitScrub: { _ in }, cancelScrub: { _, _ in })
        actions.deletionConfirmation = MonitorPlaybackDeletionActions(
            capture: { [unowned self] captured in
                capturedItems.append(captured)
                captureRequestIDs.append(request.id)
                active.append(request.id)
                return request
            },
            isCurrent: { [unowned self] in $0 == request.id },
            confirm: { [unowned self] id in
                confirmed.append(id)
                retire(id)
            },
            cancel: { [unowned self] id in
                cancelled.append(id)
                retire(id)
            })
        let screen = MonitorPlaybackScreen(
            value: value, actions: actions,
            onGeometry: { [weak self] geometry in self?.observedGeometry = geometry },
            picture: { Color.black },
            feedAssists: { _ in EmptyView() },
            canvasAssists: { _, _ in EmptyView() }, tools: { _ in EmptyView() }
        ).environment(\.scenePhase, .active)
        host = UIHostingController(
            rootView: AnyView(screen.frame(maxWidth: .infinity, maxHeight: .infinity)))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        let timer = Timer(
            timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil,
            repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        observe()
    }

    // The shared input guard rejects any visible scene window covering the dismissal point
    // (nativeContractInputRejections). UIKit adds its own UITextEffectsWindow above this one when
    // the confirmation is presented, so, like the hosted fixture's hideOtherWindows, this host
    // owns every other scene window: hidden and transparent before each observation. A window
    // UIKit adds or shows again later is hidden again on the next tick (50 ms).
    @objc private func tick() {
        if let scene = window.windowScene {
            for other in scene.windows where other !== window {
                other.isHidden = true
                other.alpha = 0
            }
        }
        observe()
    }

    // Retirement is recorded only on an actual callback from the shared screen, never on input
    // invocation, a receipt read, an expected ID, a driver message, or ordinary host teardown.
    private func retire(_ id: UUID) {
        if let index = active.firstIndex(of: id) {
            active.remove(at: index)
            retired.append(id)
        }
        observe()
    }

    @objc private func observe() {
        guard let scene = window.windowScene, let host else { return }
        var controller: UIViewController? = host
        var mounted: UIAlertController?
        while let current = controller {
            if let alert = current as? UIAlertController, alert.viewIfLoaded?.window != nil {
                mounted = alert
            }
            controller = current.presentedViewController
        }
        if let mounted { observedDialog = mounted }
        let nativePopup: NativeCancelPopup? = mounted.flatMap { dialog in
            guard let presentation = dialog.presentationController,
                let container = presentation.containerView
            else { return nil }
            let frame = dialog.view.convert(dialog.view.bounds, to: window.screen.coordinateSpace)
            let presentationFrame = container.convert(
                presentation.frameOfPresentedViewInContainerView, to: window.screen.coordinateSpace)
            guard !frame.isEmpty, !frame.isNull, !presentationFrame.isEmpty,
                !presentationFrame.isNull
            else { return nil }
            var strings = Set<String>()
            var count = 0
            func visit(_ view: UIView) {
                guard count < 5_000, !view.isHidden, view.alpha >= 0.01 else { return }
                count += 1
                if let text = (view as? UILabel)?.text { strings.insert(text) }
                if let text = view.accessibilityLabel { strings.insert(text) }
                for child in view.subviews { visit(child) }
            }
            visit(dialog.view)
            return NativeCancelPopup(
                identity: String(describing: ObjectIdentifier(dialog)), title: dialog.title,
                message: dialog.message,
                actions: dialog.actions.map {
                    NativeCancelAction(title: $0.title, style: $0.style.rawValue)
                },
                frame: NativeCancelRect(frame),
                presentationFrame: NativeCancelRect(presentationFrame),
                mountedInHostWindow: dialog.view.window === window && container.window === window
                    && !dialog.isBeingPresented && scene.activationState == .foregroundActive,
                renderedStrings: strings.sorted(), viewWalkAtLimit: count >= 5_000,
                presentationClass: String(describing: type(of: presentation)),
                modalStyle: dialog.modalPresentationStyle.rawValue,
                horizontalSizeClass: dialog.traitCollection.horizontalSizeClass.rawValue,
                verticalSizeClass: dialog.traitCollection.verticalSizeClass.rawValue)
        }
        let dismissal = mounted.map { systemDismissal(dialog: $0, scene: scene) }
        sequence += 1
        let receipt = NativeCancelReceipt(
            schema: 1, nonce: nonce, sourceSeal: sourceSeal,
            bundleID: Bundle.main.bundleIdentifier!,
            simulatorID: simulatorID, processID: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence, observedAt: Date().timeIntervalSince1970, requestID: request.id,
            item: NativeCancelItem(owner: item.owner, revision: item.revision),
            capturedItems: capturedItems.map {
                NativeCancelItem(owner: $0.owner, revision: $0.revision)
            },
            captureRequestIDs: captureRequestIDs, confirmed: confirmed, cancelled: cancelled,
            deletedCount: deleted.count,
            activeRequestIDs: active, retiredRequestIDs: retired,
            foreground: scene.activationState == .foregroundActive
                && UIApplication.shared.applicationState == .active,
            keyWindow: window.isKeyWindow && !window.isHidden,
            rootMounted: host.view.window === window,
            sceneID: scene.session.persistentIdentifier,
            windowIdentity: String(describing: ObjectIdentifier(window)),
            windowFrame: NativeCancelRect(
                window.convert(window.bounds, to: window.screen.coordinateSpace)),
            screenFrame: NativeCancelRect(window.screen.bounds),
            rootFillsScene: window.frame == scene.coordinateSpace.bounds
                && host.view.frame == window.bounds,
            orientation: scene.interfaceOrientation.rawValue, popup: nativePopup,
            dialogWindowGone: observedDialog != nil && observedDialog?.viewIfLoaded?.window == nil,
            presentingControllerGone: observedDialog != nil
                && observedDialog?.presentingViewController == nil,
            mode: "native-system-popover-dismissal",
            windows: scene.windows.map {
                NativeSystemWindow(
                    identity: identity($0), sceneID: $0.windowScene?.session.persistentIdentifier,
                    frame: NativeCancelRect(
                        $0.convert($0.bounds, to: window.screen.coordinateSpace)),
                    key: $0.isKeyWindow, hidden: $0.isHidden,
                    rootController: $0.rootViewController.map(identity))
            },
            systemDismissal: dismissal?.0,
            systemDismissalRejections: dismissal?.1 ?? ["No mounted native dialog"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // This is the only receipt write. There is deliberately no receipt reader in the app.
        try! encoder.encode(receipt).write(to: receiptURL, options: .atomic)
    }

    private func identity(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    // Existing shared-screen geometry is observed without requesting layout or changing values.
    // Public semantic leaves cover the frozen buttons/scrubber; the actual emitted feed covers
    // every other gesture in this frozen screen. Empty host slots add no custom interaction.
    private func neutralBackground(point: CGPoint) -> NativeSystemNeutralBackground? {
        guard let geometry = observedGeometry else { return nil }
        var seen = Set<ObjectIdentifier>()
        var actionables: [NativeSystemActionable] = []
        var opaque = 0
        var atLimit = false
        func record(_ object: NSObject) {
            let traits = object.accessibilityTraits
            let custom = object.accessibilityCustomActions?.count ?? 0
            let other =
                traits.contains(.link) || traits.contains(.searchField)
                || traits.contains(.keyboardKey) || traits.contains(.allowsDirectInteraction)
            guard
                object is UIControl || custom > 0 || traits.contains(.button)
                    || traits.contains(.adjustable) || other
                    || (object.isAccessibilityElement
                        && object.accessibilityRespondsToUserInteraction)
            else { return }
            let kind: String
            if object.isAccessibilityElement && traits.contains(.button)
                && !traits.contains(.adjustable) && !other
            {
                kind = "button"
            } else if object.isAccessibilityElement && traits.contains(.adjustable)
                && !traits.contains(.button) && !other
            {
                kind = "adjustable"
            } else {
                kind = "unknown"
            }
            actionables.append(
                NativeSystemActionable(
                    identity: identity(object), label: object.accessibilityLabel, kind: kind,
                    frame: NativeCancelRect(object.accessibilityFrame), customActions: custom))
        }
        func children(_ object: NSObject) -> [NSObject] {
            if object.isAccessibilityElement { return [] }
            for raw in [object.automationElements, object.accessibilityElements] {
                if let raw, !raw.isEmpty {
                    guard let values = raw as? [NSObject] else {
                        opaque += 1
                        return []
                    }
                    return values
                }
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                guard count < 5_000 else {
                    atLimit = true
                    return []
                }
                return (0..<count).compactMap { index in
                    guard let value = object.accessibilityElement(at: index) as? NSObject else {
                        opaque += 1
                        return nil
                    }
                    return value
                }
            }
            if count < 0 { opaque += 1 }
            return (object as? UIView)?.subviews ?? []
        }
        func visit(_ object: NSObject) {
            guard seen.count < 5_000 else {
                atLimit = true
                return
            }
            guard seen.insert(ObjectIdentifier(object)).inserted else {
                opaque += 1
                return
            }
            if let view = object as? UIView {
                guard view.alpha.isFinite else {
                    opaque += 1
                    return
                }
                if view.isHidden || view.alpha < 0.01 { return }
            }
            // Hidden semantic subtrees cannot silently establish complete interaction coverage.
            guard !object.accessibilityElementsHidden else {
                opaque += 1
                return
            }
            record(object)
            for child in children(object) { visit(child) }
        }
        visit(host.view)
        // A native control/custom action outside the canonical semantic route is unknown,
        // even if a hosting container omits it from its vended accessibility children.
        var nativeCount = 0
        func nativeControls(_ view: UIView) {
            guard nativeCount < 5_000 else {
                atLimit = true
                return
            }
            nativeCount += 1
            guard view.alpha.isFinite else {
                opaque += 1
                return
            }
            guard !view.isHidden, view.alpha >= 0.01 else { return }
            if !seen.contains(ObjectIdentifier(view)),
                view is UIControl || !(view.accessibilityCustomActions ?? []).isEmpty
            {
                record(view)
            }
            for child in view.subviews { nativeControls(child) }
        }
        nativeControls(host.view)
        let local = host.view.convert(point, from: window)
        return NativeSystemNeutralBackground(
            item: geometry.item.map { NativeCancelItem(owner: $0.owner, revision: $0.revision) },
            canvas: NativeCancelRect(CGRect(origin: .zero, size: geometry.canvas)),
            feed: NativeCancelRect(geometry.feed), zoomScale: Double(geometry.zoom.scale),
            zoomOffset: NativeSystemPoint(
                CGPoint(
                    x: geometry.zoom.offset.width, y: geometry.zoom.offset.height)),
            hostBounds: NativeCancelRect(host.view.bounds),
            hostFrameOnScreen: NativeCancelRect(
                host.view.convert(host.view.bounds, to: window.screen.coordinateSpace)),
            hostTransformIdentity: host.view.transform.isIdentity,
            pointInHost: NativeSystemPoint(local),
            pointBackInWindow: NativeSystemPoint(host.view.convert(local, to: window)),
            actionables: actionables, publicWalkCount: seen.count,
            publicWalkAtLimit: atLimit, opaqueObjects: opaque)
    }

    // Read-only public UIKit observations. This never creates a surface, assigns a delegate,
    // changes passthrough policy or geometry, calls an action, or dismisses any controller.
    private func systemDismissal(dialog: UIAlertController, scene: UIWindowScene)
        -> (NativeSystemDismissalProof?, [String])
    {
        guard let popover = dialog.popoverPresentationController,
            let presentation = dialog.presentationController,
            let container = presentation.containerView,
            let popoverContainer = popover.containerView,
            let presenting = dialog.presentingViewController
        else {
            return (nil, ["Public popover/controller/container/presenting ownership unavailable"])
        }
        let visible = window.bounds.inset(by: window.safeAreaInsets)
            .intersection(window.convert(window.screen.bounds, from: window.screen.coordinateSpace))
            .intersection(container.convert(container.bounds, to: window))
        guard NativeCancelRect(visible).finite else {
            return (nil, ["The sole original-rule visible intersection is not finite and nonempty"])
        }
        // The sole original candidate rule. No scan, clamping, fallback, retry or point search.
        let point = CGPoint(x: visible.minX + 16, y: visible.maxY - 16)
        let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
        let popupFrame = dialog.view.convert(dialog.view.bounds, to: window.screen.coordinateSpace)
        let presentationFrame = container.convert(
            presentation.frameOfPresentedViewInContainerView, to: window.screen.coordinateSpace)
        func node(_ view: UIView) -> NativeSystemView {
            NativeSystemView(
                identity: identity(view), parent: view.superview.map(identity),
                window: view.window.map(identity),
                diagnosticClass: String(describing: type(of: view)),
                identifier: view.accessibilityIdentifier, label: view.accessibilityLabel,
                frame: NativeCancelRect(
                    view.convert(view.bounds, to: window.screen.coordinateSpace)),
                hidden: view.isHidden, alpha: Double(view.alpha),
                interactive: view.isUserInteractionEnabled,
                control: view is UIControl,
                sharedContent: view === host.view || view.isDescendant(of: host.view),
                popupContent: view === dialog.view || view.isDescendant(of: dialog.view))
        }
        func visibleAtPoint(_ view: UIView) -> Bool {
            guard view.window === window else { return false }
            var current: UIView? = view
            while let value = current {
                if value.isHidden || value.alpha < 0.01 { return false }
                current = value.superview
            }
            return view.convert(view.bounds, to: window.screen.coordinateSpace).contains(
                screenPoint)
        }
        var views: [UIView] = []
        func visit(_ view: UIView) {
            guard views.count < 5_000 else { return }
            views.append(view)
            for child in view.subviews { visit(child) }
        }
        visit(window)
        let regions = views.filter { $0.accessibilityIdentifier == "PopoverDismissRegion" }
        let controls = views.filter { $0 is UIControl && visibleAtPoint($0) }
        let passthrough = popover.passthroughViews ?? []
        // hitTest observes the deepest native view. The shared pure policy separately requires
        // the exact frozen neutral background and the active public popover contract.
        let finitePoint =
            point.x.isFinite && point.y.isFinite && !visible.isNull && !visible.isEmpty
        var hitChain: [UIView] = []
        var current = finitePoint ? window.hitTest(point, with: nil) : nil
        while let value = current, hitChain.count < 128 {
            hitChain.append(value)
            current = value.superview
        }
        let passthroughAtPoint = passthrough.filter { view in
            visibleAtPoint(view) || hitChain.contains { $0 === view || $0.isDescendant(of: view) }
        }
        // A window can be key while another non-key window intercepts this exact point.
        // Without public proof excluding every other eligible window, withhold input even
        // when the selected window's backdrop is generally accessible and hittable.
        let sceneWindows = scene.windows
        let otherWindowHits = sceneWindows.filter { $0 !== window }.map { other in
            let local = other.convert(screenPoint, from: window.screen.coordinateSpace)
            let converted = other.convert(local, to: window.screen.coordinateSpace)
            let finite = NativeSystemPoint(local).finite && NativeSystemPoint(converted).finite
            let eligible = !other.isHidden && other.alpha >= 0.01 && other.isUserInteractionEnabled
            let hit = eligible && finite ? other.hitTest(local, with: nil) : nil
            return NativeSystemOtherWindowHit(
                identity: identity(other), sceneID: other.windowScene?.session.persistentIdentifier,
                screen: identity(other.screen), hidden: other.isHidden, alpha: Double(other.alpha),
                frame: NativeCancelRect(
                    other.convert(other.bounds, to: window.screen.coordinateSpace)),
                interactive: other.isUserInteractionEnabled,
                pointInWindow: finite ? NativeSystemPoint(local) : nil,
                convertedScreenPoint: finite ? NativeSystemPoint(converted) : nil,
                hitTestObserved: eligible && finite, hitIdentity: hit.map(identity))
        }
        var controllers: [UIViewController] = []
        var controller: UIViewController? = host
        while let value = controller, controllers.count < 128 {
            controllers.append(value)
            controller = value.presentedViewController
        }
        let inHostChain = controllers.contains { $0 === presenting }
        var rejected: [String] = []
        if sceneWindows.filter({ $0 === window }).count != 1
            || otherWindowHits.contains(where: {
                !$0.alpha.isFinite
                    || (!$0.hidden && $0.alpha >= 0.01 && $0.interactive
                        && ($0.sceneID != scene.session.persistentIdentifier
                            || $0.screen != identity(window.screen)
                            || !$0.hitTestObserved || $0.hitIdentity != nil
                            || $0.convertedScreenPoint?.point != screenPoint))
            })
        {
            rejected.append(
                "Public exact-point observations do not exclude another scene window intercepting input"
            )
        }
        if popover !== presentation || container !== popoverContainer
            || popover.presentedViewController !== dialog
            || popover.presentingViewController !== presenting || !inHostChain
        {
            rejected.append(
                "Public popover/controller identities do not describe this presentation")
        }
        if container.window !== window || dialog.view.window !== window
            || !dialog.view.isDescendant(of: container) || window.windowScene !== scene
        {
            rejected.append("Public container/presented view/window/scene ownership mismatch")
        }
        if dialog.modalPresentationStyle != .popover || dialog.isModalInPresentation
            || dialog.isBeingPresented || dialog.isBeingDismissed
        {
            rejected.append("Presentation is transitioning, modal, or not an actual popover")
        }
        if !finitePoint || visible.width <= 40 || visible.height <= 40 || !visible.contains(point)
            || !window.bounds.contains(point)
            || !window.screen.bounds.contains(screenPoint)
            || popupFrame.insetBy(dx: -1, dy: -1).contains(screenPoint)
            || presentationFrame.insetBy(dx: -1, dy: -1).contains(screenPoint)
        {
            rejected.append("The sole original-rule point is not a visible outside point")
        }
        if window.convert(screenPoint, from: window.screen.coordinateSpace) != point {
            rejected.append("Native window/screen point does not round-trip exactly")
        }
        if views.count >= 5_000 || hitChain.count >= 128 || controllers.count >= 128 {
            rejected.append("Native traversal reached its diagnostic limit")
        }
        var proof = NativeSystemDismissalProof(
            popover: identity(popover), presentation: identity(presentation),
            presented: identity(popover.presentedViewController),
            expectedPresented: identity(dialog),
            presenting: identity(popover.presentingViewController),
            expectedPresenting: identity(presenting),
            presentingInHostChain: inHostChain,
            container: identity(container), popoverContainer: identity(popoverContainer),
            containerWindow: container.window.map(identity), presentedView: identity(dialog.view),
            sharedView: identity(host.view), window: identity(window),
            sceneID: scene.session.persistentIdentifier,
            selectedScreen: identity(window.screen),
            screenScale: Double(window.screen.scale),
            sceneWindowIDs: sceneWindows.map(identity).sorted(),
            otherWindowHits: otherWindowHits,
            modalStyle: dialog.modalPresentationStyle.rawValue,
            presentationStyle: presentation.presentationStyle.rawValue,
            arrowDirection: popover.arrowDirection.rawValue,
            fullscreen: presentation.shouldPresentInFullscreen,
            neutralBackground: neutralBackground(point: point),
            modalInPresentation: dialog.isModalInPresentation,
            transitioning: dialog.isBeingPresented || dialog.isBeingDismissed,
            windowBounds: NativeCancelRect(window.bounds),
            safeWindowBounds: NativeCancelRect(window.bounds.inset(by: window.safeAreaInsets)),
            screenBoundsInWindow: NativeCancelRect(
                window.convert(window.screen.bounds, from: window.screen.coordinateSpace)),
            containerBoundsInWindow: NativeCancelRect(
                container.convert(container.bounds, to: window)),
            visible: NativeCancelRect(visible), pointInWindow: NativeSystemPoint(point),
            pointOnScreen: NativeSystemPoint(screenPoint),
            convertedBack: NativeSystemPoint(
                window.convert(screenPoint, from: window.screen.coordinateSpace)),
            popupFrameOnScreen: NativeCancelRect(popupFrame),
            presentationFrameOnScreen: NativeCancelRect(presentationFrame),
            regions: regions.map(node), hitChain: hitChain.map(node),
            controlsAtPoint: controls.map(node),
            passthroughViews: passthrough.map(node),
            passthroughAtPoint: passthroughAtPoint.map(identity),
            walkAtLimit: views.count >= 5_000 || hitChain.count >= 128 || controllers.count >= 128,
            rejections: rejected)
        rejected += nativeContractInputRejections(
            proof, item: NativeCancelItem(owner: item.owner, revision: item.revision),
            windowFrame: NativeCancelRect(
                window.convert(window.bounds, to: window.screen.coordinateSpace)))
        proof.rejections = rejected
        return (proof, rejected)
    }
}
