#if os(iOS)
import SwiftUI

/// Motion settings receive the host's bindings, ranges and feedback policy.
public struct MonitorMotionIntegerSetting {
    let value: Binding<Int>
    let range: ClosedRange<Int>
    let help: String
    let suffix: String
    let feedback: () -> Void

    public init(value: Binding<Int>, range: ClosedRange<Int>, help: String,
        suffix: String = "", feedback: @escaping () -> Void = {}) {
        self.value = value; self.range = range; self.help = help
        self.suffix = suffix; self.feedback = feedback
    }
}

public struct MonitorMotionChoiceSetting {
    let options: [String]
    let selection: Binding<String>
    let help: String
    let feedback: () -> Void

    public init(options: [String], selection: Binding<String>, help: String,
        feedback: @escaping () -> Void = {}) {
        self.options = options; self.selection = selection
        self.help = help; self.feedback = feedback
    }
}

public struct MonitorMotionToggleSetting {
    let value: Binding<Bool>
    let help: String
    let feedback: () -> Void

    public init(value: Binding<Bool>, help: String, feedback: @escaping () -> Void = {}) {
        self.value = value; self.help = help; self.feedback = feedback
    }
}

public struct MonitorGimbalSettings: View {
    private let sensitivity: MonitorMotionIntegerSetting
    private let headTracking: MonitorMotionToggleSetting?

    public init(sensitivity: MonitorMotionIntegerSetting,
        headTracking: MonitorMotionToggleSetting? = nil) {
        self.sensitivity = sensitivity; self.headTracking = headTracking
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "Gimbal") {
            MonitorSettingsInlineRow(title: "Joystick sensitivity", help: sensitivity.help,
                showTopDivider: false, stacked: true) {
                MotionIntegerSlider(setting: sensitivity, title: "Joystick sensitivity", labelWidth: 24)
            }
            if let headTracking {
                MonitorSettingsSwitchInlineRow(title: "Head Tracking (Experimental)",
                    help: headTracking.help, isOn: headTracking.value.wrappedValue,
                    feedback: headTracking.feedback) { headTracking.value.wrappedValue.toggle() }
            }
        }
    }
}

public struct MonitorJoystickSettings: View {
    private let size: MonitorMotionChoiceSetting
    private let invertPan: MonitorMotionToggleSetting
    private let invertTilt: MonitorMotionToggleSetting
    private let deadZone: MonitorMotionIntegerSetting
    private let response: MonitorMotionChoiceSetting
    private let identifierPrefix: String

    public init(size: MonitorMotionChoiceSetting, invertPan: MonitorMotionToggleSetting,
        invertTilt: MonitorMotionToggleSetting, deadZone: MonitorMotionIntegerSetting,
        response: MonitorMotionChoiceSetting, identifierPrefix: String = "monitor.joystick") {
        self.size = size; self.invertPan = invertPan; self.invertTilt = invertTilt
        self.deadZone = deadZone; self.response = response; self.identifierPrefix = identifierPrefix
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "On-screen joystick") {
            MonitorSettingsInlineRow(title: "Size", help: size.help,
                showTopDivider: false, stacked: true) {
                MotionChoiceControl(setting: size)
                    .accessibilityIdentifier(identifierPrefix + ".size")
            }
            MonitorSettingsSwitchInlineRow(title: "Invert pan", help: invertPan.help,
                isOn: invertPan.value.wrappedValue, identifier: identifierPrefix + ".invertPan",
                feedback: invertPan.feedback) { invertPan.value.wrappedValue.toggle() }
            MonitorSettingsSwitchInlineRow(title: "Invert tilt", help: invertTilt.help,
                isOn: invertTilt.value.wrappedValue, identifier: identifierPrefix + ".invertTilt",
                feedback: invertTilt.feedback) { invertTilt.value.wrappedValue.toggle() }
            MonitorSettingsInlineRow(title: "Dead zone", help: deadZone.help, stacked: true) {
                MotionIntegerSlider(setting: deadZone, title: "Dead zone", labelWidth: 40,
                    identifier: identifierPrefix + ".deadzone")
            }
            MonitorSettingsInlineRow(title: "Response curve", help: response.help, stacked: true) {
                MotionChoiceControl(setting: response)
                    .accessibilityIdentifier(identifierPrefix + ".response")
            }
        }
    }
}

public struct MonitorControllerSettings: View {
    private let stick: MonitorMotionChoiceSetting
    private let status: String
    private let statusHelp: String

    public init(stick: MonitorMotionChoiceSetting, status: String, statusHelp: String) {
        self.stick = stick; self.status = status; self.statusHelp = statusHelp
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "Controller") {
            MonitorSettingsInlineRow(title: "Gimbal joystick", help: stick.help,
                showTopDivider: false, stacked: true) { MotionChoiceControl(setting: stick) }
            MonitorSettingsInlineRow(title: "Gamepad", help: statusHelp) {
                MonitorSettingsValueText(value: status)
            }
        }
    }
}

/// An optional native processing choice uses the common settings row and segmented control.
private struct MotionChoiceControl: View {
    let setting: MonitorMotionChoiceSetting
    @State private var revision = 0
    private var selection: Binding<String> {
        Binding(get: { setting.selection.wrappedValue }, set: { setting.selection.wrappedValue = $0; revision += 1 })
    }
    var body: some View {
        let _ = revision
        MonitorSegmentedControl(options: setting.options, selection: selection,
            compact: true, title: { $0 }, onSelectionFeedback: setting.feedback)
            .buttonStyle(MonitorSettingsButtonStyle())
    }
}

private struct MotionIntegerSlider: View {
    let setting: MonitorMotionIntegerSetting
    let title: String
    let labelWidth: CGFloat
    var identifier: String = ""

    private var label: String { "\(setting.value.wrappedValue)" + setting.suffix }

    var body: some View {
        HStack(spacing: 9) {
            Slider(value: Binding(get: { Double(setting.value.wrappedValue) }, set: {
                let next = min(max(Int($0.rounded()), setting.range.lowerBound), setting.range.upperBound)
                guard next != setting.value.wrappedValue else { return }
                setting.feedback()
                setting.value.wrappedValue = next
            }), in: Double(setting.range.lowerBound)...Double(setting.range.upperBound), step: 1)
                .tint(MonitorTheme.accent)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
                .accessibilityValue(label)
            Text(label).font(MonitorTheme.font(12, weight: .medium)).monospacedDigit()
                .foregroundStyle(MonitorTheme.text)
                .frame(width: labelWidth, alignment: .trailing)
        }
    }
}
#endif
