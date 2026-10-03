import Foundation
import OpenCineMedia

extension MonitorFrameEffects {
    public func withInspectorDemand(_ tool: MonitorAssistSelection?) -> MonitorFrameEffects {
        guard let tool else { return self }
        var next = self
        switch tool {
        case .waveform: next.waveform = true
        case .parade: next.parade = true
        case .histogram: next.histogram = true
        case .vectorscope: next.vectorscope = true
        case .trafficLights: next.trafficLights = true
        case .ndMeter: next.ndMeter = true
        case .evMeter: break
        default: next.inspectorSample = MonitorInspectorPreviewPolicy.isImage(tool)
        }
        return next
    }
}

public enum MonitorInspectorPreviewPolicy {
    public static let maximumImageDimension: Double = MonitorInspectorImageSizing.maximumDimension
    public static func height(width: Double, tool: MonitorAssistSelection) -> Double {
        let ratio: Double
        switch tool {
        case .waveform, .parade: ratio = 0.612
        case .histogram: ratio = 0.42
        case .vectorscope: ratio = 0.9
        case .trafficLights: ratio = 0.62
        default: ratio = 0.5625
        }
        return min(196, max(56, width * ratio))
    }

    public static func isImage(_ tool: MonitorAssistSelection) -> Bool {
        switch tool {
        case .lut, .peaking, .falseColor, .zebra, .guides, .grid, .crosshair, .mirror, .desqueeze:
            true
        default: false
        }
    }

}
