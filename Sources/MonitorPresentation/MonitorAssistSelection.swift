import Foundation

/// Current tool identities plus saved legacy choices. The current catalog stays unchanged.
public struct MonitorAssistSelection: RawRepresentable, Hashable, Sendable, Identifiable, CaseIterable {
    public let rawValue: String
    public var id: String { rawValue }
    public var sharedTool: MonitorAssistTool? { MonitorAssistTool(rawValue: rawValue) }
    public init?(rawValue: String) {
        guard MonitorAssistTool(rawValue: rawValue) != nil || rawValue == "PLAY" || rawValue == "MAG" else { return nil }
        self.rawValue = rawValue
    }
    public init(_ tool: MonitorAssistTool) { rawValue = tool.rawValue }
    private init(legacy: String) { rawValue = legacy }
    public static let instantReview = Self(legacy: "PLAY")
    public static let magnification = Self(legacy: "MAG")
    public static var allCases: [Self] {
        MonitorAssistTool.allCases.map(Self.init) + [.instantReview, .magnification]
    }
    public static let lut = Self(.lut)
    public static let peaking = Self(.peaking)
    public static let falseColor = Self(.falseColor)
    public static let zebra = Self(.zebra)
    public static let waveform = Self(.waveform)
    public static let parade = Self(.parade)
    public static let histogram = Self(.histogram)
    public static let vectorscope = Self(.vectorscope)
    public static let trafficLights = Self(.trafficLights)
    public static let ndMeter = Self(.ndMeter)
    public static let evMeter = Self(.evMeter)
    public static let audioMeters = Self(.audioMeters)
    public static let guides = Self(.guides)
    public static let grid = Self(.grid)
    public static let crosshair = Self(.crosshair)
    public static let level = Self(.level)
    public static let desqueeze = Self(.desqueeze)
    public static let mirror = Self(.mirror)
}
