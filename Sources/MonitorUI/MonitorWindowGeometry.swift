#if os(iOS)
    import MonitorPresentation
    import SwiftUI
    import UIKit

    /// A snapshot of the containing native window. Reading this value during
    /// SwiftUI layout never asks UIKit to calculate its safe areas again.
    public struct MonitorWindowGeometry: Equatable, Sendable {
        public var size: CGSize
        public var safeArea: EdgeInsets
        /// Additional room above controls for iPad window buttons. This is
        /// separate from physical safe areas so the picture can remain edge-to-edge.
        public var topControlInset: CGFloat

        public init(
            size: CGSize = .zero, safeArea: EdgeInsets = EdgeInsets(),
            topControlInset: CGFloat = 0
        ) {
            self.size = size
            self.safeArea = safeArea
            self.topControlInset = max(0, topControlInset.isFinite ? topControlInset : 0)
        }

        /// The initial snapshot is empty until the observer joins a window.
        /// A host can use its GeometryReader proposal while this is nil.
        public var validSize: CGSize? {
            size.width > 0 && size.height > 0 ? size : nil
        }
    }

    private struct MonitorWindowGeometryKey: EnvironmentKey {
        static let defaultValue = MonitorWindowGeometry()
    }

    extension EnvironmentValues {
        public var monitorWindowGeometry: MonitorWindowGeometry {
            get { self[MonitorWindowGeometryKey.self] }
            set { self[MonitorWindowGeometryKey.self] = newValue }
        }
    }

    extension View {
        /// Install once around an app's root view. Descendant pages and presented
        /// covers inherit physical insets even when their own view ignores them.
        public func observeMonitorWindowGeometry() -> some View {
            modifier(MonitorWindowGeometryObserver())
        }
    }

    extension View {
        /// Publishes the page safe area (`monitor.review.safeArea`) from this view during a staged
        /// review. The root observer does; a page presented as a full-screen cover takes the root
        /// off screen, so such a page publishes it too.
        func monitorReviewSafeArea() -> some View { modifier(MonitorReviewSafeAreaPublisher()) }
    }

    private struct MonitorReviewSafeAreaPublisher: ViewModifier {
        /// Only a staged review (`ReviewLaunch`) in a Debug build publishes the safe area.
        #if DEBUG
            private let reviewed = ReviewLaunch.current != nil
        #else
            private let reviewed = false
        #endif

        func body(content: Content) -> some View {
            content.background {
                if reviewed { MonitorReviewSafeAreaMarker().allowsHitTesting(false) }
            }
        }
    }

    private struct MonitorWindowGeometryObserver: ViewModifier {
        @State private var geometry = MonitorWindowGeometry()

        func body(content: Content) -> some View {
            content
                .environment(\.monitorWindowGeometry, geometry)
                .background {
                    MonitorWindowGeometryProbe { geometry = $0 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .monitorReviewSafeArea()
        }
    }

    /// The safe area full-screen pages lay out in (`OperatorPanelMetrics.fullScreenPanelSafeArea`:
    /// the window's insets, with the landscape side that holds no camera housing given back to the
    /// page), published as one accessibility element `monitor.review.safeArea` in screen
    /// coordinates. The conformance screenshot matrix requires page content inside it (the Kotlin
    /// kit reads the system bars and the display cutout from the activity's window insets).
    private struct MonitorReviewSafeAreaMarker: UIViewRepresentable {
        func makeUIView(context: Context) -> MonitorReviewSafeAreaView {
            MonitorReviewSafeAreaView()
        }
        func updateUIView(_ view: MonitorReviewSafeAreaView, context: Context) {}
    }

    private final class MonitorReviewSafeAreaView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityIdentifier = "monitor.review.safeArea"
            accessibilityLabel = "Safe area"
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override var accessibilityFrame: CGRect {
            get {
                guard let window else { return .zero }
                let raw = window.safeAreaInsets
                let portrait = window.bounds.height > window.bounds.width
                let panel = OperatorPanelMetrics.fullScreenPanelSafeArea(
                    from: EdgeInsets(
                        top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right),
                    isPortrait: portrait,
                    mirrored: LiveMonitorLayout.shouldMirror(leading: raw.left, trailing: raw.right)
                )
                let safe = window.bounds.inset(
                    by: UIEdgeInsets(
                        top: panel.top, left: panel.leading, bottom: panel.bottom,
                        right: panel.trailing))
                return window.convert(safe, to: window.screen.coordinateSpace)
            }
            set {}
        }
    }

    private struct MonitorWindowGeometryProbe: UIViewRepresentable {
        let onChange: (MonitorWindowGeometry) -> Void

        func makeUIView(context: Context) -> MonitorWindowGeometryView {
            let view = MonitorWindowGeometryView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.onChange = onChange
            return view
        }

        func updateUIView(_ view: MonitorWindowGeometryView, context: Context) {
            view.onChange = onChange
            view.scheduleSample()
        }

        static func dismantleUIView(_ view: MonitorWindowGeometryView, coordinator: ()) {
            view.onChange = nil
        }
    }

    private final class MonitorWindowGeometryView: UIView {
        var onChange: ((MonitorWindowGeometry) -> Void)?
        private var scheduled = false
        private var last: MonitorWindowGeometry?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleSample()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleSample()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleSample()
        }

        func scheduleSample() {
            guard !scheduled else { return }
            scheduled = true
            // UIKit's safeAreaInsets getter can reenter SwiftUI's layout graph
            // on iOS 26. Sample after the current layout/update transaction, then
            // publish only changed values. No polling and no frame callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.onChange != nil, let window = self.window else { return }
                let insets = window.safeAreaInsets
                let topControlInset: CGFloat
                if #available(iOS 26.0, *), window.traitCollection.userInterfaceIdiom == .pad {
                    // Unlike ordinary safeAreaInsets, this region excludes
                    // the window controls that float over an app's top corner.
                    // On iPhone it instead describes the rounded display corners;
                    // those are already handled by the monitor's edge geometry.
                    let adapted = window.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
                    topControlInset = max(0, adapted.top - insets.top)
                } else {
                    topControlInset = 0
                }
                let sample = MonitorWindowGeometry(
                    size: window.bounds.size,
                    safeArea: EdgeInsets(
                        top: insets.top, leading: insets.left,
                        bottom: insets.bottom, trailing: insets.right),
                    topControlInset: topControlInset)
                guard sample != self.last else { return }
                self.last = sample
                self.onChange?(sample)
            }
        }
    }
#endif
