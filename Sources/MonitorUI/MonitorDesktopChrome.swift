#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    public typealias MonitorChromeStyle = MonitorPresentation.MonitorChromeStyle

    private struct MonitorChromeStyleKey: EnvironmentKey {
        static let defaultValue = MonitorChromeStyle.device
    }

    extension EnvironmentValues {
        /// Device (a phone or tablet screen) or desktop (a window whose title bar is a toolbar).
        /// A host sets desktop only where it runs as a desktop window; the default is device.
        public var monitorChromeStyle: MonitorChromeStyle {
            get { self[MonitorChromeStyleKey.self] }
            set { self[MonitorChromeStyleKey.self] = newValue }
        }
    }

    extension View {
        /// Lays the live monitor out for a device screen or a desktop window.
        public func monitorChromeStyle(_ style: MonitorChromeStyle) -> some View {
            environment(\.monitorChromeStyle, style)
        }
    }
#endif
