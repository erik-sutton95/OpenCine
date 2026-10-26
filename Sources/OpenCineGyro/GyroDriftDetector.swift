import Foundation

/// One gravity and motion observation used to compare the phone's down with the camera's down.
public struct GyroDriftReading: Equatable, Sendable {
    /// Phone monotonic time in seconds.
    public let timestamp: Double
    /// Physical down in phone axes; the gravity direction, not the screen orientation.
    public let phoneDown: GyroVector3
    /// Magnitude of angular velocity in radians per second.
    public let rotationRate: Double
    /// Magnitude of specific force in g, including gravity and operator motion.
    public let accelerationG: Double

    /// Creates one reading for a steady-moment check.
    public init(
        timestamp: Double, phoneDown: GyroVector3, rotationRate: Double, accelerationG: Double
    ) {
        self.timestamp = timestamp
        self.phoneDown = phoneDown
        self.rotationRate = rotationRate
        self.accelerationG = accelerationG
    }
}

/// Confirms a mount that moved after calibration by watching steady moments where the phone and
/// the camera both report down.
public struct GyroDriftDetector: Sendable {
    /// Angular disagreement that counts as a moved mount.
    public static let thresholdDegrees = 2.5
    /// Disagreement duration required before drift is confirmed, in seconds.
    public static let holdSeconds = 1.0
    /// Rotation rate below which a reading counts as steady, in radians per second.
    public static let steadyRotationRate = 0.05
    /// Distance from one g within which a reading counts as steady.
    public static let steadyAccelerationToleranceG = 0.03
    /// Maximum age of the newest camera down reading, in seconds.
    public static let cameraFreshness = 0.25
    /// Maximum spacing between steady comparable readings before the run restarts, in seconds.
    public static let maximumSteadyGap = 0.25

    private let calibration: GyroMountCalibration
    private let threshold: Double
    private var cameraDown: GyroVector3?
    private var cameraTimestamp: Double?
    private var disagreementStart: Double?
    private var lastSteadyTimestamp: Double?
    /// True after a sustained disagreement; `reset()` clears it.
    public private(set) var hasDrifted = false

    /// Creates a detector for one frozen mount calibration.
    public init(
        calibration: GyroMountCalibration, thresholdDegrees: Double = Self.thresholdDegrees
    ) {
        self.calibration = calibration
        threshold = thresholdDegrees
    }

    /// Records the newest camera down reading; nil clears it and the disagreement run.
    public mutating func observeCamera(down: GyroVector3?, at timestamp: Double) {
        guard timestamp.isFinite else { return }
        cameraDown = down
        cameraTimestamp = down == nil ? nil : timestamp
        if down == nil { disagreementStart = nil }
    }

    /// Returns true exactly once, on the steady reading that completes the hold duration.
    public mutating func observePhone(_ reading: GyroDriftReading) -> Bool {
        guard reading.timestamp.isFinite, reading.rotationRate.isFinite,
            reading.accelerationG.isFinite, reading.rotationRate < Self.steadyRotationRate,
            abs(reading.accelerationG - 1) <= Self.steadyAccelerationToleranceG
        else { return false }
        guard let cameraDown, let cameraTimestamp else { return false }
        let age = reading.timestamp - cameraTimestamp
        guard age >= 0, age <= Self.cameraFreshness else { return false }
        if let lastSteadyTimestamp,
            reading.timestamp - lastSteadyTimestamp > Self.maximumSteadyGap
        {
            disagreementStart = nil
        }
        lastSteadyTimestamp = reading.timestamp
        guard !hasDrifted else { return false }
        guard calibration.mapping(reading.phoneDown).angle(to: cameraDown) > threshold else {
            disagreementStart = nil
            return false
        }
        if disagreementStart == nil { disagreementStart = reading.timestamp }
        guard let start = disagreementStart,
            reading.timestamp - start >= Self.holdSeconds
        else { return false }
        hasDrifted = true
        return true
    }

    /// Clears drift confirmation, the camera reading and any partial disagreement run.
    public mutating func reset() {
        cameraDown = nil
        cameraTimestamp = nil
        disagreementStart = nil
        lastSteadyTimestamp = nil
        hasDrifted = false
    }
}
