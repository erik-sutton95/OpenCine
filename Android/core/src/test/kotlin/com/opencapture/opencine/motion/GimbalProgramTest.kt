package com.opencapture.opencine.motion

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Swift `GimbalProgramTests` pose and duration cases; the engine cases run in dji's `GimbalProgramTest`. */
class GimbalProgramTest {
    // Moved from the Insta app's LunaGimbalAimTest.programPoseFollowsStraightLegs.
    @Test fun programPoseFollowsStraightLegs() {
        val a = GimbalWaypoint(0.0, 0.0, 1.0)
        val b = GimbalWaypoint(20.0, 10.0, 1.0)
        val c = GimbalWaypoint(20.0, -10.0, 1.0)
        val take = GimbalProgram(a, b, c, durationAB = 4.0, durationBC = 2.0)
        assertEquals(6.0, take.duration, 1e-9)
        assertEquals(a, take.pose(0.0))
        assertEquals(10.0, take.pose(2.0)!!.yawDeg, 1e-9)
        assertEquals(0.0, take.pose(5.0)!!.pitchDeg, 1e-9)
        assertEquals(c.pitchDeg, take.pose(6.0)!!.pitchDeg, 1e-9)
        assertEquals(4.0, take.copy(c = null).duration, 1e-9)
        assertNull(GimbalProgram(a).pose(1.0))
    }

    @Test fun durationLabelShowsWholeAndHalfSecondsWithoutLocale() {
        assertEquals("5s", GimbalProgram.durationLabel(5.0))
        assertEquals("2.5s", GimbalProgram.durationLabel(2.4))
        assertEquals("0.5s", GimbalProgram.durationLabel(0.1))
        assertEquals("120s", GimbalProgram.durationLabel(500.0))
    }
}
