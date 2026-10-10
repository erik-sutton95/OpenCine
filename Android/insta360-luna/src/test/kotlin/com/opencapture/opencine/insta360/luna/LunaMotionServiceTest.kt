package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.insta360.shell.CameraGimbalAngle
import com.opencapture.opencine.motion.GimbalWaypoint
import kotlin.test.*
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test

/** Swift `LunaMotionServiceTests`, over the backend's controls. */
@OptIn(ExperimentalCoroutinesApi::class)
class LunaMotionServiceTest {
    private val controls = RecordingControls()

    @Test fun heldStickRepeatsMoveEveryIntervalUntilTheHoldEnds() = runTest {
        val motion = LunaMotionService({ controls }, backgroundScope)
        motion.hold(0.25, -1.0)
        assertTrue(motion.isHeld)
        advanceTimeBy(120)
        assertEquals(List(3) { listOf<Any?>(0.25, -1.0) }, controls.calls("gimbalStick"), "at 0, 50 and 100 ms")
        motion.hold(0.0, 0.0)
        advanceTimeBy(50)
        assertEquals(listOf<Any?>(0.0, 0.0), controls.calls("gimbalStick").last(), "a held stick at rest keeps repeating MOVE")
        val sent = controls.calls.size
        motion.endHold()
        assertFalse(motion.isHeld)
        advanceTimeBy(200)
        assertEquals(sent, controls.calls.size)
    }

    @Test fun singleRequestsReachTheirControls() = runTest {
        val motion = LunaMotionService({ controls }, backgroundScope)
        assertTrue(motion.release())
        assertTrue(motion.recenter())
        assertTrue(motion.flip())
        assertEquals(listOf("gimbalStick" to listOf<Any?>(0.0, 0.0), "gimbalRecenter" to emptyList(), "gimbalFlip" to emptyList()), controls.calls)
        controls.accepts = false
        assertFalse(motion.recenter())
    }

    @Test fun aimWrapsYawAndKeepsPitchInsideTheDeclaredReach() = runTest {
        val motion = LunaMotionService({ controls }, backgroundScope)
        assertTrue(motion.aim(GimbalWaypoint(190.0, 110.0, 1.0)))
        assertTrue(motion.aim(GimbalWaypoint(10.0, -80.0, 1.0)))
        // The Insta app's level case (moved from `LunaGimbalAimTest`): pitch inside the reach passes.
        assertTrue(motion.aim(GimbalWaypoint(190.0, 7.0, 2.0)))
        assertEquals(
            listOf(listOf<Any?>(90.0, -170.0), listOf<Any?>(-57.0, 10.0), listOf<Any?>(7.0, -170.0)),
            controls.calls("gimbalSetAngle"),
        )
    }

    @Test fun angleReadUpdatesTheLatestPose() = runTest {
        val at = MonotonicInstant.ZERO + 7.seconds
        val motion = LunaMotionService({ controls }, backgroundScope, now = { at })
        assertNull(motion.poses.value.value, "unknown until the camera answers GET_ANGLE")
        controls.angle = CameraGimbalAngle(pitch = -12.5, yaw = -170.0)
        assertEquals(controls.angle, motion.readAngle())
        val pose = motion.poses.value
        assertEquals(GimbalWaypoint(190.0, -12.5, 1.0, 12.5), pose.value, "yaw unwrapped across the gap")
        assertEquals(ObservationOrigin.CAMERA_REPORTED, pose.origin)
        assertEquals(at, pose.observedAt)
        controls.angle = null
        assertNull(motion.readAngle())
        assertEquals(pose, motion.poses.value)
    }

    @Test fun sharedServiceMapsOntoTheLunaRequests() = runTest {
        val motion = LunaMotionService({ controls }, backgroundScope)
        assertTrue(motion.stick(1.0, 0.0))
        assertTrue(motion.isHeld)
        assertTrue(motion.stick(0.0, 0.0))
        assertFalse(motion.isHeld, "zero on both axes releases")
        assertEquals(listOf<Any?>(0.0, 0.0), controls.calls("gimbalStick").last())

        val target = assertNotNull(motion.capabilities.target(GimbalWaypoint(10.0, 5.0, 1.0)))
        assertFalse(motion.move(target, 2.seconds), "Luna has no timed SET")
        assertTrue(controls.calls("gimbalSetAngle").isEmpty())
        assertTrue(motion.move(target, null))
        assertEquals(listOf<Any?>(5.0, 10.0), controls.calls("gimbalSetAngle").single())
        assertTrue(motion.stop())
        assertEquals(listOf<Any?>(0.0, 0.0), controls.calls("gimbalStick").last())
    }

    @Test fun nothingGoesOutWithoutControls() = runTest {
        val motion = LunaMotionService({ null }, backgroundScope)
        assertFalse(motion.stick(1.0, 0.0))
        assertFalse(motion.recenter())
        assertNull(motion.readAngle())
        motion.endHold()
    }

    // From the Insta app's LunaGimbalAimTest.levelKeepsYawAndCancelsHeadPitch (reached); Swift
    // `testArrivalIsWithinHalfADegreeOnEachAxisAcrossTheWrap`.
    @Test fun arrivalIsWithinHalfADegreeOnEachAxisAcrossTheWrap() {
        val target = GimbalWaypoint(190.0, 7.0, 2.0, -7.0)
        assertTrue(LunaMotionService.hasReached(CameraGimbalAngle(7.3, -170.4), target))
        val far = GimbalWaypoint(200.0, 10.0, 1.0)
        assertTrue(LunaMotionService.hasReached(CameraGimbalAngle(10.4, -160.4), far))
        assertFalse(LunaMotionService.hasReached(CameraGimbalAngle(10.6, -160.0), far))
        assertFalse(LunaMotionService.hasReached(CameraGimbalAngle(10.0, -159.4), far))
    }
}
