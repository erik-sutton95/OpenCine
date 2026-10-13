import Foundation

/// Source-calibrated ruler values for the same bands the monitor paints.
public struct MonitorFalseColorReferencePlan: Sendable {
    public struct Segment: Sendable {
        public let lowerFraction: Double
        public let upperFraction: Double
        public let band: LiveFalseColorBand
    }
    public struct Marker: Sendable {
        public enum Kind: Equatable, Sendable { case stop, clip }
        public let kind: Kind
        public let sceneStop: Double
        public let fraction: Double
        public var label: String {
            if kind == .clip { return "clip" }
            return sceneStop == 0 ? "18%" : sceneStop < 0 ? "−\(Int(-sceneStop))" : "+\(Int(sceneStop))"
        }
    }
    public let segments: [Segment]
    public let markers: [Marker]
    public let clipStops: Double

    public init(scale: LiveFalseColorScale, transfer: MonitorTransfer, clipByte: Int,
        lookCurve: [Double]? = nil, readThroughLook: Bool = false) {
        precondition((1...255).contains(clipByte))
        let clip = LiveColorScience.falseColorClip(scale: scale, transfer: transfer,
            rec709: readThroughLook, lookCurve: lookCurve, clipEncoded: Double(clipByte) / 255)
        let measured = LiveColorScience.stops(
            encoded: LiveColorScience.clipShelf(ceiling: clip.ceiling), transfer: clip.transfer)
        let stops = measured.isFinite ? measured : LiveColorScience.sceneStopDefaultClip
        clipStops = stops
        let lower = -8.5
        let upper = max(2.5, stops) + 1
        func fraction(_ value: Double, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            let coordinate = scale.usesSceneStops ? (value - lower) / (upper - lower) : value / 100
            return min(1, max(0, coordinate))
        }
        segments = LiveColorScience.falseColorBands(scale, transfer: clip.transfer,
            clipEncoded: clip.ceiling).map {
            Segment(lowerFraction: fraction($0.lowerBound, fallback: 0),
                upperFraction: fraction($0.upperBound, fallback: 1), band: $0)
        }
        if scale.usesSceneStops {
            markers = stride(from: -6.0, to: stops - 1.5, by: 2).map { stop in
                Marker(kind: .stop, sceneStop: stop, fraction: fraction(stop, fallback: 0))
            } + [Marker(kind: .clip, sceneStop: stops, fraction: fraction(stops, fallback: 1))]
        } else {
            markers = []
        }
    }
}
