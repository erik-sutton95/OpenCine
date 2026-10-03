#if canImport(CoreImage)
import Foundation
import OpenCineMedia

/// Native paint values. Operator palette names and persisted keys stay above this layer.
public struct MonitorRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(_ rgb: (Double, Double, Double)) {
        red = rgb.0; green = rgb.1; blue = rgb.2
    }
    public var rgb: (Double, Double, Double) { (red, green, blue) }
    public static let red = MonitorRGB((1, 72.0 / 255, 64.0 / 255))
}

public struct MonitorPeakingSensitivity: Equatable, Sendable {
    public var ratioThreshold: Double
    public var noiseGate: Double
    public init(ratioThreshold: Double, noiseGate: Double) {
        self.ratioThreshold = ratioThreshold; self.noiseGate = noiseGate
    }
    public static let medium = MonitorPeakingSensitivity(ratioThreshold: 2.10, noiseGate: 0.00174)
}

public struct MonitorZebraSpec: Equatable, Sendable {
    public var highlightEnabled: Bool
    public var highlightIRE: Double
    public var highlightColor: MonitorRGB
    public var midtoneEnabled: Bool
    public var midtoneIRE: Double
    public var midtoneColor: MonitorRGB
    public init(highlightEnabled: Bool = true, highlightIRE: Double = LiveZebra.highlightIRE,
        highlightColor: MonitorRGB = .init((1, 1, 1)), midtoneEnabled: Bool = true,
        midtoneIRE: Double = LiveZebra.midtoneIRE, midtoneColor: MonitorRGB = .init((1, 0.72, 0.2))) {
        self.highlightEnabled = highlightEnabled; self.highlightIRE = highlightIRE
        self.highlightColor = highlightColor; self.midtoneEnabled = midtoneEnabled
        self.midtoneIRE = midtoneIRE; self.midtoneColor = midtoneColor
    }
}

/// One complete false-color paint and weight snapshot, already qualified by its source owner.
public struct MonitorOverlayMaps: Equatable, Sendable {
    public var dimension: Int
    public var paint: Data
    public var weight: Data
    public init(dimension: Int, paint: Data, weight: Data) {
        self.dimension = dimension; self.paint = paint; self.weight = weight
    }
}

/// Core Image's immutable per-render input. It carries source facts, never raw camera settings.
public struct MonitorImageEffects: Equatable, Sendable {
    public var peaking = false
    public var zebra = false
    public var falseColor = false
    public var lutDimension = 0
    public var lutRGBA = Data()
    public var peakingColor = MonitorRGB.red
    public var peakingSensitivity = MonitorPeakingSensitivity.medium
    public var peakingGateScale: Double = 1
    public var zebraSpec = MonitorZebraSpec()
    public var transfer = MonitorTransfer.rec709
    public var clipByte = 255
    public var falseColorMaps: MonitorOverlayMaps?
    public var falseColorPaintsFullFrame = false
    public var splitComparison = false
    public var splitVertical = true
    public var desqueezeFactor: Double = 1
    public var desqueezeHorizontal = true
    public init() {}
    public var appliesSplitComparison: Bool {
        FeedPresentPolicy.appliesSplitComparison(enabled: splitComparison,
            hasLUTCube: lutDimension >= 2 && !lutRGBA.isEmpty,
            falseColorPaintsFullFrame: falseColorPaintsFullFrame)
    }
}
#endif
