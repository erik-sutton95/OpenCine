#if os(iOS)
import MonitorPresentation
import SwiftUI

public typealias MonitorAssistTool = MonitorPresentation.MonitorAssistTool

extension MonitorAssistTool {
    public var monitorIcon: MonitorAssistIcon? {
        switch self {
        case .lut: .lut
        case .peaking: .peaking
        case .falseColor: .falseColor
        case .zebra: .zebra
        case .waveform: .waveform
        case .parade: .rgbParade
        case .histogram: .histogram
        case .vectorscope: .vectorscope
        case .trafficLights: .trafficLights
        case .guides: .frameGuide
        case .grid: .grid
        case .crosshair: .crosshair
        case .mirror: .mirror
        case .audioMeters: .audioMeters
        case .level: .level
        default: nil
        }
    }

    public var fallbackIcon: MonitorIcon? {
        switch self {
        case .lut: .blend
        case .peaking: .mountain
        case .falseColor: .contrast
        case .zebra: nil
        case .waveform: .audioWaveform
        case .parade: .chartColumn
        case .histogram: .audioLines
        case .vectorscope: .crosshair
        case .trafficLights: .sun
        case .ndMeter: .aperture
        case .evMeter: nil
        case .audioMeters: .slidersVertical
        case .guides: .squareDashed
        case .grid: .grid3x3
        case .crosshair: .plus
        case .level: .circle
        case .desqueeze: .chevronsUpDown
        case .mirror: .flipHorizontal2
        }
    }
}

/// Exact shared artwork; exposure uses its readable abbreviation and optics its rotated glyph.
public struct MonitorAssistToolGlyph: View {
    public let tool: MonitorAssistTool
    public let size: CGFloat?
    public init(tool: MonitorAssistTool, size: CGFloat? = 19) { self.tool = tool; self.size = size }
    public var body: some View {
        if tool == .evMeter {
            Text("EV")
                .font(MonitorTheme.font(size.map { $0 * 0.7 } ?? 17, weight: .semibold))
                .frame(width: size, height: size)
        } else if let icon = tool.monitorIcon {
            icon.frame(width: size, height: size)
        } else if let icon = tool.fallbackIcon {
            icon.frame(width: size, height: size)
                .rotationEffect(.degrees(tool == .desqueeze ? 90 : 0))
        }
    }
}
#endif
