import Foundation
import OpenCineMotion

extension HeadTrack {
    /// DJI gimbal reach (see `GimbalReach`). Kept as `HeadTrack.Reach` for call sites.
    public typealias Reach = GimbalReach
}

// Call sites from before the move, bound to the Pocket reach.
extension GimbalWaypoint {
    public static func unwrapYaw(_ rawDeg: Double) -> Double {
        unwrapYaw(rawDeg, in: HeadTrack.Reach.bounds)
    }

    public func clamped() -> GimbalWaypoint { clamped(to: HeadTrack.Reach.bounds) }

    /// Live `0x04/0x05` yaw/pitch in tenths of a degree; native pitch from attitude i16 @0.
    public static func from(yawTenth: Int16?, pitchTenth: Int16?, zoom: Double,
        nativePitchTenth: Int16? = nil) -> GimbalWaypoint? {
        guard let yawTenth, let pitchTenth else { return nil }
        return GimbalWaypoint(
            yawDeg: unwrapYaw(Double(yawTenth) / 10),
            pitchDeg: Double(pitchTenth) / 10,
            zoom: zoom, nativePitchDeg: nativePitchTenth.map { Double($0) / 10 })
    }
}

extension HeadTrackNative {
    public init() { self.init(bounds: HeadTrack.Reach.bounds) }
}

// The waypoint overload needs GimbalWaypoint (motion math), so it lives with it and not
// in the DJI command builders.
extension Commands {
    /// Validate physical display tilt before encoding the distinct native pitch.
    public static func gimbalTimedTarget(
        waypoint: GimbalWaypoint, duration: TimeInterval, seq: UInt16 = 0
    ) -> Duml.Frame? {
        guard waypoint.pitchDeg.isFinite,
            (HeadTrack.Reach.tiltMinDeg...HeadTrack.Reach.tiltMaxDeg).contains(waypoint.pitchDeg),
            let nativePitch = waypoint.nativePitchDeg else { return nil }
        return gimbalTimedTarget(yawDeg: waypoint.yawDeg, nativePitchDeg: nativePitch,
            duration: duration, seq: seq)
    }
}
