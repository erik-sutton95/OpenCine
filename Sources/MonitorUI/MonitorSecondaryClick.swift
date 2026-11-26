#if os(iOS)
    import SwiftUI
    import UIKit
    import os

    /// On a Mac, a secondary click (right-click, or Control-click) does what a long press does on a
    /// touch screen. Click-and-hold keeps working as the long press. iPhone and iPad are unchanged:
    /// nothing is attached there.
    ///
    /// On the Mac one recognizer per window (`buttonMaskRequired = .secondary`, recognizing beside
    /// every other recognizer and cancelling no touches) takes the click before SwiftUI's own
    /// gestures can claim it, and hands it to the smallest registered region under the pointer that
    /// is on screen: a SwiftUI view (`monitorSecondaryClick`) or a UIKit view (`register`).
    public enum MonitorSecondaryClick {
        /// True where a secondary click stands in for a long press: a Mac (Mac Catalyst) only.
        public static var standsInForLongPress: Bool {
            #if targetEnvironment(macCatalyst)
                true
            #else
                false
            #endif
        }

        /// One secondary click: one tap of the secondary button.
        @MainActor static func configure(_ recognizer: UITapGestureRecognizer) -> UITapGestureRecognizer {
            recognizer.buttonMaskRequired = .secondary
            recognizer.numberOfTapsRequired = 1
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            return recognizer
        }

        /// Runs `action` with the click's point in `view` when a Mac's secondary click lands on it.
        /// Returns the registration to keep (dropping it, or `cancel()`, ends it), or nil on iPhone
        /// and iPad, where nothing is attached.
        @MainActor public static func register(
            _ view: UIView, enabled: @escaping () -> Bool = { true }, action: @escaping (CGPoint) -> Void
        ) -> MonitorSecondaryClickRegistration? {
            #if targetEnvironment(macCatalyst)
                let registration = MonitorSecondaryClickRegistration(view: view, enabled: enabled, action: action)
                MonitorSecondaryClickRouter.shared.add(registration)
                return registration
            #else
                return nil
            #endif
        }
    }

    /// A UIKit view's secondary click (`MonitorSecondaryClick.register`).
    @MainActor public final class MonitorSecondaryClickRegistration {
        fileprivate weak var view: UIView?
        fileprivate let enabled: () -> Bool
        fileprivate let action: (CGPoint) -> Void

        fileprivate init(view: UIView, enabled: @escaping () -> Bool, action: @escaping (CGPoint) -> Void) {
            self.view = view
            self.enabled = enabled
            self.action = action
        }

        /// Ends the registration.
        public func cancel() { view = nil }
    }

    extension View {
        /// On a Mac, a secondary click runs `action`, the view's long-press action; `enabled` is read
        /// when the click lands. Nothing changes on iPhone or iPad.
        public func monitorSecondaryClick(enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
            modifier(MonitorSecondaryClickModifier(enabled: enabled, action: action))
        }
    }

    extension View {
        /// On a Mac, a right-click menu with `items`, such as what a phone keeps behind a "..." button.
        /// Nothing changes on iPhone or iPad.
        public func monitorMacContextMenu<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
            modifier(MonitorMacContextMenuModifier(items: items))
        }
    }

    private struct MonitorMacContextMenuModifier<Items: View>: ViewModifier {
        let items: () -> Items

        func body(content: Content) -> some View {
            #if targetEnvironment(macCatalyst)
                content.contextMenu { items() }
            #else
                content
            #endif
        }
    }

    private struct MonitorSecondaryClickModifier: ViewModifier {
        let enabled: Bool
        let action: () -> Void

        func body(content: Content) -> some View {
            #if targetEnvironment(macCatalyst)
                content.background(MonitorSecondaryClickProbe(enabled: enabled, action: action))
            #else
                content
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
        /// The view's frame as the window sees it. It takes no touches, so it changes nothing about
        /// how primary clicks reach the view.
        private struct MonitorSecondaryClickProbe: UIViewRepresentable {
            let enabled: Bool
            let action: () -> Void

            func makeUIView(context: Context) -> ProbeView {
                let view = ProbeView()
                update(view)
                return view
            }

            func updateUIView(_ view: ProbeView, context: Context) { update(view) }

            private func update(_ view: ProbeView) {
                view.enabled = enabled
                view.action = action
            }

            final class ProbeView: UIView {
                var enabled = true
                var action: () -> Void = {}
                private var registration: MonitorSecondaryClickRegistration?

                override init(frame: CGRect) {
                    super.init(frame: frame)
                    isUserInteractionEnabled = false
                    backgroundColor = .clear
                }

                required init?(coder: NSCoder) { nil }

                override func didMoveToWindow() {
                    super.didMoveToWindow()
                    registration?.cancel()
                    registration = nil
                    guard window != nil else { return }
                    registration = MonitorSecondaryClick.register(
                        self, enabled: { [weak self] in self?.enabled ?? false },
                        action: { [weak self] _ in self?.action() })
                }
            }
        }

        /// One secondary-click recognizer per window, and the regions it serves.
        @MainActor private final class MonitorSecondaryClickRouter: NSObject, UIGestureRecognizerDelegate {
            static let shared = MonitorSecondaryClickRouter()
            private static let log = Logger(subsystem: "com.opencapture.opencine.monitor", category: "secondary-click")

            private var registrations: [MonitorSecondaryClickRegistration] = []
            private let windows = NSHashTable<UIWindow>.weakObjects()

            func add(_ registration: MonitorSecondaryClickRegistration) {
                registrations.removeAll { $0.view == nil }
                registrations.append(registration)
                if let window = registration.view?.window { install(on: window) }
            }

            private func install(on window: UIWindow) {
                guard !windows.contains(window) else { return }
                windows.add(window)
                let recognizer = MonitorSecondaryClick.configure(
                    UITapGestureRecognizer(target: self, action: #selector(click(_:))))
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                Self.log.notice("secondary click installed on a window")
            }

            @objc private func click(_ recognizer: UITapGestureRecognizer) {
                guard recognizer.state == .ended, let window = recognizer.view as? UIWindow else { return }
                let point = recognizer.location(in: window)
                registrations.removeAll { $0.view == nil }
                let target = registrations
                    .compactMap { registration -> (MonitorSecondaryClickRegistration, UIView, CGFloat)? in
                        guard let view = registration.view, view.window === window, Self.shown(view) else { return nil }
                        let frame = view.convert(view.bounds, to: window)
                        guard frame.contains(point) else { return nil }
                        return (registration, view, frame.width * frame.height)
                    }
                    .min { $0.2 < $1.2 }
                guard let (registration, view, _) = target else {
                    Self.log.notice("secondary click with no region under the pointer")
                    return
                }
                guard registration.enabled() else {
                    Self.log.notice("secondary click on a disabled region")
                    return
                }
                Self.log.notice("secondary click runs the long-press action")
                registration.action(window.convert(point, to: view))
            }

            /// On screen: in a window, and neither it nor a superview hidden or transparent.
            private static func shown(_ view: UIView) -> Bool {
                var current: UIView? = view
                while let next = current {
                    if next.isHidden || next.alpha < 0.01 || next.layer.opacity < 0.01 { return false }
                    current = next.superview
                }
                return true
            }

            /// The click never stops another recognizer, and no other recognizer stops it.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool { true }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool { false }
        }
    #endif
#endif
