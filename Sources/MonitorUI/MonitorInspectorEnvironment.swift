#if os(iOS)
    import SwiftUI

    private struct MonitorInspectorHelpKey: EnvironmentKey {
        static let defaultValue: Bool? = nil
    }

    private struct MonitorInspectorInteractiveBackgroundKey: EnvironmentKey {
        static let defaultValue = false
    }

    private struct MonitorInspectorContentHeightKey: EnvironmentKey {
        static let defaultValue: CGFloat? = nil
    }

    extension EnvironmentValues {
        /// Nil keeps ordinary settings help badges; an inspector chooses inline
        /// guidance with true, or a quiet controls-only presentation with false.
        public var monitorInspectorHelp: Bool? {
            get { self[MonitorInspectorHelpKey.self] }
            set { self[MonitorInspectorHelpKey.self] = newValue }
        }

        package var monitorInspectorInteractiveBackground: Bool {
            get { self[MonitorInspectorInteractiveBackgroundKey.self] }
            set { self[MonitorInspectorInteractiveBackgroundKey.self] = newValue }
        }

        package var monitorInspectorContentHeight: CGFloat? {
            get { self[MonitorInspectorContentHeightKey.self] }
            set { self[MonitorInspectorContentHeightKey.self] = newValue }
        }
    }
#endif
