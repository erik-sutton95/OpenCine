import Foundation

/// Explicit display-only encoded-pixel suppression. Measurement pixels remain pristine.
public struct MonitorBlockSmoothing: Equatable, Sendable {
    public var radius: Double
    public var gateLevels: Double
    public var strength: Double
    public init(radius: Double = 2, gateLevels: Double = 5, strength: Double = 0.8) {
        self.radius = radius; self.gateLevels = gateLevels; self.strength = strength
    }
}

public struct MonitorBlockDither: Equatable, Sendable {
    public var levels: Double
    public init(levels: Double = 3) { self.levels = levels }
}
