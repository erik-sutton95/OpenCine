import Foundation
import OpenCineMedia

public struct MonitorNDOptions: Codable, Equatable, Sendable {
    public var scale: Double
    public var position: MonitorScopeStoredCenter?
    public var positionPortrait: MonitorScopeStoredCenter?
    public var notation: MonitorNDFilterNotation?
    public init(scale: Double, position: MonitorScopeStoredCenter?, positionPortrait: MonitorScopeStoredCenter?,
        notation: MonitorNDFilterNotation?) {
        self.scale = scale; self.position = position; self.positionPortrait = positionPortrait
        self.notation = notation
    }
}
public struct MonitorTrafficLightsOptions: Codable, Equatable, Sendable {
    public var compensation: MonitorCrushClipCompensation
    public var scale: Double
    public var position: MonitorScopeStoredCenter?
    public var positionPortrait: MonitorScopeStoredCenter?
    public init(compensation: MonitorCrushClipCompensation, scale: Double,
        position: MonitorScopeStoredCenter?, positionPortrait: MonitorScopeStoredCenter?) {
        self.compensation = compensation; self.scale = scale
        self.position = position; self.positionPortrait = positionPortrait
    }
}
