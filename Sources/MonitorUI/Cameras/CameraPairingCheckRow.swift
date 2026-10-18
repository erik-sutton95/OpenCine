#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// A passive pairing status row. Hosts supply observed values and own any surrounding action.
    /// The pairing page and on-demand permission steps share this renderer (Compose
    /// `MonitorPairingCheckRow`).
    public struct CameraPairingCheckRow: View {
        public var check: CameraPairingCheck

        public init(_ check: CameraPairingCheck) {
            self.check = check
        }

        public var body: some View {
            HStack(spacing: 11) {
                Text(check.state == .complete ? "✓" : check.state == .active ? "·" : "")
                    .font(MonitorTheme.font(10, weight: .bold))
                    .foregroundStyle(
                        check.state == .complete ? MonitorTheme.background : MonitorTheme.accent
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        check.state == .complete
                            ? MonitorTheme.accent
                            : MonitorTheme.accent.opacity(check.state == .active ? 0.16 : 0.04),
                        in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(MonitorTheme.font(13, weight: .semibold))
                    Text(check.subtitle).font(MonitorTheme.font(9.5)).foregroundStyle(
                        MonitorTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(check.stateLabel).font(MonitorTheme.font(8.5, weight: .bold)).tracking(1.1)
                    .foregroundStyle(
                        check.state == .complete
                            ? Color(red: 63 / 255, green: 211 / 255, blue: 163 / 255)
                            : check.state == .active ? MonitorTheme.accent : MonitorTheme.faint)
            }
            .padding(13).background(
                Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }
#endif
