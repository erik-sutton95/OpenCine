import Foundation
import OpenCineDJI
import OpenCineMotion
import Testing

/// OpenPocketCine#621: Pocket 3 on current firmware pushes 49-byte `0x04/0x05` attitude.
/// The `captured...` tests read the reporter's real frames from
/// `Fixtures/dji-attitude-pocket3-49.tsv`. The other frames are SYNTHETIC: built from the
/// documented offsets (native pitch `@0`, yaw `@4`, display pitch `-@20`) on top of a captured
/// 50-byte push, cut to 49 bytes for the compact layout, to reach poses the capture lacks.
@Suite struct GimbalAttitudeLayoutTests {
    /// One real 49-byte push and its expected tenths of a degree.
    struct CapturedFrame {
        var payload: [UInt8]
        var native: Int16
        var yaw: Int16
        var display: Int16
    }

    /// `Fixtures/dji-attitude-pocket3-49.tsv`, keyed by pose (`level`, `up`, `down`).
    static let captured: [String: CapturedFrame] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Fixtures/dji-attitude-pocket3-49.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var frames: [String: CapturedFrame] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 5, let native = Int16(f[2]), let yaw = Int16(f[3]),
                let display = Int16(f[4])
            else { continue }
            let hex = Array(f[1])
            let payload = stride(from: 0, to: hex.count, by: 2).compactMap {
                UInt8(String(hex[$0..<$0 + 2]), radix: 16)
            }
            frames[f[0]] = CapturedFrame(payload: payload, native: native, yaw: yaw, display: display)
        }
        return frames
    }()

    static func pose(_ payload: [UInt8]) -> GimbalWaypoint? {
        GimbalWaypoint.from(
            yawTenth: GimbalStick.yawTenthDeg(payload), pitchTenth: GimbalStick.pitchTenthDeg(payload),
            zoom: 1, nativePitchTenth: GimbalStick.nativePitchTenthDeg(payload))
    }

    @Test func capturedCompactFramesDecode() throws {
        #expect(Self.captured.keys.sorted() == ["down", "level", "up"])
        for (name, frame) in Self.captured {
            #expect(frame.payload.count == 49, "\(name)")
            #expect(GimbalStick.AttitudeLayout(frame.payload) == .pocket3Compact)
            #expect(GimbalStick.nativePitchTenthDeg(frame.payload) == frame.native)
            #expect(GimbalStick.yawTenthDeg(frame.payload) == frame.yaw)
            #expect(GimbalStick.pitchTenthDeg(frame.payload) == frame.display)
            #expect(frame.payload[40...].allSatisfy { $0 == 0 }, "bytes 40-48 are unused zeros")
            #expect(WorldLevel.attitude(frame.payload) != nil, "unit quaternion at @24")
            let pose = try #require(Self.pose(frame.payload))
            #expect(pose.yawDeg == Double(frame.yaw) / 10 + 360, "yaw -168° unwraps past selfie")
        }
        let level = try #require(Self.captured["level"]), up = try #require(Self.captured["up"])
        let down = try #require(Self.captured["down"])
        #expect((level.native, level.yaw, level.display) == (-1769, -1682, -7))
        #expect((up.native, up.yaw, up.display) == (1719, -1682, 100))
        #expect((down.native, down.yaw, down.display) == (-1695, -1681, -90))
    }

    /// The capture's look-up crosses the wrap: native −176.9° at level reads +171.9° tilted up,
    /// which is −188.1° on the calibration side. Look-down raises native to −169.5°.
    @Test func capturedPosesKeepHeadTrackTargetsOnTheCalibrationSide() throws {
        let level = try #require(Self.captured["level"]), up = try #require(Self.captured["up"])
        let down = try #require(Self.captured["down"])
        let calibration = try #require(Self.pose(level.payload))
        let wire = try #require(GimbalStick.AttitudeLayout(level.payload)).nativePitch
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let upMeasured = try #require(wire.target(Double(up.native) / 10, around: -176.9))
        #expect(abs(upMeasured - -188.1) < 1e-9, "continuous up pose is below −180°")
        let downMeasured = try #require(wire.target(Double(down.native) / 10, around: -176.9))
        #expect(abs(downMeasured - -169.5) < 1e-9)

        for (frame, measured) in [(up, upMeasured), (down, downMeasured)] {
            let live = try #require(Self.pose(frame.payload))
            let lookUp = Double(frame.display - level.display) / 10
            let targetLook = track.target(lookRightDeg: 0, lookUpDeg: lookUp)
            let target = try #require(targetLook)
            let native = try #require(target.nativePitchDeg)
            #expect(abs(native - measured) < 1, "head target agrees with the camera's own reading")
            let sent = Self.nativeTenths(Commands.gimbalTimedTarget(
                waypoint: target, live: live, nativePitch: wire,
                duration: HeadTrackNative.commandDuration))
            #expect(sent == Int16((native * 10).rounded()))
        }
        // Up (+10.7° of look) goes out as −187.6°, never +172.4° on the far side of −180°.
        let upLook = track.target(lookRightDeg: 0, lookUpDeg: 10.7)
        let upTarget = try #require(upLook)
        let upLive = try #require(Self.pose(up.payload))
        #expect(Self.nativeTenths(Commands.gimbalTimedTarget(
            waypoint: upTarget, live: upLive, nativePitch: wire,
            duration: HeadTrackNative.commandDuration)) == -1876)
        #expect(Self.nativeTenths(Commands.gimbalTimedTarget(
            waypoint: upTarget, live: upLive, nativePitch: .wrapped,
            duration: HeadTrackNative.commandDuration)) == 1724, "the old wrapped encoding")
        let centreLook = track.target(lookRightDeg: 0, lookUpDeg: 0)
        #expect(centreLook?.nativePitchDeg == -176.9, "return to centre is the calibration point")
    }

    /// Bytes 24-39 decode with the 50-byte quaternion offsets: unit norm, and the world tilt
    /// follows the display pitch (about 2° below it on this capture, which three frames cannot
    /// explain; the 50-byte fit was within 0.5°).
    @Test func capturedQuaternionFollowsTheDisplayPitch() throws {
        var tilts: [String: Double] = [:]
        for (name, frame) in Self.captured {
            var reading = LevelReading()
            reading.ingest(frame.payload, now: 1)
            let tilt = try #require(reading.pitchDeg(now: 1))
            #expect(abs(tilt - Double(frame.display) / 10) < 2.5, "\(name) \(tilt)")
            tilts[name] = tilt
        }
        let level = try #require(tilts["level"]), up = try #require(tilts["up"])
        let down = try #require(tilts["down"])
        #expect(abs((up - level) - 10.7) < 1 && abs((down - level) - -8.3) < 1)
    }

    /// Level from the captured poses lands on the reference's side; the old wrap sent the
    /// tilted-down Pocket 3 to +180.0° from −169.5°.
    @Test func capturedPosesLevelBesideTheirNativePitch() throws {
        for (name, continuous, wrapped) in [("up", Int16(1800), Int16(-1800)), ("down", -1800, 1800)] {
            let frame = try #require(Self.captured[name])
            var reading = LevelReading()
            reading.ingest(frame.payload, now: 1)
            let tilt = try #require(reading.pitchDeg(now: 1))
            let pose = try #require(Self.pose(frame.payload))
            let wire = try #require(GimbalStick.AttitudeLayout(frame.payload)).nativePitch
            let plan = try #require(WorldLevelSnap.plan(tiltDeg: tilt, pose: pose, now: 1, nativePitch: wire))
            #expect(Self.nativeTenths(plan.frame) == continuous, "\(name)")
            let old = try #require(WorldLevelSnap.plan(tiltDeg: tilt, pose: pose, now: 1))
            #expect(Self.nativeTenths(old.frame) == wrapped, "\(name)")
        }
    }

    /// Captured 50-byte push (2026-09-12 reliability logs): native 180.0°, yaw 0, display 0.
    static let captured50: [UInt8] = {
        let hex =
            "0807000000008600000000020219CD05B3C5000000000200AA10D73532D7763F15BB873E1FB8B43600000000010000000000"
        return stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }()

    /// SYNTHETIC attitude with the given angles in tenths of a degree.
    static func attitude(native: Int16, yaw: Int16, pitch: Int16, count: Int) -> [UInt8] {
        var bytes = captured50
        func put(_ value: Int16, at offset: Int) {
            let bits = UInt16(bitPattern: value)
            bytes[offset] = UInt8(bits & 0xFF)
            bytes[offset + 1] = UInt8(bits >> 8)
        }
        put(native, at: 0)
        put(yaw, at: 4)
        put(0 &- pitch, at: 20)
        if count <= bytes.count { return Array(bytes.prefix(count)) }
        return bytes + [UInt8](repeating: 0, count: count - bytes.count)
    }

    static func nativeTenths(_ frame: Duml.Frame?) -> Int16? {
        frame.flatMap { GimbalStick.i16LE($0.payload, at: 4) }
    }

    @Test func compactFramesParseYawAndPitchLikeTheFullLayout() {
        let compact = Self.attitude(native: 1744, yaw: -123, pitch: 56, count: 49)
        let full = Self.attitude(native: 1744, yaw: -123, pitch: 56, count: 50)
        #expect(GimbalStick.AttitudeLayout(compact) == .pocket3Compact)
        #expect(GimbalStick.AttitudeLayout(full) == .full)
        for payload in [compact, full] {
            #expect(GimbalStick.isAttitude(payload))
            #expect(GimbalStick.yawTenthDeg(payload) == -123)
            #expect(GimbalStick.pitchTenthDeg(payload) == 56)
            #expect(GimbalStick.nativePitchTenthDeg(payload) == 1744)
            #expect(GimbalStick.rotated180(payload) == false)
            let pose = GimbalWaypoint.from(
                yawTenth: GimbalStick.yawTenthDeg(payload),
                pitchTenth: GimbalStick.pitchTenthDeg(payload), zoom: 1,
                nativePitchTenth: GimbalStick.nativePitchTenthDeg(payload))
            #expect(pose == GimbalWaypoint(yawDeg: -12.3, pitchDeg: 5.6, zoom: 1, nativePitchDeg: 174.4))
        }
        var mapping = GimbalStickMapping()
        mapping.applyAttitude(compact)
        #expect(mapping.yawTenthDeg == -123 && mapping.pitchTenthDeg == 56)
        #expect(GimbalStick.AttitudeLayout.pocket3Compact.nativePitch == .continuous)
        #expect(GimbalStick.AttitudeLayout.full.nativePitch == .wrapped)
    }

    @Test(arguments: [0, 22, 40, 48, 51, 52, 64])
    func otherLengthsStillFailClosed(count: Int) {
        let payload = Self.attitude(native: 1744, yaw: 300, pitch: 56, count: count)
        #expect(GimbalStick.AttitudeLayout(payload) == nil)
        #expect(!GimbalStick.isAttitude(payload))
        #expect(GimbalStick.yawTenthDeg(payload) == nil)
        #expect(GimbalStick.pitchTenthDeg(payload) == nil)
        #expect(GimbalStick.nativePitchTenthDeg(payload) == nil)
        #expect(GimbalStick.rotated180(payload) == nil)
        var mapping = GimbalStickMapping(yawTenthDeg: 5, pitchTenthDeg: 7)
        mapping.applyAttitude(payload)
        #expect(mapping.yawTenthDeg == 5 && mapping.pitchTenthDeg == 7)
    }

    /// The reporter's journal: calibrated at native +174.4°, a 9° look-down went out as −176.6°
    /// and the gimbal ran the long way into its limit. A +181.9° probe moved 1.8° as asked.
    @Test func headTrackNearTheWrapStaysOnTheCalibrationSide() throws {
        let payload = Self.attitude(native: 1744, yaw: 0, pitch: 56, count: 49)
        let layout = try #require(GimbalStick.AttitudeLayout(payload))
        let calibration = try #require(GimbalWaypoint.from(
            yawTenth: GimbalStick.yawTenthDeg(payload), pitchTenth: GimbalStick.pitchTenthDeg(payload),
            zoom: 1, nativePitchTenth: GimbalStick.nativePitchTenthDeg(payload)))
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)

        func sent(lookUp: Double, live: GimbalWaypoint = calibration) -> Int16? {
            guard let target = track.target(lookRightDeg: 0, lookUpDeg: lookUp) else { return nil }
            return Self.nativeTenths(Commands.gimbalTimedTarget(
                waypoint: target, live: live, nativePitch: layout.nativePitch,
                duration: HeadTrackNative.commandDuration))
        }
        #expect(sent(lookUp: -9) == 1834, "+183.4°, not −176.6°")
        #expect(sent(lookUp: -2) == 1764)
        #expect(sent(lookUp: 5) == 1694)
        // The gimbal has crossed and now reports −178.3°: the target stays on the calibration side.
        var crossed = calibration
        crossed.nativePitchDeg = -178.3
        crossed.pitchDeg = -2.1
        #expect(sent(lookUp: -9, live: crossed) == 1834)
        #expect(sent(lookUp: 0) == 1744, "return to centre is the calibration point")

        // Hard tilt bounds cap the offset inside the reach, on the same side: tilt −44° is
        // native +224.0°, tilt +70° is native +110.0°.
        let lowest = try #require(sent(lookUp: -100))
        #expect(lowest == 2240)
        #expect(sent(lookUp: 0) == 1744, "head look unwraps, so return before the opposite stop")
        let highest = try #require(sent(lookUp: 100))
        #expect(highest == 1100)
        for value in [lowest, highest] {
            #expect(abs(Double(value) / 10 - 174.4) <= GimbalNativePitchWire.maxOffsetDeg)
        }
    }

    /// The full layout keeps its wire: the same calibration still sends wrapped targets.
    @Test func fullLayoutHeadTrackBytesAreUnchanged() throws {
        let payload = Self.attitude(native: 1744, yaw: 0, pitch: 56, count: 50)
        let layout = try #require(GimbalStick.AttitudeLayout(payload))
        let calibration = GimbalWaypoint(yawDeg: 0, pitchDeg: 5.6, zoom: 1, nativePitchDeg: 174.4)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        for (lookUp, tenths) in [(-9.0, Int16(-1766)), (-2, 1764), (5, 1694), (0, 1744)] {
            let targetLook = track.target(lookRightDeg: 0, lookUpDeg: lookUp)
            let target = try #require(targetLook)
            let frame = Commands.gimbalTimedTarget(
                waypoint: target, live: calibration, nativePitch: layout.nativePitch,
                duration: HeadTrackNative.commandDuration)
            #expect(Self.nativeTenths(frame) == tenths)
            var wrapped = target
            wrapped.nativePitchDeg = GimbalPath.wrapAngle(try #require(target.nativePitchDeg))
            #expect(frame?.payload == Commands.gimbalTimedTarget(
                waypoint: wrapped, duration: HeadTrackNative.commandDuration)?.payload)
        }
    }

    @Test func continuousTargetsStopWhenTheReferenceOrLivePoseIsImplausible() {
        let wire = GimbalNativePitchWire.continuous
        func near(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 1e-9 } == true
        }
        #expect(near(wire.target(-176.6, around: 174.4), 183.4))
        #expect(near(wire.target(169.4, around: 174.4), 169.4))
        #expect(near(wire.target(-178.3, around: 174.4), 181.7))
        #expect(wire.target(0, around: 174.4) == nil, "174° from the reference is outside the reach")
        #expect(wire.target(10, around: 190) == nil, "a reference is a reported ±180° pitch")
        #expect(wire.target(10, around: .nan) == nil)
        #expect(wire.wireDeg(183.4, live: -178.3) == 183.4)
        #expect(wire.wireDeg(183.4, live: 20) == nil, "the gimbal is not near the target")
        #expect(wire.wireDeg(183.4, live: 200) == nil)
        #expect(wire.wireDeg(400, live: 179) == nil)
        #expect(GimbalNativePitchWire.wrapped.wireDeg(183.4, live: 174.4).map { ($0 * 10).rounded() } == -1766)
        #expect(GimbalNativePitchWire.wrapped.target(-176.6, around: 174.4) == -176.6)
        // The command keeps the wrapped range unless the gimbal reads continuous targets.
        #expect(Commands.gimbalTimedTarget(yawDeg: 0, nativePitchDeg: 183.4, duration: 0.1) == nil)
        #expect(Commands.gimbalTimedTarget(
            yawDeg: 0, nativePitchDeg: 183.4, duration: 0.1, nativePitch: .continuous) != nil)
    }

    /// Programmed moves plan wrapped native targets from the pose at Start; a continuous gimbal
    /// gets them beside that reference.
    @Test func programmedTargetsAreSentBesideTheStartReference() throws {
        let start = GimbalWaypoint(yawDeg: 0, pitchDeg: 5.6, zoom: 1, nativePitchDeg: 174.4)
        let program = GimbalProgram(
            a: start, b: GimbalWaypoint(yawDeg: 30, pitchDeg: -10, zoom: 1, nativePitchDeg: 0),
            durationAB: 2)
        let planned = GimbalMoveEngine.planFromLive(program, live: start)
        let b = try #require(planned.b)
        #expect(b.nativePitchDeg.map { abs($0 - -170) < 1e-9 } == true, "shared plan wraps")
        let mid = GimbalMoveEngine.lerp(start, b, u: 0.5)
        for (target, continuous, wrapped) in [(b, Int16(1900), Int16(-1700)), (mid, 1822, -1778)] {
            #expect(Self.nativeTenths(Commands.gimbalTimedTarget(
                waypoint: target, live: start, nativePitch: .continuous, reference: 174.4,
                duration: 2)) == continuous)
            #expect(Self.nativeTenths(Commands.gimbalTimedTarget(
                waypoint: target, live: start, nativePitch: .wrapped, reference: 174.4,
                duration: 2)) == wrapped)
            #expect(Commands.gimbalTimedTarget(
                waypoint: target, live: start, nativePitch: .wrapped, reference: 174.4,
                duration: 2)?.payload == Commands.gimbalTimedTarget(waypoint: target, duration: 2)?.payload)
        }
        #expect(Commands.gimbalTimedTarget(
            waypoint: b, live: start, nativePitch: .continuous, reference: 250, duration: 2) == nil)
    }

    @Test func levelPlansBesideTheLiveNativePitch() throws {
        // Display tilt +6° at native +177°: the horizon is a 6° look-down, native +183°.
        let pose = GimbalWaypoint(yawDeg: 0, pitchDeg: 6, zoom: 1, nativePitchDeg: 177)
        let continuous = try #require(
            WorldLevelSnap.plan(tiltDeg: 6, pose: pose, now: 0, nativePitch: .continuous))
        #expect(Self.nativeTenths(continuous.frame) == 1830)
        let wrapped = try #require(WorldLevelSnap.plan(tiltDeg: 6, pose: pose, now: 0))
        #expect(Self.nativeTenths(wrapped.frame) == -1770)
        #expect(continuous.snap == wrapped.snap)
        var far = pose
        far.nativePitchDeg = 200
        #expect(WorldLevelSnap.plan(tiltDeg: 6, pose: far, now: 0, nativePitch: .continuous) == nil)
    }
}
