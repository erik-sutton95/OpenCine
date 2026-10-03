import Foundation
import OpenCineMedia

/// Options contain the exact saved schema. Each source supplies storage and its existing key.
public protocol MonitorScopePanelOptions: Codable, Equatable, Sendable {
    var scale: Double { get set }
    var hasCustomScale: Bool { get set }
    var storedCenter: MonitorScopeStoredCenter? { get set }
    var storedCenterPortrait: MonitorScopeStoredCenter? { get set }
    static var `default`: Self { get }
    static func clampedScale(_ value: Double) -> Double
}
public struct MonitorWaveformOptions: MonitorScopePanelOptions {
    public static let scaleRange: ClosedRange<Double> = 0.6...1.6
    public static let defaultScale = 1.0
    public static let brightnessRange: ClosedRange<Int> = 0...200
    public static let defaultBrightness = 100
    public var mode: MonitorWaveformMode
    public var brightness: Int
    public var guides: MonitorScopeGuides
    public var scale: Double
    /// False only for a fresh automatic size; legacy saved scales stay explicit.
    public var hasCustomScale: Bool
    public var storedCenter: MonitorScopeStoredCenter?
    public var storedCenterPortrait: MonitorScopeStoredCenter?

    public static let `default` = Self(
        mode: .rgb,
        brightness: defaultBrightness,
        guides: .default,
        scale: defaultScale,
        storedCenter: nil,
        storedCenterPortrait: nil)

    public init(
        mode: MonitorWaveformMode = .rgb,
        brightness: Int = defaultBrightness,
        guides: MonitorScopeGuides = .default,
        scale: Double = defaultScale,
        hasCustomScale: Bool = false,
        storedCenter: MonitorScopeStoredCenter? = nil,
        storedCenterPortrait: MonitorScopeStoredCenter? = nil
    ) {
        self.mode = mode
        self.brightness = Self.clampedBrightness(brightness)
        self.guides = guides
        self.scale = Self.clampedScale(scale)
        self.hasCustomScale = hasCustomScale || scale != Self.defaultScale
        self.storedCenter = storedCenter
        self.storedCenterPortrait = storedCenterPortrait
    }

    enum CodingKeys: String, CodingKey {
        case mode, brightness, guides, scale, hasCustomScale, storedCenter, storedCenterPortrait
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(MonitorWaveformMode.self, forKey: .mode) ?? .rgb
        brightness = Self.clampedBrightness(
            try c.decodeIfPresent(Int.self, forKey: .brightness) ?? Self.defaultBrightness)
        guides = try c.decodeIfPresent(MonitorScopeGuides.self, forKey: .guides) ?? .default
        scale = Self.clampedScale(
            try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale)
        // Old JSON cannot distinguish an untouched 1.0 from a manual 1.0.
        // Preserve it rather than rewriting an operator's layout on upgrade.
        hasCustomScale =
            try c.decodeIfPresent(Bool.self, forKey: .hasCustomScale)
            ?? true
        storedCenter = try c.decodeIfPresent(MonitorScopeStoredCenter.self, forKey: .storedCenter)
        storedCenterPortrait = try c.decodeIfPresent(
            MonitorScopeStoredCenter.self, forKey: .storedCenterPortrait)
    }

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    public static func clampedBrightness(_ value: Int) -> Int {
        min(max(value, brightnessRange.lowerBound), brightnessRange.upperBound)
    }
}

public struct MonitorParadeOptions: MonitorScopePanelOptions {
    public static let scaleRange: ClosedRange<Double> = 0.6...1.6
    public static let defaultScale = 1.0
    public static let brightnessRange: ClosedRange<Int> = 0...200
    public static let defaultBrightness = 100
    public var mode: MonitorParadeMode
    public var brightness: Int
    public var guides: MonitorScopeGuides
    public var scale: Double
    /// False only for a fresh automatic size; legacy saved scales stay explicit.
    public var hasCustomScale: Bool
    public var storedCenter: MonitorScopeStoredCenter?
    public var storedCenterPortrait: MonitorScopeStoredCenter?

    public static let `default` = Self(
        mode: .rgb,
        brightness: defaultBrightness,
        guides: .default,
        scale: defaultScale,
        storedCenter: nil,
        storedCenterPortrait: nil)

    public init(
        mode: MonitorParadeMode = .rgb,
        brightness: Int = defaultBrightness,
        guides: MonitorScopeGuides = .default,
        scale: Double = defaultScale,
        hasCustomScale: Bool = false,
        storedCenter: MonitorScopeStoredCenter? = nil,
        storedCenterPortrait: MonitorScopeStoredCenter? = nil
    ) {
        self.mode = mode
        self.brightness = Self.clampedBrightness(brightness)
        self.guides = guides
        self.scale = Self.clampedScale(scale)
        self.hasCustomScale = hasCustomScale || scale != Self.defaultScale
        self.storedCenter = storedCenter
        self.storedCenterPortrait = storedCenterPortrait
    }

    enum CodingKeys: String, CodingKey {
        case mode, brightness, guides, scale, hasCustomScale, storedCenter, storedCenterPortrait
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(MonitorParadeMode.self, forKey: .mode) ?? .rgb
        brightness = Self.clampedBrightness(
            try c.decodeIfPresent(Int.self, forKey: .brightness) ?? Self.defaultBrightness)
        guides = try c.decodeIfPresent(MonitorScopeGuides.self, forKey: .guides) ?? .default
        scale = Self.clampedScale(
            try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale)
        // Old JSON cannot distinguish an untouched 1.0 from a manual 1.0.
        // Preserve it rather than rewriting an operator's layout on upgrade.
        hasCustomScale =
            try c.decodeIfPresent(Bool.self, forKey: .hasCustomScale)
            ?? true
        storedCenter = try c.decodeIfPresent(MonitorScopeStoredCenter.self, forKey: .storedCenter)
        storedCenterPortrait = try c.decodeIfPresent(
            MonitorScopeStoredCenter.self, forKey: .storedCenterPortrait)
    }

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    public static func clampedBrightness(_ value: Int) -> Int {
        min(max(value, brightnessRange.lowerBound), brightnessRange.upperBound)
    }
}

public struct MonitorVectorscopeOptions: MonitorScopePanelOptions {
    public static let scaleRange: ClosedRange<Double> = 0.6...1.6
    public static let defaultScale = 1.0
    public static let brightnessRange: ClosedRange<Int> = 0...200
    public static let defaultBrightness = 100
    public var zoom: MonitorVectorscopeZoom
    public var brightness: Int
    public var scale: Double
    /// False only for a fresh automatic size; legacy saved scales stay explicit.
    public var hasCustomScale: Bool
    public var storedCenter: MonitorScopeStoredCenter?
    public var storedCenterPortrait: MonitorScopeStoredCenter?

    public static let `default` = Self(
        zoom: .x1,
        brightness: defaultBrightness,
        scale: defaultScale,
        storedCenter: nil,
        storedCenterPortrait: nil)

    public init(
        zoom: MonitorVectorscopeZoom = .x1,
        brightness: Int = defaultBrightness,
        scale: Double = defaultScale,
        hasCustomScale: Bool = false,
        storedCenter: MonitorScopeStoredCenter? = nil,
        storedCenterPortrait: MonitorScopeStoredCenter? = nil
    ) {
        self.zoom = zoom
        self.brightness = Self.clampedBrightness(brightness)
        self.scale = Self.clampedScale(scale)
        self.hasCustomScale = hasCustomScale || scale != Self.defaultScale
        self.storedCenter = storedCenter
        self.storedCenterPortrait = storedCenterPortrait
    }

    enum CodingKeys: String, CodingKey {
        case zoom, brightness, scale, hasCustomScale, storedCenter, storedCenterPortrait
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try c.decodeIfPresent(MonitorVectorscopeZoom.self, forKey: .zoom) ?? .x1
        brightness = Self.clampedBrightness(
            try c.decodeIfPresent(Int.self, forKey: .brightness) ?? Self.defaultBrightness)
        scale = Self.clampedScale(
            try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale)
        // Old JSON cannot distinguish an untouched 1.0 from a manual 1.0.
        // Preserve it rather than rewriting an operator's layout on upgrade.
        hasCustomScale =
            try c.decodeIfPresent(Bool.self, forKey: .hasCustomScale)
            ?? true
        storedCenter = try c.decodeIfPresent(MonitorScopeStoredCenter.self, forKey: .storedCenter)
        storedCenterPortrait = try c.decodeIfPresent(
            MonitorScopeStoredCenter.self, forKey: .storedCenterPortrait)
    }

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    public static func clampedBrightness(_ value: Int) -> Int {
        min(max(value, brightnessRange.lowerBound), brightnessRange.upperBound)
    }
}

public struct MonitorHistogramOptions: MonitorScopePanelOptions {
    public static let scaleRange: ClosedRange<Double> = 0.6...1.6
    public static let defaultScale = 1.0
    public static let brightnessRange: ClosedRange<Int> = 0...200
    public static let defaultBrightness = 100
    public var trafficLights: Bool
    public var crushClipCompensation: MonitorCrushClipCompensation
    public var scale: Double
    /// False only for a fresh automatic size; legacy saved scales stay explicit.
    public var hasCustomScale: Bool
    public var storedCenter: MonitorScopeStoredCenter?
    public var storedCenterPortrait: MonitorScopeStoredCenter?

    public static let `default` = Self(
        trafficLights: true,
        crushClipCompensation: .zero,
        scale: defaultScale,
        storedCenter: nil,
        storedCenterPortrait: nil)

    public init(
        trafficLights: Bool = true,
        crushClipCompensation: MonitorCrushClipCompensation = .zero,
        scale: Double = defaultScale,
        hasCustomScale: Bool = false,
        storedCenter: MonitorScopeStoredCenter? = nil,
        storedCenterPortrait: MonitorScopeStoredCenter? = nil
    ) {
        self.trafficLights = trafficLights
        self.crushClipCompensation = crushClipCompensation
        self.scale = Self.clampedScale(scale)
        self.hasCustomScale = hasCustomScale || scale != Self.defaultScale
        self.storedCenter = storedCenter
        self.storedCenterPortrait = storedCenterPortrait
    }

    enum CodingKeys: String, CodingKey {
        case trafficLights, crushClipCompensation, scale, hasCustomScale, storedCenter,
            storedCenterPortrait
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trafficLights = try c.decodeIfPresent(Bool.self, forKey: .trafficLights) ?? true
        crushClipCompensation =
            try c.decodeIfPresent(MonitorCrushClipCompensation.self, forKey: .crushClipCompensation)
            ?? .zero
        scale = Self.clampedScale(
            try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale)
        // Old JSON cannot distinguish an untouched 1.0 from a manual 1.0.
        // Preserve it rather than rewriting an operator's layout on upgrade.
        hasCustomScale =
            try c.decodeIfPresent(Bool.self, forKey: .hasCustomScale)
            ?? true
        storedCenter = try c.decodeIfPresent(MonitorScopeStoredCenter.self, forKey: .storedCenter)
        storedCenterPortrait = try c.decodeIfPresent(
            MonitorScopeStoredCenter.self, forKey: .storedCenterPortrait)
    }

    public static func clampedScale(_ value: Double) -> Double {
        min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }
}
