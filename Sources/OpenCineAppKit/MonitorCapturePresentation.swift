import Foundation
import OpenCineCore
import OpenCineMedia

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
        case .aperture: "IRIS"
        case .whiteBalance: "WB"
        case .exposureCompensation: "EV"
        case .focusMode: "FOCUS"
        case .frameRate: "FPS"
        default: nil
        }
    }

    /// The dashes a readout draws for a value the camera has not reported.
    public static let unreportedMarks: Set<String> = ["", "--", "\u{2014}"]

    /// What assistive technology reads for a readout's drawn value: an unreported value is drawn
    /// as a dash and read as "Not set", never as punctuation.
    public static func spokenValue(_ drawn: String) -> String {
        unreportedMarks.contains(drawn) ? "Not set" : drawn
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
        case .aperture(let aperture): "f/\(number(aperture))"
        case .whiteBalance(.auto): "Auto"
        case .whiteBalance(.preset(let name)): name
        case .whiteBalance(.kelvin(let kelvin)): "\(kelvin)K"
        case .exposureCompensation(let stops): ExposureCompensation.label(stops: stops.doubleValue)
        case .focusMode(.manual): "MF"
        case .focusMode(.single): "AF-S"
        case .focusMode(.continuous): "AF-C"
        case .frameRate(let rate): frameRate(rate)
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
                // Every detent lies on the domain's own grid; a set keeps the merge linear (R-03).
                var listed = Set(values)
                for index in 0...count {
                    let kelvin = range.lowerBound + Double(index) * step
                    if kelvin.rounded() == kelvin {
                        let value = SettingValue.whiteBalance(.kelvin(Int(kelvin)))
                        if listed.insert(value).inserted { values.append(value) }
                    }
                }
            }
        }
        return values.map { MonitorCaptureChoice(value: $0, label: label($0)) }
    }

    /// Whole rates print whole (24); the rest print two decimals (24000/1001 shows 23.98).
    /// Kotlin twin: `MonitorCapturePresentation.frameRate`.
    public static func frameRate(_ rate: Rational) -> String {
        rate.denominator == 1
            ? String(rate.numerator)
            : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rate.doubleValue)
    }

    /// C `%g` (no locale: a locale switches Foundation to `1.5E-05` and `1000000`). The Kotlin
    /// twin mirrors it; both read `Fixtures/capture-label-vectors.tsv`.
    private static func number(_ value: Double) -> String {
        String(format: "%g", value)
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
        let writable =
            authorized && snapshot.connection == .ready
            && descriptor.access == .readWrite && descriptor.availability == .available
        return MonitorCaptureField(
            key: key, title: title, selection: shown(key), choices: drum(key, domain: descriptor.domain),
            editor: writable ? edit(key) : nil)
    }

    /// The drum for a domain, built once per domain rather than on every read.
    private func drum(_ key: SettingKey, domain: SettingDomain?) -> [MonitorCaptureChoice] {
        guard let domain else { return [] }
        if let cached = captureChoices[key], cached.domain == domain { return cached.choices }
        let choices = MonitorCapturePresentation.choices(key, domain: domain)
        captureChoices[key] = (domain, choices)
        return choices
    }

    /// Both held gestures and persistent drums commit the editor they opened, never a new one.
    @discardableResult public func commit(
        _ choice: MonitorCaptureChoice, from field: MonitorCaptureField
    ) -> Bool {
        guard let editor = field.editor, field.choices.contains(choice),
            let current = captureField(field.key), current.isEditable,
            current.editor == editor
        else { return false }
        return commit(choice.value, from: editor, label: "\(field.title) \(choice.label)")
    }
}
