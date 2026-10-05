import Foundation
import OpenCineMotion
import Testing

/// A reference handheld reach: pan one arc from -48 through front to 225, tilt -44 to 70.
let reach = MotionBounds(pan: -48...225, tilt: -44...70)

// Moved from the app cores' GimbalProgramTests, GimbalProgramCurveTests, HeadTrackTests and
// HeadTrackNativeTests with their numbers unchanged; the vendor-wire cases stayed behind.

@Suite struct GimbalProgramTests {
    /// Raw yaw past the gap middle unwraps onto the long side; measured
    /// angles elsewhere pass through, with no invented stops.
    @Test(arguments: [
        (-150.0, 210.0), (50, 50), (90, 90), (100, 100), (-48, -48),
        (-135, 225), (-180, 180), (180, 180), (-80, -80), (-100, 260),
    ])
    func unwrapYawCrossesTheRawWrapOnThePositiveArc(raw: Double, expected: Double) {
        #expect(GimbalWaypoint.unwrapYaw(raw, in: reach) == expected)
    }

    @Test func lerpFromShortSideToSelfieNeverEntersTheGap() {
        let from = GimbalWaypoint(yawDeg: 50, pitchDeg: 0, zoom: 1)
        let to = GimbalWaypoint(yawDeg: 200, pitchDeg: 0, zoom: 1)
        for i in 0...80 {
            let yaw = GimbalPath.lerp(from, to, u: Double(i) / 80).yawDeg
            #expect(yaw <= reach.pan.upperBound + 1e-9)
            #expect(yaw >= reach.pan.lowerBound - 1e-9)
        }
    }

    @Test func durationStepsByHalfSecond() {
        #expect(GimbalProgram.steppedDuration(1.5, delta: 0.5, floor: 1.0) == 2.0)
        #expect(GimbalProgram.durationLabel(1.5) == "1.5s")
    }

    @Test func pointsSummaryAndZoomChange() {
        var program = GimbalProgram()
        #expect(program.summary == "Not set" && !program.canRun)
        program.setPoint(.a, GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 1))
        #expect(program.summary == "Partial")
        program.setPoint(.b, GimbalWaypoint(yawDeg: 30, pitchDeg: 10, zoom: 1))
        #expect(program.summary == "A·B" && program.canRun && !program.changesZoom)
        program[.c] = GimbalWaypoint(yawDeg: 30, pitchDeg: 10, zoom: 3)
        #expect(program.summary == "A·B·C" && program.changesZoom)
        #expect(GimbalProgram(durationAB: 500).durationAB == GimbalProgram.maxDuration)
    }

    @Test func clampedHoldsZoomAndNativePitch() {
        let wild = GimbalWaypoint(yawDeg: 300, pitchDeg: -90, zoom: 2, nativePitchDeg: 12)
        #expect(wild.clamped(to: reach)
            == GimbalWaypoint(yawDeg: 225, pitchDeg: -44, zoom: 2, nativePitchDeg: 12))
        #expect(GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 0.2).zoom == 1)
    }
}

@Suite struct GimbalProgramCurveTests {
    private let a = GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 1, nativePitchDeg: 175)
    private let b = GimbalWaypoint(yawDeg: 30, pitchDeg: 0, zoom: 1, nativePitchDeg: 175)
    private let c = GimbalWaypoint(yawDeg: 30, pitchDeg: 20, zoom: 1, nativePitchDeg: 155)

    private func program(_ smoothness: Double) -> GimbalProgram {
        GimbalProgram(a: a, b: b, c: c, durationAB: 3, durationBC: 2, smoothness: smoothness)
    }

    @Test func zeroIsExactAndIncreasingSmoothnessRoundsFartherFromB() {
        #expect(GimbalProgramCurve(program: program(0)) == nil)
        let tight = GimbalProgramCurve(program: program(0.2))!
        let wide = GimbalProgramCurve(program: program(1))!
        #expect(wide.position(at: 0) == a)
        #expect(wide.position(at: 5) == c)
        #expect(GimbalPath.angularDistance(wide.position(at: 3), b)
            > GimbalPath.angularDistance(tight.position(at: 3), b))
        #expect(wide.position(at: 3).yawDeg == 27.5)
        #expect(wide.position(at: 3).pitchDeg == 2.5)
        #expect(wide.samples().allSatisfy { $0 == $0.clamped(to: reach) })
    }

    @Test func angularVelocityIsContinuousAtBothBezierJoins() {
        let curve = GimbalProgramCurve(program: program(1))!
        let epsilon = 0.0001
        for time in [2.0, 4.0] {
            let left = curve.position(at: time - epsilon)
            let mid = curve.position(at: time)
            let right = curve.position(at: time + epsilon)
            #expect(abs((mid.yawDeg - left.yawDeg) / epsilon - (right.yawDeg - mid.yawDeg) / epsilon) < 0.001)
            #expect(abs((mid.pitchDeg - left.pitchDeg) / epsilon - (right.pitchDeg - mid.pitchDeg) / epsilon) < 0.001)
        }
    }

    // The engine streams the smoothed curve as 0.1 s targets and stops a stalled scheduler.
    @Test func curveStreamsThroughBAndSchedulesFinalTargetBeforeDeadline() {
        var engine = GimbalMoveEngine()
        let started = engine.start(program: program(1), live: a)
        #expect(started)
        var live = a
        var start = a
        var target = a
        var motionAt = 0.0
        var sends: [(Double, GimbalWaypoint)] = []
        for step in 1...800 {
            let now = Double(step) * 0.01
            live = GimbalMoveEngine.lerp(start, target, u: (now - motionAt) / 0.1)
            guard let out = engine.tick(dt: 0.01, live: live) else { break }
            if let next = out.target {
                #expect(out.duration == 0.1)
                sends.append((now, next))
                start = live
                target = next
                motionAt = now
            }
            if out.finished { break }
        }
        #expect(engine.failure == nil)
        #expect(engine.readout(live: live)?.phase == "DONE")
        #expect(sends.count == 99)
        if let first = sends.first, let last = sends.last {
            #expect(abs(last.0 - first.0 - 4.9) < 1e-8)
            #expect(last.1 == c)
            for pair in zip(sends, sends.dropFirst()) {
                #expect(abs(pair.1.0 - pair.0.0 - 0.05) < 1e-8)
            }
        }
        #expect(!sends.contains { $0.1 == b })
    }

    @Test func schedulerCannotSkipTheFinalCCommand() {
        var engine = GimbalMoveEngine()
        let started = engine.start(program: program(1), live: a)
        #expect(started)
        for _ in 0..<689 { _ = engine.tick(dt: 0.01, live: a) }
        let skipped = engine.tick(dt: 0.11, live: c)
        #expect(skipped?.stop == true)
        #expect(engine.failure == "Move interrupted \u{2014} waypoint dispatch was late")
    }

    @Test func curveCannotContinueAfterAStalledScheduler() {
        var engine = GimbalMoveEngine()
        let started = engine.start(program: program(1), live: a)
        #expect(started)
        for _ in 0..<200 { _ = engine.tick(dt: 0.01, live: a) }
        let late = engine.tick(dt: 0.09, live: a)
        #expect(late?.stop == true)
        #expect(late?.target == nil)
    }

    @Test func remainingKeepsTheEndAndStartsAtTheMeasuredPose() {
        let curve = GimbalProgramCurve(program: program(1))!
        let pose = GimbalWaypoint(yawDeg: 10, pitchDeg: 1, zoom: 1, nativePitchDeg: 174)
        let rest = curve.remaining(after: 1, from: pose)
        #expect(rest.position(at: 0) == pose)
        #expect(rest.position(at: rest.duration) == c)
        #expect(abs(rest.duration - 4) < 1e-9)
    }
}

@Suite struct HeadTrackTests {
    @Test func axisDialsFollowLook() {
        #expect(HeadTrack.yawDialDeg(lookRightDeg: 90) == 90)
        #expect(HeadTrack.yawDialDeg(lookRightDeg: -45) == -45)
        #expect(HeadTrack.pitchDialDeg(lookUpDeg: 0) == 90, "level look points right")
        #expect(HeadTrack.pitchDialDeg(lookUpDeg: 30) == 60, "nod up from 3 o'clock")
        #expect(HeadTrack.pitchDialDeg(lookUpDeg: -20) == 110, "nod down from 3 o'clock")
        #expect(abs(HeadTrack.yawDialDeg(lookRightDeg: 270) - -90) < 0.001)
        #expect(HeadTrack.bodyLookRightDeg(liveYawDeg: 30, originYawDeg: 10) == 20)
        #expect(
            abs(HeadTrack.bodyLookRightDeg(liveYawDeg: -170, originYawDeg: 170) - 20) < 0.001,
            "gimbal pan wraps the same as head yaw")
        #expect(HeadTrack.bodyLookUpDeg(livePitchDeg: 25, originPitchDeg: 5) == 20)
    }

    @Test func projectClampsToControllableBox() {
        let past = reach.project(lookRight: 300, lookUp: 80, yaw0: 0, pitch0: 0)
        #expect(past.yaw == reach.pan.upperBound)
        #expect(past.pitch == reach.tilt.upperBound)
        let left = reach.project(lookRight: -300, lookUp: -200, yaw0: 0, pitch0: 0)
        #expect(left.yaw == reach.pan.lowerBound)
        #expect(left.pitch == reach.tilt.lowerBound)
        #expect(reach.project(lookRight: 20, lookUp: 0, yaw0: 190, pitch0: 0).yaw == 210)
        #expect(reach.gapMidDeg == -91.5)
    }

    @Test func unwrapKeepsSpinningPast180() {
        #expect(HeadTrack.unwrap(170, previous: 160) == 170)
        #expect(HeadTrack.unwrap(-170, previous: 170) == 190)
        #expect(HeadTrack.unwrap(10, previous: 350) == 370)
    }

    @Test func noseLookNodHasNoPan() {
        let origin = HeadTrack.Quat.identity
        let nod = HeadTrack.Quat.axisAngle(x: 1, y: 0, z: 0, deg: 25)
        let look = HeadTrack.Quat.look(from: nod, origin: origin)
        #expect(abs(look.right) < 0.01, "a pure nod must not invent look-right")
        #expect(abs(look.up - 25) < 0.01)
        let pan90 = HeadTrack.Quat.axisAngle(x: 0, y: 0, z: -1, deg: 90)
        #expect(abs(HeadTrack.Quat.look(from: pan90, origin: origin).right - 90) < 0.01)
        let yawed = HeadTrack.Quat.axisAngle(x: 0, y: 0, z: -1, deg: 30)
        let nodAfter = yawed.multiply(HeadTrack.Quat.axisAngle(x: 1, y: 0, z: 0, deg: 40))
        let kept = HeadTrack.look(current: nodAfter, origin: origin)
        #expect(abs(kept.right - 30) < 1.5, "a nod must not add Euler yaw onto look-right")
        #expect(abs(kept.up - 40) < 1.5)
    }

    @Test func wrapDegFoldsAround180() {
        #expect(HeadTrack.wrapDeg(190) == -170)
        #expect(HeadTrack.wrapDeg(-190) == 170)
        #expect(abs(HeadTrack.wrapDeg(180)) == 180)
        #expect(HeadTrack.wrapDeg(20) == 20)
    }
}

@Suite struct HeadTrackNativeTests {
    private let origin = GimbalWaypoint(yawDeg: -20, pitchDeg: -10, zoom: 1, nativePitchDeg: -171)

    @Test func capturedForwardMapsHeadAnglesWithoutRateCalibration() {
        var track = HeadTrackNative(bounds: reach)
        #expect(track.center(pose: origin) == .centered)
        #expect(track.target(lookRightDeg: 0, lookUpDeg: 0) == origin)
        let point = track.target(lookRightDeg: 53, lookUpDeg: 12)
        #expect(point?.yawDeg == 33)
        #expect(point?.pitchDeg == 2)
        #expect(point?.nativePitchDeg == 177)
        #expect(HeadTrackNative.commandDuration == 0.1)
    }

    @Test func clampBodyLookBeforeMappingNativePitch() {
        var track = HeadTrackNative(bounds: reach)
        var edgeOrigin = origin
        edgeOrigin.yawDeg = 200
        #expect(track.center(pose: edgeOrigin) == .centered)
        let point = track.target(lookRightDeg: 120, lookUpDeg: 100)
        #expect(point?.yawDeg == reach.pan.upperBound)
        #expect(point?.pitchDeg == reach.tilt.upperBound)
        #expect(point?.nativePitchDeg == 109)
        #expect(track.target(lookRightDeg: 0, lookUpDeg: 0) == edgeOrigin)
    }

    @Test func hardTiltBoundsKeepObservationsHonest() {
        var track = HeadTrackNative(bounds: reach)
        #expect(track.center(pose: origin) == .centered)
        let lower = track.target(lookRightDeg: 0, lookUpDeg: -100)
        #expect(lower?.pitchDeg == -44)
        #expect(lower?.nativePitchDeg == -137)
        for pitch in [-44.1, 70.1] {
            let pose = GimbalWaypoint(yawDeg: 0, pitchDeg: pitch, zoom: 1, nativePitchDeg: -151)
            #expect(track.center(pose: pose) == .waitingForGimbal)
        }
    }

    @Test func nativePitchCrossesWrapWithoutInventingMountOffset() {
        var track = HeadTrackNative(bounds: reach)
        let mounted = GimbalWaypoint(yawDeg: 180, pitchDeg: 3, zoom: 1, nativePitchDeg: 179)
        #expect(track.center(pose: mounted) == .centered)
        #expect(track.target(lookRightDeg: 0, lookUpDeg: -2)?.nativePitchDeg == -179)
        #expect(track.target(lookRightDeg: 10, lookUpDeg: 0)?.yawDeg == 190)
    }

    @Test func lockRequiresCompleteNativePoseAndStillHead() {
        var track = HeadTrackNative(bounds: reach)
        #expect(track.center(pose: nil) == .waitingForGimbal)
        #expect(track.center(pose: GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 1)) == .waitingForGimbal)
        #expect(track.center(pose: origin, gyroYaw: 0.1) == .waitingForStill)
        #expect(track.center(pose: origin, gyroLookUp: .nan) == .waitingForStill)
        #expect(!track.isCentered)
    }

    @Test func cachedSamplesExpireWithoutChangingPose() {
        #expect(HeadTrackNative.headSampleIsFresh(measuredAt: 10, now: 10.1))
        #expect(!HeadTrackNative.headSampleIsFresh(measuredAt: 10, now: 10.201))
        #expect(!HeadTrackNative.headSampleIsFresh(measuredAt: nil, now: 10.1))
        #expect(!HeadTrackNative.headSampleIsFresh(measuredAt: 11, now: 10))
        #expect(!HeadTrackNative.headSampleIsFresh(measuredAt: .nan, now: 10))
    }

    @Test func retargetIsImmediateAndInvalidLookCannotMove() {
        var track = HeadTrackNative(bounds: reach)
        #expect(track.target(lookRightDeg: 20, lookUpDeg: 0) == nil)
        #expect(track.center(pose: origin) == .centered)
        #expect(track.target(lookRightDeg: 20, lookUpDeg: 0)?.yawDeg == 0)
        #expect(track.target(lookRightDeg: .nan, lookUpDeg: 0) == nil)
        track.reset()
        #expect(!track.isCentered && track.lastTarget == nil)
    }

    @Test func queuedOldMeasurementsAndPriorGenerationCallbacksAreRejected() {
        var gate = HeadTrackNativeSampleGate()
        let first = gate.begin()
        #expect(!gate.accepts(first, measuredAt: 10, now: 10.3))
        #expect(gate.accepts(first, measuredAt: 10.25, now: 10.3))
        gate.invalidate()
        #expect(!gate.accepts(first, measuredAt: 10.3, now: 10.3))
        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.accepts(second, measuredAt: 10.4, now: 10.4))
    }
}
