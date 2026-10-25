import Foundation
import OpenCineGyro

/// Owner-keyed Android access to the portable drift detector.
public final class GyroDriftWire: @unchecked Sendable {
    /// Process-local registry; each monitor session owns one frozen calibration.
    public static let shared = GyroDriftWire()
    private let lock = NSLock()
    private var detectors: [String: GyroDriftDetector] = [:]

    /// Starts a detector for one validated mount calibration; nil for invalid stored JSON.
    public func create(calibrationJSON: String) -> String? {
        guard let calibration = GyroWireJSON.decodeCalibration(calibrationJSON) else { return nil }
        return lock.withLock {
            let owner = UUID().uuidString
            detectors[owner] = GyroDriftDetector(calibration: calibration)
            return owner
        }
    }

    /// Records the newest camera down reading, derived from measured level angles.
    /// A missing level, or angles that cannot determine down, clears the camera reading.
    public func observeCamera(
        owner: String, hasLevel: Bool, rollDegrees: Double, pitchDegrees: Double,
        timestamp: Double
    ) {
        lock.withLock {
            guard var detector = detectors[owner] else { return }
            let down: GyroVector3? =
                hasLevel
                ? GyroCameraGravity.down(
                    rollDegrees: rollDegrees, pitchDegrees: pitchDegrees)
                : nil
            detector.observeCamera(down: down, at: timestamp)
            detectors[owner] = detector
        }
    }

    /// Records one phone reading; true exactly once, on the reading that confirms drift.
    public func observePhone(
        owner: String, x: Double, y: Double, z: Double, timestamp: Double,
        rotationRate: Double, accelerationG: Double
    ) -> Bool {
        lock.withLock {
            guard var detector = detectors[owner] else { return false }
            let confirmed = detector.observePhone(
                GyroDriftReading(
                    timestamp: timestamp, phoneDown: GyroVector3(x: x, y: y, z: z),
                    rotationRate: rotationRate, accelerationG: accelerationG))
            detectors[owner] = detector
            return confirmed
        }
    }

    /// Clears drift confirmation and every partial disagreement run.
    public func reset(owner: String) {
        lock.withLock {
            guard var detector = detectors[owner] else { return }
            detector.reset()
            detectors[owner] = detector
        }
    }

    /// Releases a monitor session.
    public func close(owner: String) { _ = lock.withLock { detectors.removeValue(forKey: owner) } }
}
