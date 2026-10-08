#if os(iOS)
import SwiftUI

/// Shared compact tool artwork and enabled state; optional extension glyphs are bounded leaves.
public struct MonitorAssistChip<Icon: View>: View {
    private let id: String
    private let isOn: Bool
    private let compact: Bool
    private let icon: () -> Icon
    public init(id: String, isOn: Bool, compact: Bool = false, @ViewBuilder icon: @escaping () -> Icon) {
        self.id = id; self.isOn = isOn; self.compact = compact; self.icon = icon
    }
    public var body: some View {
        VStack(spacing: 3) {
            icon().frame(height: 23)
            Text(id).font(MonitorTheme.font(9, weight: .medium)).monospacedDigit().tracking(0.9).lineLimit(1)
        }
        .foregroundStyle(isOn ? MonitorTheme.accent : MonitorTheme.muted)
        .padding(.vertical, 5).padding(.horizontal, compact ? 5 : 8).frame(minWidth: compact ? 48 : 52)
        .background {
            RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                .fill(isOn ? MonitorTheme.accent.opacity(0.16) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                .strokeBorder(isOn ? MonitorTheme.accent : Color.clear, lineWidth: 1)
        }
    }
}
#endif
