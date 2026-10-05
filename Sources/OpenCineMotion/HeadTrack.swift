import Foundation

/// Head-look math shared by the native head-track path (`HeadTrackNative`)
/// and the iOS dials. Look is the SET-relative nose azimuth/elevation
/// (`Quat.look`, +Y forward): Euler Δatt yaw wobbles during a nod at a
/// yawed heading (18:29 take: diagonal drift).
public enum HeadTrack {
    public static let calibrateStillRadPerSec = 0.08

    public static func gyroMagnitude(lookRight: Double, lookUp: Double, yaw: Double = 0)
        -> Double
    {
        (lookRight * lookRight + lookUp * lookUp + yaw * yaw).squareRoot()
    }

    /// SET-relative gimbal pan. Live yaw minus Calibrate Head Lock.
    public static func bodyLookRightDeg(liveYawDeg: Double, originYawDeg: Double) -> Double {
        wrapDeg(liveYawDeg - originYawDeg)
    }

    /// SET-relative gimbal tilt. Live pitch minus Calibrate Head Lock.
    public static func bodyLookUpDeg(livePitchDeg: Double, originPitchDeg: Double) -> Double {
        livePitchDeg - originPitchDeg
    }

    /// Clockwise degrees from 12 o'clock on the yaw ring. Matches `lookRightDeg`.
    public static func yawDialDeg(lookRightDeg: Double) -> Double {
        wrapDeg(lookRightDeg)
    }

    /// Clockwise degrees for an up-drawn arrow on the pitch ring. 0 look
    /// points right (3 o'clock). Nod up is counter-clockwise; nod down clockwise.
    public static func pitchDialDeg(lookUpDeg: Double) -> Double {
        wrapDeg(90 - lookUpDeg)
    }

    /// AirPods CMAttitude: +X right, +Y forward (nose), +Z up.
    /// Tracking +Z as the nose made look-right follow roll and inverted pitch.
    public struct Quat: Equatable, Sendable {
        public var w: Double
        public var x: Double
        public var y: Double
        public var z: Double

        public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

        public init(w: Double, x: Double, y: Double, z: Double) {
            self.w = w
            self.x = x
            self.y = y
            self.z = z
        }

        public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

        public func multiply(_ r: Quat) -> Quat {
            Quat(
                w: w * r.w - x * r.x - y * r.y - z * r.z,
                x: w * r.x + x * r.w + y * r.z - z * r.y,
                y: w * r.y - x * r.z + y * r.w + z * r.x,
                z: w * r.z + x * r.y - y * r.x + z * r.w)
        }

        public func rotate(_ v: (x: Double, y: Double, z: Double)) -> (
            x: Double, y: Double, z: Double
        ) {
            let p = Quat(w: 0, x: v.x, y: v.y, z: v.z)
            let r = multiply(p).multiply(conjugate)
            return (r.x, r.y, r.z)
        }

        public static func axisAngle(x: Double, y: Double, z: Double, deg: Double) -> Quat {
            let half = deg * .pi / 360
            let s = sin(half)
            let n = (x * x + y * y + z * z).squareRoot()
            let inv = n > 0 ? s / n : 0
            return Quat(w: cos(half), x: x * inv, y: y * inv, z: z * inv)
        }

        /// SET-relative look in degrees. +right / +up from the nose (+Y).
        public static func look(from q: Quat, origin q0: Quat) -> (right: Double, up: Double) {
            let v = q0.conjugate.multiply(q).rotate((0, 1, 0))
            let right = atan2(v.x, v.y) * 180 / .pi
            let up = atan2(v.z, hypot(v.x, v.y)) * 180 / .pi
            return (right, up)
        }
    }

    /// Nose on the SET sphere. Euler Δatt yaw jumps when you nod; this does not.
    public static func look(current: Quat, origin: Quat) -> (right: Double, up: Double) {
        Quat.look(from: current, origin: origin)
    }

    public enum CenterResult: Equatable, Sendable {
        case centered
        case waitingForGimbal
        case waitingForStill
        public var ok: Bool { self == .centered }
    }

    public static func wrapDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Keep spinning past ±180 as a continuous look, not a wrap to the other stop.
    public static func unwrap(_ wrapped: Double, previous: Double) -> Double {
        previous + wrapDeg(wrapped - previous)
    }

    public static func radToDeg(_ rad: Double) -> Double { rad * 180 / .pi }
}

extension HeadTrack {
    /// One head-tracking target at its measurement time (uptime seconds).
    public struct Sample: Equatable, Sendable {
        public var t: Double
        public var yaw: Double
        public var pitch: Double

        public init(t: Double, yaw: Double, pitch: Double) {
            self.t = t
            self.yaw = yaw
            self.pitch = pitch
        }
    }

    /// Where the head points: degrees, with rate (deg/s) and acceleration (deg/s²) to feed
    /// forward.
    public struct Reference: Equatable, Sendable {
        public var yaw: Double
        public var pitch: Double
        public var yawRate: Double
        public var pitchRate: Double
        public var yawAccel: Double
        public var pitchAccel: Double

        public init(
            yaw: Double, pitch: Double, yawRate: Double = 0, pitchRate: Double = 0,
            yawAccel: Double = 0, pitchAccel: Double = 0
        ) {
            self.yaw = yaw
            self.pitch = pitch
            self.yawRate = yawRate
            self.pitchRate = pitchRate
            self.yawAccel = yawAccel
            self.pitchAccel = pitchAccel
        }
    }

    /// Head angle at `time` with its rate and acceleration, from a quadratic least-squares
    /// fit of the samples within `fitWindow` seconds of the newest (a line with fewer than
    /// four), carried on past the newest sample; after 0.2 s without one it holds.
    public static func reference(_ samples: [Sample], at time: Double, fitWindow: Double) -> Reference? {
        guard let newest = samples.last else { return nil }
        let recent = samples.filter { newest.t - $0.t <= fitWindow }
        let xs = recent.map { $0.t - newest.t }
        func fit(_ ys: [Double]) -> (value: Double, rate: Double, accel: Double) {
            let n = Double(xs.count)
            var s = [Double](repeating: 0, count: 5)
            var sy = [0.0, 0.0, 0.0]
            for (x, y) in zip(xs, ys) {
                var power = 1.0
                for k in 0..<5 {
                    s[k] += power
                    if k < 3 { sy[k] += power * y }
                    power *= x
                }
            }
            func det3(_ m: [[Double]]) -> Double {
                m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                    + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
            }
            if xs.count >= 4 {
                let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
                let d = det3(m)
                if abs(d) > 1e-12 {
                    func solve(_ column: Int) -> Double {
                        var c = m
                        for row in 0..<3 { c[row][column] = sy[row] }
                        return det3(c) / d
                    }
                    return (solve(0), solve(1), 2 * solve(2))
                }
            }
            let denominator = n * s[2] - s[1] * s[1]
            guard xs.count >= 2, abs(denominator) > 1e-12 else { return (ys.last ?? 0, 0, 0) }
            let rate = (n * sy[1] - s[1] * sy[0]) / denominator
            return ((sy[0] - rate * s[1]) / n, rate, 0)
        }
        // A stale head (no sample for 0.2 s) holds its last angle instead of drifting on.
        guard time - newest.t <= 0.2 else { return Reference(yaw: newest.yaw, pitch: newest.pitch) }
        let yaw = fit(recent.map(\.yaw))
        let pitch = fit(recent.map(\.pitch))
        let h = max(time - newest.t, 0)
        return Reference(
            yaw: yaw.value + yaw.rate * h + yaw.accel * h * h / 2,
            pitch: pitch.value + pitch.rate * h + pitch.accel * h * h / 2,
            yawRate: yaw.rate, pitchRate: pitch.rate, yawAccel: yaw.accel, pitchAccel: pitch.accel)
    }
}
