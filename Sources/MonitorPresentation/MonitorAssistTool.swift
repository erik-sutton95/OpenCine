import Foundation

/// Current monitor-assist identities. Sources provide availability and choose their tool ordering.
public enum MonitorAssistTool: String, CaseIterable, Sendable, Identifiable {
    case lut = "LUT"
    case peaking = "PEAK"
    case falseColor = "FALSE"
    case zebra = "ZEBRA"
    case waveform = "WAVE"
    case parade = "PARADE"
    case histogram = "HISTO"
    case vectorscope = "VECTOR"
    case trafficLights = "LIGHTS"
    case ndMeter = "ND"
    case evMeter = "EV"
    case audioMeters = "AUDIO"
    case guides = "GUIDES"
    case grid = "GRID"
    case crosshair = "CROSS"
    case level = "LEVEL"
    case desqueeze = "DE-SQ"
    case mirror = "MIRROR"

    public var id: String { rawValue }
    public var chipLabel: String { rawValue }
    public var hasConfiguration: Bool { self != .level && self != .evMeter }
    public var displaySettingsTitle: String {
        switch self {
        case .parade: "Parade"
        case .ndMeter: "ND"
        case .audioMeters: "Audio Levels"
        default: title
        }
    }

    public var title: String {
        switch self {
        case .lut: "LUT"
        case .peaking: "Peaking"
        case .falseColor: "False Color"
        case .zebra: "Zebra"
        case .waveform: "Waveform"
        case .parade: "RGB Parade"
        case .histogram: "Histogram"
        case .vectorscope: "Vectorscope"
        case .trafficLights: "Traffic Lights"
        case .ndMeter: "ND Suggestion"
        case .evMeter: "EV Meter"
        case .audioMeters: "Audio Levels"
        case .guides: "Guides"
        case .grid: "Grid"
        case .crosshair: "Crosshair"
        case .level: "Level"
        case .desqueeze: "Anamorphic Desqueeze"
        case .mirror: "Mirror"
        }
    }
}
