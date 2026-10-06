#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// The startup and watcher screens' palette, read once from the monitor theme.
    public enum StartupColors {
        public static let background = MonitorTheme.background
        public static let surface = MonitorTheme.surface
        public static let tile = MonitorTheme.raised
        public static let control = MonitorTheme.faint
        public static let ink = MonitorTheme.text
        public static let muted = MonitorTheme.muted
        public static let dim = MonitorTheme.faint
        public static let border = Color.white
        public static let card = MonitorTheme.surface
        public static let accent = MonitorTheme.accent
        public static let ready = Color(red: 0.247, green: 0.710, blue: 0.416)
        public static let destructive = MonitorTheme.recording
        public static let darkText = MonitorTheme.canvas
        public static var backdrop: some View { MonitorTheme.background }
    }

    /// The startup and watcher screens' filled accent button.
    public struct StartupFilledButtonStyle: ButtonStyle {
        public init() {}

        public func makeBody(configuration: Configuration) -> some View {
            Label(configuration: configuration)
        }

        private struct Label: View {
            let configuration: Configuration
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(MonitorTheme.font(16, weight: .semibold))
                    .foregroundStyle(StartupColors.darkText)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(
                        StartupColors.accent.opacity(configuration.isPressed ? 0.80 : 1),
                        in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
                    )
                    .opacity(isEnabled ? 1 : 0.4)
            }
        }
    }
#endif
