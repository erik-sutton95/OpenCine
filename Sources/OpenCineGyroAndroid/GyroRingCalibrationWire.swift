import Foundation
import OpenCineGyro

/// Owner-keyed Android access to the portable three-pose ring calibration.
public final class GyroRingCalibrationWire: @unchecked Sendable {
    /// Process-local registry; each open calibration screen owns one independent session.
    public static let shared = GyroRingCalibrationWire()
    private let lock = NSLock()
    private var sessions: [String: GyroRingCalibration] = [:]

    /// Starts a calibration without starting sensors or changing a saved alignment.
    public func create() -> String {
        lock.withLock {
            let owner = UUID().uuidString
            sessions[owner] = GyroRingCalibration()
            return owner
        }
    }

    /// Starts or restarts the ring; recording is -1 unknown, 0 not recording, 1 recording.
    /// Returns the reply the next screen redraw draws from.
    public func start(owner: String, cameraConnected: Bool, recording: Int) -> String? {
        mutate(owner: owner) { session in
            session.start(cameraConnected: cameraConnected, recording: Self.recording(recording))
            return nil
        }
    }

    /// Tracks camera state between readings; the ring reports any invalidation in the reply.
    public func updateCamera(owner: String, connected: Bool, recording: Int) -> String? {
        mutate(owner: owner) { session in
            session.updateCamera(connected: connected, recording: Self.recording(recording))
            return nil
        }
    }

    /// Feeds one simultaneous phone and camera reading; the camera level is physical down in
    /// camera axes. A missing level (or a vector that is not finite or has zero length) blocks
    /// the step waiting for a camera.
    public func observe(
        owner: String, phoneX: Double, phoneY: Double, phoneZ: Double,
        phoneTimestamp: Double, hasCameraLevel: Bool, cameraX: Double, cameraY: Double,
        cameraZ: Double, cameraTimestamp: Double
    ) -> String? {
        mutate(owner: owner) { session in
            let cameraDown = Self.down(
                hasCameraLevel: hasCameraLevel, x: cameraX, y: cameraY, z: cameraZ)
            return session.observe(
                phoneDown: GyroVector3(x: phoneX, y: phoneY, z: phoneZ),
                phoneTimestamp: phoneTimestamp, cameraDown: cameraDown,
                cameraTimestamp: cameraDown == nil ? nil : cameraTimestamp)
        }
    }

    /// Discards the ring and reports why; calibration must be started again.
    public func invalidate(owner: String, reason: String) -> String? {
        guard let invalidation = GyroCalibrationInvalidation(rawValue: reason) else { return nil }
        return mutate(owner: owner) { session in
            session.invalidate(invalidation)
            return nil
        }
    }

    /// Returns to the intro phase with an empty session.
    public func cancel(owner: String) -> String? {
        mutate(owner: owner) { session in
            session.cancel()
            return nil
        }
    }

    /// Releases a calibration screen's transient samples and poses.
    public func close(owner: String) { _ = lock.withLock { sessions.removeValue(forKey: owner) } }

    /// Checks a stored value through the same rotation validation used on iOS.
    public func validate(calibrationJSON: String) -> Bool {
        GyroWireJSON.decodeCalibration(calibrationJSON) != nil
    }

    private func mutate(
        owner: String,
        operation: (inout GyroRingCalibration) -> GyroRingEvent?
    ) -> String? {
        lock.withLock {
            guard var session = sessions[owner] else { return nil }
            let event = operation(&session)
            sessions[owner] = session
            return Self.reply(session, event: event)
        }
    }

    private static func recording(_ value: Int) -> Bool? {
        switch value {
        case -1: return nil
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    private static func down(
        hasCameraLevel: Bool, x: Double, y: Double, z: Double
    ) -> GyroVector3? {
        guard hasCameraLevel, x.isFinite, y.isFinite, z.isFinite else { return nil }
        let length = hypot(hypot(x, y), z)
        guard length.isFinite, length > 0 else { return nil }
        return GyroVector3(x: x, y: y, z: z)
    }

    private static func reply(_ session: GyroRingCalibration, event: GyroRingEvent?) -> String? {
        var reply: [String: Any] = [
            "phase": "intro",
            "step": NSNull(),
            "inZone": NSNull(),
            "hold": NSNull(),
            "block": NSNull(),
            "invalidation": NSNull(),
            "completedSteps": session.completedSteps,
            "event": NSNull(),
            "calibration": NSNull(),
        ]
        var calibration: GyroMountCalibration?
        switch session.phase {
        case .intro:
            break
        case .posing(let step, let inZone, let hold):
            reply["phase"] = "posing"
            reply["step"] = step.rawValue
            reply["inZone"] = inZone
            reply["hold"] = hold
        case .blocked(let step, let reason):
            reply["phase"] = "blocked"
            reply["step"] = step.rawValue
            reply["block"] = reason.rawValue
        case .retrying:
            reply["phase"] = "retrying"
        case .invalidated(let reason):
            reply["phase"] = "invalidated"
            reply["invalidation"] = reason.rawValue
        case .complete(let value):
            reply["phase"] = "complete"
            calibration = value
        }
        switch event {
        case .stepCaptured?:
            reply["event"] = "stepCaptured"
        case .verificationFailed?:
            reply["event"] = "verificationFailed"
        case .completed(let value)?:
            reply["event"] = "completed"
            calibration = value
        case nil:
            break
        }
        if let calibration, let object = GyroWireJSON.object(calibration) {
            reply["calibration"] = object
        }
        return GyroWireJSON.string(reply)
    }
}
