import OpenCineMotion
import Testing

@Suite struct GimbalOverlayMotionTests {
    private func point(_ yaw: Double, _ pitch: Double = 0) -> GimbalWaypoint {
        GimbalWaypoint(yawDeg: yaw, pitchDeg: pitch, zoom: 1, nativePitchDeg: 170)
    }

    @Test func predictionIsBoundedAndStaleFeedbackHidesMarkers() {
        var motion = GimbalOverlayMotion()
        motion.observe(point(0), at: 1)
        motion.observe(point(10), at: 1.1)
        #expect(abs(motion.pose(at: 1.35)!.yawDeg - 20) < 1e-9)
        #expect(motion.pose(at: 1.401) == nil)
        motion.reset()
        #expect(motion.pose(at: 1.4) == nil)
    }

    @Test func wrapStopAndReversalDoNotContinueAnOldThrow() {
        var motion = GimbalOverlayMotion()
        motion.observe(point(179), at: 1)
        motion.observe(point(-179), at: 1.1)
        #expect(abs(motion.pose(at: 1.15)!.yawDeg - (-178)) < 1e-9)
        motion.observe(point(-179), at: 1.2)
        #expect(motion.pose(at: 1.25)?.yawDeg == -179)
        motion.observe(point(179), at: 1.3)
        #expect(abs(motion.pose(at: 1.35)!.yawDeg - 178) < 1e-9)
    }

    @Test func duplicateOutOfOrderAndGappedReportsDoNotInventVelocity() {
        var motion = GimbalOverlayMotion()
        motion.observe(point(1), at: 1)
        motion.observe(point(20), at: 1)
        motion.observe(point(30), at: 0.9)
        #expect(motion.pose(at: 1.1)?.yawDeg == 1)
        motion.observe(point(40), at: 2)
        #expect(motion.pose(at: 2.1)?.yawDeg == 40)
    }
}
