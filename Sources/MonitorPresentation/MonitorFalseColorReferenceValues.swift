import Foundation

public struct MonitorFalseColorReferenceSegment: Equatable, Sendable, Identifiable {
    public let id: Int
    public let lowerFraction: Double
    public let upperFraction: Double
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(id: Int, lowerFraction: Double, upperFraction: Double,
        red: Double, green: Double, blue: Double) {
        self.id = id; self.lowerFraction = lowerFraction; self.upperFraction = upperFraction
        self.red = red; self.green = green; self.blue = blue
    }
}

public struct MonitorFalseColorReferenceMarker: Equatable, Sendable, Identifiable {
    public let id: Int
    public let label: String
    public let fraction: Double
    public init(id: Int, label: String, fraction: Double) {
        self.id = id; self.label = label; self.fraction = fraction
    }
}

/// A resolved key for one sampled source/profile. UI never selects a camera curve.
public struct MonitorFalseColorReferenceValues: Equatable, Sendable {
    public let subtitle: String
    public let segments: [MonitorFalseColorReferenceSegment]
    public let markers: [MonitorFalseColorReferenceMarker]
    public let axisLabels: [String]
    public init(subtitle: String, segments: [MonitorFalseColorReferenceSegment],
        markers: [MonitorFalseColorReferenceMarker] = [], axisLabels: [String] = []) {
        self.subtitle = subtitle; self.segments = segments
        self.markers = markers; self.axisLabels = axisLabels
    }
}
