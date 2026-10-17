import Foundation

/// An exact ratio, normalized so that equal values compare equal (2/100 == 1/50).
public struct Rational: Hashable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator != 0, "Rational denominator must not be zero")
        var a = abs(numerator)
        var b = abs(denominator)
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(a, 1) * (denominator < 0 ? -1 : 1)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let denominator = try container.decode(Int.self, forKey: .denominator)
        guard denominator != 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .denominator, in: container, debugDescription: "zero denominator")
        }
        self.init(try container.decode(Int.self, forKey: .numerator), denominator)
    }

    public var doubleValue: Double { Double(numerator) / Double(denominator) }
    public var description: String { "\(numerator)/\(denominator)" }

    /// The exact rate for a source that reports frames per second as a decimal: whole rates stay
    /// whole, the NTSC family (23.976, 29.97, 59.94, ...) is N*1000/1001, anything else keeps
    /// thousandths. `nil` when not a positive finite rate. Kotlin twin: `Rational.frameRate`.
    public static func frameRate(_ framesPerSecond: Double) -> Rational? {
        guard framesPerSecond.isFinite, framesPerSecond > 0, framesPerSecond < 100_000 else { return nil }
        let whole = framesPerSecond.rounded()
        if abs(framesPerSecond - whole) < 0.005 { return Rational(Int(whole)) }
        let ntsc = (framesPerSecond * 1.001).rounded()
        if abs(framesPerSecond - ntsc / 1.001) < 0.005 { return Rational(Int(ntsc) * 1000, 1001) }
        return Rational(Int((framesPerSecond * 1000).rounded()), 1000)
    }
}

/// The small common setting vocabulary. Expand only for a real use case.
///
/// `recording` and `focusPoint` are command-only controls: they carry support, access and
/// availability but no value domain. Recording is commanded with explicit start/stop intents and
/// observed through `CameraSnapshot.recording`.
public enum SettingKey: String, Hashable, Codable, Sendable, CaseIterable {
    case iso
    case shutter
    case aperture
    case exposureCompensation
    case whiteBalance
    /// White balance tint, a separate setting because cameras expose it apart from the white
    /// balance mode (plan 5.6). A camera without tint lists it as unsupported.
    case whiteBalanceTint
    case frameRate
    case focusMode
    case zoom
    case recording
    case focusPoint
}

/// ISO is an enumerated ladder, auto, or auto bounded by a ceiling. Never assume every integer.
public enum ISOValue: Hashable, Codable, Sendable {
    case auto
    case autoLimited(maximum: Int)
    case manual(Int)
}

/// Native duration mode keeps the duration when the recording frame rate changes; native angle
/// mode keeps the angle. A camera's domain contains only the mode it is in, so a duration is never
/// silently converted to an angle (or back) and the camera mode is never changed as a side effect.
public enum ShutterValue: Hashable, Codable, Sendable {
    case auto
    /// Exposure time in seconds, for example 1/50.
    case duration(Rational)
    /// Shutter angle in degrees, for example 180.
    case angle(Double)
}

public enum WhiteBalanceValue: Hashable, Codable, Sendable {
    case auto
    /// Integration-owned preset identifier such as `daylight`.
    case preset(String)
    case kelvin(Int)
}

public enum FocusMode: String, Hashable, Codable, Sendable {
    case manual
    case single
    case continuous
}

/// The reviewed sum type used wherever settings are collected, serialized or shown generically.
/// Each case implies its key, so a value can never be filed under the wrong setting.
public enum SettingValue: Hashable, Codable, Sendable {
    case iso(ISOValue)
    case shutter(ShutterValue)
    /// f-number.
    case aperture(Double)
    /// Stops, for example -1/3.
    case exposureCompensation(Rational)
    case whiteBalance(WhiteBalanceValue)
    /// Green-magenta offset on the integration's own scale (its domain gives range and step).
    /// Positive is toward magenta. Applies on top of the white balance mode, auto included.
    case whiteBalanceTint(Double)
    /// Recording frame rate in frames per second, for example 24000/1001.
    case frameRate(Rational)
    case focusMode(FocusMode)
    /// Zoom ratio, 1 = widest.
    case zoom(Double)

    public var key: SettingKey {
        switch self {
        case .iso: .iso
        case .shutter: .shutter
        case .aperture: .aperture
        case .exposureCompensation: .exposureCompensation
        case .whiteBalance: .whiteBalance
        case .whiteBalanceTint: .whiteBalanceTint
        case .frameRate: .frameRate
        case .focusMode: .focusMode
        case .zoom: .zoom
        }
    }

    /// The number a `SettingDomain.range` constrains. Other values must be listed as choices.
    public var numericValue: Double? {
        switch self {
        case .iso(.manual(let iso)): Double(iso)
        case .aperture(let fNumber): fNumber
        case .whiteBalance(.kelvin(let kelvin)): Double(kelvin)
        case .whiteBalanceTint(let tint): tint
        case .zoom(let ratio): ratio
        default: nil
        }
    }
}

/// Layer 2: valid values. A value is valid when it is one of `choices`, or when its
/// `numericValue` lies in `range` on a `step` boundary. Automatic modes are listed as choices.
/// The unit is implied by the setting key.
public struct SettingDomain: Hashable, Codable, Sendable {
    public var choices: [SettingValue]
    public var range: ClosedRange<Double>?
    public var step: Double?

    public init(
        choices: [SettingValue] = [], range: ClosedRange<Double>? = nil, step: Double? = nil
    ) {
        self.choices = choices
        self.range = range
        self.step = step
    }

    public func contains(_ value: SettingValue) -> Bool {
        if choices.contains(value) { return true }
        guard let x = value.numericValue, let range, range.contains(x) else { return false }
        guard let step, step > 0 else { return true }
        let steps = (x - range.lowerBound) / step
        return abs(steps - steps.rounded()) < 1e-9 * max(1, abs(steps))
    }
}

/// Layer 1: support.
public enum SupportStatus: Hashable, Codable, Sendable {
    case supported
    case unsupported
    /// Not yet discovered for this device, firmware, route or mode.
    case unknown
}

public enum SettingAccess: Hashable, Codable, Sendable {
    case readOnly
    case readWrite
}

public enum UnavailableReason: Hashable, Codable, Sendable {
    case recordingActive
    case mode
    case link
    case authority
    case busy
    case route
    /// A camera prerequisite is not met yet, for example its own live view is not running.
    case notReady
    case otherSetting(SettingKey)
}

/// Layer 3: current availability.
public enum Availability: Hashable, Codable, Sendable {
    case available
    case unavailable(UnavailableReason)
}

/// Layer 4: semantics and evidence.
public struct SettingSemantics: Hashable, Codable, Sendable {
    public enum Implementation: Hashable, Codable, Sendable {
        case native
        /// Implemented by the integration on top of other camera behavior, with side effects.
        case emulated
    }

    public enum Confirmation: Hashable, Codable, Sendable {
        /// The camera later reports the resulting value; commands wait for it.
        case readback
        /// The camera only acknowledges; an accepted command is finished.
        case acknowledgementOnly
    }

    public enum Qualification: Hashable, Codable, Sendable {
        case qualified
        case unqualified
    }

    public var implementation: Implementation
    public var confirmation: Confirmation
    public var qualification: Qualification

    public init(
        implementation: Implementation = .native, confirmation: Confirmation = .readback,
        qualification: Qualification = .unqualified
    ) {
        self.implementation = implementation
        self.confirmation = confirmation
        self.qualification = qualification
    }
}

/// Layers 2 to 4 of one supported setting. Layer 1 lives in `CapabilitySnapshot`.
/// Display titles are UI copy and stay in the UI.
public struct SettingDescriptor: Hashable, Codable, Sendable {
    public var key: SettingKey
    public var access: SettingAccess
    /// `nil` for command-only controls.
    public var domain: SettingDomain?
    public var availability: Availability
    public var semantics: SettingSemantics

    public init(
        _ key: SettingKey, access: SettingAccess = .readWrite, domain: SettingDomain? = nil,
        availability: Availability = .available, semantics: SettingSemantics = .init()
    ) {
        self.key = key
        self.access = access
        self.domain = domain
        self.availability = availability
        self.semantics = semantics
    }

    /// Whether `value` belongs to this setting and its current domain.
    public func accepts(_ value: SettingValue) -> Bool {
        value.key == key && domain?.contains(value) == true
    }
}

/// How precisely a source counts its timecode. Shared formatting follows it, so a seconds-only
/// source never shows a frame field and a frame-counting source never loses one.
public enum TimecodePrecision: Hashable, Codable, Sendable {
    /// Whole seconds only (a host clock, or a counter whose frame field is not proven per frame).
    case seconds
    /// Frames at `rate`. `dropFrame` is `nil` when the camera does not say.
    case frames(rate: Rational, dropFrame: Bool?)
}

/// Support for `CameraSnapshot.timecode` plus its declared precision. `precision` is `nil` while
/// support is not `.supported` or the source has not said how it counts.
public struct TimecodeCapability: Hashable, Codable, Sendable {
    public var support: SupportStatus
    public var precision: TimecodePrecision?

    public init(support: SupportStatus = .unknown, precision: TimecodePrecision? = nil) {
        self.support = support
        self.precision = support == .supported ? precision : nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(support: try values.decode(SupportStatus.self, forKey: .support),
            precision: try values.decodeIfPresent(TimecodePrecision.self, forKey: .precision))
    }

    public static let unknown = TimecodeCapability()
    public static let unsupported = TimecodeCapability(support: .unsupported)
    public static func supported(_ precision: TimecodePrecision?) -> TimecodeCapability {
        TimecodeCapability(support: .supported, precision: precision)
    }
}

/// The revisioned set of setting descriptors, plus support for the observations that are not
/// settings. A key that is neither described nor listed as unsupported has unknown support.
/// Missing groups (no aperture, say) never block the rest.
public struct CapabilitySnapshot: Hashable, Codable, Sendable {
    public var revision: CapabilityRevision
    public var descriptors: [SettingKey: SettingDescriptor]
    public var unsupported: Set<SettingKey>
    /// Whether the camera reports timecode. The published support-only contract is retained.
    public var timecode: SupportStatus {
        get { timecodeCapability.support }
        set {
            if newValue != timecodeCapability.support {
                timecodeCapability = TimecodeCapability(support: newValue)
            }
        }
    }
    /// Support and declared precision for the additive `CameraSnapshot.timecodeReading`.
    public var timecodeCapability: TimecodeCapability
    /// Whether the camera reports live `CameraSnapshot.audioLevels`.
    public var audioLevels: SupportStatus

    public init(
        revision: CapabilityRevision = .init(), descriptors: [SettingDescriptor] = [],
        unsupported: Set<SettingKey> = [], timecode: SupportStatus = .unknown,
        audioLevels: SupportStatus = .unknown
    ) {
        self.init(revision: revision, descriptors: descriptors, unsupported: unsupported,
            timecodeCapability: TimecodeCapability(support: timecode), audioLevels: audioLevels)
    }

    public init(
        revision: CapabilityRevision = .init(), descriptors: [SettingDescriptor] = [],
        unsupported: Set<SettingKey> = [], timecodeCapability: TimecodeCapability,
        audioLevels: SupportStatus = .unknown
    ) {
        self.revision = revision
        self.descriptors = Dictionary(descriptors.map { ($0.key, $0) }) { _, last in last }
        self.unsupported = unsupported
        self.timecodeCapability = timecodeCapability
        self.audioLevels = audioLevels
    }

    private enum CodingKeys: String, CodingKey {
        case revision, descriptors, unsupported, timecode, timecodeCapability, audioLevels
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(CapabilityRevision.self, forKey: .revision)
        descriptors = try values.decode([SettingKey: SettingDescriptor].self, forKey: .descriptors)
        unsupported = try values.decode(Set<SettingKey>.self, forKey: .unsupported)
        audioLevels = try values.decode(SupportStatus.self, forKey: .audioLevels)
        let compatibility: TimecodeCapability
        if let support = try? values.decode(SupportStatus.self, forKey: .timecode) {
            // The published enum uses its synthesized case tag, for example {"supported":{}}.
            compatibility = TimecodeCapability(support: support)
        } else if let text = try? values.decode(String.self, forKey: .timecode) {
            let support: SupportStatus
            switch text {
            case "supported": support = .supported
            case "unsupported": support = .unsupported
            case "unknown": support = .unknown
            default:
                throw DecodingError.dataCorruptedError(forKey: .timecode, in: values,
                    debugDescription: "Unknown timecode support string")
            }
            compatibility = TimecodeCapability(support: support)
        } else {
            // The parity checkpoint wrote the rich object under the legacy key before migration.
            compatibility = try values.decode(TimecodeCapability.self, forKey: .timecode)
        }
        if let precise = try values.decodeIfPresent(TimecodeCapability.self, forKey: .timecodeCapability) {
            guard precise.support == compatibility.support else {
                throw DecodingError.dataCorruptedError(forKey: .timecodeCapability, in: values,
                    debugDescription: "Timecode support disagrees with the legacy field")
            }
            timecodeCapability = precise
        } else {
            timecodeCapability = compatibility
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(descriptors, forKey: .descriptors)
        try values.encode(unsupported, forKey: .unsupported)
        try values.encode(timecode, forKey: .timecode)
        try values.encode(timecodeCapability, forKey: .timecodeCapability)
        try values.encode(audioLevels, forKey: .audioLevels)
    }

    public subscript(key: SettingKey) -> SettingDescriptor? { descriptors[key] }

    public func support(of key: SettingKey) -> SupportStatus {
        if descriptors[key] != nil { return .supported }
        return unsupported.contains(key) ? .unsupported : .unknown
    }
}
