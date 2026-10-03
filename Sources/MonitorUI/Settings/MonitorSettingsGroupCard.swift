#if os(iOS)
import SwiftUI

/// A common expandable settings section with an optional reset action.
public struct MonitorSettingsGroupCard<Content: View>: View {
    private let title: String
    private let caption: String
    private let onReset: (() -> Void)?
    private let expansion: Binding<Bool>?
    private let content: Content

    public init(title: String, caption: String, onReset: (() -> Void)? = nil,
        expansion: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.caption = caption; self.onReset = onReset
        self.expansion = expansion; self.content = content()
    }

    private var isExpanded: Bool { expansion?.wrappedValue ?? true }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let expansion {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expansion.wrappedValue.toggle() }
                } label: { header }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else { header }
            if isExpanded { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .monitorCardSurface()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MonitorTheme.font(13, weight: .semibold))
                    .foregroundStyle(MonitorTheme.text)
                Text(caption).font(MonitorTheme.font(11.5))
                    .foregroundStyle(MonitorTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onReset, isExpanded { MonitorSettingsResetButton(action: onReset) }
            if expansion != nil {
                (isExpanded ? MonitorIcon.chevronUp : MonitorIcon.chevronDown)
                    .frame(width: 20, height: 20).foregroundStyle(MonitorTheme.muted)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
