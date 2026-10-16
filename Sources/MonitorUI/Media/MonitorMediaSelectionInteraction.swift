#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// Native input and scrolling for the shared lazy catalog. Geometry comes from
    /// mounted cell anchors, without publishing scroll offsets through SwiftUI.
    @MainActor final class MonitorMediaSelectionInteraction: NSObject, UIGestureRecognizerDelegate {
        private struct Anchor {
            let id: String
            weak var view: UIView?
        }

        // Old and new lazy layouts can coexist during a grid/list transition.
        // Retiring one view must not remove its successor with the same clip ID.
        private var anchors: [ObjectIdentifier: Anchor] = [:]
        private var controller = MonitorMediaSelectionController()
        private var publish: (Set<String>) -> Void = { _ in }
        private var feedback: (MonitorMediaSelectionFeedback) -> Void = { _ in }
        private var configuration = MonitorMediaSelectionConfiguration.standard
        private weak var scrollView: UIScrollView?
        private weak var activeRecognizer: UIGestureRecognizer?
        private var touchStart: CGPoint = .zero
        private var windowPoint: CGPoint = .zero
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var viewportWidth: CGFloat = 0
        private var viewportHeight: CGFloat = 0
        private var context = ""
        private weak var mountedProbe: UIView?

        private lazy var hold: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle))
            recognizer.minimumPressDuration = 0.28
            recognizer.allowableMovement = 8
            recognizer.delegate = self
            return recognizer
        }()
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        func configure(
            ids: [String], selected: Set<String>, selecting: Bool, context: String,
            configuration: MonitorMediaSelectionConfiguration = .standard,
            feedback: @escaping (MonitorMediaSelectionFeedback) -> Void = { _ in },
            publish: @escaping (Set<String>) -> Void
        ) {
            if controller.ids != ids || self.context != context
                || self.configuration != configuration
                || (controller.selecting && !selecting)
            {
                cancel()
            }
            if let scroll = scrollView, controller.consuming,
                abs(scroll.bounds.width - viewportWidth) >= 1
            {
                cancel()
            }
            controller.configuration = configuration
            controller.movementTolerance = configuration.movementTolerance
            controller.holdMilliseconds = configuration.holdMilliseconds
            controller.bind(ids: ids, selecting: selecting, selected: selected, context: context)
            self.context = context
            self.configuration = configuration
            self.feedback = feedback
            self.publish = publish
            hold.minimumPressDuration = Double(configuration.holdMilliseconds) / 1_000
            hold.allowableMovement = configuration.movementTolerance
        }

        func register(id: String, view: UIView) {
            anchors[ObjectIdentifier(view)] = Anchor(id: id, view: view)
        }

        func unregister(view: UIView) {
            anchors.removeValue(forKey: ObjectIdentifier(view))
        }

        func attach(from view: UIView) {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView {
                    if scrollView === scroll {
                        mountedProbe = view
                        return
                    }
                    detach()
                    scrollView = scroll
                    mountedProbe = view
                    viewportWidth = scroll.bounds.width
                    viewportHeight = scroll.bounds.height
                    scroll.addGestureRecognizer(hold)
                    scroll.addGestureRecognizer(pan)
                    // Browsing rejects this pan immediately. Selection gives it
                    // first refusal so scrolling and pull-refresh cannot compete.
                    scroll.panGestureRecognizer.require(toFail: pan)
                    return
                }
                ancestor = candidate.superview
            }
        }

        func detach() {
            cancel()
            scrollView?.removeGestureRecognizer(hold)
            scrollView?.removeGestureRecognizer(pan)
            scrollView = nil
            mountedProbe = nil
        }

        func detach(from probe: UIView) {
            guard mountedProbe === probe else { return }
            detach()
        }

        func cancel() {
            finish()
            hold.isEnabled = false
            pan.isEnabled = false
            hold.isEnabled = true
            pan.isEnabled = true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            guard let scroll = scrollView, scroll.window != nil,
                controller.selecting || configuration.allowsSelectionEntry,
                gestureRecognizer !== pan || (controller.selecting && configuration.sweepsSideways),
                let id = item(at: touch.location(in: scroll), nearest: false)
            else { return false }
            touchStart = touch.location(in: scroll)
            controller.down(id: id, x: touchStart.x, y: touchStart.y, timeMilliseconds: 0)
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard controller.canBegin else { return false }
            if gestureRecognizer === pan {
                guard controller.selecting && configuration.sweepsSideways else { return false }
                let location = gestureRecognizer.location(in: scrollView)
                // Vertical swipes remain native scrolling, even in selection
                // mode. A sideways start claims a sweep; hold permits any axis.
                return abs(location.x - touchStart.x) > abs(location.y - touchStart.y)
            }
            return true
        }

        @objc private func handle(_ recognizer: UIGestureRecognizer) {
            guard let scroll = scrollView else { return }
            windowPoint = recognizer.location(in: scroll.window)
            switch recognizer.state {
            case .began:
                let point = recognizer.location(in: scroll)
                let event =
                    recognizer === hold
                    ? controller.holdDue(timeMilliseconds: controller.holdMilliseconds)
                    : controller.move(id: item(at: point, nearest: true), x: point.x, y: point.y)
                guard controller.consuming else { return }
                activeRecognizer = recognizer
                viewportWidth = scroll.bounds.width
                viewportHeight = scroll.bounds.height
                publishSelection(event)
                updateSelection()
                updateClock()
            case .changed:
                guard activeRecognizer === recognizer else { return }
                updateSelection()
                updateClock()
            case .ended:
                guard activeRecognizer === recognizer else { return }
                updateSelection()
                finish()
            case .cancelled, .failed:
                guard activeRecognizer === recognizer else { return }
                finish()
            default: break
            }
        }

        private func publishSelection(_ event: MonitorMediaSelectionController.News?) {
            guard case .selection(_, let value, let result) = event else { return }
            publish(value)
            if let result { feedback(result) }
        }

        private func updateSelection() {
            guard let scroll = scrollView, controller.consuming else { return }
            let point = scroll.convert(windowPoint, from: scroll.window)
            publishSelection(
                controller.move(id: item(at: point, nearest: true), x: point.x, y: point.y))
        }

        private func item(at point: CGPoint, nearest: Bool) -> String? {
            guard let scroll = scrollView else { return nil }
            let visible = scroll.bounds
            if !nearest && !visible.contains(point) { return nil }
            let clamped = CGPoint(
                x: min(visible.maxX - 1, max(visible.minX + 1, point.x)),
                y: min(visible.maxY - 1, max(visible.minY + 1, point.y)))
            var closest: (String, CGFloat)?
            for anchor in anchors.values {
                let id = anchor.id
                guard controller.contains(id), let view = anchor.view, view.window != nil else {
                    continue
                }
                let frame = view.convert(view.bounds, to: scroll)
                guard !frame.isEmpty, frame.intersects(visible) else { continue }
                if frame.contains(clamped) { return id }
                if nearest {
                    let dx = max(frame.minX - clamped.x, 0, clamped.x - frame.maxX)
                    let dy = max(frame.minY - clamped.y, 0, clamped.y - frame.maxY)
                    let distance = dx * dx + dy * dy
                    if closest == nil || distance < closest!.1 { closest = (id, distance) }
                }
            }
            return nearest ? closest?.0 : nil
        }

        private func edgeVelocity() -> Double {
            guard controller.consuming, let scroll = scrollView else { return 0 }
            let point = scroll.convert(windowPoint, from: scroll.window)
            let pointerY = Double(point.y - scroll.bounds.minY)
            // The selection tray shrinks the gallery as the sweep begins; that alone must not scroll.
            if abs(scroll.bounds.height - viewportHeight) >= 1 {
                controller.viewportResized(pointerY: pointerY)
                viewportHeight = scroll.bounds.height
            }
            guard point.x >= scroll.bounds.minX - 32, point.x <= scroll.bounds.maxX + 32 else {
                return 0
            }
            return controller.edgeVelocity(
                pointerY: pointerY, viewportHeight: Double(scroll.bounds.height))
        }

        private func updateClock() {
            guard edgeVelocity() != 0 else {
                stopClock()
                return
            }
            guard displayLink == nil else { return }
            let link = CADisplayLink(
                target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
            let maximum = Float(scrollView?.window?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        fileprivate func tick(_ link: CADisplayLink) {
            guard controller.consuming, let scroll = scrollView, scroll.window != nil,
                abs(scroll.bounds.width - viewportWidth) < 1,
                UIApplication.shared.applicationState == .active
            else {
                cancel()
                return
            }
            let elapsed =
                lastTimestamp == 0
                ? link.targetTimestamp - link.timestamp : link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            let velocity = edgeVelocity()
            guard velocity != 0 else {
                stopClock()
                return
            }
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(
                minimum,
                scroll.contentSize.height - scroll.bounds.height
                    + scroll.adjustedContentInset.bottom)
            let offset = min(
                maximum,
                max(
                    minimum,
                    scroll.contentOffset.y
                        + MonitorMediaSelectionScroll.step(
                            pointerY: scroll.convert(windowPoint, from: scroll.window).y
                                - scroll.bounds.minY,
                            viewportHeight: scroll.bounds.height, elapsed: elapsed,
                            configuration: configuration)))
            if abs(offset - scroll.contentOffset.y) > 0.01 {
                scroll.setContentOffset(
                    CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            } else {
                stopClock()
            }
            updateSelection()
        }

        private func finish() {
            stopClock()
            controller.cancel()
            activeRecognizer = nil
            touchStart = .zero
        }

        private func stopClock() {
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = 0
        }

        @MainActor private final class DisplayTarget: NSObject {
            weak var owner: MonitorMediaSelectionInteraction?
            init(_ owner: MonitorMediaSelectionInteraction) { self.owner = owner }
            @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
        }
    }

    struct MonitorMediaSelectionBridge: UIViewRepresentable {
        let interaction: MonitorMediaSelectionInteraction
        let ids: [String]
        let selected: Set<String>
        let selecting: Bool
        let context: String
        var configuration: MonitorMediaSelectionConfiguration = .standard
        var feedback: (MonitorMediaSelectionFeedback) -> Void = { _ in }
        let publish: (Set<String>) -> Void

        func makeUIView(context: Context) -> Probe { Probe(interaction: interaction) }
        func updateUIView(_ view: Probe, context: Context) {
            if view.interaction !== interaction {
                view.interaction.detach(from: view)
                view.interaction = interaction
            }
            interaction.configure(
                ids: ids, selected: selected, selecting: selecting, context: self.context,
                configuration: configuration, feedback: feedback,
                publish: publish)
            interaction.attach(from: view)
        }
        static func dismantleUIView(_ view: Probe, coordinator: ()) {
            view.interaction.detach(from: view)
        }

        final class Probe: UIView {
            var interaction: MonitorMediaSelectionInteraction
            init(interaction: MonitorMediaSelectionInteraction) {
                self.interaction = interaction
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window == nil {
                    interaction.detach(from: self)
                } else {
                    interaction.attach(from: self)
                }
            }
        }
    }

    /// A mounted cell's native bounds. Lazy retirement removes only that view's
    /// anchor, so an older layout cannot evict its replacement with the same ID.
    struct MonitorMediaSelectionAnchor: View {
        let id: String
        let interaction: MonitorMediaSelectionInteraction

        var body: some View {
            MonitorMediaSelectionAnchorView(id: id, interaction: interaction)
        }
    }

    private struct MonitorMediaSelectionAnchorView: UIViewRepresentable {
        let id: String
        let interaction: MonitorMediaSelectionInteraction
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            interaction.register(id: id, view: view)
            return view
        }
        func updateUIView(_ view: UIView, context: Context) {
            if context.coordinator.interaction !== interaction {
                context.coordinator.interaction.unregister(view: view)
                context.coordinator.interaction = interaction
            }
            interaction.register(id: id, view: view)
        }
        func makeCoordinator() -> Coordinator { Coordinator(interaction: interaction) }
        static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
            coordinator.interaction.unregister(view: view)
        }
        final class Coordinator {
            var interaction: MonitorMediaSelectionInteraction
            init(interaction: MonitorMediaSelectionInteraction) {
                self.interaction = interaction
            }
        }
    }
#endif
