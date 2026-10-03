#if os(iOS)
import SwiftUI

/// Local exposure-meter presentation. The host supplies its exercised reading policy and action.
public struct MonitorExposureMeterSettings: View {
    private let isOn: Bool
    private let help: String
    private let feedback: () -> Void
    private let onToggle: () -> Void

    public init(isOn: Bool, help: String, feedback: @escaping () -> Void = {},
        onToggle: @escaping () -> Void) {
        self.isOn = isOn; self.help = help
        self.feedback = feedback; self.onToggle = onToggle
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "EV Meter") {
            MonitorSettingsSwitchInlineRow(title: "Enabled", help: help,
                showTopDivider: false, isOn: isOn, feedback: feedback, action: onToggle)
        }
    }
}

/// A known selected look and a local picker action. Catalogs and preparation remain source-owned.
public struct MonitorLookSettings: View {
    private let look: String
    private let help: String
    private let onOpen: () -> Void

    public init(look: String, help: String, onOpen: @escaping () -> Void) {
        self.look = look; self.help = help; self.onOpen = onOpen
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "LUT") {
            MonitorSettingsInlineRow(title: "Look", help: help, showTopDivider: false) {
                MonitorSettingsValueText(value: look)
            }
            MonitorSettingsInlineRow(title: "Choose look") {
                MonitorSettingsActionPill(title: "Open", action: onOpen)
            }
        }
    }
}
#endif
