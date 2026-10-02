import Foundation
import OpenCineCore

/// A drum detent keeps its typed command value. Display copy never becomes a wire mapping.
public struct MonitorCaptureChoice: Hashable, Sendable {
    public let value: SettingValue
    public let label: String

    public init(value: SettingValue, label: String) {
        self.value = value
        self.label = label
    }
}

/// One common readout and the immutable editor its gestures opened against.
@available(macOS 14, *)
public struct MonitorCaptureField: Hashable, Sendable {
    public let key: SettingKey
    public let title: String
    /// An absent report stays absent, including when there is a visual drum fallback.
    public let selection: SettingValue?
    public let choices: [MonitorCaptureChoice]
    public let editor: MonitorControlModel.Editor?

    public var label: String? { selection.map(MonitorCapturePresentation.label) }
    public var isEditable: Bool { editor != nil && !choices.isEmpty }
}

/// Common setting copy and bounded drum sampling. Integrations own the accepted domain.
public enum MonitorCapturePresentation {
    public static func title(_ key: SettingKey) -> String? {
        switch key {
        case .iso: "ISO"
        case .shutter: "SHUTTER"
        case .whiteBalance: "WB"
        default: nil
        }
    }

    public static func label(_ value: SettingValue) -> String {
        switch value {
        case .iso(.auto): "Auto"
        case .iso(.autoLimited(let maximum)): "Auto \(maximum)"
        case .iso(.manual(let iso)): String(iso)
        case .shutter(.auto): "Auto"
        case .shutter(.duration(let seconds)):
            seconds.numerator == 1 ? "1/\(seconds.denominator)" : "\(number(seconds.doubleValue))s"
        case .shutter(.angle(let angle)): "\(number(angle))°"
        case .whiteBalance(.auto): "Auto"
        case .whiteBalance(.preset(let name)): name
        case .whiteBalance(.kelvin(let kelvin)): "\(kelvin)K"
        default: ""
        }
    }

    static func choices(_ key: SettingKey, domain: SettingDomain?) -> [MonitorCaptureChoice] {
        guard let domain else { return [] }
        var values = domain.choices.filter { $0.key == key }
        if key == .whiteBalance, let range = domain.range {
            // Kelvin has integer units. A continuous domain uses 100 K detents; an explicit
            // camera step is honored. Bound allocation even for an erroneous remote domain.
            let step = domain.step ?? 100
            if range.lowerBound.isFinite, range.upperBound.isFinite, step.isFinite, step > 0,
                range.lowerBound >= 0, range.upperBound < Double(Int.max),
                (range.upperBound - range.lowerBound) / step <= 1_000
            {
                let count = Int(((range.upperBound - range.lowerBound) / step).rounded(.down))
                for index in 0...count {
                    let kelvin = range.lowerBound + Double(index) * step
                    if kelvin.rounded() == kelvin {
                        let value = SettingValue.whiteBalance(.kelvin(Int(kelvin)))
                        if domain.contains(value), !values.contains(value) { values.append(value) }
                    }
                }
            }
        }
        return values.map { MonitorCaptureChoice(value: $0, label: label($0)) }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

@available(macOS 14, *)
extension MonitorControlModel {
    /// A described common field remains readable while unavailable; only a writable, ready
    /// field gets an editor. No observation or capability is inferred from a brand.
    public func captureField(_ key: SettingKey) -> MonitorCaptureField? {
        guard let title = MonitorCapturePresentation.title(key), let snapshot,
            let descriptor = snapshot.capabilities[key]
        else { return nil }
        let authorized: Bool
        switch snapshot.authority {
        case .owner, .lease: authorized = true
        default: authorized = false
        }
        let writable = authorized && snapshot.connection == .ready
            && descriptor.access == .readWrite && descriptor.availability == .available
        return MonitorCaptureField(
            key: key, title: title, selection: shown(key),
            choices: MonitorCapturePresentation.choices(key, domain: descriptor.domain),
            editor: writable ? edit(key) : nil)
    }

    /// Both held gestures and persistent drums commit the editor they opened, never a new one.
    @discardableResult public func commit(_ choice: MonitorCaptureChoice, from field: MonitorCaptureField) -> Bool {
        guard let editor = field.editor, field.choices.contains(choice),
            let current = captureField(field.key), current.isEditable,
            current.editor == editor
        else { return false }
        return commit(choice.value, from: editor, label: "\(field.title) \(choice.label)")
    }
}
