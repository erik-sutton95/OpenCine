#if os(iOS)
    import SwiftUI

    private struct MonitorZoomRulerOpenKey: EnvironmentKey {
        static let defaultValue = false
    }

    extension EnvironmentValues {
        /// True while the zoom ruler is open: the timecode block, the joystick cluster and the
        /// Go live control step aside until it closes. Set by the live screen.
        public var monitorZoomRulerOpen: Bool {
            get { self[MonitorZoomRulerOpenKey.self] }
            set { self[MonitorZoomRulerOpenKey.self] = newValue }
        }
    }

    private struct MonitorHiddenWhileZoom: ViewModifier {
        let hidden: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            content
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
                .animation(MonitorMotion.dim(reduceMotion), value: hidden)
        }
    }

    extension View {
        /// Fades the view out and ignores touches while the zoom ruler is open; it stays mounted,
        /// so its state comes back unchanged when the ruler closes.
        public func monitorHiddenWhileZoom(_ hidden: Bool) -> some View {
            modifier(MonitorHiddenWhileZoom(hidden: hidden))
        }
    }
#endif
