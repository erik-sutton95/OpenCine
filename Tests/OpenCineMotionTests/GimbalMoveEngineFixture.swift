import OpenCineMotion

// The engine tests were written against a gimbal with `reach` (pan -48...225, tilt -44...70)
// that arrives within 0.15 degrees. These bind the shared engine to it.
extension MotionCapabilities {
    static let testGimbal = MotionCapabilities(
        axes: [.pan, .tilt, .zoom], frame: .handle, bounds: reach, maxRateDegPerSec: nil,
        feedbackMaxAge: .milliseconds(300), arrivalToleranceDeg: 0.15, pose: .supported)
}

extension GimbalMoveEngine {
    init() { self.init(capabilities: .testGimbal) }

    static func canSendNativeTarget(from live: GimbalWaypoint, to target: GimbalWaypoint) -> Bool {
        canSendNativeTarget(from: live, to: target, in: reach)
    }
}

extension GimbalWaypoint {
    func clamped() -> GimbalWaypoint { clamped(to: reach) }
}

extension GimbalWaypointOverlay {
    static func project(
        waypoint: GimbalWaypoint, slot: GimbalWaypointSlot, live: GimbalWaypoint, aspect: Double
    ) -> Mark {
        project(waypoint: waypoint, slot: slot, live: live, aspect: aspect, wideHFovDeg: 84)
    }
}
