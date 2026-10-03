#if os(iOS)
import SwiftUI
import UIKit

/// Native numeric input, action and display controls shared by operator settings.
public struct MonitorSettingsNumberField: View {
    @Binding var value: Int
    var maximum: Int = 100

    public init(value: Binding<Int>, maximum: Int = 100) {
        self._value = value; self.maximum = maximum
    }

    public static let doneTitle = "Done"

    public var body: some View {
        MonitorSettingsNumberPadInput(value: $value, maximum: maximum)
            .frame(width: 44, height: 30)
            .background(
                MonitorTheme.background.opacity(0.5),
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                    .stroke(MonitorTheme.border, lineWidth: 1)
            )
    }
}

/// Number pad has no Return. A UIKit accessory is the reliable Done control
/// outside a NavigationStack (live / playback assist overlays).
private struct MonitorSettingsNumberPadInput: UIViewRepresentable {
    @Binding var value: Int
    var maximum: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, maximum: maximum)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.textAlignment = .center
        _ = MonitorTheme.font(12, weight: .semibold)
        field.font =
            UIFont(name: "Sora-SemiBold", size: 12)
            ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = UIColor(MonitorTheme.text)
        field.tintColor = UIColor(MonitorTheme.accent)
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.delegate = context.coordinator
        field.text = String(value)
        field.accessibilityValue = String(value)
        field.inputAccessoryView = context.coordinator.makeDoneBar()
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged)
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.value = $value
        context.coordinator.maximum = maximum
        if !field.isFirstResponder, field.text != String(value) {
            field.text = String(value)
            field.accessibilityValue = String(value)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var value: Binding<Int>
        var maximum: Int
        weak var field: UITextField?

        init(value: Binding<Int>, maximum: Int) {
            self.value = value
            self.maximum = maximum
        }

        func makeDoneBar() -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.barStyle = .black
            bar.isTranslucent = true
            bar.tintColor = UIColor(MonitorTheme.accent)
            bar.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(
                    title: MonitorSettingsNumberField.doneTitle,
                    style: .done,
                    target: self,
                    action: #selector(done)),
            ]
            bar.sizeToFit()
            return bar
        }

        @objc func editingChanged(_ field: UITextField) {
            field.accessibilityValue = field.text
        }

        @objc func done() {
            field?.resignFirstResponder()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(textField)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let next = current.replacingCharacters(in: swiftRange, with: string)
            if next.isEmpty { return true }
            return next.allSatisfy(\.isNumber) && next.count <= 3
        }

        private func commit(_ textField: UITextField) {
            let parsed = Int(textField.text ?? "") ?? value.wrappedValue
            let clamped = min(max(parsed, 0), maximum)
            value.wrappedValue = clamped
            textField.text = String(clamped)
            textField.accessibilityValue = String(clamped)
        }
    }
}

public struct MonitorSettingsActionPill: View {
    let title: String
    var icon: MonitorIcon? = nil
    var tint: Color = MonitorTheme.accent
    var background: Color = MonitorTheme.accent.opacity(0.16)
    var fillsHeight = false
    let action: () -> Void

    public init(title: String, icon: MonitorIcon? = nil, tint: Color = MonitorTheme.accent,
        background: Color = MonitorTheme.accent.opacity(0.16), fillsHeight: Bool = false,
        action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.tint = tint; self.background = background
        self.fillsHeight = fillsHeight; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    icon.frame(width: 13, height: 13)
                }
                Text(title.uppercased())
                    .font(MonitorTheme.font(10.5, weight: .bold)).monospacedDigit()
                    .kerning(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(MonitorSettingsButtonStyle())
    }
}

public struct MonitorSettingsDisplayToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    public init(title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title; self.isOn = isOn; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(MonitorTheme.font( 11.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                Spacer(minLength: 0)
                MonitorSettingsSwitchGraphic(isOn: isOn)
                    .scaleEffect(0.86)
            }
            .padding(.horizontal, 9)
            .frame(height: 46)
            .background(
                MonitorTheme.background.opacity(0.38),
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius)
                    .stroke(MonitorTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(MonitorSettingsButtonStyle())
    }
}

#endif
