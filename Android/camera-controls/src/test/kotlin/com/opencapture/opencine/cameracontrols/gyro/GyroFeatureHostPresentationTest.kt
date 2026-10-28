package com.opencapture.opencine.cameracontrols.gyro

import com.opencapture.opencine.gyro.GyroArmingStep
import com.opencapture.opencine.gyro.GyroCaptureState
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The feature host's full-screen priority (Swift twin: gyroFeature's presentation order). */
class GyroFeatureHostPresentationTest {
    private val ring = GyroRingState(
        phase = GyroRingPhase.INTRO, step = null, inZone = null, hold = null, block = null,
        invalidation = null, completedSteps = 0, event = null, calibrationJSON = null,
    )
    private val stabilization = GyroArmingStep.Stabilization(lensHasVRSwitch = null)

    @Test
    fun setupWinsOverCalibrationAndLogs() {
        val state = GyroCaptureState(
            setupSteps = listOf(stabilization, GyroArmingStep.Calibration(false)),
            ring = ring,
            logsPresented = true,
            driftPromptPresented = true,
        )
        assertEquals(GyroFullScreen.Setup(stabilization, ring), gyroFullScreenPresentation(state))
    }

    @Test
    fun calibrationWinsOverLogs() {
        val state = GyroCaptureState(ring = ring, logsPresented = true)
        assertEquals(GyroFullScreen.Calibration(ring), gyroFullScreenPresentation(state))
    }

    @Test
    fun logsAloneAndNothingOtherwise() {
        assertEquals(GyroFullScreen.Logs, gyroFullScreenPresentation(GyroCaptureState(logsPresented = true)))
        assertNull(
            gyroFullScreenPresentation(GyroCaptureState(driftPromptPresented = true)),
            "The drift prompt is a sheet over the monitor, not a full-screen dialog",
        )
        assertNull(gyroFullScreenPresentation(GyroCaptureState()))
    }
}
