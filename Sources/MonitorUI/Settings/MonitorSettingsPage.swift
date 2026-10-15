#if os(iOS)
import MonitorPresentation
import SwiftUI
import UIKit

/// Actual operator page navigation, session actions and keyboard-safe content layout.
/// Rows compose common controls and typed domain sections without importing an app model.
public struct MonitorSettingsPage<Rows: View>: View {
    private let safeArea: EdgeInsets
    private let brand: String
    @Binding private var selection: MonitorSettingsTab
    private let tabs: [MonitorSettingsTab]
    private let tabSpacing: CGFloat
    private let isLive: Bool
    private let phaseLabel: String
    private let sharingSubtitle: String?
    private let sharingRail: String?
    private let scrollOffsets: Binding<[MonitorSettingsTab: CGFloat]>?
    private let feedback: () -> Void
    private let onClose: () -> Void
    private let disconnect: () -> Void
    private let rows: (MonitorSettingsTab) -> Rows
    @State private var keyboardInset: CGFloat = 0

    public init(
        safeArea: EdgeInsets, brand: String, selection: Binding<MonitorSettingsTab>,
        tabs: [MonitorSettingsTab] = MonitorSettingsTab.allCases, tabSpacing: CGFloat = 6,
        isLive: Bool, phaseLabel: String, sharingSubtitle: String? = nil,
        sharingRail: String? = nil, scrollOffsets: Binding<[MonitorSettingsTab: CGFloat]>? = nil,
        feedback: @escaping () -> Void = {}, onClose: @escaping () -> Void,
        disconnect: @escaping () -> Void,
        @ViewBuilder rows: @escaping (MonitorSettingsTab) -> Rows
    ) {
        self.safeArea = safeArea; self.brand = brand; self._selection = selection
        self.tabs = tabs; self.tabSpacing = tabSpacing; self.isLive = isLive; self.phaseLabel = phaseLabel
        self.sharingSubtitle = sharingSubtitle; self.sharingRail = sharingRail
        self.scrollOffsets = scrollOffsets; self.feedback = feedback
        self.onClose = onClose; self.disconnect = disconnect; self.rows = rows
    }

    public var body: some View {
        MonitorPage(
            safeArea: safeArea, navigationWidth: 188,
            heading: MonitorPageHeading(brand: brand, title: "Operator Setup"),
            backLabel: isLive ? "Back to live" : "Your cameras", back: onClose
        ) { portrait in
            navigation(portrait: portrait)
        } detail: { _ in
            content
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func navigation(portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: portrait ? 9 : 8) {
            ScrollView(portrait ? .horizontal : .vertical, showsIndicators: false) {
                MonitorTabStrip(vertical: !portrait, spacing: tabSpacing) {
                    ForEach(tabs) { tab in
                        MonitorNavigationItem(
                            tab.rawValue, subtitle: tab == .sharing ? (sharingRail ?? tab.rail) : tab.rail,
                            selected: selection == tab,
                            separator: tab != tabs.first
                        ) {
                            if tab != selection { feedback() }
                            selection = tab
                        }
                        .fixedSize(horizontal: portrait, vertical: false)
                        .accessibilityIdentifier("monitor.settings.tab.\(tab.id)")
                    }
                }
            }
            .monitorScrollFade(portrait ? .horizontal : .vertical)
            .frame(height: portrait ? 44 : nil)
            .accessibilityIdentifier("monitor.settings.tabs")
            sessionControls(portrait: portrait)
        }
    }

    private func sessionControls(portrait: Bool) -> some View {
        let layout = portrait
            ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            HStack(spacing: 8) {
                Circle().fill(isLive ? Color.green : MonitorTheme.faint)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLive ? "Active link" : "No camera connected")
                        .font(MonitorTheme.font(11.5, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                    Text(phaseLabel).font(MonitorTheme.font(9))
                        .foregroundStyle(MonitorTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            if isLive {
                Button(action: disconnect) {
                    HStack(spacing: 7) {
                        MonitorIcon.link2Off.frame(width: 14, height: 14)
                        Text("Disconnect")
                    }
                    .frame(maxWidth: portrait ? nil : .infinity)
                }
                .buttonStyle(CameraPageButtonStyle(destructive: true))
                .accessibilityIdentifier("monitor.system.disconnect")
            }
        }
    }

    private var savedOffset: Binding<CGFloat>? {
        guard let scrollOffsets else { return nil }
        let tab = selection
        return Binding(
            get: { scrollOffsets.wrappedValue[tab, default: 0] },
            set: { scrollOffsets.wrappedValue[tab] = $0 }
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selection.rawValue).font(MonitorTheme.font(17, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                    Text(selection == .sharing ? (sharingSubtitle ?? selection.subtitle) : selection.subtitle)
                        .font(MonitorTheme.font(10.5)).foregroundStyle(MonitorTheme.muted)
                        .lineLimit(2)
                }
                Spacer()
                Text(selection.pill.uppercased())
                    .font(MonitorTheme.font(10, weight: .bold)).monospacedDigit().kerning(0.6)
                    .foregroundStyle(MonitorTheme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Capsule().stroke(MonitorTheme.accent.opacity(0.16), lineWidth: 1))
            }
            MonitorSettingsTabScrollArea(tabID: selection.id, savedOffset: savedOffset) {
                MonitorCardColumns { rows(selection) }
                    .padding(.bottom, keyboardInset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let overlap = max(0, UIScreen.main.bounds.maxY - frame.minY)
            withAnimation(.easeOut(duration: 0.2)) { keyboardInset = overlap }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardInset = 0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
