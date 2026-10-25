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

    static let levelDown = GyroVector3(x: -1, y: 0, z: 0)

    /// A camera pose tilted up from level by the given degrees.
    static func tiltedDown(degrees: Double) -> GyroVector3 {
        rotate(levelDown, axis: GyroVector3(x: 0, y: 1, z: 0), degrees: degrees)
    }

    /// The third pose: tilted up, then leaned about the optical axis.
    static func mixedDown() -> GyroVector3 {
        rotate(tiltedDown(degrees: 30), axis: GyroVector3(x: 0, y: 0, z: 1), degrees: 25)
    }
}

/// Feeds wire observations on the same 30 Hz clock the portable ring tests use.
private struct RingWireDriver {
    let wire: GyroRingCalibrationWire
    let owner: String
    private(set) var tick = 0

    var timestamp: Double { Double(tick) / 30 }

    mutating func observe(cameraDown: GyroVector3?) throws -> [String: Any] {
        tick += 1
        let now = timestamp
        let phone =
            cameraDown.map { RingWireRig.phoneDown(for: $0) } ?? RingWireRig.levelDown
        return try ringObject(
            wire.observe(
                owner: owner, phoneX: phone.x, phoneY: phone.y, phoneZ: phone.z,
                phoneTimestamp: now, hasCameraLevel: cameraDown != nil,
                cameraX: cameraDown?.x ?? 0, cameraY: cameraDown?.y ?? 0,
                cameraZ: cameraDown?.z ?? 0, cameraTimestamp: now))
    }

    mutating func hold(_ cameraDown: GyroVector3, seconds: Double) throws -> [[String: Any]] {
        var replies: [[String: Any]] = []
        for _ in 0..<Int((seconds * 30).rounded()) {
            replies.append(try observe(cameraDown: cameraDown))
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

        let levelReplies = try driver.hold(RingWireRig.levelDown, seconds: 3)
        #expect(levelReplies.compactMap { $0["event"] as? String } == ["stepCaptured"])
        let lastLevel = try #require(levelReplies.last)
        #expect(lastLevel["phase"] as? String == "posing")
        #expect(lastLevel["step"] as? Int == 1)
        #expect(lastLevel["completedSteps"] as? Int == 1)

        let tiltReplies = try driver.hold(RingWireRig.tiltedDown(degrees: 35), seconds: 3)
        #expect(tiltReplies.compactMap { $0["event"] as? String } == ["stepCaptured"])
        let lastTilt = try #require(tiltReplies.last)
        #expect(lastTilt["step"] as? Int == 2)
        #expect(lastTilt["completedSteps"] as? Int == 2)

        let mixedReplies = try driver.hold(RingWireRig.mixedDown(), seconds: 3)
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
        let mixedDown = RingWireRig.mixedDown()
        let mapped = calibration.mapping(RingWireRig.phoneDown(for: mixedDown))
        #expect(mapped.angle(to: mixedDown) < 1e-6)
    }

    @Test func missingOrInvalidCameraLevelRepliesWaitingForCamera() throws {
        let wire = GyroRingCalibrationWire()
        let owner = wire.create()
        defer { wire.close(owner: owner) }
        _ = wire.start(owner: owner, cameraConnected: true, recording: 0)
        let missing = try ringObject(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 1,
                hasCameraLevel: false, cameraX: 0, cameraY: 0, cameraZ: 0,
                cameraTimestamp: 1))
        #expect(missing["phase"] as? String == "blocked")
        #expect(missing["step"] as? Int == 0)
        #expect(missing["block"] as? String == "waitingForCamera")
        #expect(isNull(missing["inZone"]))
        #expect(isNull(missing["hold"]))
        #expect(isNull(missing["invalidation"]))
        #expect(isNull(missing["event"]))
        #expect(isNull(missing["calibration"]))
        #expect(missing["completedSteps"] as? Int == 0)

        let zeroLength = try ringObject(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 2,
                hasCameraLevel: true, cameraX: 0, cameraY: 0, cameraZ: 0, cameraTimestamp: 2))
        #expect(zeroLength["block"] as? String == "waitingForCamera")

        let notFinite = try ringObject(
            wire.observe(
                owner: owner, phoneX: -1, phoneY: 0, phoneZ: 0, phoneTimestamp: 3,
                hasCameraLevel: true, cameraX: -1, cameraY: .nan, cameraZ: 0,
                cameraTimestamp: 3))
        #expect(notFinite["block"] as? String == "waitingForCamera")
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
                hasCameraLevel: true, cameraX: -1, cameraY: 0, cameraZ: 0,
                cameraTimestamp: 1) == nil)
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
        let levelReplies = try driver.hold(RingWireRig.levelDown, seconds: 3)
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
