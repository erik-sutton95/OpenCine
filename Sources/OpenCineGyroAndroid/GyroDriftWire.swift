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

    /// Records the newest camera down reading; the level is physical down in camera axes.
    /// A missing level, or a vector that is not finite or has zero length, clears the reading.
    public func observeCamera(
        owner: String, hasLevel: Bool, x: Double, y: Double, z: Double, timestamp: Double
    ) {
        lock.withLock {
            guard var detector = detectors[owner] else { return }
            let down = Self.down(hasLevel: hasLevel, x: x, y: y, z: z)
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

    private static func down(hasLevel: Bool, x: Double, y: Double, z: Double) -> GyroVector3? {
        guard hasLevel, x.isFinite, y.isFinite, z.isFinite else { return nil }
        let length = hypot(hypot(x, y), z)
        guard length.isFinite, length > 0 else { return nil }
        return GyroVector3(x: x, y: y, z: z)
    }
}
