#if os(iOS)
import CoreMotion
import Foundation
import OpenCineGyro

/// What a capture surface drives: raw gyro samples and the shared device-motion stream.
@MainActor
public protocol GyroMotionDriving: AnyObject {
    /// Starts raw gyro samples into the bounded handoff.
    func startGyro(into buffer: GyroSampleBuffer) throws
    /// Stops raw gyro samples; a later `startGyro` starts them again.
    func stopGyro()
    /// Device motion at 30 Hz: phoneDown = gravity, rotationRate = |rotationRate|,
    /// accelerationG = |gravity + userAcceleration|.
    func startMotion(_ receive: @escaping (GyroDriftReading) -> Void) throws -> UUID
    /// Stops the device-motion consumer with this identity.
    func stopMotion(_ id: UUID)
    /// Unfiltered gravity x, y, z for a host's level overlay.
    func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID
    /// Stops the level consumer with this identity.
    func stopLevel(_ id: UUID)
}

/// Why the platform could not start a motion stream.
public enum PhoneMotionError: LocalizedError {
    /// No gyroscope is available.
    case unavailable
    /// No device-motion stream is available.
    case motionUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This phone's gyroscope is unavailable."
        case .motionUnavailable: "This phone's device motion is unavailable."
        }
    }
}

/// One motion manager serves the raw gyro logger and the independently paced device-motion
/// consumers.
@MainActor
public final class PhoneMotionDriver: GyroMotionDriving {
    /// One motion manager per process, shared by every capture surface.
    public static let shared = PhoneMotionDriver()
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.opencine.gyro"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var motionConsumers: [UUID: (GyroDriftReading) -> Void] = [:]
    private var levelConsumers: [UUID: (Double, Double, Double) -> Void] = [:]

    private init() {}

    public func startGyro(into buffer: GyroSampleBuffer) throws {
        guard manager.isGyroAvailable else { throw PhoneMotionError.unavailable }
        manager.stopGyroUpdates()
        manager.gyroUpdateInterval = 1 / GyroTakeSession.requestedRate
        manager.startGyroUpdates(to: queue, withHandler: Self.gyroHandler(into: buffer))
    }

    /// The raw gyro callback; Core Motion invokes it on the driver's serial sensor queue.
    public nonisolated static func gyroHandler(into buffer: GyroSampleBuffer)
        -> @Sendable (CMGyroData?, Error?) -> Void
    {
        { data, error in
            guard error == nil, let data else {
                buffer.fail()
                return
            }
            let rate = data.rotationRate
            buffer.append(GyroSample(timestamp: data.timestamp, x: rate.x, y: rate.y, z: rate.z))
        }
    }

    public func stopGyro() { manager.stopGyroUpdates() }

    public func startMotion(_ receive: @escaping (GyroDriftReading) -> Void) throws -> UUID {
        guard manager.isDeviceMotionAvailable else { throw PhoneMotionError.motionUnavailable }
        let id = UUID()
        motionConsumers[id] = receive
        startDeviceMotionIfNeeded()
        return id
    }

    public func stopMotion(_ id: UUID) {
        motionConsumers.removeValue(forKey: id)
        stopDeviceMotionIfIdle()
    }

    public func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID {
        let id = UUID()
        levelConsumers[id] = receive
        startDeviceMotionIfNeeded()
        return id
    }

    public func stopLevel(_ id: UUID) {
        levelConsumers.removeValue(forKey: id)
        stopDeviceMotionIfIdle()
    }

    /// Maps one Core Motion sample to a drift reading without touching a sensor.
    public nonisolated static func reading(
        gravity: (Double, Double, Double),
        userAcceleration: (Double, Double, Double),
        rotationRate: (Double, Double, Double),
        timestamp: Double
    ) -> GyroDriftReading {
        let totalAcceleration = (
            gravity.0 + userAcceleration.0,
            gravity.1 + userAcceleration.1,
            gravity.2 + userAcceleration.2)
        return GyroDriftReading(
            timestamp: timestamp,
            phoneDown: GyroVector3(x: gravity.0, y: gravity.1, z: gravity.2),
            rotationRate: magnitude(rotationRate),
            accelerationG: magnitude(totalAcceleration))
    }

    private nonisolated static func magnitude(_ vector: (Double, Double, Double)) -> Double {
        (vector.0 * vector.0 + vector.1 * vector.1 + vector.2 * vector.2).squareRoot()
    }

    /// Starts the one device-motion subscription on the first consumer.
    private func startDeviceMotionIfNeeded() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = (motion.gravity.x, motion.gravity.y, motion.gravity.z)
            let userAcceleration = (
                motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
            let rotationRate = (
                motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
            let timestamp = motion.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                let reading = Self.reading(
                    gravity: gravity, userAcceleration: userAcceleration,
                    rotationRate: rotationRate, timestamp: timestamp)
                for receive in Array(self.motionConsumers.values) { receive(reading) }
                for receive in Array(self.levelConsumers.values) {
                    receive(gravity.0, gravity.1, gravity.2)
                }
            }
        }
    }

    /// Stops the shared device-motion subscription after the last consumer leaves.
    private func stopDeviceMotionIfIdle() {
        guard motionConsumers.isEmpty, levelConsumers.isEmpty else { return }
        manager.stopDeviceMotionUpdates()
    }
}
#endif
