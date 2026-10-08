package com.opencapture.opencine.motion

import com.opencapture.opencine.core.MonotonicInstant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** Swift GimbalProgramPlaybackTests, same scenario names and manual instants. */
class GimbalProgramPlaybackTest {
    private val a = GimbalWaypoint(0.0, 0.0, 1.0)
    private val b = GimbalWaypoint(20.0, 0.0, 1.0)
    private val program = GimbalProgram(a = a, b = b, durationAB = 2.0)
    private val capabilities = MotionCapabilities(setOf(MotionAxis.PAN, MotionAxis.TILT, MotionAxis.ZOOM),
        MotionReferenceFrame.HANDLE, MotionBounds(-48.0..225.0, -44.0..70.0), null, 300.milliseconds, 0.15)
    private fun at(seconds: Double) = MonotonicInstant(seconds.seconds)
    private fun playback(program: GimbalProgram = this.program): GimbalProgramPlayback =
        assertNotNull(GimbalProgramPlayback.create(program, capabilities, 3.seconds, MonotonicInstant.ZERO))

    @Test fun countdownCancelRetiresInitialAndAllFutureTargets() {
        val move = playback()
        assertEquals(a, move.step(MonotonicInstant.ZERO).target)
        assertEquals(3, move.state.countdown)
        assertFalse(move.pause(at(1.0)))
        assertNull(move.step(at(1.0)).target); assertEquals(2, move.state.countdown)
        assertNull(move.step(at(2.0)).target); assertEquals(1, move.state.countdown)
        move.cancel()
        assertEquals(GimbalProgramPlayback.State.IDLE, move.state)
        assertNull(move.step(at(100.0)).target)
        assertFalse(move.step(at(200.0)).finished)
    }

    @Test fun pauseBudgetUsesTapTimeAndIgnoresPausedWallTime() {
        val move = playback()
        move.step(MonotonicInstant.ZERO)
        assertEquals(a, move.step(at(3.0)).target)
        assertEquals(5.0, move.step(at(3.5)).target?.yawDeg)
        assertTrue(move.pause(at(3.75))); assertEquals(0.75, move.state.elapsed)
        assertNull(move.step(at(30.0)).target); assertEquals(0.75, move.state.elapsed)
        assertTrue(move.resume(at(40.0)))
        assertEquals(10.0, move.step(at(40.25)).target?.yawDeg)
        assertEquals(GimbalProgramPlayback.Output(b, finished = true), move.step(at(41.25)))
    }

    @Test fun loopEndAndLateTickPreservePassDirection() {
        val move = playback(program.copy(loop = true))
        move.step(MonotonicInstant.ZERO)
        assertEquals(b, move.step(at(5.0)).target)
        assertTrue(move.state.reversing && move.state.elapsed == 0.0)
        assertEquals(a, move.step(at(7.0)).target)
        assertTrue(!move.state.reversing && move.state.elapsed == 0.0)
        assertEquals(10.0, move.step(at(12.0)).target?.yawDeg)
        assertTrue(!move.state.reversing && move.state.elapsed == 1.0)
        assertEquals(10.0, move.step(at(14.0)).target?.yawDeg)
        assertTrue(move.state.reversing && move.state.elapsed == 1.0)
        assertTrue(move.state.running)
    }

    @Test fun finiteEndEmitsLastTargetOnce() {
        val move = playback()
        move.step(MonotonicInstant.ZERO)
        assertEquals(GimbalProgramPlayback.Output(b, finished = true), move.step(at(30.0)))
        assertTrue(!move.state.running && move.state.elapsed == 2.0)
        assertEquals(GimbalProgramPlayback.Output(), move.step(at(31.0)))
        assertFalse(move.resume(at(32.0)))
    }

    @Test fun backwardsClockConsumesNoBudget() {
        val move = playback()
        move.step(MonotonicInstant.ZERO); move.step(at(4.0))
        assertEquals(10.0, move.step(at(3.0)).target?.yawDeg); assertEquals(1.0, move.state.elapsed)
        assertTrue(move.pause(at(3.0))); assertTrue(move.resume(at(3.0)))
        assertEquals(15.0, move.step(at(4.5)).target?.yawDeg)
    }

    @Test fun admissionRequiresDeclaredAxesBoundsAndFiniteDurations() {
        val withoutZoom = capabilities.copy(axes = setOf(MotionAxis.PAN, MotionAxis.TILT))
        val zoom = program.copy(b = b.copy(zoom = 2.0))
        assertNull(GimbalProgramPlayback.create(zoom, withoutZoom, 3.seconds, MonotonicInstant.ZERO))
        assertNull(GimbalProgramPlayback.create(program.copy(b = b.copy(yawDeg = 300.0)), capabilities, 3.seconds, MonotonicInstant.ZERO))
        assertNull(GimbalProgramPlayback.create(program.copy(durationAB = Double.NaN), capabilities, 3.seconds, MonotonicInstant.ZERO))
        assertNull(GimbalProgramPlayback.create(program.copy(smoothness = Double.POSITIVE_INFINITY), capabilities, 3.seconds, MonotonicInstant.ZERO))
        assertNull(GimbalProgramPlayback.create(program, capabilities, (-1).seconds, MonotonicInstant.ZERO))
    }

    @Test fun smoothedPathUsesExistingCurveWithoutChangingDuration() {
        val smooth = program.copy(c = GimbalWaypoint(20.0, 20.0, 1.0), durationBC = 3.0, smoothness = 0.7)
        val move = playback(smooth); move.step(MonotonicInstant.ZERO)
        val curve = assertNotNull(GimbalProgramCurve.create(smooth))
        for (time in listOf(0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0))
            assertEquals(curve.position(time), move.step(at(3 + time)).target)
        assertTrue(!move.state.running && move.state.elapsed == 5.0)
    }

    @Test fun countdownDeadlineDoesNotRoundToTargetCadence() {
        val move = playback(); move.step(at(2.99))
        assertEquals(10.milliseconds, move.nextDelay(33.milliseconds))
        move.step(at(3.0)); assertNull(move.state.countdown)
        assertEquals(33.milliseconds, move.nextDelay(33.milliseconds))
    }
}
