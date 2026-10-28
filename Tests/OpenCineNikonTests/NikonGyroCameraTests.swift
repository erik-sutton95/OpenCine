import Foundation
import Testing

@testable import OpenCineNikon

@Suite struct NikonGyroCameraTests {
    @Test func stabilizationReadsBothValues() {
        let state = NikonGyroCamera.stabilization(
            from: PTPCameraPropertySnapshot(vibrationReduction: "SPORT", electronicVR: "ON"))

        #expect(state?.values == ["movieVR": "SPORT", "electronicVR": "ON"])
        #expect(state?.lensHasVRSwitch == nil)
        #expect(state?.isOff(NikonGyroCamera.settings) == false)
    }

    @Test func unknownValuesAreNil() {
        #expect(NikonGyroCamera.stabilization(from: PTPCameraPropertySnapshot()) == nil)
    }

    @Test func writesRestoreExactLabels() throws {
        let writes = NikonGyroCamera.writes(
            for: ["movieVR": "SPORT", "electronicVR": "ON"])
        let movieVR = try #require(PTPCameraPropertyWrite.vibrationReduction(label: "SPORT"))

        #expect(writes == [movieVR, PTPCameraPropertyWrite.electronicVR(on: true)])
    }

    @Test func unknownKeysAndLabelsAreDropped() {
        let writes = NikonGyroCamera.writes(
            for: ["unknown": "OFF", "movieVR": "invalid", "electronicVR": "invalid"])

        #expect(writes.isEmpty)
    }

    @Test func levelWithoutPitchIsNoReading() {
        let noPitch = PTPLevelAngles(roll: 0, pitch: 0, yaw: 0, hasPitch: false)

        #expect(NikonGyroCamera.cameraDown(from: noPitch) == nil)
        #expect(NikonGyroCamera.cameraDown(from: nil) == nil)
    }

    @Test func levelMapsThroughGyroCameraGravity() throws {
        let down = try #require(
            NikonGyroCamera.cameraDown(from: PTPLevelAngles(roll: 0, pitch: 0, yaw: 0)))

        #expect(down.x == -1)
        #expect(down.y == 0)
        #expect(down.z == 0)
    }

    @Test func identityPrefersTheSerial() {
        let native = nativeIdentity(serialNumber: "123", model: "ZR")
        let identified = NikonGyroCamera.identity(native)

        #expect(identified.id == "nikon-123")
        #expect(identified.automaticRestoreEligible)
        #expect(identified.name == native.displayName)
        let unidentified = NikonGyroCamera.identity(nativeIdentity(serialNumber: "", model: "ZR"))
        #expect(unidentified.id == "nikon-model-ZR")
        #expect(!unidentified.automaticRestoreEligible)
    }

    @Test func videoModeFollowsTheSelector() {
        #expect(NikonGyroCamera.videoMode(from: PTPCameraPropertySnapshot(captureSelector: .video)) == true)
        #expect(NikonGyroCamera.videoMode(from: PTPCameraPropertySnapshot(captureSelector: .photo)) == false)
        #expect(NikonGyroCamera.videoMode(from: PTPCameraPropertySnapshot()) == nil)
    }

    private func nativeIdentity(
        serialNumber: String, model: String
    ) -> NativeCameraIdentity {
        NativeCameraIdentity(
            host: "192.168.1.2", cameraName: model, manufacturer: "Nikon", model: model,
            deviceVersion: "1.0", serialNumber: serialNumber, establishmentSummary: "SIMULATED")
    }
}
