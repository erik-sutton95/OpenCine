import Foundation

/// The three still poses the ring calibration walks through, in capture order.
public enum GyroRingStep: Int, CaseIterable, Sendable {
    /// Camera level, the first pose.
    case level = 0
    /// Camera tilted up from the level pose, the second pose.
    case tiltUp
    /// Camera tilted and leaned together, the independent verification pose.
    case tiltAndLean
}

/// Why the ring calibration cannot accept a reading for the current step.
public enum GyroCalibrationBlock: String, Sendable {
    /// No camera is connected.
    case cameraDisconnected
    /// The camera is recording; calibration needs a resting rig.
    case recording
    /// The rig is inside the target zone but the phone is not still.
    case moving
    /// The camera reports no level, or its reading is too far from the phone's clock.
    case waitingForCamera
}

/// Why an in-progress ring calibration was discarded.
public enum GyroCalibrationInvalidation: String, Sendable {
    /// The active camera body changed.
    case cameraChanged
    /// Recording started before the ring finished.
    case recordingStarted
    /// The camera connection ended before the ring finished.
    case connectionEnded
}

/// What the ring calibration screen shows after the latest reading.
public enum GyroRingPhase: Equatable, Sendable {
    /// Not started, or cancelled.
    case intro
    /// Aiming for the step; the hold fills from 0 to 1 over the hold duration.
    case posing(step: GyroRingStep, inZone: Bool, hold: Double)
    /// A block prevents progress on the step; the step resumes when the block clears.
    case blocked(step: GyroRingStep, reason: GyroCalibrationBlock)
    /// The verification pose failed; the next reading restarts at the level step.
    case retrying
    /// The in-progress calibration was discarded for the reason.
    case invalidated(GyroCalibrationInvalidation)
    /// All three poses verified and the mount rotation is ready to save.
    case complete(GyroMountCalibration)
}

/// One completed transition reported by the ring calibration.
public enum GyroRingEvent: Equatable, Sendable {
    /// One of the first two poses was captured; the step names the pose that completed.
    case stepCaptured(GyroRingStep)
    /// The third pose did not verify; the ring restarted at the level step.
    case verificationFailed
    /// The third pose verified and produced the mount rotation.
    case completed(GyroMountCalibration)
}

/// Walks the operator through the three still poses that solve and verify a mount rotation.
public struct GyroRingCalibration: Sendable {
    /// Seconds the rig must stay still inside the target zone before a pose is captured.
    public static let holdSeconds = 2.0
    private static let stillnessSeconds = 1.5
    private static let stillnessDegrees = 3.0
    private static let levelDegrees = 12.0
    private static let tiltUpDegrees = 25.0
    private static let tiltUpLimitDegrees = 150.0
    private static let mixedDegrees = 18.0
    private static let maximumSkewSeconds = 0.25
    private static let levelDown = GyroVector3(x: -1, y: 0, z: 0)

    private var session = GyroMountCalibrationSession()
    private var holdStart: Double?
    private var phoneWindow: [Reading] = []
    private var isCameraConnected = false
    private var isRecording: Bool?
    /// The latest published phase; starts at the intro phase.
    public private(set) var phase: GyroRingPhase = .intro

    /// Starts before the first pose with an empty session.
    public init() {}

    /// Accepted poses so far, 0 to 3, which drives the three progress dots.
    public var completedSteps: Int { session.poseCount }

    /// Clears any earlier progress and begins at the level step unless a block already applies.
    public mutating func start(cameraConnected: Bool, recording: Bool?) {
        session.reset()
        phoneWindow.removeAll(keepingCapacity: true)
        holdStart = nil
        isCameraConnected = cameraConnected
        isRecording = recording
        if !cameraConnected {
            phase = .blocked(step: .level, reason: .cameraDisconnected)
        } else if recording == true {
            phase = .blocked(step: .level, reason: .recording)
        } else {
            phase = .posing(step: .level, inZone: false, hold: 0)
        }
    }

    /// Tracks camera state between readings; discards a started ring when it becomes invalid.
    public mutating func updateCamera(connected: Bool, recording: Bool?) {
        let wasConnected = isCameraConnected
        let wasRecording = isRecording
        isCameraConnected = connected
        isRecording = recording
        guard completedSteps > 0, isInProgress else { return }
        if wasConnected, !connected {
            invalidate(.connectionEnded)
        } else if recording == true, wasRecording != true {
            invalidate(.recordingStarted)
        }
    }

    /// Feeds one simultaneous phone and camera reading and reports the transition it completed.
    public mutating func observe(
        phoneDown: GyroVector3, phoneTimestamp: Double,
        cameraDown: GyroVector3?, cameraTimestamp: Double?
    ) -> GyroRingEvent? {
        switch phase {
        case .intro, .invalidated, .complete:
            return nil
        case .posing, .blocked, .retrying:
            break
        }
        let step = self.step
        if !isCameraConnected {
            holdStart = nil
            phase = .blocked(step: step, reason: .cameraDisconnected)
            return nil
        }
        if isRecording == true {
            holdStart = nil
            phase = .blocked(step: step, reason: .recording)
            return nil
        }
        guard let cameraDown, let cameraTimestamp,
            cameraTimestamp - phoneTimestamp <= Self.maximumSkewSeconds,
            phoneTimestamp - cameraTimestamp <= Self.maximumSkewSeconds
        else {
            holdStart = nil
            session.invalidateReadings()
            phase = .blocked(step: step, reason: .waitingForCamera)
            return nil
        }
        session.add(
            phoneDown: phoneDown, phoneTimestamp: phoneTimestamp,
            cameraDown: cameraDown, cameraTimestamp: cameraTimestamp)
        guard isInZone(cameraDown) else {
            holdStart = nil
            phoneWindow.removeAll(keepingCapacity: true)
            phase = .posing(step: step, inZone: false, hold: 0)
            return nil
        }
        updateWindow(phoneDown, at: phoneTimestamp)
        guard isStill else {
            holdStart = nil
            phase = .blocked(step: step, reason: .moving)
            return nil
        }
        if holdStart == nil { holdStart = phoneTimestamp }
        guard let holdStart else {
            phase = .posing(step: step, inZone: true, hold: 0)
            return nil
        }
        let hold = min(1, max(0, (phoneTimestamp - holdStart) / Self.holdSeconds))
        phase = .posing(step: step, inZone: true, hold: hold)
        guard hold >= 1 else { return nil }
        return attemptCapture(at: phoneTimestamp, step: step)
    }

    /// Discards the ring and reports why; calibration must be started again.
    public mutating func invalidate(_ reason: GyroCalibrationInvalidation) {
        session.reset()
        phoneWindow.removeAll(keepingCapacity: true)
        holdStart = nil
        phase = .invalidated(reason)
    }

    /// Returns to the intro phase with an empty session.
    public mutating func cancel() {
        session.reset()
        phoneWindow.removeAll(keepingCapacity: true)
        holdStart = nil
        isCameraConnected = false
        isRecording = nil
        phase = .intro
    }

    private var step: GyroRingStep {
        switch session.poseCount {
        case 0: return .level
        case 1: return .tiltUp
        default: return .tiltAndLean
        }
    }

    private var isInProgress: Bool {
        switch phase {
        case .posing, .blocked, .retrying: return true
        case .intro, .invalidated, .complete: return false
        }
    }

    /// Only readings inside the current target zone count toward stillness: readings of the
    /// previous pose must not delay the new hold.
    private mutating func updateWindow(_ down: GyroVector3, at timestamp: Double) {
        phoneWindow.append(Reading(down: down, timestamp: timestamp))
        let oldest = timestamp - Self.stillnessSeconds
        phoneWindow.removeAll { $0.timestamp < oldest || $0.timestamp > timestamp }
    }

    private var isStill: Bool {
        guard !phoneWindow.isEmpty else { return false }
        guard phoneWindow.count > 1 else { return true }
        let sum = phoneWindow.reduce(GyroVector3(x: 0, y: 0, z: 0)) { $0 + $1.down }
        guard let mean = try? sum.normalized() else { return false }
        return phoneWindow.allSatisfy { $0.down.angle(to: mean) <= Self.stillnessDegrees }
    }

    private func isInZone(_ cameraDown: GyroVector3) -> Bool {
        guard let down = try? cameraDown.normalized() else { return false }
        switch step {
        case .level:
            return down.angle(to: Self.levelDown) <= Self.levelDegrees
        case .tiltUp:
            guard let first = session.capturedPoses.first,
                let level = try? first.cameraDown.normalized()
            else { return false }
            let angle = down.angle(to: level)
            return (Self.tiltUpDegrees...Self.tiltUpLimitDegrees).contains(angle)
        case .tiltAndLean:
            guard session.capturedPoses.count >= 2,
                let first = try? session.capturedPoses[0].cameraDown.normalized(),
                let second = try? session.capturedPoses[1].cameraDown.normalized(),
                let third = try? first.cross(second).normalized()
            else { return false }
            let secondBasis = third.cross(first)
            let minimum = sin(Self.mixedDegrees * .pi / 180)
            return abs(down.dot(secondBasis)) >= minimum && abs(down.dot(third)) >= minimum
        }
    }

    private mutating func attemptCapture(
        at timestamp: Double, step: GyroRingStep
    ) -> GyroRingEvent? {
        do {
            let calibration = try session.capture(at: timestamp)
            phoneWindow.removeAll(keepingCapacity: true)
            holdStart = nil
            if let calibration {
                phase = .complete(calibration)
                return .completed(calibration)
            }
            phase = .posing(step: self.step, inZone: false, hold: 0)
            return .stepCaptured(step)
        } catch let error as GyroMountCalibrationError {
            return handle(error, for: step)
        } catch {
            phase = .posing(step: step, inZone: true, hold: 1)
            return nil
        }
    }

    private mutating func handle(
        _ error: GyroMountCalibrationError, for step: GyroRingStep
    ) -> GyroRingEvent? {
        switch error {
        case .staleReadings, .insufficientReadings, .invalidReadings:
            phase = .posing(step: step, inZone: true, hold: 1)
            return nil
        case .moving:
            holdStart = nil
            phase = .blocked(step: step, reason: .moving)
            return nil
        case .insufficientSeparation:
            restart(step)
            return nil
        case .inconsistentPoses:
            guard step != .tiltAndLean else { return failVerification() }
            restart(step)
            return nil
        case .validationMismatch, .unmixedValidation, .invalidCalibration, .completed:
            return failVerification()
        }
    }

    /// Keeps the current step and discards only the hold, for a pose that still can be retried.
    private mutating func restart(_ step: GyroRingStep) {
        holdStart = nil
        phase = .posing(step: step, inZone: false, hold: 0)
    }

    /// Discards every pose and waits for a fresh level reading after a failed verification.
    private mutating func failVerification() -> GyroRingEvent? {
        session.reset()
        phoneWindow.removeAll(keepingCapacity: true)
        holdStart = nil
        phase = .retrying
        return .verificationFailed
    }

    private struct Reading: Sendable {
        let down: GyroVector3
        let timestamp: Double
    }
}
