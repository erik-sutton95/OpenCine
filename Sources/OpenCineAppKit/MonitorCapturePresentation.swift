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

/// Which observation a readout presents; pending commands never become camera reports.
public enum MonitorCaptureSelection: Hashable, Sendable { case reported, pending }

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

@available(macOS 14, *)
extension MonitorCaptureField {
    /// The Custom white balance hold drum: Kelvin detents only. Leaving Custom for Auto or a
    /// preset takes the panel, so a quick drag never flips the white balance mode.
    public var kelvinScrub: MonitorCaptureField {
        MonitorCaptureField(key: key, title: title, selection: selection, choices: choices.filter {
            if case .whiteBalance(.kelvin) = $0.value { true } else { false }
        }, editor: editor)
    }
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
        isUnreported(drawn) ? "Not set" : drawn
    }

    /// Whether a readout's drawn value stands for a value the camera has not reported.
    public static func isUnreported(_ drawn: String) -> Bool {
        unreportedMarks.contains(drawn) || drawn == "Not set"
    }

    /// An unreported readout whose owner offers nothing to edit is inert: it is disabled and opens
    /// no panel. `editable` is nil when the readout declares no field or native owner; such a
    /// readout keeps the host's panel unless it disabled its quick control. A host action or a
    /// reported value always keeps the readout live.
    public static func readoutIsInert(reported: Bool, editable: Bool?, quickEnabled: Bool,
        hasAction: Bool) -> Bool {
        if hasAction || reported { return false }
        guard let editable else { return !quickEnabled }
        return !(quickEnabled && editable)
    }

    /// The same rule for a readout drawn from a common field or a native quick control.
    @available(macOS 14, *)
    public static func readoutIsInert(value: String, field: MonitorCaptureField?, nativeEnabled: Bool?,
        quickEnabled: Bool, hasAction: Bool) -> Bool {
        if let field {
            return readoutIsInert(reported: field.selection != nil, editable: field.isEditable,
                quickEnabled: quickEnabled, hasAction: hasAction)
        }
        return readoutIsInert(reported: !isUnreported(value), editable: nativeEnabled,
            quickEnabled: quickEnabled, hasAction: hasAction)
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
        // One decimal, as every body and its menus spell it ("f/4.0").
        case .aperture(let aperture): String(format: "f/%.1f", aperture)
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

    /// Bounded typed detents from the reported domain; this projection grants no command authority.
    public static func choices(_ key: SettingKey, domain: SettingDomain?) -> [MonitorCaptureChoice] {
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

    public static func exposureProgram(_ value: CameraExposureProgram) -> String {
        switch value {
        case .automatic, .aperturePriority: "A"
        case .manual: "M"
        case .isoPriority: "I"
        case .shutterPriority: "S"
        case .program: "P"
        }
    }

    /// Recording facts are independent of preview encoding and pending format commands.
    public static func recordingFormat(_ snapshot: CameraSnapshot) -> CameraRecordingFormat {
        let rate: Rational?
        if case .frameRate(let value)? = snapshot.value(of: .frameRate).value { rate = value } else { rate = nil }
        return CameraRecordingFormat(dimensions: snapshot.recordingFormat.dimensions.value,
            frameRate: rate, profile: snapshot.recordingFormat.profile.value, codec: snapshot.recordingFormat.codec.value)
    }

    public static func recordingLabel(_ format: CameraRecordingFormat) -> String? {
        let size = format.dimensions.map(resolutionLabel)
        let rate = format.frameRate.map { frameRate($0) + "p" }
        let parts = [size, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A compact caption derives from measured geometry and keeps uncommon dimensions exact.
    public static func resolutionLabel(_ size: CameraRecordingFormat.Dimensions) -> String {
        let width = max(size.width, size.height)
        let label: String
        switch width {
        case 7680...: label = "8K"
        case 5000..<7680: label = "6K"
        case 3500..<5000: label = "4K"
        case 2880..<3500: label = "3K"
        case 2500..<2880: label = "2.7K"
        case 2160 where size.width == size.height: label = "2160p"
        case 1080 where size.width == size.height: label = "1080p"
        case 1920: label = "1080p"
        default: return "\(size.width)×\(size.height)"
        }
        let ratio = Double(size.width) / Double(size.height)
        let aspect: String
        switch ratio {
        case let x where abs(x - 16.0 / 9.0) < 0.015: aspect = ""
        case let x where abs(x - 4.0 / 3.0) < 0.015: aspect = " 4:3"
        case let x where abs(x - 9.0 / 16.0) < 0.015: aspect = " 9:16"
        case let x where abs(x - 1.0) < 0.015: aspect = " 1:1"
        case let x where abs(x - 2.35) < 0.03: aspect = " 2.35:1"
        default: aspect = ""
        }
        return label + aspect
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
        captureField(key, selection: .pending)
    }

    /// Read a reported or pending value through the same descriptor and editor admission.
    public func captureField(_ key: SettingKey, selection: MonitorCaptureSelection) -> MonitorCaptureField? {
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
            key: key, title: title, selection: captureValue(key, selection: selection),
            choices: drum(key, domain: descriptor.domain),
            editor: writable ? edit(key) : nil)
    }

    /// Readout observations do not require a writable descriptor or create an editor.
    public func captureValue(_ key: SettingKey, selection: MonitorCaptureSelection) -> SettingValue? {
        selection == .pending ? shown(key) : snapshot?.value(of: key).value
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
