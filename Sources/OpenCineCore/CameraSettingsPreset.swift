import Foundation

/// A named set of exposure and white balance values the operator saved from a camera, recalled
/// later through the common setting commands. The values are common `SettingValue`s, so a preset
/// carries no wire bytes and names no manufacturer: what a camera can take back is decided by its
/// setting descriptors at recall time. Kotlin twin: `CameraSettingsPreset`.
public struct CameraSettingsPreset: Hashable, Sendable, Identifiable {
    /// The settings a preset holds, in recall order: white balance before its tint (a tint rides on
    /// a known white balance), then ISO, shutter, aperture and exposure compensation.
    public static let keys: [SettingKey] = [
        .whiteBalance, .whiteBalanceTint, .iso, .shutter, .aperture, .exposureCompensation,
    ]

    public var id: String
    public var name: String
    /// At most one value per key of `keys`, in recall order.
    public private(set) var values: [SettingValue]

    /// Keys outside `keys` drop out; a later value for the same key replaces an earlier one.
    public init(id: String = UUID().uuidString, name: String, values: [SettingValue]) {
        self.id = id
        self.name = name
        var byKey: [SettingKey: SettingValue] = [:]
        for value in values where Self.keys.contains(value.key) { byKey[value.key] = value }
        self.values = Self.keys.compactMap { byKey[$0] }
    }

    public func value(of key: SettingKey) -> SettingValue? {
        values.first { $0.key == key }
    }

    /// The values the operator can set on `snapshot`'s camera right now: each preset key the camera
    /// describes as writable and available, with a valid reported value inside its domain. `nil`
    /// when there is none (nothing reported yet, or nothing settable in this mode).
    public static func capture(
        name: String, id: String = UUID().uuidString, from snapshot: CameraSnapshot
    ) -> CameraSettingsPreset? {
        let values = keys.compactMap { key -> SettingValue? in
            guard let descriptor = snapshot.capabilities[key], descriptor.access == .readWrite,
                descriptor.availability == .available
            else { return nil }
            let observed = snapshot.value(of: key)
            guard observed.validity == .valid, let value = observed.value, descriptor.accepts(value)
            else { return nil }
            return value
        }
        return values.isEmpty ? nil : CameraSettingsPreset(id: id, name: name, values: values)
    }
}

/// Why a recall left a preset value out: the camera it was recalled on cannot take it now.
public enum CameraSettingsPresetSkip: Hashable, Sendable {
    /// The camera does not describe the setting (or says it has none).
    case unsupported
    case readOnly
    case unavailable(UnavailableReason)
    /// The camera offers the setting, but not this value.
    case outOfDomain

    /// The skip a shared admission rejection stands for; `nil` for a rejection about the link,
    /// authority or stale state rather than what the camera can do.
    public init?(_ rejection: CommandRejection) {
        switch rejection {
        case .unsupported, .supportUnknown: self = .unsupported
        case .readOnly: self = .readOnly
        case .unavailable(let reason): self = .unavailable(reason)
        case .outOfDomain: self = .outOfDomain
        default: return nil
        }
    }
}

/// What recalling one preset did, value by value, in recall order.
public struct CameraSettingsPresetRecall: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// The camera confirmed it (or acknowledged it, where it only acknowledges).
        case applied
        /// The camera already reported this value; nothing was sent.
        case unchanged
        /// The camera cannot take it now; nothing was sent.
        case skipped(CameraSettingsPresetSkip)
        /// Refused for another reason, or sent without a confirmation; the stage says which.
        case failed(CommandStage)
    }

    public struct Entry: Hashable, Sendable {
        public var value: SettingValue
        public var outcome: Outcome
        public init(value: SettingValue, outcome: Outcome) {
            self.value = value
            self.outcome = outcome
        }
    }

    public var name: String
    public var entries: [Entry]

    public init(name: String, entries: [Entry]) {
        self.name = name
        self.entries = entries
    }

    public var applied: [SettingKey] {
        entries.compactMap { $0.outcome == .applied ? $0.value.key : nil }
    }

    public var skipped: [(key: SettingKey, skip: CameraSettingsPresetSkip)] {
        entries.compactMap {
            if case .skipped(let skip) = $0.outcome { return ($0.value.key, skip) }
            return nil
        }
    }

    public var failed: [(key: SettingKey, stage: CommandStage)] {
        entries.compactMap {
            if case .failed(let stage) = $0.outcome { return ($0.value.key, stage) }
            return nil
        }
    }
}

/// The stored text of a preset list: a version line, then one line per preset with tab-separated
/// id, name and value tokens. Unknown tokens and malformed lines are skipped, so a list written by
/// a later version still loads what this one understands. Kotlin twin: `CameraSettingsPresetCodec`,
/// same text for the same presets.
public enum CameraSettingsPresetCodec {
    static let header = "opencine-presets 1"

    public static func encode(_ presets: [CameraSettingsPreset]) -> String {
        var lines = [header]
        for preset in presets {
            let fields = [clean(preset.id), clean(preset.name)] + preset.values.compactMap(token)
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> [CameraSettingsPreset] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == header else { return [] }
        var seen: Set<String> = []
        var presets: [CameraSettingsPreset] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty, seen.insert(fields[0]).inserted else { continue }
            let values = fields.dropFirst(2).compactMap(value)
            guard !values.isEmpty else { continue }
            presets.append(CameraSettingsPreset(id: fields[0], name: fields[1], values: values))
        }
        return presets
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func token(_ value: SettingValue) -> String? {
        switch value {
        case .iso(.auto): "iso=auto"
        case .iso(.autoLimited(let maximum)): "iso=auto:\(maximum)"
        case .iso(.manual(let iso)): "iso=\(iso)"
        case .shutter(.auto): "shutter=auto"
        case .shutter(.duration(let seconds)): "shutter=\(seconds.numerator)/\(seconds.denominator)"
        case .shutter(.angle(let degrees)): "shutter=\(number(degrees))deg"
        case .aperture(let fNumber): "aperture=\(number(fNumber))"
        case .exposureCompensation(let stops): "ev=\(stops.numerator)/\(stops.denominator)"
        case .whiteBalance(.auto): "wb=auto"
        case .whiteBalance(.kelvin(let kelvin)): "wb=\(kelvin)K"
        case .whiteBalance(.preset(let id)): "wb=preset:\(clean(id))"
        case .whiteBalanceTint(let tint): "tint=\(number(tint))"
        case .frameRate, .focusMode, .zoom: nil
        }
    }

    static func value(_ token: String) -> SettingValue? {
        guard let equals = token.firstIndex(of: "=") else { return nil }
        let name = token[..<equals]
        let text = String(token[token.index(after: equals)...])
        switch name {
        case "iso":
            if text == "auto" { return .iso(.auto) }
            if text.hasPrefix("auto:") { return Int(text.dropFirst(5)).map { .iso(.autoLimited(maximum: $0)) } }
            return Int(text).map { .iso(.manual($0)) }
        case "shutter":
            if text == "auto" { return .shutter(.auto) }
            if text.hasSuffix("deg") { return double(String(text.dropLast(3))).map { .shutter(.angle($0)) } }
            return rational(text).map { .shutter(.duration($0)) }
        case "aperture": return double(text).map { .aperture($0) }
        case "ev": return rational(text).map { .exposureCompensation($0) }
        case "wb":
            if text == "auto" { return .whiteBalance(.auto) }
            if text.hasPrefix("preset:") {
                let id = String(text.dropFirst(7))
                return id.isEmpty ? nil : .whiteBalance(.preset(id))
            }
            guard text.hasSuffix("K") else { return nil }
            return Int(text.dropLast()).map { .whiteBalance(.kelvin($0)) }
        case "tint": return double(text).map { .whiteBalanceTint($0) }
        default: return nil
        }
    }

    private static func number(_ value: Double) -> String { String(describing: value) }

    private static func double(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func rational(_ text: String) -> Rational? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let numerator = Int(parts[0]), let denominator = Int(parts[1]),
            denominator != 0
        else { return nil }
        return Rational(numerator, denominator)
    }
}
