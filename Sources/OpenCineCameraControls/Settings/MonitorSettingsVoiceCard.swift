#if os(iOS)
import MonitorUI
import OpenCineAppKitApple
import SwiftUI

struct MonitorSettingsVoiceCard: View {
    let preferences: MonitorVoicePreferences
    let supportsLens: Bool
    let feedback: () -> Void

    var body: some View {
        MonitorSettingsRowCard(title: "Voice Control") {
            Text("Tap the monitor mic to listen for these commands.")
                .font(MonitorTheme.font(12))
                .foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(preferences.availableActions(supportsLens: supportsLens)) { action in
                let (title, phrases) = copy(for: action)
                MonitorSettingsSwitchInlineRow(title: title, help: phrases, isOn: preferences.isEnabled(action),
                    identifier: "monitor.settings.voice.\(action.rawValue)", feedback: feedback) {
                    preferences.setEnabled(!preferences.isEnabled(action), for: action)
                }
            }
        }
    }

    private func copy(for action: MonitorVoiceAction) -> (String, String) {
        switch action {
        case .start: ("Start recording", "“Camera, start” or “Camera, record”")
        case .stop: ("Stop recording", "“Camera, stop”")
        case .preset:
            ("Recall preset", "“Camera, load next” or “Camera, load previous” follows the preset list. “Camera, load three” loads Preset 3.")
        case .lens: ("Switch lens", "“Camera, switch lens” or “Camera, change lens” switches between 1× and 3×.")
        }
    }
}
#endif
