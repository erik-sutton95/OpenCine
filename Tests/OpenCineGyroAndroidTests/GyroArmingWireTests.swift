import Foundation
import Testing

@testable import OpenCineGyroAndroid

@Suite("Android gyro arming wire")
struct GyroArmingWireTests {
    private func inputs(
        toggleOn: Bool = true,
        camera: Bool = true,
        hostEligible: Bool = true,
        videoMode: Bool? = true,
        recording: Bool? = false,
        stabilization: String? = #"{"values":{"ibis":"SPORT"},"lensHasVRSwitch":false}"#,
        settings: String = #"[{"key":"ibis","title":"IBIS","offValue":"OFF"}]"#,
        providesLevel: Bool = true,
        hasSavedCalibration: Bool = false
    ) -> String {
        let cameraJSON = camera ? #"{"id":"body-1","name":"Camera A"}"# : "null"
        let videoModeJSON = videoMode.map { $0 ? "true" : "false" } ?? "null"
        let recordingJSON = recording.map { $0 ? "true" : "false" } ?? "null"
        return """
            {"toggleOn":\(toggleOn),\
            "camera":\(cameraJSON),\
            "hostEligible":\(hostEligible),\
            "videoMode":\(videoModeJSON),\
            "recording":\(recordingJSON),\
            "stabilization":\(stabilization ?? "null"),\
            "settings":\(settings),\
            "providesLevel":\(providesLevel),\
            "hasSavedCalibration":\(hasSavedCalibration)}
            """
    }

    private func object(_ text: String?) throws -> [String: Any] {
        let text = try #require(text)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func effects(_ reply: [String: Any]) throws -> [[String: Any]] {
        try #require(reply["effects"] as? [[String: Any]])
    }

    @Test func effectsEncodeInOrder() throws {
        let wire = GyroArmingWire()
        let owner = wire.create(pendingRestoresJSON: "[]")
        defer { wire.close(owner: owner) }
        let startedJSON = try #require(wire.update(owner: owner, inputsJSON: inputs()))
        #expect(
            startedJSON
                == #"{"effects":[{"kind":"sessionStarted"},{"kind":"presentSetup","steps":[{"kind":"stabilization","lensHasVRSwitch":false},{"hasSavedCalibration":false,"kind":"calibration"}]}],"isArmed":true,"stabilizationWarning":false}"#
        )
        let started = try object(startedJSON)
        #expect(started["isArmed"] as? Bool == true)
        #expect(started["stabilizationWarning"] as? Bool == false)
        let startedEffects = try effects(started)
        #expect(
            startedEffects.map { $0["kind"] as? String }
                == ["sessionStarted", "presentSetup"])
        let steps = try #require(startedEffects.last?["steps"] as? [[String: Any]])
        #expect(steps.count == 2)
        #expect(steps[0]["kind"] as? String == "stabilization")
        #expect(steps[0]["lensHasVRSwitch"] as? Bool == false)
        #expect(steps[1]["kind"] as? String == "calibration")
        #expect(steps[1]["hasSavedCalibration"] as? Bool == false)

        let turnedOff = try object(wire.chooseTurnOff(owner: owner))
        let turnOffEffects = try effects(turnedOff)
        #expect(
            turnOffEffects.map { $0["kind"] as? String }
                == ["persistPendingRestores", "writeStabilization"])
        let restores = try #require(
            turnOffEffects.first?["restores"] as? [[String: Any]])
        #expect(restores.count == 1)
        #expect(restores.first?["cameraID"] as? String == "body-1")
        #expect(restores.first?["saved"] as? [String: String] == ["ibis": "SPORT"])
        #expect(restores.first?["applied"] as? [String: String] == ["ibis": "OFF"])
        #expect(turnOffEffects.last?["purpose"] as? String == "turnOff")
        #expect(turnOffEffects.last?["values"] as? [String: String] == ["ibis": "OFF"])

        let finished = try object(
            wire.writeFinished(owner: owner, purpose: "turnOff", succeeded: true))
        let finishedEffects = try effects(finished)
        #expect(finishedEffects.isEmpty)
        #expect(finished["isArmed"] as? Bool == true)
        #expect(finished["stabilizationWarning"] as? Bool == false)
    }

    @Test func pendingRestoresSurviveAWireRoundTrip() throws {
        let first = GyroArmingWire()
        let owner = first.create(pendingRestoresJSON: "[]")
        _ = first.update(owner: owner, inputsJSON: inputs())
        let turnedOff = try object(first.chooseTurnOff(owner: owner))
        _ = first.writeFinished(owner: owner, purpose: "turnOff", succeeded: true)
        first.close(owner: owner)
        let turnedOffEffects = try effects(turnedOff)
        let persisted = try #require(
            turnedOffEffects.first?["restores"] as? [[String: Any]])
        let restoresJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: persisted), as: UTF8.self)

        let second = GyroArmingWire()
        let resumed = second.create(pendingRestoresJSON: restoresJSON)
        defer { second.close(owner: resumed) }
        let restoring = try object(
            second.update(
                owner: resumed,
                inputsJSON: inputs(stabilization: #"{"values":{"ibis":"OFF"},"lensHasVRSwitch":false}"#)))
        let restoringEffects = try effects(restoring)
        #expect(restoringEffects.count == 1)
        #expect(restoringEffects.first?["kind"] as? String == "writeStabilization")
        #expect(restoringEffects.first?["purpose"] as? String == "restore")
        #expect(restoringEffects.first?["values"] as? [String: String] == ["ibis": "SPORT"])
        #expect(restoring["isArmed"] as? Bool == false)

        let restored = try object(
            second.writeFinished(owner: resumed, purpose: "restore", succeeded: true))
        let restoredEffects = try effects(restored)
        #expect(
            restoredEffects.map { $0["kind"] as? String }
                == ["persistPendingRestores", "sessionStarted", "presentSetup"])
        #expect(
            (restoredEffects.first?["restores"] as? [[String: Any]])?.isEmpty == true)
        #expect(restored["isArmed"] as? Bool == true)
    }

    @Test func malformedInputsAndUnknownPurposeReturnNil() throws {
        let wire = GyroArmingWire()
        let owner = wire.create(pendingRestoresJSON: "not json")
        defer { wire.close(owner: owner) }
        #expect(wire.update(owner: owner, inputsJSON: "") == nil)
        #expect(wire.update(owner: owner, inputsJSON: "{}") == nil)
        #expect(wire.update(owner: owner, inputsJSON: #"{"toggleOn":true}"#) == nil)
        #expect(wire.writeFinished(owner: owner, purpose: "unknown", succeeded: true) == nil)
        #expect(wire.update(owner: "not-an-owner", inputsJSON: inputs()) == nil)
        #expect(wire.chooseTurnOff(owner: "not-an-owner") == nil)
        #expect(wire.chooseKeepOn(owner: "not-an-owner") == nil)
        wire.close(owner: "not-an-owner")

        let started = try object(wire.update(owner: owner, inputsJSON: inputs()))
        let startedEffects = try effects(started)
        #expect(startedEffects.contains { $0["kind"] as? String == "writeStabilization" } == false)
        #expect(started["isArmed"] as? Bool == true)
    }

    @Test func absentLensSwitchEncodesAsNull() throws {
        let wire = GyroArmingWire()
        let owner = wire.create(pendingRestoresJSON: "[]")
        defer { wire.close(owner: owner) }
        let reply = try object(
            wire.update(
                owner: owner,
                inputsJSON: inputs(
                    stabilization: #"{"values":{"ibis":"SPORT"},"lensHasVRSwitch":null}"#)))
        let replyEffects = try effects(reply)
        let steps = try #require(replyEffects.last?["steps"] as? [[String: Any]])
        #expect(steps[0]["lensHasVRSwitch"] is NSNull)    }

    @Test func failedTurnOffReportsTheNotice() throws {
        let wire = GyroArmingWire()
        let owner = wire.create(pendingRestoresJSON: "[]")
        defer { wire.close(owner: owner) }
        _ = wire.update(owner: owner, inputsJSON: inputs())
        _ = wire.chooseTurnOff(owner: owner)
        let failed = try object(
            wire.writeFinished(owner: owner, purpose: "turnOff", succeeded: false))
        let failedEffects = try effects(failed)
        #expect(failedEffects.count == 1)
        #expect(failedEffects.first?["kind"] as? String == "notice")
        #expect(failedEffects.first?["notice"] as? String == "turnOffFailed")
        #expect(failed["stabilizationWarning"] as? Bool == true)
    }

    @Test func keepOnRaisesTheWarningWithoutAnEffect() throws {
        let wire = GyroArmingWire()
        let owner = wire.create(pendingRestoresJSON: "[]")
        defer { wire.close(owner: owner) }
        _ = wire.update(owner: owner, inputsJSON: inputs())
        let kept = try object(wire.chooseKeepOn(owner: owner))
        #expect(try effects(kept).isEmpty)
        #expect(kept["stabilizationWarning"] as? Bool == true)
    }
}
