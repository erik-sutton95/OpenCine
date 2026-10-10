import Foundation

/// Preparation, timed lens targets and immediate cancellation share one transport owner.
/// The integration encodes each command for its camera.
public enum NativeProgramZoomCommand: Equatable, Sendable {
    case position(Double)
    case track(Double)
    case stop
}

public struct NativeProgramZoomDemand: Equatable, Sendable {
    public var command: NativeProgramZoomCommand
    public var destination: Double
    public var failureReason: String?
    public var nextChange: TimeInterval

    public init(command: NativeProgramZoomCommand, destination: Double, failureReason: String? = nil,
        nextChange: TimeInterval = .infinity) {
        self.command = command
        self.destination = destination
        self.failureReason = failureReason
        self.nextChange = nextChange
    }
}

/// Linear zoom-factor targets, sampled above the measured 25 fps picture cadence.
/// A rocker with a few fixed gears cannot represent arbitrary timed linear moves.
public enum NativeProgramZoom {
    public static let interval: TimeInterval = 0.02

    public static func demand(from: Double, to: Double, duration: TimeInterval, elapsed: TimeInterval)
        -> NativeProgramZoomDemand
    {
        guard from.isFinite, to.isFinite, duration.isFinite, elapsed.isFinite,
            from >= 1, to >= 1, duration > 0, elapsed >= 0 else {
            return .init(command: .stop, destination: to, failureReason: "Invalid zoom movement")
        }
        guard abs(from - to) > 1e-6 else { return .init(command: .stop, destination: to) }
        let fraction = min(1, elapsed / duration)
        return .init(command: .track(from + (to - from) * fraction), destination: to,
            nextChange: elapsed < duration ? duration - elapsed : .infinity)
    }
}
