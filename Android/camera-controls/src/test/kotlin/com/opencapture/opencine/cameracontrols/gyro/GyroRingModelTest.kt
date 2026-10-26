package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroCalibrationBlock
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The calibration ring's phase mapping and the spoken hold milestones. Swift twin:
 * `GyroRingModelTests`.
 */
class GyroRingModelTest {
    private fun state(
        phase: GyroRingPhase,
        step: Int? = 0,
        inZone: Boolean? = null,
        hold: Double? = null,
        block: GyroCalibrationBlock? = null,
        invalidation: GyroCalibrationInvalidation? = null,
        completedSteps: Int = 0,
    ) = GyroRingState(
        phase = phase,
        step = step,
        inZone = inZone,
        hold = hold,
        block = block,
        invalidation = invalidation,
        completedSteps = completedSteps,
        event = null,
        calibrationJSON = null,
    )

    @Test
    fun introIsEmpty() {
        val model = gyroRingModel(state(GyroRingPhase.INTRO))
        assertEquals(0.0, model.litFraction)
        assertFalse(model.dimmed)
        assertFalse(model.checkmark)
        assertEquals(0, model.litTicks)
    }

    @Test
    fun holdFillsTheRing() {
        assertEquals(
            0.15,
            gyroRingModel(state(GyroRingPhase.POSING, inZone = false, hold = 0.9)).litFraction,
        )
        assertEquals(
            0.15,
            gyroRingModel(state(GyroRingPhase.POSING, inZone = true, hold = 0.0)).litFraction,
        )
        assertEquals(
            0.575,
            gyroRingModel(state(GyroRingPhase.POSING, inZone = true, hold = 0.5)).litFraction,
            1e-9,
        )
        val full = gyroRingModel(state(GyroRingPhase.POSING, inZone = true, hold = 1.0))
        assertEquals(1.0, full.litFraction)
        assertEquals(60, full.litTicks)
        assertFalse(full.checkmark)
        assertEquals(
            0.0,
            gyroRingModel(state(GyroRingPhase.RETRYING, step = 0)).litFraction,
        )
    }

    @Test
    fun tiltFollowsTheStep() {
        assertEquals(0.0, gyroRingModel(state(GyroRingPhase.POSING, step = 0)).tiltDegrees)
        assertEquals(-14.0, gyroRingModel(state(GyroRingPhase.POSING, step = 1)).tiltDegrees)
        assertEquals(-24.0, gyroRingModel(state(GyroRingPhase.POSING, step = 2)).tiltDegrees)
        assertEquals(-24.0, gyroRingModel(state(GyroRingPhase.BLOCKED, step = 2)).tiltDegrees)
        assertEquals(0.0, gyroRingModel(state(GyroRingPhase.RETRYING, step = 2)).tiltDegrees)
        assertEquals(0.0, gyroRingModel(state(GyroRingPhase.COMPLETE, step = null)).tiltDegrees)
    }

    @Test
    fun litTicksRoundUp() {
        assertEquals(9, GyroRingModel(litFraction = 0.15, dimmed = false, checkmark = false).litTicks)
        assertEquals(1, GyroRingModel(litFraction = 0.001, dimmed = false, checkmark = false).litTicks)
        assertEquals(35, GyroRingModel(litFraction = 0.575, dimmed = false, checkmark = false).litTicks)
    }

    @Test
    fun blockedDims() {
        val blocked = gyroRingModel(
            state(GyroRingPhase.BLOCKED, block = GyroCalibrationBlock.MOVING),
        )
        assertTrue(blocked.dimmed)
        assertFalse(blocked.checkmark)
        assertEquals(0.15, blocked.litFraction)

        val invalidated = gyroRingModel(
            state(
                GyroRingPhase.INVALIDATED,
                step = null,
                invalidation = GyroCalibrationInvalidation.CAMERA_CHANGED,
            ),
        )
        assertTrue(invalidated.dimmed)
        assertEquals(0.0, invalidated.litFraction)
    }

    @Test
    fun completeShowsTheCheckmark() {
        val model = gyroRingModel(state(GyroRingPhase.COMPLETE, step = null))
        assertEquals(1.0, model.litFraction)
        assertTrue(model.checkmark)
        assertFalse(model.dimmed)
        assertEquals(60, model.litTicks)
    }

    @Test
    fun ringAnnouncesAtQuarterThresholds() {
        assertNull(gyroHoldAnnouncement(previousThreshold = 0, hold = 0.24))
        assertEquals(25, gyroHoldAnnouncement(previousThreshold = 0, hold = 0.25))
        assertEquals(25, gyroHoldAnnouncement(previousThreshold = 0, hold = 0.3))
        assertNull(gyroHoldAnnouncement(previousThreshold = 25, hold = 0.4))
        assertEquals(50, gyroHoldAnnouncement(previousThreshold = 25, hold = 0.6))
        assertEquals(75, gyroHoldAnnouncement(previousThreshold = 50, hold = 0.9))
        assertNull(gyroHoldAnnouncement(previousThreshold = 75, hold = 0.1))
        assertNull(gyroHoldAnnouncement(previousThreshold = 0, hold = Double.NaN))
    }
}
