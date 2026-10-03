#if os(iOS)
import SwiftUI

/// Known local account state. Authorization, tokens and requests remain with the host.
public enum MonitorAccountState: Sendable {
    case notConfigured, connecting, signedOut, signedIn
}

public struct MonitorAccountSettings: View {
    private let title: String
    private let help: String
    private let state: MonitorAccountState
    private let signIn: (() -> Void)?
    private let signOut: (() -> Void)?

    public init(title: String, help: String, state: MonitorAccountState,
        signIn: (() -> Void)? = nil, signOut: (() -> Void)? = nil) {
        self.title = title; self.help = help; self.state = state
        self.signIn = signIn; self.signOut = signOut
    }

    public var body: some View {
        MonitorSettingsRowCard {
            MonitorSettingsInlineRow(title: title, help: help, showTopDivider: false) {
                switch state {
                case .notConfigured:
                    MonitorSettingsValueText(value: "Not configured")
                case .connecting:
                    ProgressView().controlSize(.small).tint(MonitorTheme.accent)
                case .signedOut:
                    if let signIn { action("Sign in", signIn) }
                    else { MonitorSettingsValueText(value: "Signed out") }
                case .signedIn:
                    if let signOut { action("Log out", signOut) }
                    else { MonitorSettingsValueText(value: "Connected") }
                }
            }
        }
    }

    private func action(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(MonitorTheme.font(13, weight: .semibold))
                .foregroundStyle(MonitorTheme.accent)
        }
        .buttonStyle(MonitorSettingsButtonStyle())
    }
}
#endif
