package com.opencapture.opencine.gyro

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import org.json.JSONObject

/**
 * Mount drift during a calibrated take: the confirmation marks the take and turns the pill, the
 * prompt waits for REC to stop and "Not now" silences the session, and without a calibration
 * nothing is detected.
 */
class GyroCaptureDriftTest {
    private fun GyroCaptureHarness.steady(readings: Int) {
        repeat(readings) {
            adapter.emitLevel(GyroVector3(-1.0, 0.0, 0.0), nowSeconds)
            settle()
            sensors.emitSteady(nowSeconds)
            settle()
            advance(50)
        }
    }

    private fun calibrated(test: kotlinx.coroutines.test.TestScope): GyroCaptureHarness {
        val h = GyroCaptureHarness(test)
        GyroPreferences(h.prefs, h.keys, null, h.native)
            .saveCalibration("fake-1", FakeGyroNative.DEFAULT_CALIBRATION)
        h.arm(stabilization = IBIS_OFF)
        h.coordinator.setupUseLastCalibration()
        h.settle()
        return h
    }

    @Test
    fun steadyMismatchMarksTakeAndPill() = runTest {
        val h = calibrated(this)
        assertFalse(h.sensors.motionRunning)
        h.steady(3)
        assertTrue(h.native.calls("driftCreate").isEmpty(), "no drift between takes")

        h.adapter.recording.value = true
        h.advance(200)
        assertTrue(h.sensors.motionRunning)
        val frozen = h.native.calls("driftCreate").single().args[0] as String
        assertEquals(1.5, JSONObject(frozen).getDouble("validationErrorDegrees"))
        assertEquals(3, JSONObject(frozen).getJSONArray("rotation").length())
        h.steady(3)
        assertEquals(1, h.native.calls("loggingMountMoved").size)
        assertEquals(GyroPillKind.MOUNT_MOVED, h.state.pill.kind)
        assertEquals(1, h.state.driftHapticToken)
        assertFalse(h.state.driftPromptPresented)

        h.adapter.recording.value = false
        h.advance(2_300)
        val take = h.state.logs.single()
        assertFalse(take.active)
        assertNotNull(take.summary?.opt("mountMovedOffset"))
        assertTrue(take.status is GyroTakeStatus.MountMoved)
        assertFalse(h.sensors.motionRunning)
        h.cleanup()
    }

    @Test
    fun promptAfterRecStopsAndNotNowSilences() = runTest {
        val h = calibrated(this)
        h.adapter.recording.value = true
        h.advance(200)
        h.steady(3)
        assertFalse(h.state.driftPromptPresented)
        h.adapter.recording.value = false
        h.advance(100)
        assertTrue(h.state.driftPromptPresented)
        h.coordinator.dismissDriftPrompt()
        h.settle()
        assertFalse(h.state.driftPromptPresented)

        h.advance(2_300)
        h.adapter.recording.value = true
        h.advance(200)
        h.steady(3)
        assertEquals(2, h.state.driftHapticToken)
        assertEquals(GyroPillKind.MOUNT_MOVED, h.state.pill.kind)
        h.adapter.recording.value = false
        h.advance(100)
        assertFalse(h.state.driftPromptPresented, "Not now silences this armed session")

        // A new armed session prompts again; recalibrating opens the ring intro.
        h.coordinator.setHostEligible(false)
        h.advance(2_300)
        h.coordinator.setHostEligible(true)
        h.advance(200)
        h.coordinator.setupUseLastCalibration()
        h.adapter.recording.value = true
        h.advance(200)
        h.steady(3)
        h.adapter.recording.value = false
        h.advance(100)
        assertTrue(h.state.driftPromptPresented)
        h.coordinator.recalibrateAfterDrift()
        h.settle()
        assertFalse(h.state.driftPromptPresented)
        assertEquals(GyroRingPhase.INTRO, h.state.ring?.phase)
        h.cleanup()
    }

    @Test
    fun sessionArmedWhileRecordingDetects() = runTest {
        val h = GyroCaptureHarness(this)
        h.saveCalibration()
        h.coordinator.setEnabled(true)
        h.coordinator.bind(h.adapter)
        h.adapter.connect(stabilization = IBIS_OFF, recording = true)
        h.advance(100)
        assertFalse(h.state.isArmed)
        // The host becomes eligible while the camera already records: arm, log and watch drift.
        h.coordinator.setHostEligible(true)
        h.advance(200)
        assertTrue(h.state.isArmed)
        assertTrue(h.state.logs.single().active)
        assertTrue(h.sensors.motionRunning)
        h.steady(3)
        assertEquals(GyroPillKind.MOUNT_MOVED, h.state.pill.kind)

        // A logging failure stops the motion stream with the take.
        h.failWrites = true
        h.advance(100)
        assertEquals(GyroNotice.SAVE_FAILED, h.state.notice)
        assertFalse(h.sensors.motionRunning)
        h.cleanup()
    }

    @Test
    fun sessionEndClosesTheDriftPrompt() = runTest {
        val h = calibrated(this)
        h.adapter.recording.value = true
        h.advance(200)
        h.steady(3)
        h.adapter.recording.value = false
        h.advance(100)
        assertTrue(h.state.driftPromptPresented)
        h.coordinator.setHostEligible(false)
        h.advance(100)
        assertFalse(h.state.driftPromptPresented)
        h.cleanup()
    }

    @Test
    fun uncalibratedNeverDetects() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)
        h.coordinator.setupSkipCalibration()
        h.adapter.recording.value = true
        h.advance(200)
        h.steady(5)
        assertTrue(h.native.calls("driftCreate").isEmpty())
        assertEquals(0, h.sensors.motionStartCount)
        assertEquals(GyroPillKind.RECORDING, h.state.pill.kind)
        h.cleanup()

        val skipped = calibrated(this)
        skipped.coordinator.setHostEligible(false)
        skipped.advance(100)
        skipped.coordinator.setHostEligible(true)
        skipped.advance(200)
        skipped.coordinator.setupSkipCalibration()
        skipped.adapter.recording.value = true
        skipped.advance(200)
        skipped.steady(5)
        assertTrue(skipped.native.calls("driftCreate").isEmpty())
        assertFalse(skipped.state.logs.first().isCalibrated)
        skipped.cleanup()
    }
}
