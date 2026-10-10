import Foundation

/// Source-independent encoded-image mask policy. No camera or UI types.
public struct MonitorZebraMaskPolicy: Equatable, Sendable {
    public enum HighlightMeasure: Equatable, Sendable {
        case maximumComponent
        case rec709Luma
    }
    public var highlightMeasure: HighlightMeasure
    public var rampBias: Double
    public init(highlightMeasure: HighlightMeasure = .maximumComponent, rampBias: Double = 1) {
        self.highlightMeasure = highlightMeasure
        self.rampBias = rampBias
    }
}

/// Already resolved code thresholds. Nil means that zone is absent.
/// The source adapter resolves its existing curve/calibration/editor policy before capture.
public struct MonitorZebraCodeThresholds: Equatable, Sendable {
    public var highlight: Double?
    public var midtoneLower: Double?
    public var midtoneUpper: Double?
    public init(highlight: Double?, midtoneLower: Double?, midtoneUpper: Double?) {
        self.highlight = highlight
        self.midtoneLower = midtoneLower
        self.midtoneUpper = midtoneUpper
    }
}
