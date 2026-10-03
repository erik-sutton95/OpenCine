import Foundation

/// Persisted centers stay normalized against the full canvas. Native layout never rewrites storage.
public struct MonitorScopeStoredCenter: Codable, Equatable, Sendable {
    public var xFraction: Double
    public var yFraction: Double
    public init(xFraction: Double, yFraction: Double) {
        self.xFraction = xFraction; self.yFraction = yFraction
    }
}

public enum MonitorScopeCanvasSlot: String, Sendable {
    case landscape, portrait
    public static func forSize(width: Double, height: Double) -> Self {
        height > width ? .portrait : .landscape
    }
}
