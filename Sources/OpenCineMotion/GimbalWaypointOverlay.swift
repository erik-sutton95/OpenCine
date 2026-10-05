import Foundation

/// Project a stored yaw/pitch onto the live picture. Each waypoint is a
/// direction on the unit sphere in gimbal space; as the live yaw/pitch
/// change, that sphere rotates with the camera. `wideHFovDeg` is the
/// camera's horizontal field of view at 1x, which the integration knows.
public enum GimbalWaypointOverlay {
    /// Waypoint pitch is look-up positive. +1 draws look-up above center.
    /// Flip if a device disagrees.
    public static let pitchUpSign = 1.0

    public struct Mark: Equatable, Sendable {
        public var slot: GimbalWaypointSlot
        public var nx: Double
        public var ny: Double
        public var onScreen: Bool

        public init(slot: GimbalWaypointSlot, nx: Double, ny: Double, onScreen: Bool) {
            self.slot = slot
            self.nx = nx
            self.ny = ny
            self.onScreen = onScreen
        }
    }

    /// Digital zoom scales the image, i.e. the tangent, not the angle.
    public static func tanHalfHFov(zoom: Double, wideHFovDeg: Double) -> Double {
        tan(wideHFovDeg / 2 * .pi / 180) / max(zoom, 1)
    }

    public static func project(
        waypoint: GimbalWaypoint,
        slot: GimbalWaypointSlot,
        live: GimbalWaypoint,
        aspect: Double,
        wideHFovDeg: Double
    ) -> Mark {
        let tanH = tanHalfHFov(zoom: live.zoom, wideHFovDeg: wideHFovDeg)
        let tanV = tanH / max(aspect, 0.1)
        let dYaw = (waypoint.yawDeg - live.yawDeg) * .pi / 180
        let tp = pitchUpSign * waypoint.pitchDeg * .pi / 180
        let cp = pitchUpSign * live.pitchDeg * .pi / 180
        // Target direction with the camera yaw removed: (right, up, forward).
        let x = sin(dYaw) * cos(tp)
        let y = sin(tp)
        let z = cos(dYaw) * cos(tp)
        // Remove the camera pitch (rotation about the right axis).
        let yc = y * cos(cp) - z * sin(cp)
        let zc = y * sin(cp) + z * cos(cp)
        guard zc > 1e-6 else {
            return Mark(slot: slot, nx: x >= 0 ? 1 : 0, ny: 0.5, onScreen: false)
        }
        let nx = 0.5 + (x / zc) / (2 * tanH)
        let ny = 0.5 - (yc / zc) / (2 * tanV)
        let onScreen = nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1
        return Mark(
            slot: slot,
            nx: min(max(nx, 0), 1),
            ny: min(max(ny, 0), 1),
            onScreen: onScreen)
    }

    public static func marks(
        program: GimbalProgram, live: GimbalWaypoint, aspect: Double, wideHFovDeg: Double
    ) -> [Mark] {
        GimbalWaypointSlot.allCases.compactMap { slot in
            guard let point = program[slot] else { return nil }
            return project(
                waypoint: point, slot: slot, live: live, aspect: aspect, wideHFovDeg: wideHFovDeg)
        }
    }
}

/// Converts native waypoint projection into the live picture's horizontal space.
/// Used by both waypoint letters and the Motion Control curve in the shell.
public enum GimbalWaypointPresentation {
    /// The camera's settled pan inversion (a head turned to face the other way)
    /// composes with the MIRROR assist. A camera-side picture flip changes the
    /// encoding and its decoder compensation together, so the decoder's
    /// extra-mirror flag is not the native-to-picture pan direction.
    public static func normalizedX(
        _ normalizedX: Double, poseInvertPan: Bool, assistMirror: Bool
    ) -> Double {
        (poseInvertPan != assistMirror) ? 1 - normalizedX : normalizedX
    }
}
