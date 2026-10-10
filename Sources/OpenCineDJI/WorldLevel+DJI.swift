import Foundation
import OpenCineMotion

// The `0x04/0x05` attitude and the `0x04/0x14` snap frame; the level math is OpenCineMotion's.
extension WorldLevel {
    /// Camera attitude against gravity from the `0x04/0x05` push.
    ///
    /// `@24…@39` are float32 LE `x, w, y, z` of a unit quaternion that maps world
    /// to camera (camera x forward, y up; world gravity −y). Fit on 1,014 captured
    /// front/selfie frames: tilt matches display pitch `−@20` (p50 0.02°, p95 0.46°)
    /// and roll stays within 1.1° while the gimbal holds the horizon. Heading is
    /// free (IMU) and unused. Roll sign is not yet confirmed on a rolled handle.
    public static func attitude(_ payload: [UInt8]) -> HeadTrack.Quat? {
        guard payload.count >= 40 else { return nil }
        func f32(_ o: Int) -> Double {
            let bits =
                UInt32(payload[o]) | UInt32(payload[o + 1]) << 8
                | UInt32(payload[o + 2]) << 16 | UInt32(payload[o + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
        let q = HeadTrack.Quat(w: f32(28), x: f32(24), y: f32(32), z: f32(36))
        let norm = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
        guard norm.isFinite, abs(norm - 1) <= 1e-3 else { return nil }
        return q
    }
}

extension LevelReading {
    /// One `0x04/0x05` push; a payload without a valid attitude is ignored.
    public mutating func ingest(_ payload: [UInt8], now: TimeInterval) {
        guard let q = WorldLevel.attitude(payload) else { return }
        ingest(attitude: q, now: now)
    }
}

extension WorldLevelSnap {
    /// One `0x04/0x14` timed target to the nearest world target (mode `05` ignores roll).
    public static func plan(tiltDeg: Double, pose: GimbalWaypoint, now: TimeInterval)
        -> (snap: WorldLevelSnap, frame: Duml.Frame)?
    {
        guard let move = move(tiltDeg: tiltDeg, pose: pose),
            let frame = Commands.gimbalTimedTarget(
                yawDeg: pose.yawDeg, nativePitchDeg: (move.nativePitchDeg * 10).rounded() / 10,
                duration: move.duration)
        else { return nil }
        return (WorldLevelSnap(target: move.target, deadline: now + move.duration + settleGrace), frame)
    }
}
