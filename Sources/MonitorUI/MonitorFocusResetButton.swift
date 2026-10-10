#if os(iOS)
    import SwiftUI

    /// The focus recenter key takes appearance values and an admitted native action.
    /// Camera ownership, focus-lock policy and haptics remain with the caller.
    public struct MonitorFocusResetButton: View {
        private let size: CGFloat
        private let foreground: Color
        private let outline: Color
        private let action: () -> Void

        public init(
            size: CGFloat = LiveChromeMetrics.focusResetSize,
            foreground: Color = MonitorTheme.text, outline: Color = MonitorTheme.border,
            action: @escaping () -> Void
        ) {
            self.size = size
            self.foreground = foreground
            self.outline = outline
            self.action = action
        }

        public var body: some View {
            Button(action: action) {
                MonitorIcon.rotateCw
                    .frame(width: 17, height: 17)
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
                    .background(.black.opacity(0.55), in: Circle())
                    .overlay(Circle().strokeBorder(outline, lineWidth: 1))
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityLabel("Recenter focus")
            .accessibilityHint("Moves the focus box back to the center and ends subject tracking")
            .accessibilityIdentifier("monitor.system.focusReset")
        }
    }
#endif
