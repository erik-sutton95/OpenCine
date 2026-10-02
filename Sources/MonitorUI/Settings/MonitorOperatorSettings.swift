#if os(iOS)
import SwiftUI

/// Common touch safety choices. The host owns persistence and supplies optional domain copy.
public struct MonitorOperatorSafetySettings: View {
    @Binding private var recordConfirmation: Bool
    @Binding private var haptics: Bool
    @Binding private var keepScreenAwake: Bool
    private let hapticsHelp: String
    private let keepScreenAwakeHelp: String
    private let feedback: () -> Void

    public init(
        recordConfirmation: Binding<Bool>, haptics: Binding<Bool>, keepScreenAwake: Binding<Bool>,
        hapticsHelp: String = "Short confirmation pulses for switches, settings and controls.",
        keepScreenAwakeHelp: String = "Prevents auto-lock while this app is open. A monitor should stay lit.",
        feedback: @escaping () -> Void = {}
    ) {
        self._recordConfirmation = recordConfirmation; self._haptics = haptics
        self._keepScreenAwake = keepScreenAwake; self.hapticsHelp = hapticsHelp
        self.keepScreenAwakeHelp = keepScreenAwakeHelp; self.feedback = feedback
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "Touch & safety") {
            MonitorSettingsSwitchInlineRow(
                title: "Record confirmation", help: "Ask before starting or stopping recording to prevent mistaps.",
                showTopDivider: false, isOn: recordConfirmation, feedback: feedback
            ) { recordConfirmation.toggle() }
            MonitorSettingsSwitchInlineRow(title: "Haptics", help: hapticsHelp,
                isOn: haptics, feedback: feedback) { haptics.toggle() }
            MonitorSettingsSwitchInlineRow(title: "Keep screen awake", help: keepScreenAwakeHelp,
                isOn: keepScreenAwake, feedback: feedback) { keepScreenAwake.toggle() }
        }
    }
}

/// A panel preference changes the monitor display, independently of camera capture settings.
public struct MonitorPanelSettings: View {
    @Binding private var hdrDisplay: Bool
    private let help: String
    private let feedback: () -> Void

    public init(hdrDisplay: Binding<Bool>, help: String, feedback: @escaping () -> Void = {}) {
        self._hdrDisplay = hdrDisplay; self.help = help; self.feedback = feedback
    }
    public var body: some View {
        MonitorSettingsRowCard(title: "Panel") {
            MonitorSettingsSwitchInlineRow(title: "HDR display", help: help, showTopDivider: false,
                isOn: hdrDisplay, feedback: feedback) { hdrDisplay.toggle() }
        }
    }
}
#endif
