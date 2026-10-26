import Foundation

/// One stabilization restore the app still owes a camera body.
public struct GyroPendingRestore: Codable, Equatable, Sendable {
    /// Stable camera identity the restore belongs to.
    public let cameraID: String
    /// Values captured before the app turned stabilization off.
    public let saved: [String: String]
    /// Values the app wrote, one per affected setting.
    public let applied: [String: String]

    /// Creates one owed restore.
    public init(cameraID: String, saved: [String: String], applied: [String: String]) {
        self.cameraID = cameraID
        self.saved = saved
        self.applied = applied
    }
}

/// One step of the arming setup sheet.
public enum GyroArmingStep: Equatable, Sendable {
    /// Offer to turn camera stabilization off; nil when lens switch knowledge is unavailable.
    case stabilization(lensHasVRSwitch: Bool?)
    /// Offer ring calibration; a saved calibration enables the skip link.
    case calibration(hasSavedCalibration: Bool)
}

/// Why a stabilization write was sent.
public enum GyroWritePurpose: String, Codable, Sendable {
    /// Turn stabilization off for the armed session.
    case turnOff
    /// Restore the values saved before arming.
    case restore
}

/// A plain notice the host shows after a failed camera write.
public enum GyroArmingNotice: String, Codable, Sendable {
    /// Turning stabilization off was refused.
    case turnOffFailed
    /// Restoring the saved stabilization values was refused.
    case restoreFailed
}

/// One ordered side effect a host applies after a machine call.
public enum GyroArmingEffect: Equatable, Sendable {
    /// Write these camera stabilization values.
    case writeStabilization([String: String], purpose: GyroWritePurpose)
    /// Present the setup sheet with these steps.
    case presentSetup([GyroArmingStep])
    /// Persist this exact list of owed restores.
    case persistPendingRestores([GyroPendingRestore])
    /// An armed session started.
    case sessionStarted
    /// The armed session ended.
    case sessionEnded
    /// Show this notice.
    case notice(GyroArmingNotice)
}

/// Current host and camera observations the arming machine evaluates.
public struct GyroArmingInputs: Equatable, Sendable {
    /// The saved Gyro toggle: arm whenever possible.
    public var toggleOn: Bool
    /// Active camera body, or nil when not connected.
    public var camera: GyroCameraIdentity?
    /// Monitor showing, app in front, and no multicam or relay.
    public var hostEligible: Bool
    /// Camera in movie mode; nil when unknown.
    public var videoMode: Bool?
    /// Camera recording; nil when unknown.
    public var recording: Bool?
    /// Current stabilization values; nil when the camera reports them unavailable.
    public var stabilization: GyroStabilizationState?
    /// Stabilization controls the camera adapter exposes.
    public var settings: [GyroStabilizationSetting]
    /// False when the camera has no level sensor.
    public var providesLevel: Bool
    /// Whether a calibration is saved for this camera.
    public var hasSavedCalibration: Bool

    /// Creates one observation set; every field is a parameter.
    public init(
        toggleOn: Bool,
        camera: GyroCameraIdentity?,
        hostEligible: Bool,
        videoMode: Bool?,
        recording: Bool?,
        stabilization: GyroStabilizationState?,
        settings: [GyroStabilizationSetting],
        providesLevel: Bool,
        hasSavedCalibration: Bool
    ) {
        self.toggleOn = toggleOn
        self.camera = camera
        self.hostEligible = hostEligible
        self.videoMode = videoMode
        self.recording = recording
        self.stabilization = stabilization
        self.settings = settings
        self.providesLevel = providesLevel
        self.hasSavedCalibration = hasSavedCalibration
    }
}

/// Session arming and the stabilization save/restore owed across camera connections.
public struct GyroArmingMachine: Sendable {
    /// Whether a capture session is armed for the current connection.
    public private(set) var isArmed = false
    /// Whether the operator kept stabilization on and the camera has not reported it off.
    public private(set) var stabilizationWarning = false
    /// Restores still owed, at most one per camera id.
    public private(set) var pendingRestores: [GyroPendingRestore]

    private struct WriteContext: Sendable {
        let cameraID: String
        let connection: Int
        let applied: [String: String]
    }

    private var latest: GyroArmingInputs?
    private var writesInFlight: [GyroWritePurpose: WriteContext] = [:]
    private var connection = 0
    private var restoreBlocked = false
    private var deferredSetup = false

    /// Creates a machine that resumes with the owed restores a host persisted.
    public init(pendingRestores: [GyroPendingRestore]) {
        self.pendingRestores = pendingRestores
    }

    /// Evaluates one observation set and returns the effects to apply in order.
    public mutating func update(_ inputs: GyroArmingInputs) -> [GyroArmingEffect] {
        var effects: [GyroArmingEffect] = []
        if stabilizationWarning, inputs.stabilization?.isOff(inputs.settings) == true {
            stabilizationWarning = false
        }
        let previousCameraID = latest?.camera?.id
        let cameraID = inputs.camera?.id
        if previousCameraID != cameraID {
            connection += 1
            restoreBlocked = false
            writesInFlight.removeAll()
            stabilizationWarning = false
            if isArmed {
                isArmed = false
                deferredSetup = false
                effects.append(.sessionEnded)
            }
        }
        latest = inputs
        reconcile(inputs, into: &effects)
        return effects
    }

    /// Records that the operator chose to turn stabilization off.
    public mutating func chooseTurnOff() -> [GyroArmingEffect] {
        guard isArmed, let inputs = latest, let camera = inputs.camera,
            writesInFlight.isEmpty
        else {
            return []
        }
        var saved: [String: String] = [:]
        var applied: [String: String] = [:]
        if let stabilization = inputs.stabilization {
            for setting in inputs.settings {
                guard let value = stabilization.values[setting.key], value != setting.offValue
                else { continue }
                saved[setting.key] = value
                applied[setting.key] = setting.offValue
            }
        }
        guard !applied.isEmpty else { return [] }
        if let index = pendingRestores.firstIndex(where: { $0.cameraID == camera.id }) {
            let pending = pendingRestores[index]
            var mergedSaved = pending.saved
            var mergedApplied = pending.applied
            for (key, value) in saved where mergedSaved[key] == nil {
                mergedSaved[key] = value
                mergedApplied[key] = applied[key]
            }
            pendingRestores[index] = GyroPendingRestore(
                cameraID: camera.id, saved: mergedSaved, applied: mergedApplied)
            applied = mergedApplied
        } else {
            pendingRestores.append(
                GyroPendingRestore(cameraID: camera.id, saved: saved, applied: applied))
        }
        writesInFlight[.turnOff] = WriteContext(
            cameraID: camera.id, connection: connection, applied: applied)
        return [
            .persistPendingRestores(pendingRestores),
            .writeStabilization(applied, purpose: .turnOff),
        ]
    }

    /// Records that the operator chose to keep stabilization on.
    public mutating func chooseKeepOn() -> [GyroArmingEffect] {
        guard isArmed else { return [] }
        stabilizationWarning = true
        return []
    }

    /// Records the outcome of the last stabilization write of the given purpose.
    /// Call once per write effect; a finish that arrives after the connection changed is ignored.
    public mutating func writeFinished(
        _ purpose: GyroWritePurpose, succeeded: Bool
    ) -> [GyroArmingEffect] {
        guard let context = writesInFlight[purpose], context.connection == connection,
            var inputs = latest
        else { return [] }
        writesInFlight[purpose] = nil
        var effects: [GyroArmingEffect] = []
        switch purpose {
        case .turnOff:
            if succeeded {
                stabilizationWarning = false
                inputs.stabilization = Self.applying(context.applied, to: inputs.stabilization)
            } else {
                if isArmed { stabilizationWarning = true }
                effects.append(.notice(.turnOffFailed))
            }
        case .restore:
            if succeeded {
                // The camera now holds the restored values; the session that may start below
                // offers the stabilization step from them, not from the pre-restore reading.
                inputs.stabilization = Self.applying(context.applied, to: inputs.stabilization)
                if let index = pendingRestores.firstIndex(where: {
                    $0.cameraID == context.cameraID
                }) {
                    pendingRestores.remove(at: index)
                }
                effects.append(.persistPendingRestores(pendingRestores))
            } else {
                effects.append(.notice(.restoreFailed))
                if inputs.camera?.id == context.cameraID {
                    restoreBlocked = true
                }
            }
        }
        latest = inputs
        reconcile(inputs, into: &effects)
        return effects
    }

    private static func applying(
        _ applied: [String: String], to stabilization: GyroStabilizationState?
    ) -> GyroStabilizationState {
        var values = stabilization?.values ?? [:]
        for (key, value) in applied { values[key] = value }
        return GyroStabilizationState(
            values: values, lensHasVRSwitch: stabilization?.lensHasVRSwitch)
    }

    private mutating func reconcile(
        _ inputs: GyroArmingInputs, into effects: inout [GyroArmingEffect]
    ) {
        let eligible =
            inputs.toggleOn && inputs.camera != nil && inputs.hostEligible
            && inputs.videoMode == true
        if isArmed && !eligible {
            isArmed = false
            deferredSetup = false
            stabilizationWarning = false
            effects.append(.sessionEnded)
        }
        if !writesInFlight.isEmpty {
            return
        }
        if isArmed {
            if deferredSetup, inputs.recording == false {
                deferredSetup = false
                let steps = setupSteps(inputs)
                if !steps.isEmpty {
                    effects.append(.presentSetup(steps))
                }
            }
            return
        }
        guard let cameraID = inputs.camera?.id else { return }
        let index = inputs.camera?.automaticRestoreEligible == true
            ? pendingRestores.firstIndex(where: { $0.cameraID == cameraID }) : nil
        if !restoreBlocked, let index {
            guard let stabilization = inputs.stabilization, inputs.recording != true else {
                return
            }
            let values = restoreValues(pendingRestores[index], current: stabilization)
            if values.isEmpty {
                pendingRestores.remove(at: index)
                effects.append(.persistPendingRestores(pendingRestores))
            } else {
                writesInFlight[.restore] = WriteContext(
                    cameraID: cameraID, connection: connection, applied: values)
                effects.append(.writeStabilization(values, purpose: .restore))
                return
            }
        }
        if eligible {
            effects.append(contentsOf: startSession(inputs))
        }
    }

    private mutating func startSession(_ inputs: GyroArmingInputs) -> [GyroArmingEffect] {
        isArmed = true
        var effects: [GyroArmingEffect] = [.sessionStarted]
        let steps = setupSteps(inputs)
        if !steps.isEmpty {
            if inputs.recording == true {
                deferredSetup = true
            } else {
                effects.append(.presentSetup(steps))
            }
        }
        return effects
    }

    private func setupSteps(_ inputs: GyroArmingInputs) -> [GyroArmingStep] {
        var steps: [GyroArmingStep] = []
        if !inputs.settings.isEmpty, inputs.stabilization?.isOff(inputs.settings) == false {
            steps.append(.stabilization(lensHasVRSwitch: inputs.stabilization?.lensHasVRSwitch))
        }
        if inputs.providesLevel {
            steps.append(.calibration(hasSavedCalibration: inputs.hasSavedCalibration))
        }
        return steps
    }

    private func restoreValues(
        _ pending: GyroPendingRestore, current: GyroStabilizationState
    ) -> [String: String] {
        var values: [String: String] = [:]
        for (key, applied) in pending.applied {
            guard current.values[key] == applied, let saved = pending.saved[key] else { continue }
            values[key] = saved
        }
        return values
    }
}
