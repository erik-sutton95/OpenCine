#if os(iOS)
import MonitorPresentation
import SwiftUI

/// What the live stream card can ask for. The composition layer validates and stores; the card
/// never sees a saved key.
public struct LiveStreamSettingsActions {
    public var selectService: (String) -> Void
    public var setServer: (String) -> Void
    /// Saves a pasted key (and the entered server, for services that need one).
    public var saveKey: (String) -> Void
    public var removeKey: () -> Void
    public var setShowOnMonitor: (Bool) -> Void
    /// Chooses a Quality option by id.
    public var selectQuality: (String) -> Void

    public init(
        selectService: @escaping (String) -> Void, setServer: @escaping (String) -> Void,
        saveKey: @escaping (String) -> Void, removeKey: @escaping () -> Void,
        setShowOnMonitor: @escaping (Bool) -> Void, selectQuality: @escaping (String) -> Void = { _ in }
    ) {
        self.selectQuality = selectQuality
        self.selectService = selectService
        self.setServer = setServer
        self.saveKey = saveKey
        self.removeKey = removeKey
        self.setShowOnMonitor = setShowOnMonitor
    }
}

/// The Sharing tab's live stream card: service, server, stream key, quality, the monitor switch and
/// why going live is not possible right now. Kotlin twin: `LiveStreamSettingsCard` (part 3).
public struct LiveStreamSettingsCard: View {
    let state: LiveStreamSettingsState
    let actions: LiveStreamSettingsActions
    let feedback: () -> Void
    @State private var pastedKey = ""
    @State private var server = ""
    @State private var confirmingRemove = false

    public init(state: LiveStreamSettingsState, actions: LiveStreamSettingsActions, feedback: @escaping () -> Void = {}) {
        self.state = state
        self.actions = actions
        self.feedback = feedback
    }

    public var body: some View {
        MonitorSettingsRowCard(title: LiveStreamCopy.cardTitle) {
            serviceRow
            if let hint = state.selected?.keyHint {
                note(hint).accessibilityIdentifier("monitor.livestream.keyHint")
            }
            if state.showsServer { serverRow }
            if state.showsPlainWarning {
                warning(state.plainWarning).accessibilityIdentifier("monitor.livestream.plainWarning")
            }
            keyRow
            if let problem = state.problem {
                warning(problem.text).accessibilityIdentifier("monitor.livestream.serverProblem")
            }
            if state.showsQualityPicker {
                qualityPickerRow
                Text(state.qualityLine).font(MonitorTheme.font(12, weight: .semibold))
                    .foregroundStyle(MonitorTheme.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("monitor.livestream.quality")
                if let detail = state.qualityDetail {
                    note(detail).accessibilityIdentifier("monitor.livestream.qualityDetail")
                }
            } else {
                MonitorSettingsInlineRow(title: LiveStreamCopy.qualityTitle) {
                    Text(state.qualityLine).font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(MonitorTheme.secondary).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("monitor.livestream.quality")
                }
            }
            if let vertical = state.verticalNote {
                note(vertical).accessibilityIdentifier("monitor.livestream.verticalNote")
            }
            MonitorSettingsSwitchInlineRow(title: LiveStreamCopy.showOnMonitorTitle, isOn: state.showOnMonitor,
                identifier: "monitor.livestream.showOnMonitor", feedback: feedback) {
                actions.setShowOnMonitor(!state.showOnMonitor)
            }
            if let reason = state.eligibilityNote {
                warning(reason).accessibilityIdentifier("monitor.livestream.eligibility")
            }
            if state.isLocked {
                note(LiveStreamCopy.lockedWhileLive).accessibilityIdentifier("monitor.livestream.lockedWhileLive")
            }
        }
        .onAppear { server = state.server }
        .onChange(of: state.server) { _, value in if value != server { server = value } }
        .onChange(of: state.selectedID) { _, _ in pastedKey = "" }
        .alert(LiveStreamCopy.removeTitle, isPresented: $confirmingRemove) {
            Button(LiveStreamCopy.remove, role: .destructive) { actions.removeKey() }
            Button(LiveStreamCopy.cancel, role: .cancel) {}
        } message: {
            Text(LiveStreamCopy.removeMessage(service: state.selected?.name ?? ""))
        }
    }

    private var serviceRow: some View {
        MonitorSettingsInlineRow(title: LiveStreamCopy.serviceTitle, showTopDivider: false) {
            Menu {
                ForEach(state.services) { service in
                    Button(service.name) { feedback(); actions.selectService(service.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(state.selected?.name ?? "").font(MonitorTheme.font(12, weight: .semibold))
                    MonitorIcon.chevronDown.frame(width: 11, height: 11)
                }
                .foregroundStyle(MonitorTheme.accent)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(MonitorTheme.accent.opacity(0.16), in: Capsule())
            }
            .monitorMenuStyle()
            .disabled(state.isLocked)
            .accessibilityLabel(LiveStreamCopy.serviceTitle)
            .accessibilityValue(state.selected?.name ?? "")
            .accessibilityIdentifier("monitor.livestream.service")
        }
    }

    /// The Quality choices, as the service row's menu; an unavailable choice is listed disabled.
    private var qualityPickerRow: some View {
        MonitorSettingsInlineRow(title: LiveStreamCopy.qualityTitle) {
            Menu {
                ForEach(state.qualityOptions) { option in
                    Button(option.title) { feedback(); actions.selectQuality(option.id) }
                        .disabled(!option.isEnabled)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(state.selectedQuality?.title ?? "").font(MonitorTheme.font(12, weight: .semibold))
                    MonitorIcon.chevronDown.frame(width: 11, height: 11)
                }
                .foregroundStyle(MonitorTheme.accent)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(MonitorTheme.accent.opacity(0.16), in: Capsule())
            }
            .monitorMenuStyle()
            .disabled(state.isLocked)
            .accessibilityLabel(LiveStreamCopy.qualityTitle)
            .accessibilityValue(state.selectedQuality?.title ?? "")
            .accessibilityIdentifier("monitor.livestream.qualityChoice")
        }
    }

    private var serverRow: some View {
        MonitorSettingsInlineRow(title: LiveStreamCopy.serverTitle, stacked: true) {
            TextField(state.serverPlaceholder, text: $server)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.text)
                .padding(.horizontal, 10).frame(height: 36)
                .background(MonitorTheme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
                .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius).stroke(MonitorTheme.border))
                .disabled(state.isLocked || state.key == .saved)
                .onChange(of: server) { _, value in actions.setServer(value) }
                .accessibilityLabel(LiveStreamCopy.serverTitle)
                .accessibilityIdentifier("monitor.livestream.server")
        }
    }

    @ViewBuilder private var keyRow: some View {
        switch state.key {
        case .saved:
            MonitorSettingsInlineRow(title: LiveStreamCopy.keyTitle) {
                HStack(spacing: 8) {
                    Text(state.keyValueText ?? "").font(MonitorTheme.font(12, weight: .semibold))
                        .foregroundStyle(MonitorTheme.secondary)
                        .accessibilityIdentifier("monitor.livestream.key.saved")
                    MonitorSettingsActionPill(title: LiveStreamCopy.remove, tint: MonitorTheme.muted, background: .clear) {
                        feedback(); confirmingRemove = true
                    }
                    .disabled(state.isLocked)
                    .accessibilityLabel("Remove the stream key")
                    .accessibilityIdentifier("monitor.livestream.key.remove")
                }
            }
        case .absent:
            MonitorSettingsInlineRow(title: LiveStreamCopy.keyTitle, stacked: true) {
                HStack(spacing: 8) {
                    SecureField(LiveStreamCopy.keyPlaceholder, text: $pastedKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.text)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(MonitorTheme.background.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
                        .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius).stroke(MonitorTheme.border))
                        .accessibilityLabel(LiveStreamCopy.keyTitle)
                        .accessibilityIdentifier("monitor.livestream.key")
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in pastedKey = text }
                    }
                    .labelStyle(.titleOnly).buttonBorderShape(.capsule).tint(MonitorTheme.accent)
                    .accessibilityIdentifier("monitor.livestream.key.paste")
                    MonitorSettingsActionPill(title: LiveStreamCopy.save) {
                        feedback()
                        actions.saveKey(pastedKey)
                    }
                    .disabled(pastedKey.isEmpty)
                    .opacity(pastedKey.isEmpty ? 0.4 : 1)
                    .accessibilityIdentifier("monitor.livestream.key.save")
                }
                .disabled(state.isLocked)
            }
        case .unavailable:
            MonitorSettingsInlineRow(title: LiveStreamCopy.keyTitle, stacked: true) {
                note(state.keyUnavailableNote ?? "").accessibilityIdentifier("monitor.livestream.key.unavailable")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(MonitorTheme.font(11, weight: .semibold))
            .foregroundStyle(MonitorTheme.linkHealthColor(.watch))
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}
#endif
