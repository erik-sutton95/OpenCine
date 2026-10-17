import Insta360Apple
import Insta360Protocol
import OpenCineCore
import OpenCineMotion
import XCTest

/// The Luna gimbal requests on the session's control path, and the shared motion service over them.
@MainActor
final class LunaMotionServiceTests: XCTestCase {
    @MainActor private final class Wire {
        var sent: [(request: LunaRequest, timeout: Duration?)] = []
        var reply: (LunaRequest) throws -> Data = { _ in Data() }
        var pauses: [Duration] = []
    }

    private func service(_ wire: Wire, ready: Bool = true) -> (LunaMotionService, LunaCameraSession)
    {
        let session = LunaCameraSession(
            send: {
                wire.sent.append(($0, nil))
                return try wire.reply($0)
            },
            sendWithin: {
                wire.sent.append(($0, $1))
                return try wire.reply($0)
            },
            functionMode: { LunaFunctionMode.normalVideo.rawValue },
            readSettings: {}, readCapture: {})
        if ready { session.linkChanged(.streaming, serial: "LUNA-TEST") }
        let motion = LunaMotionService(
            session: { session },
            sleep: { duration in
                await MainActor.run { wire.pauses.append(duration) }
                try await Task.sleep(for: .milliseconds(1))
            })
        return (motion, session)
    }

    private func settle(until predicate: () -> Bool) async {
        for _ in 0..<500 where !predicate() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func testHeldStickRepeatsRoundedMoveEveryIntervalUntilTheHoldEnds() async throws {
        let wire = Wire()
        let (motion, _) = service(wire)
        motion.hold(pan: 0.25, tilt: -1)
        let pushed = try LunaProtocol.gimbalMove(upDown: -99, leftRight: 25)
        await settle { wire.sent.count >= 3 }
        XCTAssertTrue(
            wire.sent.prefix(3).allSatisfy { $0.request == pushed && $0.timeout == .seconds(2) })
        XCTAssertTrue(wire.pauses.allSatisfy { $0 == LunaMotionService.stickInterval })

        motion.hold(pan: 0, tilt: 0)
        let rest = try LunaProtocol.gimbalMove(upDown: 0, leftRight: 0)
        await settle { wire.sent.last?.request == rest }
        XCTAssertEqual(
            wire.sent.last?.timeout, .seconds(2), "a held stick at rest keeps repeating MOVE")
        motion.endHold()
        XCTAssertFalse(motion.isHeld)
        let count = wire.sent.count
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertLessThanOrEqual(wire.sent.count, count + 1, "at most the MOVE already in flight")
    }

    /// OPENINSTACINE-IOS-3: a slow gamepad deflection past the deadzone rounded to MOVE 0, 0,
    /// which Luna reads as the release request, so the head stopped mid-move.
    func testAKeptSlowDeflectionNeverRoundsToTheReleaseSpeed() async throws {
        let wire = Wire()
        let (motion, _) = service(wire)
        motion.hold(pan: 0.004, tilt: -0.004)
        let slow = try LunaProtocol.gimbalMove(upDown: -1, leftRight: 1)
        await settle { !wire.sent.isEmpty }
        XCTAssertEqual(wire.sent.first?.request, slow)
        motion.endHold()
    }

    func testSingleRequestsUseTheirTimeouts() async throws {
        let wire = Wire()
        let (motion, _) = service(wire)
        let steered = await motion.steer(pan: 12, tilt: -3)
        XCTAssertTrue(steered)
        let r1 = await motion.release()
        XCTAssertTrue(r1)
        let r2 = await motion.recenter()
        XCTAssertTrue(r2)
        let r3 = await motion.flip()
        XCTAssertTrue(r3)
        XCTAssertEqual(
            wire.sent.map(\.request),
            [
                try LunaProtocol.gimbalMove(upDown: -3, leftRight: 12),
                try LunaProtocol.gimbalReleaseRequest(),
                try LunaProtocol.gimbalRecenterRequest(),
                try LunaProtocol.gimbalFlipRequest(),
            ])
        XCTAssertEqual(wire.sent.map(\.timeout), [.seconds(2), nil, nil, nil])
    }

    func testAimWrapsYawAndKeepsPitchInsideTheDeclaredReach() async throws {
        let wire = Wire()
        let (motion, _) = service(wire)
        let aimed = await motion.aim(at: GimbalWaypoint(yawDeg: 270, pitchDeg: 120, zoom: 1))
        XCTAssertTrue(aimed)
        XCTAssertEqual(
            wire.sent.last?.request, try LunaProtocol.gimbalSetAngle(pitch: 90, yaw: -90))
        XCTAssertEqual(wire.sent.last?.timeout, .seconds(2))
    }

    func testAngleReadUpdatesTheLatestPoseAndPosesStartUnknown() async throws {
        struct NoAnswer: Error {}
        let wire = Wire()
        let (motion, _) = service(wire)
        // The stream keeps only the newest pose, so the camera answers once `.unknown` was read.
        wire.reply = { _ in throw NoAnswer() }
        var poses = await motion.poses().makeAsyncIterator()
        let first = await poses.next()
        XCTAssertNil(first?.value, "unknown until the camera answers GET_ANGLE")
        wire.reply = { request in
            guard request == (try? LunaProtocol.gimbalGetAngleRequest()),
                let pitch = try? ProtoMessage.float(field: 3, value: -12.5),
                let yaw = try? ProtoMessage.float(field: 4, value: 33)
            else { return Data() }
            return pitch + yaw
        }
        let reading = await poses.next()
        XCTAssertEqual(reading?.value?.pitchDeg, -12.5)
        XCTAssertEqual(reading?.value?.yawDeg, 33)
        XCTAssertEqual(reading?.origin, .cameraReported)
        XCTAssertEqual(wire.sent.first?.timeout, .seconds(1))
        let pose = try XCTUnwrap(reading)
        XCTAssertNotNil(motion.capabilities.feedback(pose, at: MonotonicInstant.now()))
        XCTAssertEqual(motion.latestPose.value, pose.value)
    }

    func testSharedServiceMapsOntoTheLunaRequests() async throws {
        let wire = Wire()
        let (motion, _) = service(wire)
        let held = await motion.stick(pan: 1, tilt: 0)
        XCTAssertTrue(held)
        XCTAssertTrue(motion.isHeld)
        let rested = await motion.stick(pan: 0, tilt: 0)
        XCTAssertTrue(rested)
        XCTAssertFalse(motion.isHeld, "zero on both axes releases")
        XCTAssertEqual(wire.sent.last?.request, try LunaProtocol.gimbalReleaseRequest())
        XCTAssertNil(wire.sent.last?.timeout)

        let target = try XCTUnwrap(
            motion.capabilities.target(GimbalWaypoint(yawDeg: 10, pitchDeg: 5, zoom: 1)))
        let before = wire.sent.count
        let timed = await motion.move(to: target, over: .seconds(2))
        XCTAssertFalse(timed, "Luna has no timed SET")
        XCTAssertEqual(wire.sent.count, before)
        let moved = await motion.move(to: target, over: nil)
        XCTAssertTrue(moved)
        XCTAssertEqual(wire.sent.last?.request, try LunaProtocol.gimbalSetAngle(pitch: 5, yaw: 10))
        let r4 = await motion.stop()
        XCTAssertTrue(r4)
        XCTAssertEqual(wire.sent.last?.request, try LunaProtocol.gimbalReleaseRequest())
    }

    func testNothingGoesOutWithoutAReadyOwnedSession() async throws {
        let wire = Wire()
        let (motion, _) = service(wire, ready: false)
        let refused = await motion.stick(pan: 1, tilt: 0)
        XCTAssertFalse(refused)
        let r5 = await motion.recenter()
        XCTAssertFalse(r5)
        let r6 = await motion.readAngle()
        XCTAssertNil(r6)
        motion.endHold()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(wire.sent.isEmpty)
    }

    func testArrivalIsWithinHalfADegreeOnEachAxisAcrossTheWrap() {
        let target = GimbalWaypoint(yawDeg: 200, pitchDeg: 10, zoom: 1)
        XCTAssertTrue(LunaMotionService.hasReached(LunaGimbalAngle(pitch: 10.4, yaw: -160.4), target))
        XCTAssertFalse(LunaMotionService.hasReached(LunaGimbalAngle(pitch: 10.6, yaw: -160), target))
        XCTAssertFalse(LunaMotionService.hasReached(LunaGimbalAngle(pitch: 10, yaw: -159.4), target))
    }

    func testHeadTrackSteeringFeedsRatePullsAngleAndModelsTheStick() {
        let tuning = LunaHeadTrackSteering.Tuning()
        var steering = LunaHeadTrackSteering(now: 0)
        // Still camera, head 10° right moving 15 deg/s: 15 + 4 × 10 = 55 deg/s, 73 units.
        let head = HeadTrack.Reference(yaw: 10, pitch: 120, yawRate: 15)
        let first = steering.step(yaw: 0, pitch: 0, readAt: 0, toward: head, now: 0, tuning: tuning)
        XCTAssertEqual(first.pan, 73)
        XCTAssertEqual(first.wantPitch, 90, "pitch stays inside the Luna's tilt reach")
        XCTAssertEqual(first.tilt, 99, "the stick clamps to ±99")
        // One lag later the modelled rate is 1 - 1/e of the stick's; GET_ANGLE is carried on by it.
        steering.sent(pan: 73, tilt: 0, now: 0.23, tuning: tuning)
        let rate = 73 * 0.75 * (1 - exp(-1))
        let second = steering.step(yaw: 0, pitch: 0, readAt: 0.2, toward: head, now: 0.23, tuning: tuning)
        XCTAssertEqual(second.yaw, rate * (0.03 + 0.015), accuracy: 1e-9)
        XCTAssertEqual(second.pitch, 0)
        XCTAssertEqual(
            second.pan, Int32(((15 + 4 * (10 - second.yaw)) / 0.75).rounded()))
    }
}
