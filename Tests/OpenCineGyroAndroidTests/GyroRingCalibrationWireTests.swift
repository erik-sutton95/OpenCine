import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineGyroAndroid

/// A manual 30 Hz rig: one fixed mount rotation, camera angles the wire turns into down, and a
/// clock that only moves when a reading is fed.
private struct RingWireRig {
    static let mountAxis = GyroVector3(x: 0.3, y: -0.5, z: 0.8)
    static let mountDegrees = 37.0

    /// Rodrigues rotation, independent of the solver's basis construction.
    static func rotate(_ vector: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroVector3 {
        let length = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        let unit = GyroVector3(x: axis.x / length, y: axis.y / length, z: axis.z / length)
        let angle = degrees * .pi / 180
        let cross = GyroVector3(
            x: unit.y * vector.z - unit.z * vector.y,
            y: unit.z * vector.x - unit.x * vector.z,
            z: unit.x * vector.y - unit.y * vector.x)
        let dot = unit.x * vector.x + unit.y * vector.y + unit.z * vector.z
        let cosine = cos(angle)
        let sine = sin(angle)
        return GyroVector3(
            x: vector.x * cosine + cross.x * sine + unit.x * dot * (1 - cosine),
            y: vector.y * cosine + cross.y * sine + unit.y * dot * (1 - cosine),
            z: vector.z * cosine + cross.z * sine + unit.z * dot * (1 - cosine))
    }

    /// The phone's reading of a physical camera down through the mount rotation.
    static func phoneDown(for cameraDown: GyroVector3) -> GyroVector3 {
        rotate(cameraDown, axis: mountAxis, degrees: mountDegrees)
    }
}

/// Feeds wire observations on the same 30 Hz clock the portable ring tests use.
private struct RingWireDriver {
    let wire: GyroRingCalibrationWire
    let owner: String
    private(set) var tick = 0

    var timestamp: Double { Double(tick) / 30 }

    mutating func observe(roll: Double, pitch: Double, hasCameraLevel: Bool = true) throws
        -> [String: Any]
    {
        tick += 1
        let now = timestamp
        let cameraDown =
            hasCameraLevel
            ? GyroCameraGravity.down(rollDegrees: roll, pitchDegrees: pitch) : nil
        let phone =
            cameraDown.map { RingWireRig.phoneDown(for: $0) }
            ?? GyroVector3(x: -1, y: 0, z: 0)
        return try ringObject(
            wire.observe(
                owner: owner, phoneX: phone.x, phoneY: phone.y, phoneZ: phone.z,
                phoneTimestamp: now, hasCameraLevel: hasCameraLevel, rollDegrees: roll,
                pitchDegrees: pitch, cameraTimestamp: now))
    }

    mutating func hold(roll: Double, pitch: Double, seconds: Double) throws -> [[String: Any]] {
        var replies: [[String: Any]] = []
        for _ in 0..<Int((seconds * 30).rounded()) {
            replies.append(try observe(roll: roll, pitch: pitch))
        }
        return replies
    }
}

private func ringObject(_ text: String?) throws -> [String: Any] {
    let text = try #require(text)
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func isNull(_ value: Any?) -> Bool { value is NSNull }

@Suite("Android gyro ring calibration wire")
struct GyroRingCalibrationWireTests {
    private static let replyKeys: Set<String> = [
        "phase", "step", "inZone", "hold", "block", "invalidation", "completedSteps", "event",
        "calibration",
    ]

    @Test func observeRepliesWithPhaseAndCompletes() throws {
        let wire = GyroRingCalibrationWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        var driver = RingWireDriver(wire: wire, owner: owner)
        let startJSON = try #require(
            wire.start(owner: owner, cameraConnected: true, recording: 0))
        #expect(
            startJSON
                == #"{"block":null,"calibration":null,"completedSteps":0,"event":null,"hold":0,"invalidation":null,"inZone":false,"phase":"posing","step":0}"#
        )
        let start = try ringObject(startJSON)
        #expect(Set(start.keys) == Self.replyKeys)
        #expect(start["phase"] as? String == "posing")
        #expect(start["step"] as? Int == 0)
        #expect(start["inZone"] as? Bool == false)
        #expect(start["hold"] as? Double == 0)
        #expect(start["completedSteps"] as? Int == 0)
        #expect(isNull(start["event"]))
        #expect(isNull(start["calibration"]))

        let levelReplies = try driver.hold(roll: 0, pitch: 0, seconds: 3)
        #expect(levelReplies.compactMap { $0["event"] as? String } == ["stepCaptured"])
        let lastLevel = try #require(levelReplies.last)
        #expect(lastLevel["phase"] as? String == "posing")
        #expect(lastLevel["step"] as? Int == 1)
        #expect(lastLevel["completedSteps"] as? Int == 1)

        let tiltReplies = try driver.hold(roll: 0, pitch: 35, seconds: 3)
        #expect(tiltReplies.compactMap { $0["event"] as? String } == ["stepCaptured"])
        let lastTilt = try #require(tiltReplies.last)
        #expect(lastTilt["step"] as? Int == 2)
        #expect(lastTilt["completedSteps"] as? Int == 2)

        let mixedReplies = try driver.hold(roll: 25, pitch: 30, seconds: 3)
        #expect(mixedReplies.compactMap { $0["event"] as? String } == ["completed"])
        let completed = try #require(mixedReplies.last)
        #expect(completed["phase"] as? String == "complete")
        #expect(completed["completedSteps"] as? Int == 3)
        #expect(isNull(completed["step"]))
        #expect(isNull(completed["inZone"]))
        #expect(isNull(completed["hold"]))

        let calibrationObject = try #require(completed["calibration"] as? [String: Any])
        let calibrationData = try JSONSerialization.data(withJSONObject: calibrationObject)
        let calibration = try JSONDecoder().decode(
            GyroMountCalibration.self, from: calibrationData)
        #expect(calibration.validationErrorDegrees < 1e-6)
        #expect(abs(calibration.separationDegrees - 35) < 1e-6)
        let cameraDown = try #require(
            GyroCameraGravity.down(rollDegrees: 25, pitchDegrees: 30))
        let mapped = calibration.mapping(RingWireRig.phoneDown(for: cameraDown))
        #expect(mapped.angle(to: cameraDown) < 1e-6)
    }

    @Test func missingCameraLevelRepliesWaitingForCamera() throws {
        let wire = GyroRingCalibrationWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        _ = wire.start(owner: owner, cameraConnected: true, recording: 0)
        let missing = try ringObject(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 1,
                hasCameraLevel: false, rollDegrees: 0, pitchDegrees: 0, cameraTimestamp: 1))
        #expect(missing["phase"] as? String == "blocked")
        #expect(missing["step"] as? Int == 0)
        #expect(missing["block"] as? String == "waitingForCamera")
        #expect(isNull(missing["inZone"]))
        #expect(isNull(missing["hold"]))
        #expect(isNull(missing["invalidation"]))
        #expect(isNull(missing["event"]))
        #expect(isNull(missing["calibration"]))
        #expect(missing["completedSteps"] as? Int == 0)

        let undeterminable = try ringObject(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 2,
                hasCameraLevel: true, rollDegrees: 90, pitchDegrees: 90, cameraTimestamp: 2))
        #expect(undeterminable["block"] as? String == "waitingForCamera")
    }

    @Test func retiredOwnerReturnsNil() {
        let wire = GyroRingCalibrationWire()
        let owner = wire.create()
        wire.close(owner: owner)
        #expect(wire.start(owner: owner, cameraConnected: true, recording: 0) == nil)
        #expect(wire.updateCamera(owner: owner, connected: true, recording: 0) == nil)
        #expect(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 1,
                hasCameraLevel: true, rollDegrees: 0, pitchDegrees: 0, cameraTimestamp: 1) == nil)
        #expect(wire.invalidate(owner: owner, reason: "cameraChanged") == nil)
        #expect(wire.cancel(owner: owner) == nil)
        #expect(wire.validate(calibrationJSON: "{}") == false)
    }

    @Test func recordingMappingAndInvalidationReachTheRing() throws {
        let wire = GyroRingCalibrationWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        let unknown = try ringObject(
            wire.start(owner: owner, cameraConnected: true, recording: -1))
        #expect(unknown["phase"] as? String == "posing")
        let recording = try ringObject(
            wire.start(owner: owner, cameraConnected: true, recording: 1))
        #expect(recording["phase"] as? String == "blocked")
        #expect(recording["block"] as? String == "recording")
        let unrecognized = try ringObject(
            wire.start(owner: owner, cameraConnected: true, recording: 7))
        #expect(unrecognized["phase"] as? String == "posing")
        let disconnected = try ringObject(
            wire.start(owner: owner, cameraConnected: false, recording: 0))
        #expect(disconnected["block"] as? String == "cameraDisconnected")

        _ = wire.start(owner: owner, cameraConnected: true, recording: 0)
        var driver = RingWireDriver(wire: wire, owner: owner)
        let levelReplies = try driver.hold(roll: 0, pitch: 0, seconds: 3)
        #expect(levelReplies.last?["completedSteps"] as? Int == 1)
        let invalidated = try ringObject(
            wire.updateCamera(owner: owner, connected: true, recording: 1))
        #expect(invalidated["phase"] as? String == "invalidated")
        #expect(invalidated["invalidation"] as? String == "recordingStarted")
        #expect(isNull(invalidated["step"]))
        #expect(invalidated["completedSteps"] as? Int == 0)
        let reason = try ringObject(wire.invalidate(owner: owner, reason: "cameraChanged"))
        #expect(reason["invalidation"] as? String == "cameraChanged")
        #expect(wire.invalidate(owner: owner, reason: "nonsense") == nil)
        let cancelled = try ringObject(wire.cancel(owner: owner))
        #expect(cancelled["phase"] as? String == "intro")
        #expect(cancelled["completedSteps"] as? Int == 0)
    }
}
