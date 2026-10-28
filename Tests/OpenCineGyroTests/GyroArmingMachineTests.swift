import Foundation
import Testing

@testable import OpenCineGyro

@Suite struct GyroArmingMachineTests {
    private let camera = GyroCameraIdentity(id: "body-1", name: "Camera A")
    private let settings = [
        GyroStabilizationSetting(key: "ibis", title: "IBIS", offValue: "OFF")
    ]

    private func inputs(
        toggleOn: Bool = true,
        connected: Bool = true,
        camera: GyroCameraIdentity? = nil,
        hostEligible: Bool = true,
        videoMode: Bool? = true,
        recording: Bool? = false,
        stabilization: GyroStabilizationState? = nil,
        settings: [GyroStabilizationSetting]? = nil,
        providesLevel: Bool = true,
        hasSavedCalibration: Bool = false
    ) -> GyroArmingInputs {
        GyroArmingInputs(
            toggleOn: toggleOn,
            camera: connected ? (camera ?? self.camera) : nil,
            hostEligible: hostEligible,
            videoMode: videoMode,
            recording: recording,
            stabilization: stabilization,
            settings: settings ?? self.settings,
            providesLevel: providesLevel,
            hasSavedCalibration: hasSavedCalibration)
    }

    private func stabilization(
        _ values: [String: String], lensHasVRSwitch: Bool? = false
    ) -> GyroStabilizationState {
        GyroStabilizationState(values: values, lensHasVRSwitch: lensHasVRSwitch)
    }

    @Test func armingWithIbisOnOffersTheStabilizationStepThenCalibration() {
        var machine = GyroArmingMachine(pendingRestores: [])
        let effects = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        #expect(
            effects == [
                .sessionStarted,
                .presentSetup([
                    .stabilization(lensHasVRSwitch: false),
                    .calibration(hasSavedCalibration: false),
                ]),
            ])
        #expect(machine.isArmed)
    }

    @Test func stabilizationAlreadyOffSkipsTheStep() {
        var machine = GyroArmingMachine(pendingRestores: [])
        let effects = machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
        #expect(
            effects == [
                .sessionStarted,
                .presentSetup([.calibration(hasSavedCalibration: false)]),
            ])
        #expect(machine.isArmed)
    }

    @Test func unknownStabilizationSkipsTheStep() {
        var machine = GyroArmingMachine(pendingRestores: [])
        let effects = machine.update(inputs(stabilization: nil))
        #expect(
            effects == [
                .sessionStarted,
                .presentSetup([.calibration(hasSavedCalibration: false)]),
            ])
    }

    @Test func cameraWithoutLevelSkipsCalibration() {
        var machine = GyroArmingMachine(pendingRestores: [])
        let effects = machine.update(
            inputs(
                stabilization: stabilization(["ibis": "SPORT"], lensHasVRSwitch: true),
                providesLevel: false))
        #expect(
            effects == [
                .sessionStarted,
                .presentSetup([.stabilization(lensHasVRSwitch: true)]),
            ])
    }

    @Test func turnOffPersistsTheRestoreBeforeWriting() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        let restore = GyroPendingRestore(
            cameraID: "body-1", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
        #expect(
            machine.chooseTurnOff() == [
                .persistPendingRestores([restore]),
                .writeStabilization(["ibis": "OFF"], purpose: .turnOff),
            ])
        #expect(machine.pendingRestores == [restore])
        #expect(machine.writeFinished(.turnOff, succeeded: true).isEmpty)
        #expect(!machine.stabilizationWarning)
    }

    @Test func keepOnSetsTheWarningUntilTheCameraReportsOff() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        #expect(machine.chooseKeepOn().isEmpty)
        #expect(machine.stabilizationWarning)
        #expect(machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"]))).isEmpty)
        #expect(machine.stabilizationWarning)
        #expect(machine.update(inputs(stabilization: stabilization(["ibis": "OFF"]))).isEmpty)
        #expect(!machine.stabilizationWarning)
    }

    @Test func sessionEndRestoresExactSavedValues() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        #expect(machine.writeFinished(.turnOff, succeeded: true).isEmpty)
        #expect(machine.update(inputs(stabilization: stabilization(["ibis": "OFF"]))).isEmpty)
        #expect(
            machine.update(inputs(toggleOn: false, stabilization: stabilization(["ibis": "OFF"])))
                == [
                    .sessionEnded,
                    .writeStabilization(["ibis": "SPORT"], purpose: .restore),
                ])
        #expect(machine.writeFinished(.restore, succeeded: true) == [.persistPendingRestores([])])
        #expect(machine.pendingRestores.isEmpty)
        #expect(!machine.isArmed)
    }

    @Test func owedRestoreSkipsKeysTheUserChanged() {
        let pending = GyroPendingRestore(
            cameraID: "body-1",
            saved: ["ibis": "SPORT", "evr": "SPORT"],
            applied: ["ibis": "OFF", "evr": "OFF"])
        var machine = GyroArmingMachine(pendingRestores: [pending])
        let effects = machine.update(
            inputs(stabilization: stabilization(["ibis": "OFF", "evr": "ON"])))
        #expect(effects == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
        #expect(machine.pendingRestores == [pending])
        #expect(!machine.isArmed)
    }

    @Test func linkDropKeepsTheRestoreOwedAndNextConnectionRestoresFirst() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        _ = machine.writeFinished(.turnOff, succeeded: true)
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
        #expect(machine.update(inputs(connected: false)) == [.sessionEnded])
        #expect(machine.pendingRestores.count == 1)
        #expect(
            machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
        #expect(
            machine.writeFinished(.restore, succeeded: true) == [
                .persistPendingRestores([]),
                .sessionStarted,
                .presentSetup([
                    .stabilization(lensHasVRSwitch: false),
                    .calibration(hasSavedCalibration: false),
                ]),
            ])
    }

    @Test func failedRestoreIsNotRetriedInTheSameConnection() {
        let pending = GyroPendingRestore(
            cameraID: "body-1", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
        var machine = GyroArmingMachine(pendingRestores: [pending])
        #expect(
            machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
        #expect(
            machine.writeFinished(.restore, succeeded: false) == [
                .notice(.restoreFailed),
                .sessionStarted,
                .presentSetup([.calibration(hasSavedCalibration: false)]),
            ])
        #expect(machine.pendingRestores == [pending])
        #expect(machine.update(inputs(stabilization: stabilization(["ibis": "OFF"]))).isEmpty)
        #expect(machine.pendingRestores == [pending])
        #expect(machine.update(inputs(connected: false)) == [.sessionEnded])
        #expect(
            machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
    }

    @Test func recordingAtStartDefersTheSetupSheet() {
        var machine = GyroArmingMachine(pendingRestores: [])
        #expect(
            machine.update(
                inputs(recording: true, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionStarted])
        #expect(machine.isArmed)
        #expect(
            machine.update(
                inputs(recording: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [
                    .presentSetup([
                        .stabilization(lensHasVRSwitch: false),
                        .calibration(hasSavedCalibration: false),
                    ])
                ])
    }

    @Test func restoreWaitsForRecordingToStop() {
        let pending = GyroPendingRestore(
            cameraID: "body-1", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
        var machine = GyroArmingMachine(pendingRestores: [pending])
        #expect(
            machine.update(
                inputs(recording: true, stabilization: stabilization(["ibis": "OFF"]))
            ).isEmpty)
        #expect(!machine.isArmed)
        #expect(
            machine.update(
                inputs(recording: false, stabilization: stabilization(["ibis": "OFF"])))
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
    }

    @Test func turnOffInFlightThenSessionEndStillRestores() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        #expect(
            machine.update(
                inputs(toggleOn: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionEnded])
        #expect(
            machine.writeFinished(.turnOff, succeeded: true)
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
        #expect(
            machine.pendingRestores == [
                GyroPendingRestore(
                    cameraID: "body-1", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
            ])
        #expect(
            machine.writeFinished(.restore, succeeded: true) == [.persistPendingRestores([])])
        #expect(machine.pendingRestores.isEmpty)
    }

    @Test func chooseTurnOffAfterSessionEndDoesNothing() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        #expect(
            machine.update(
                inputs(toggleOn: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionEnded])
        #expect(machine.chooseTurnOff().isEmpty)
        #expect(machine.pendingRestores.isEmpty)
        #expect(!machine.isArmed)
    }

    @Test func chooseKeepOnAfterSessionEndDoesNothing() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        #expect(
            machine.update(
                inputs(toggleOn: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionEnded])
        #expect(machine.chooseKeepOn().isEmpty)
        #expect(!machine.stabilizationWarning)
    }

    @Test func disconnectDuringTurnOffWriteUnblocksTheNextConnection() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        #expect(machine.update(inputs(connected: false, stabilization: nil)) == [.sessionEnded])
        #expect(
            machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
                == [.writeStabilization(["ibis": "SPORT"], purpose: .restore)])
    }

    @Test func lateFinishFromAnOldConnectionIsIgnored() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        _ = machine.update(inputs(connected: false, stabilization: nil))
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
        #expect(machine.writeFinished(.turnOff, succeeded: false).isEmpty)
        #expect(!machine.stabilizationWarning)
    }

    @Test func sessionEndClearsTheKeepOnWarning() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseKeepOn()
        #expect(machine.stabilizationWarning)
        #expect(
            machine.update(
                inputs(toggleOn: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionEnded])
        #expect(!machine.stabilizationWarning)
    }

    @Test func warningDoesNotFollowAnotherCamera() {
        let other = GyroCameraIdentity(id: "body-2", name: "Camera B")
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        #expect(
            machine.update(
                inputs(toggleOn: false, stabilization: stabilization(["ibis": "SPORT"])))
                == [.sessionEnded])
        let finished = machine.writeFinished(.turnOff, succeeded: false)
        #expect(finished.contains(.notice(.turnOffFailed)))
        #expect(!machine.stabilizationWarning)
        _ = machine.update(inputs(camera: other, stabilization: nil, settings: []))
        #expect(!machine.stabilizationWarning)

        var kept = GyroArmingMachine(pendingRestores: [])
        _ = kept.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = kept.chooseKeepOn()
        #expect(kept.stabilizationWarning)
        _ = kept.update(inputs(connected: false, stabilization: nil))
        _ = kept.update(inputs(camera: other, stabilization: nil, settings: []))
        #expect(!kept.stabilizationWarning)
    }

    @Test func photoModeEndsTheSessionAndRestores() {
        var machine = GyroArmingMachine(pendingRestores: [])
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "SPORT"])))
        _ = machine.chooseTurnOff()
        _ = machine.writeFinished(.turnOff, succeeded: true)
        _ = machine.update(inputs(stabilization: stabilization(["ibis": "OFF"])))
        #expect(
            machine.update(inputs(videoMode: false, stabilization: stabilization(["ibis": "OFF"])))
                == [
                    .sessionEnded,
                    .writeStabilization(["ibis": "SPORT"], purpose: .restore),
                ])
        #expect(!machine.isArmed)
    }

    @Test func unidentifiedCameraNeverMatchesAPendingRestore() {
        let pending = GyroPendingRestore(
            cameraID: "nikon-model-ZR", saved: ["ibis": "SPORT"], applied: ["ibis": "OFF"])
        var machine = GyroArmingMachine(pendingRestores: [pending])
        let unidentified = GyroCameraIdentity(
            id: "nikon-model-ZR", name: "Nikon ZR", automaticRestoreEligible: false)

        #expect(machine.update(inputs(
            toggleOn: false, camera: unidentified,
            stabilization: stabilization(["ibis": "OFF"]))).isEmpty)
        #expect(machine.pendingRestores == [pending])
    }
}
