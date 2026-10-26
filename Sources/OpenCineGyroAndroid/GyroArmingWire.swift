import Foundation
import OpenCineGyro

/// Owner-keyed Android access to the portable session-arming machine.
public final class GyroArmingWire: @unchecked Sendable {
    /// Process-local registry; every operation names its monitor session.
    public static let shared = GyroArmingWire()
    private let lock = NSLock()
    private var machines: [String: GyroArmingMachine] = [:]

    /// Creates a machine that resumes with the owed restores the host persisted.
    /// A malformed restore list resumes with nothing owed rather than losing the session.
    public func create(pendingRestoresJSON: String) -> String {
        let restores = GyroWireJSON.decodePendingRestores(pendingRestoresJSON) ?? []
        return lock.withLock {
            let owner = UUID().uuidString
            machines[owner] = GyroArmingMachine(pendingRestores: restores)
            return owner
        }
    }

    /// Evaluates one observation set; malformed inputs are refused without touching the machine.
    public func update(owner: String, inputsJSON: String) -> String? {
        guard let inputs = GyroWireJSON.decodeArmingInputs(inputsJSON) else { return nil }
        return apply(owner: owner) { $0.update(inputs) }
    }

    /// Records that the operator chose to turn stabilization off.
    public func chooseTurnOff(owner: String) -> String? {
        apply(owner: owner) { $0.chooseTurnOff() }
    }

    /// Records that the operator chose to keep stabilization on.
    public func chooseKeepOn(owner: String) -> String? {
        apply(owner: owner) { $0.chooseKeepOn() }
    }

    /// Records the outcome of the last stabilization write of the given purpose.
    public func writeFinished(owner: String, purpose: String, succeeded: Bool) -> String? {
        guard let purpose = GyroWritePurpose(rawValue: purpose) else { return nil }
        return apply(owner: owner) { $0.writeFinished(purpose, succeeded: succeeded) }
    }

    /// Releases a monitor session.
    public func close(owner: String) { _ = lock.withLock { machines.removeValue(forKey: owner) } }

    private func apply(
        owner: String,
        operation: (inout GyroArmingMachine) -> [GyroArmingEffect]
    ) -> String? {
        lock.withLock {
            guard var machine = machines[owner] else { return nil }
            let effects = operation(&machine)
            machines[owner] = machine
            return Self.reply(machine: machine, effects: effects)
        }
    }

    private static func reply(
        machine: GyroArmingMachine, effects: [GyroArmingEffect]
    ) -> String? {
        var objects: [[String: Any]] = []
        for effect in effects {
            guard let object = effectObject(effect) else { return nil }
            objects.append(object)
        }
        return GyroWireJSON.string([
            "effects": objects,
            "isArmed": machine.isArmed,
            "stabilizationWarning": machine.stabilizationWarning,
        ])
    }

    private static func effectObject(_ effect: GyroArmingEffect) -> [String: Any]? {
        switch effect {
        case .writeStabilization(let values, let purpose):
            return [
                "kind": "writeStabilization", "purpose": purpose.rawValue, "values": values,
            ]
        case .presentSetup(let steps):
            var objects: [[String: Any]] = []
            for step in steps {
                guard let object = stepObject(step) else { return nil }
                objects.append(object)
            }
            return ["kind": "presentSetup", "steps": objects]
        case .persistPendingRestores(let restores):
            guard let encoded = GyroWireJSON.object(restores) else { return nil }
            return ["kind": "persistPendingRestores", "restores": encoded]
        case .sessionStarted:
            return ["kind": "sessionStarted"]
        case .sessionEnded:
            return ["kind": "sessionEnded"]
        case .notice(let notice):
            return ["kind": "notice", "notice": notice.rawValue]
        }
    }

    private static func stepObject(_ step: GyroArmingStep) -> [String: Any]? {
        switch step {
        case .stabilization(let lensHasVRSwitch):
            return [
                "kind": "stabilization",
                "lensHasVRSwitch": GyroWireJSON.optional(lensHasVRSwitch),
            ]
        case .calibration(let hasSavedCalibration):
            return ["kind": "calibration", "hasSavedCalibration": hasSavedCalibration]
        }
    }
}
