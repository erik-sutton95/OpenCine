#if os(iOS)
import MonitorPresentation
import SwiftUI

/// A settings control keeps its visual size while extending its input target to 44 points.
public struct MonitorSettingsButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(SettingsMinimumTarget())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SettingsTargetSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct SettingsMinimumTarget: ViewModifier {
    @State private var size = CGSize.zero
    func body(content: Content) -> some View {
        let x = size == .zero ? 0 : max(0, (44 - size.width) / 2)
        let y = size == .zero ? 0 : max(0, (44 - size.height) / 2)
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: SettingsTargetSize.self, value: proxy.size)
            }
        }
        .onPreferenceChange(SettingsTargetSize.self) { size = $0 }
        .padding(.horizontal, x).padding(.vertical, y)
        .contentShape(Rectangle())
        .padding(.horizontal, -x).padding(.vertical, -y)
    }
}

public struct MonitorSettingsHelpBadge: View {
    private let text: String
    @State private var showing = false
    public init(text: String) { self.text = text }
    public var body: some View {
        Button { showing.toggle() } label: {
            MonitorIcon.info.foregroundStyle(MonitorTheme.faint)
                .frame(width: 9, height: 9).frame(width: 16, height: 16)
                .background(MonitorTheme.background.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(MonitorTheme.border, lineWidth: 1))
        }
        .buttonStyle(MonitorSettingsButtonStyle())
        .accessibilityLabel("Help")
        .popover(isPresented: $showing) {
            Text(text).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.text)
                .padding(12).frame(width: 248).fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Responsive setting label and control. Inline inspector help shares the existing environment.
public struct MonitorSettingsInlineRow<Trailing: View>: View {
    @Environment(\.monitorInspectorHelp) private var inspectorHelp
    private let title: String
    private let help: String?
    private let showTopDivider: Bool
    private let stacked: Bool
    private let trailing: Trailing

    public init(
        title: String, help: String? = nil, showTopDivider: Bool = true,
        stacked: Bool = false, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title; self.help = help; self.showTopDivider = showTopDivider
        self.stacked = stacked; self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showTopDivider { Rectangle().fill(MonitorTheme.border).frame(height: 1) }
            if stacked {
                stackedRow
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        labelRow
                        Spacer(minLength: 12)
                        trailing.fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    stackedRow
                }
            }
            if inspectorHelp == true, let help, !help.isEmpty {
                Text(help).font(MonitorTheme.font(10)).foregroundStyle(MonitorTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
        }
    }
    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelRow
            trailing.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 44)
    }
    private var labelRow: some View {
        HStack(spacing: 6) {
            Text(title).font(MonitorTheme.font(CGFloat(MonitorSettingsCardMetrics.rowTitlePointSize), weight: .semibold))
                .foregroundStyle(MonitorTheme.text).lineLimit(stacked ? 2 : 1)
                .fixedSize(horizontal: !stacked, vertical: true).layoutPriority(1)
                .accessibilityIdentifier("monitor.settings.row.title")
            if inspectorHelp == nil, let help { MonitorSettingsHelpBadge(text: help) }
            if !stacked { Spacer(minLength: 0) }
        }
    }
}

public struct MonitorSettingsValueText: View {
    private let value: String
    public init(value: String) { self.value = value }
    public var body: some View {
        Text(value).font(MonitorTheme.font(12.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(MonitorTheme.muted).lineLimit(1).minimumScaleFactor(0.7)
    }
}

public struct MonitorSettingsSwitchGraphic: View {
    private let isOn: Bool
    public init(isOn: Bool) { self.isOn = isOn }
    public var body: some View {
        Capsule().fill(isOn ? MonitorTheme.accent.opacity(0.16) : MonitorTheme.surface)
            .frame(width: 39, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(isOn ? MonitorTheme.accent : MonitorTheme.muted)
                    .frame(width: 15, height: 15).padding(3.5)
            }
            .overlay(Capsule().stroke(isOn ? MonitorTheme.accent.opacity(0.16) : MonitorTheme.border))
    }
}

public struct MonitorSettingsSwitchInlineRow: View {
    private let title: String
    private let help: String?
    private let showTopDivider: Bool
    private let stacked: Bool
    private let isOn: Bool
    private let identifier: String?
    private let feedback: () -> Void
    private let action: () -> Void
    public init(
        title: String, help: String? = nil, showTopDivider: Bool = true, stacked: Bool = false,
        isOn: Bool, identifier: String? = nil, feedback: @escaping () -> Void = {},
        action: @escaping () -> Void
    ) {
        self.title = title; self.help = help; self.showTopDivider = showTopDivider
        self.stacked = stacked; self.isOn = isOn; self.identifier = identifier
        self.feedback = feedback; self.action = action
    }
    public var body: some View {
        MonitorSettingsInlineRow(title: title, help: help, showTopDivider: showTopDivider, stacked: stacked) {
            Button { feedback(); action() } label: { MonitorSettingsSwitchGraphic(isOn: isOn) }
                .buttonStyle(MonitorSettingsButtonStyle())
                .accessibilityIdentifier(identifier ?? "")
                .accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

public struct MonitorSettingsResetButton: View {
    private let feedback: () -> Void
    private let action: () -> Void
    public init(feedback: @escaping () -> Void = {}, action: @escaping () -> Void) {
        self.feedback = feedback; self.action = action
    }
    public var body: some View {
        Button { feedback(); action() } label: {
            MonitorIcon.refreshCw.foregroundStyle(MonitorTheme.muted)
                .frame(width: 12, height: 12).frame(width: 28, height: 28)
                .background(MonitorTheme.background.opacity(0.42), in: Circle())
                .overlay(Circle().stroke(MonitorTheme.border, lineWidth: 1))
        }
        .buttonStyle(MonitorSettingsButtonStyle()).accessibilityLabel("Reset to defaults")
    }
}

public struct MonitorSettingsRowCard<Content: View>: View {
    private let title: String?
    private let onReset: (() -> Void)?
    private let feedback: () -> Void
    private let content: Content
    public init(
        title: String? = nil, onReset: (() -> Void)? = nil, feedback: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.title = title; self.onReset = onReset; self.feedback = feedback
        self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(MonitorSettingsCardMetrics.titleContentGap)) {
            if let title {
                HStack(alignment: .center, spacing: 8) {
                    Text(title).font(MonitorTheme.font(CGFloat(MonitorSettingsCardMetrics.titlePointSize), weight: .semibold))
                        .foregroundStyle(MonitorTheme.text).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("monitor.settings.card.title")
                    Spacer(minLength: 0)
                    if let onReset { MonitorSettingsResetButton(feedback: feedback, action: onReset) }
                }
                .frame(minHeight: CGFloat(MonitorSettingsCardMetrics.titleMinHeight), alignment: .leading)
                .padding(.top, CGFloat(MonitorSettingsCardMetrics.titleTopPadding))
            }
            content
        }
        .padding(.horizontal, 13).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading).monitorCardSurface()
    }
}

#endif
