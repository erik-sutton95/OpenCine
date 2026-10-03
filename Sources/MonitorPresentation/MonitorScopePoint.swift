import Foundation

/// A session position in canvas coordinates, independent of native geometry overlays.
public struct MonitorScopePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
