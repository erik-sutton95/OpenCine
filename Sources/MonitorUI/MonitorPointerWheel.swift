#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// One scroll event over a view in a Mac window: this event's translation as UIKit reports it
    /// (the content's movement, so scrolling down is a negative `dy`), whether a clicking wheel or
    /// a trackpad made it, and where the pointer was, in the view's own coordinates.
    public struct MonitorPointerScroll: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        public var device: MonitorScrollAccumulator.Device
        public var location: CGPoint

        public init(dx: Double, dy: Double, device: MonitorScrollAccumulator.Device, location: CGPoint) {
            self.dx = dx
            self.dy = dy
            self.device = device
            self.location = location
        }
    }

    extension View {
        /// The pointer's hover location (nil once it leaves the window) and the scroll wheel over
        /// this view, in its own coordinates, on a Mac. It never takes a click or a touch, and other
        /// views keep their own scrolling. On an iPhone or iPad it adds nothing.
        public func monitorPointerWheel(
            onHover: @escaping @MainActor (CGPoint?) -> Void,
            onScroll: @escaping @MainActor (MonitorPointerScroll) -> Void
        ) -> some View {
            #if targetEnvironment(macCatalyst)
                background { MonitorPointerWheelReader(onHover: onHover, onScroll: onScroll) }
            #else
                self
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
        /// A view that is never hit itself: it lays the hover and scroll recognizers on its window, so
        /// they see the pointer over any view in it, and reports in its own coordinates.
        private struct MonitorPointerWheelReader: UIViewRepresentable {
            let onHover: @MainActor (CGPoint?) -> Void
            let onScroll: @MainActor (MonitorPointerScroll) -> Void

            func makeUIView(context: Context) -> MonitorPointerWheelView {
                let view = MonitorPointerWheelView()
                view.onHover = onHover
                view.onScroll = onScroll
                return view
            }

            func updateUIView(_ view: MonitorPointerWheelView, context: Context) {
                view.onHover = onHover
                view.onScroll = onScroll
            }

            static func dismantleUIView(_ view: MonitorPointerWheelView, coordinator: ()) {
                view.detach()
            }
        }

        final class MonitorPointerWheelView: UIView, UIGestureRecognizerDelegate {
            var onHover: (@MainActor (CGPoint?) -> Void)?
            var onScroll: (@MainActor (MonitorPointerScroll) -> Void)?
            private var recognizers: [UIGestureRecognizer] = []
            private var hover: UIHoverGestureRecognizer?
            private var wheel: UIPanGestureRecognizer?

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = false
                backgroundColor = .clear
                isAccessibilityElement = false
                let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
                // A clicking wheel scrolls in discrete steps, a trackpad continuously. Neither takes
                // a touch or a click (`allowedTouchTypes` empty).
                let wheel = Self.scrollRecognizer(target: self, types: .discrete)
                let trackpad = Self.scrollRecognizer(target: self, types: .continuous)
                recognizers = [hover, wheel, trackpad]
                for recognizer in recognizers {
                    recognizer.delegate = self
                    recognizer.cancelsTouchesInView = false
                    recognizer.delaysTouchesBegan = false
                    recognizer.delaysTouchesEnded = false
                }
                self.hover = hover
                self.wheel = wheel
            }

            required init?(coder: NSCoder) { nil }

            private static func scrollRecognizer(target: MonitorPointerWheelView, types: UIScrollTypeMask)
                -> UIPanGestureRecognizer
            {
                let pan = UIPanGestureRecognizer(target: target, action: #selector(scrolled(_:)))
                pan.allowedScrollTypesMask = types
                pan.allowedTouchTypes = []
                return pan
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                detach()
                guard let window else { return }
                for recognizer in recognizers { window.addGestureRecognizer(recognizer) }
            }

            func detach() {
                for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
            }

            @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
                switch recognizer.state {
                case .began, .changed: onHover?(recognizer.location(in: self))
                case .ended, .cancelled, .failed: onHover?(nil)
                default: break
                }
            }

            @objc private func scrolled(_ pan: UIPanGestureRecognizer) {
                guard pan.state == .began || pan.state == .changed else { return }
                let translation = pan.translation(in: self)
                pan.setTranslation(.zero, in: self)
                guard translation != .zero else { return }
                onScroll?(
                    MonitorPointerScroll(
                        dx: translation.x, dy: translation.y, device: pan === wheel ? .mouse : .trackpad,
                        location: pan.location(in: self)))
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool { true }
        }
    #endif
#endif
