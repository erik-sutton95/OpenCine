import Foundation

/// One camera-head IMU sample from media subtype 0x30 (1 kHz, ~100 per frame).
/// Layout per 56-byte record: u64 milliseconds, then six little-endian doubles:
/// accelerometer x, y, z in g, gyro x, y, z in rad/s. Hardware-verified 2026-09-29:
/// pan right is +gyro z, tilt up is +gyro y, level and still reads accel z ≈ −1 g.
public struct LunaIMUSample: Equatable, Sendable {
    public let milliseconds: UInt64
    public let accel: SIMD3<Double>
    public let gyro: SIMD3<Double>

    public init(milliseconds: UInt64, accel: SIMD3<Double>, gyro: SIMD3<Double>) {
        self.milliseconds = milliseconds
        self.accel = accel
        self.gyro = gyro
    }

    static let recordSize = 56

    static func decode(_ bytes: Data) -> [LunaIMUSample] {
        var samples: [LunaIMUSample] = []
        samples.reserveCapacity(bytes.count / recordSize)
        var offset = 0
        while offset + recordSize <= bytes.count {
            func double(_ index: Int) -> Double {
                Double(bitPattern: bytes.littleEndian(at: offset + 8 + index * 8, as: UInt64.self))
            }
            samples.append(
                LunaIMUSample(
                    milliseconds: bytes.littleEndian(at: offset, as: UInt64.self),
                    accel: SIMD3(double(0), double(1), double(2)),
                    gyro: SIMD3(double(3), double(4), double(5))))
            offset += recordSize
        }
        return samples
    }
}

extension LunaMediaPacket {
    public var imuSamples: [LunaIMUSample]? { subtype == 0x30 ? LunaIMUSample.decode(bytes) : nil }
}

/// Camera-head pointing from the IMU stream. Gimbal targets use cmd 226 SET_ANGLE /
/// GET_ANGLE (handle frame); this world-frame estimate feeds Level and is the pose
/// fallback when GET_ANGLE is unavailable.
///
/// Yaw is the integrated gyro (right positive) relative to the last `zeroYaw()`,
/// normally a recenter; it drifts with the residual gyro bias. Pitch is world pitch
/// (up positive): gyro integrated and pulled toward gravity by a complementary filter.
public struct LunaGimbalPoseEstimator: Sendable {
    public private(set) var yawDeg = 0.0
    public private(set) var pitchDeg = 0.0
    public private(set) var gyroBias = SIMD3<Double>(repeating: 0)
    public private(set) var sampleCount = 0
    /// Measured head rate (deg/s, bias-corrected) over the last ~20 ms of samples.
    public private(set) var yawRateDegPerSec = 0.0
    public private(set) var pitchRateDegPerSec = 0.0
    private var lastMilliseconds: UInt64?
    private var stillSeconds = 0.0
    private var stillSum = SIMD3<Double>(repeating: 0)
    private var stillCount = 0
    private var pitchSeeded = false

    /// Gravity weight per 1 ms sample: ~1 s time constant, slow enough to ride
    /// through handheld jolts, fast enough to cancel gyro pitch drift.
    public static let gravityWeight = 0.001
    /// Below this the head is treated as still and the bias is re-learned.
    public static let stillRadPerSec = 0.02
    public static let stillWindowSeconds = 0.8

    public init() {}

    /// World pitch from gravity, up positive (tilt up gives +x acceleration).
    public static func gravityPitchDeg(_ accel: SIMD3<Double>) -> Double {
        atan2(accel.x, (accel.y * accel.y + accel.z * accel.z).squareRoot()) * 180 / .pi
    }

    public mutating func zeroYaw() { yawDeg = 0 }

    /// `commanding` is true while this app is driving the stick; bias learning pauses.
    public mutating func ingest(_ samples: [LunaIMUSample], commanding: Bool = false) {
        for sample in samples {
            let gravityPitch = Self.gravityPitchDeg(sample.accel)
            if !pitchSeeded {
                pitchDeg = gravityPitch
                pitchSeeded = true
            }
            defer { lastMilliseconds = sample.milliseconds }
            guard let last = lastMilliseconds, sample.milliseconds > last,
                sample.milliseconds - last <= 50
            else { continue }
            let dt = Double(sample.milliseconds - last) / 1000
            let rate = sample.gyro - gyroBias
            yawDeg += rate.z * dt * 180 / .pi
            pitchDeg += rate.y * dt * 180 / .pi
            let smoothing = 0.05  // ~20 samples at 1 kHz
            yawRateDegPerSec += (rate.z * 180 / .pi - yawRateDegPerSec) * smoothing
            pitchRateDegPerSec += (rate.y * 180 / .pi - pitchRateDegPerSec) * smoothing
            pitchDeg += (gravityPitch - pitchDeg) * Self.gravityWeight
            sampleCount += 1
            learnBias(sample.gyro, dt: dt, commanding: commanding)
        }
    }

    private mutating func learnBias(_ gyro: SIMD3<Double>, dt: Double, commanding: Bool) {
        let magnitude = ((gyro - gyroBias) * (gyro - gyroBias)).sum().squareRoot()
        guard !commanding, magnitude < Self.stillRadPerSec else {
            stillSeconds = 0
            stillSum = .zero
            stillCount = 0
            return
        }
        stillSeconds += dt
        stillSum += gyro
        stillCount += 1
        if stillSeconds >= Self.stillWindowSeconds {
            gyroBias = stillSum / Double(stillCount)
            stillSeconds = 0
            stillSum = .zero
            stillCount = 0
        }
    }
}
