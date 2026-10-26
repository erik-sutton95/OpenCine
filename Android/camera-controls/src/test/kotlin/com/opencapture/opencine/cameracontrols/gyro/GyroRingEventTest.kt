package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import kotlin.test.Test
import kotlin.test.assertEquals

/** The event a new ring token announces when a conflated state already moved past its reply. */
class GyroRingEventTest {
    private fun ring(phase: GyroRingPhase, completed: Int, event: GyroRingEvent? = null) =
        GyroRingState(phase, step = null, inZone = null, hold = null, block = null,
            invalidation = null, completedSteps = completed, event = event, calibrationJSON = null)

    @Test
    fun theReplyEventWins() {
        assertEquals(
            GyroRingEvent.VERIFICATION_FAILED,
            gyroRingEventFor(ring(GyroRingPhase.RETRYING, 0, GyroRingEvent.VERIFICATION_FAILED)),
        )
    }

    @Test
    fun aConflatedStateImpliesItsEvent() {
        assertEquals(GyroRingEvent.STEP_CAPTURED, gyroRingEventFor(ring(GyroRingPhase.POSING, 1)))
        assertEquals(GyroRingEvent.STEP_CAPTURED, gyroRingEventFor(ring(GyroRingPhase.BLOCKED, 2)))
        assertEquals(GyroRingEvent.COMPLETED, gyroRingEventFor(ring(GyroRingPhase.COMPLETE, 3)))
        assertEquals(GyroRingEvent.VERIFICATION_FAILED, gyroRingEventFor(ring(GyroRingPhase.POSING, 0)))
    }
}
