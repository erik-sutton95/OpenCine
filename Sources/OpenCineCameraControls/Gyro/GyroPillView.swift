#if os(iOS)
    import MonitorUI
    import OpenCineGyro
    import SwiftUI

    /// The compact gyro pill on the monitor, in the uppercase style of the other monitor chips.
    /// Renders nothing when hidden; mount moved and error read amber with a warning glyph; a small
    /// amber dot marks "IBIS is still on". Tapping opens the gyro logs (the host's action).
    public struct GyroPillView: View {
        private let state: GyroPillState
        private let action: () -> Void

        public init(state: GyroPillState, action: @escaping () -> Void) {
            self.state = state
            self.action = action
        }

        private var alert: Bool { state.kind == .mountMoved || state.kind == .error }

        public var body: some View {
            if state.kind != .hidden {
                Button(action: action) {
                    HStack(spacing: 5) {
                        Image(systemName: alert ? "exclamationmark.triangle" : "waveform")
                        Text(GyroCopy.pill(state.kind))
                        if state.stabilizationWarning {
                            Circle().fill(GyroPalette.orange).frame(width: 6, height: 6)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(alert || state.kind == .gaps ? GyroPalette.orange : Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.black.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(GyroCopy.pillA11y(state.kind, warning: state.stabilizationWarning))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("gyro.pill")
            }
        }
    }
#endif
