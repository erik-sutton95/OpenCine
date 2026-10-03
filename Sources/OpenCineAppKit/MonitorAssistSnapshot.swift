import Foundation
import MonitorPresentation
import OpenCineMedia

public struct MonitorAssistSnapshot: Codable {
    public var tools: [String]
    public var guideAspect: String
    public var guideFamily: String
    public var selectedGuides: [String]
    public var guideMask: Bool
    public var gridThirds: Bool
    public var gridPhi: Bool
    public var gridDiagonal: Bool
    public var peakingColor: String
    public var peakingSensitivity: String
    public var falseColorScale: String
    public var falseColorReference: Bool
    /// Optional so settings saved before the LOG / 709 choice still decode.
    public var falseColorRec709: Bool?
    public var zebraHighlight: Bool
    public var zebraMidtone: Bool
    public var zebraHighlightIRE: Double
    public var zebraMidtoneIRE: Double
    public var zebraHighlightColor: String
    public var zebraMidtoneColor: String
    public var desqueezeFactor: Double
    public var desqueezeCustom: Bool?
    public var desqueezeCustomFactor: Double?
    public var desqueezeHorizontal: Bool
    public var splitComparison: Bool
    public var splitVertical: Bool
    public var lutArmed: Bool
    public var lutExposureStops: Double?
    public var crushClipCompensation: Int?
    public var mirrorHorizontal: Bool?
    public var mirrorVertical: Bool?

    @available(macOS 14, *) @MainActor
    public init<Looks>(_ s: MonitorAssistState<Looks>) {
        tools = MonitorAssistSelection.allCases.filter { s.isOn($0) }.map(\.rawValue)
        guideAspect = s.guideAspect.rawValue
        guideFamily = s.guideFamily.rawValue
        selectedGuides = s.selectedGuides.map(\.rawValue)
        guideMask = s.guideMask
        gridThirds = s.gridThirds
        gridPhi = s.gridPhi
        gridDiagonal = s.gridDiagonal
        peakingColor = s.peakingColor.rawValue
        peakingSensitivity = s.peakingSensitivity.rawValue
        falseColorScale = s.falseColorScale.rawValue
        falseColorReference = s.falseColorReference
        falseColorRec709 = s.falseColorRec709
        zebraHighlight = s.zebraHighlight
        zebraMidtone = s.zebraMidtone
        zebraHighlightIRE = s.zebraHighlightIRE
        zebraMidtoneIRE = s.zebraMidtoneIRE
        zebraHighlightColor = s.zebraHighlightColor.rawValue
        zebraMidtoneColor = s.zebraMidtoneColor.rawValue
        desqueezeCustom = s.desqueezeCustom
        desqueezeCustomFactor = s.desqueezeCustomFactor
        desqueezeFactor = s.desqueezeFactor
        desqueezeHorizontal = s.desqueezeHorizontal
        splitComparison = s.splitComparison
        splitVertical = s.splitVertical
        lutArmed = s.lutEnabled
        lutExposureStops = s.lutExposureStops
        crushClipCompensation = s.crushClipCompensation.rawValue
        mirrorHorizontal = s.mirrorHorizontal
        mirrorVertical = s.mirrorVertical
    }

    @available(macOS 14, *) @MainActor
    public func apply<Looks>(to s: MonitorAssistState<Looks>) {
        let on = Set(tools)
        s.peaking = on.contains(MonitorAssistSelection.peaking.rawValue)
        s.zebra = on.contains(MonitorAssistSelection.zebra.rawValue)
        s.falseColor = on.contains(MonitorAssistSelection.falseColor.rawValue)
        s.histogram = on.contains(MonitorAssistSelection.histogram.rawValue)
        s.waveform = on.contains(MonitorAssistSelection.waveform.rawValue)
        s.parade = on.contains(MonitorAssistSelection.parade.rawValue)
        s.vectorscope = on.contains(MonitorAssistSelection.vectorscope.rawValue)
        s.trafficLights = on.contains(MonitorAssistSelection.trafficLights.rawValue)
        s.ndMeter = on.contains(MonitorAssistSelection.ndMeter.rawValue)
        s.evMeter = on.contains(MonitorAssistSelection.evMeter.rawValue)
        s.audioMeters = on.contains(MonitorAssistSelection.audioMeters.rawValue)
        s.guides = on.contains(MonitorAssistSelection.guides.rawValue)
        s.grid = on.contains(MonitorAssistSelection.grid.rawValue)
        s.crosshair = on.contains(MonitorAssistSelection.crosshair.rawValue)
        s.level = on.contains(MonitorAssistSelection.level.rawValue)
        s.desqueeze = on.contains(MonitorAssistSelection.desqueeze.rawValue)
        s.mirror = on.contains(MonitorAssistSelection.mirror.rawValue)
        s.instantReview = on.contains(MonitorAssistSelection.instantReview.rawValue)
        s.guideAspect = MonitorGuideAspect(rawValue: guideAspect) ?? .cinema
        s.guideFamily = MonitorGuideFamily(rawValue: guideFamily) ?? .film
        let restored = Set(selectedGuides.compactMap(MonitorGuideAspect.init(rawValue:)))
        s.selectedGuides = restored.isEmpty ? [s.guideAspect] : restored
        s.guideMask = guideMask
        s.gridThirds = gridThirds
        s.gridPhi = gridPhi
        s.gridDiagonal = gridDiagonal
        s.peakingColor = MonitorPeakingColor(rawValue: peakingColor) ?? .red
        s.peakingSensitivity = MonitorPeakingSense(rawValue: peakingSensitivity) ?? .medium
        s.falseColorScale = MonitorFalseColorSelection(rawValue: falseColorScale) ?? .sceneStops
        s.falseColorReference = falseColorReference
        s.falseColorRec709 = falseColorRec709 ?? false
        s.zebraHighlight = zebraHighlight
        s.zebraMidtone = zebraMidtone
        s.zebraHighlightIRE = zebraHighlightIRE
        s.zebraMidtoneIRE = zebraMidtoneIRE
        s.zebraHighlightColor = MonitorZebraPaint(rawValue: zebraHighlightColor) ?? .white
        s.zebraMidtoneColor = MonitorZebraPaint(rawValue: zebraMidtoneColor) ?? .amber
        s.desqueezeFactor = MonitorAnamorphicDesqueeze.snap(desqueezeFactor)
        s.desqueezeCustom =
            desqueezeCustom ?? (MonitorDesqueezePreset.matching(s.desqueezeFactor) == nil)
        s.desqueezeCustomFactor = MonitorAnamorphicDesqueeze.snap(desqueezeCustomFactor ?? desqueezeFactor)
        s.desqueezeHorizontal = desqueezeHorizontal
        s.splitComparison = splitComparison
        s.splitVertical = splitVertical
        if let stops = lutExposureStops {
            s.lutExposureStops = LUTExposureCompensation.snap(stops)
        }
        if let raw = crushClipCompensation,
            let value = MonitorCrushClipCompensation(rawValue: raw)
        {
            s.crushClipCompensation = value
        }
        s.lutEnabled = lutArmed
        s.mirrorHorizontal = mirrorHorizontal ?? true
        s.mirrorVertical = mirrorVertical ?? false
    }
}
