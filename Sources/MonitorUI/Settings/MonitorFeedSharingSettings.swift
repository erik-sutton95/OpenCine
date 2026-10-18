#if os(iOS)
import MonitorPresentation
import SwiftUI

/// The app supplies supported relay help and keeps credentials and relay lifetime.
public struct MonitorFeedSharingHelp {
    let sharing: String
    let passcode: String
    let controlRequests: String
    let priority: String
    let join: String

    public init(sharing: String, passcode: String, controlRequests: String, priority: String,
        join: String = "On the watching device, scan this code with Camera, join the Wi-Fi, then open Watch a feed.") {
        self.sharing = sharing; self.passcode = passcode
        self.controlRequests = controlRequests; self.priority = priority; self.join = join
    }
}

/// Native host controls. Values/actions never locate a relay, keychain or app model.
///
/// The passcode field applies ``MonitorWatcherPasscodeRule``: the binding and `passcodeChanged`
/// only ever receive a code that takes effect (trimmed, empty for an open feed); a shorter entry
/// stays a draft in the field and the code already in force is kept.
public struct MonitorFeedSharingSettings: View {
    @Binding private var sharing: Bool
    @Binding private var passcode: String
    @Binding private var controlRequests: Bool
    @Binding private var priority: String
    private let priorities: [String]
    private let help: MonitorFeedSharingHelp
    private let showWiFiCode: (() -> Void)?
    private let passcodeChanged: (String) -> Void
    private let feedback: () -> Void
    @State private var passcodeDraft: String?

    public init(sharing: Binding<Bool>, passcode: Binding<String>, controlRequests: Binding<Bool>,
        priority: Binding<String>, priorities: [String], help: MonitorFeedSharingHelp,
        showWiFiCode: (() -> Void)?, passcodeChanged: @escaping (String) -> Void,
        feedback: @escaping () -> Void = {}) {
        self._sharing = sharing; self._passcode = passcode
        self._controlRequests = controlRequests; self._priority = priority
        self.priorities = priorities; self.help = help
        self.showWiFiCode = showWiFiCode; self.passcodeChanged = passcodeChanged
        self.feedback = feedback
    }

    public var body: some View {
        MonitorSettingsRowCard {
            MonitorSettingsSwitchInlineRow(title: "Share this feed", help: help.sharing,
                showTopDivider: false, isOn: sharing, feedback: feedback) { sharing.toggle() }
            // nil when watchers never join the camera's network (it would drop the monitor).
            if let showWiFiCode {
                MonitorSettingsInlineRow(title: "Join camera Wi-Fi", help: help.join) {
                    // Hosts set an explicit root foreground (ink or .primary), which would turn a
                    // default button label white; the reference monitor drew this link in the tint.
                    Button("Show Wi-Fi code", action: showWiFiCode)
                        .foregroundStyle(.tint)
                        .font(MonitorTheme.font(13, weight: .medium))
                }
            }
            MonitorSettingsInlineRow(title: "Watcher passcode", help: help.passcode) {
                VStack(alignment: .trailing, spacing: 4) {
                    SecureField("Optional", text: Binding(
                        get: { passcodeDraft ?? passcode },
                        set: { text in enterPasscode(text) }))
                        .font(MonitorTheme.font(13, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    if let passcodeDraft, MonitorWatcherPasscodeRule.entry(passcodeDraft) == .tooShort {
                        Text(MonitorWatcherPasscodeRule.tooShortHint)
                            .font(MonitorTheme.font(10))
                            .foregroundStyle(MonitorTheme.muted)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 160, alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            MonitorSettingsSwitchInlineRow(title: "Control requests", help: help.controlRequests,
                isOn: controlRequests, feedback: feedback) { controlRequests.toggle() }
            MonitorSettingsInlineRow(title: "Broadcast priority", help: help.priority, stacked: true) {
                MonitorSegmentedControl(options: priorities, selection: $priority,
                    compact: true, title: { $0 }, onSelectionFeedback: feedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
        }
    }

    private func enterPasscode(_ text: String) {
        passcodeDraft = text
        guard let code = MonitorWatcherPasscodeRule.entry(text).passcode else { return }
        if passcode != code { passcode = code }
        passcodeChanged(code)
    }
}
#endif
