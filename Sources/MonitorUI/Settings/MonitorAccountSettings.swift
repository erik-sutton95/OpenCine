#if os(iOS)
import SwiftUI

/// Known local account state. Authorization, tokens and requests remain with the host.
public enum MonitorAccountState: Sendable {
    case notConfigured, connecting, signedOut, signedIn, attention
}

public struct MonitorAccountSettings: View {
    private let title: String
    private let help: String
    private let state: MonitorAccountState
    private let signIn: (() -> Void)?
    private let signOut: (() -> Void)?
    private let statusLabel: String?
    private let signInTitle: String
    private let signOutTitle: String
    private let busyLabel: String?
    private let errorMessage: String?
    private let pillActions: Bool

    public init(title: String, help: String, state: MonitorAccountState,
        signIn: (() -> Void)? = nil, signOut: (() -> Void)? = nil,
        statusLabel: String? = nil, signInTitle: String = "Sign in", signOutTitle: String = "Log out",
        busyLabel: String? = nil, errorMessage: String? = nil, pillActions: Bool = false) {
        self.title = title; self.help = help; self.state = state
        self.signIn = signIn; self.signOut = signOut
        self.statusLabel = statusLabel; self.signInTitle = signInTitle; self.signOutTitle = signOutTitle
        self.busyLabel = busyLabel; self.errorMessage = errorMessage; self.pillActions = pillActions
    }

    public var body: some View {
        MonitorSettingsRowCard {
            MonitorSettingsInlineRow(title: title, help: help, showTopDivider: false) {
                if let busyLabel {
                    HStack(spacing: 8) {
                        MonitorSettingsValueText(value: busyLabel)
                        ProgressView().controlSize(.small).tint(MonitorTheme.accent)
                    }
                } else { switch state {
                case .notConfigured:
                    MonitorSettingsValueText(value: statusLabel ?? "Not configured")
                case .connecting:
                    ProgressView().controlSize(.small).tint(MonitorTheme.accent)
                case .signedOut:
                    if let signIn { action(signInTitle, signIn) }
                    else { MonitorSettingsValueText(value: statusLabel ?? "Signed out") }
                case .signedIn:
                    if let signOut { action(signOutTitle, signOut) }
                    else { MonitorSettingsValueText(value: statusLabel ?? "Connected") }
                case .attention:
                    if let signIn { action(signInTitle, signIn) }
                    else if let statusLabel { MonitorSettingsValueText(value: statusLabel) }
                } }
            }
            if let errorMessage {
                Text(errorMessage).font(MonitorTheme.font(11.5)).foregroundStyle(MonitorTheme.recording)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func action(_ title: String, _ action: @escaping () -> Void) -> some View {
        if pillActions { MonitorSettingsActionPill(title: title, action: action) }
        else { Button(action: action) {
            Text(title).font(MonitorTheme.font(13, weight: .semibold))
                .foregroundStyle(MonitorTheme.accent)
        }
        .buttonStyle(MonitorSettingsButtonStyle()) }
    }
}
#endif
