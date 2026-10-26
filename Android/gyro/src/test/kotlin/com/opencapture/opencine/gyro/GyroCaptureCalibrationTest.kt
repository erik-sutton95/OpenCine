package com.opencapture.opencine.gyro

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import org.json.JSONObject

/**
 * Ring calibration in the coordinator (adapted from OpenZCine's GyroCalibrationSessionTest):
 * three held poses save per camera, invalidation follows the camera, the setup sheet's links,
 * and ring owners retire exactly once.
 */
class GyroCaptureCalibrationTest {
    private val levelDown = GyroVector3(-1.0, 0.0, 0.0)

    /** One phone reading with a fresh camera level, processed before the next one. */
    private fun GyroCaptureHarness.hold(readings: Int = 1, level: GyroVector3? = levelDown) {
        repeat(readings) {
            adapter.emitLevel(level, nowSeconds)
            settle()
            sensors.emitSteady(nowSeconds)
            settle()
            advance(50)
        }
    }

    @Test
    fun threeHeldPosesSaveForThisCamera() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)
        h.prefs.deferApply = true
        assertEquals(listOf<GyroArmingStep>(GyroArmingStep.Calibration(false)), h.state.setupSteps)
        assertTrue(h.state.canCalibrate)
        assertEquals(0, h.state.ringEventToken)
        assertFalse(h.state.hasSavedCalibration)

        h.coordinator.beginCalibration()
        h.settle()
        assertEquals(GyroRingPhase.INTRO, h.state.ring?.phase)
        assertFalse(h.sensors.motionRunning)
        assertTrue(h.native.calls("ringCreate").isEmpty())

        h.coordinator.startRing()
        h.settle()
        assertEquals(GyroRingPhase.POSING, h.state.ring?.phase)
        assertEquals(0, h.state.ring?.step)
        assertTrue(h.sensors.motionRunning)

        h.hold(3)
        assertEquals(GyroRingPhase.POSING, h.state.ring?.phase)
        assertEquals(1, h.state.ring?.step)
        assertEquals(0.5, h.state.ring?.hold)
        assertEquals(1, h.state.ring?.completedSteps)
        assertEquals(1, h.state.ringEventToken)
        val observe = h.native.calls("ringObserve").last().args
        assertEquals(true, observe[5])
        assertEquals(-1.0, observe[6])

        h.hold(3)
        val ring = assertNotNull(h.state.ring)
        assertEquals(GyroRingPhase.COMPLETE, ring.phase)
        assertEquals(GyroRingEvent.COMPLETED, ring.event)
        // One token per event, so a conflated StateFlow cannot hide a capture from the screen.
        assertEquals(3, h.state.ringEventToken)
        assertTrue(h.state.hasSavedCalibration)
        assertFalse(h.sensors.motionRunning)
        assertTrue(h.native.calls("calibrationValidate").any { it.args[0] == ring.calibrationJSON })
        val saved = JSONObject(h.prefs.getString(h.keys.calibrations, null)!!)
        assertTrue(saved.has("fake-1"))
        assertEquals(1, h.native.calls("ringClose").size)

        h.coordinator.finishCalibration()
        h.settle()
        assertNull(h.state.ring)
        assertTrue(h.state.setupSteps.isEmpty())

        h.adapter.recording.value = true
        h.advance(200)
        assertTrue(h.state.logs.single().isCalibrated)
        h.cleanup()
    }

    @Test
    fun invalidationMessagesFollowRecordingSourceAndDisconnect() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)

        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.hold(2)
        assertEquals(1, h.state.ring?.completedSteps)
        h.adapter.recording.value = true
        h.advance(100)
        assertEquals(GyroRingPhase.INVALIDATED, h.state.ring?.phase)
        assertEquals(GyroCalibrationInvalidation.RECORDING_STARTED, h.state.ring?.invalidation)
        assertEquals(listOf<Any?>(true, 1), h.native.calls("ringUpdateCamera").last().args.drop(1))
        assertFalse(h.sensors.motionRunning)
        h.adapter.recording.value = false
        h.advance(100)

        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.adapter.identity.value = GyroCameraIdentity("fake-2", "Second camera")
        h.advance(100)
        assertEquals(GyroCalibrationInvalidation.CAMERA_CHANGED, h.state.ring?.invalidation)
        assertEquals("cameraChanged", h.native.calls("ringInvalidate").last().args[1])

        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.adapter.disconnect()
        h.advance(100)
        assertEquals(GyroCalibrationInvalidation.CONNECTION_ENDED, h.state.ring?.invalidation)
        assertFalse(h.state.canCalibrate)

        h.adapter.connect(stabilization = IBIS_OFF)
        h.advance(100)
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.coordinator.setForeground(false)
        h.settle()
        assertEquals(GyroCalibrationInvalidation.CONNECTION_ENDED, h.state.ring?.invalidation)
        assertFalse(h.sensors.motionRunning)
        assertTrue(h.native.openOwners("ring").isEmpty())
        h.cleanup()
    }

    @Test
    fun useLastCalibrationSkipsRing() = runTest {
        val h = GyroCaptureHarness(this)
        GyroPreferences(h.prefs, h.keys, null, h.native)
            .saveCalibration("fake-1", FakeGyroNative.DEFAULT_CALIBRATION)
        h.arm(stabilization = IBIS_OFF)
        assertTrue(h.state.hasSavedCalibration)
        assertEquals(listOf<GyroArmingStep>(GyroArmingStep.Calibration(true)), h.state.setupSteps)
        h.coordinator.setupUseLastCalibration()
        h.settle()
        assertTrue(h.state.setupSteps.isEmpty())
        assertTrue(h.native.calls("ringCreate").isEmpty())
        h.adapter.recording.value = true
        h.advance(200)
        assertTrue(h.state.logs.single().isCalibrated)
        h.cleanup()
    }

    @Test
    fun cancelInSetupArmsUncalibrated() = runTest {
        val h = GyroCaptureHarness(this)
        GyroPreferences(h.prefs, h.keys, null, h.native)
            .saveCalibration("fake-1", FakeGyroNative.DEFAULT_CALIBRATION)
        h.arm(stabilization = IBIS_OFF)
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.hold(1)
        h.coordinator.cancelCalibration()
        h.settle()
        assertNull(h.state.ring)
        assertTrue(h.state.setupSteps.isEmpty())
        assertTrue(h.state.isArmed)
        assertFalse(h.sensors.motionRunning)
        assertEquals(1, h.native.calls("ringClose").size)
        assertEquals(listOf("ringCancel", "ringClose"), h.native.members().filter { it == "ringCancel" || it == "ringClose" })
        // The earlier calibration is kept for the next session, not used by this one.
        assertTrue(h.state.hasSavedCalibration)
        h.adapter.recording.value = true
        h.advance(200)
        assertFalse(h.state.logs.single().isCalibrated)
        h.cleanup()
    }

    @Test
    fun failedSaveReturnsToIntroWithANotice() = runTest {
        val prefs = MemorySharedPreferences()
        val h = GyroCaptureHarness(this, prefs = prefs)
        h.arm(stabilization = IBIS_OFF)
        prefs.failingKeys = setOf(h.keys.calibrations)
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.hold(6)
        assertEquals(GyroRingPhase.INTRO, h.state.ring?.phase)
        assertEquals(GyroNotice.SAVE_FAILED, h.state.notice)
        assertFalse(h.state.hasSavedCalibration)
        assertFalse(h.sensors.motionRunning)
        assertTrue(h.native.openOwners("ring").isEmpty())

        prefs.failingKeys = emptySet()
        h.coordinator.startRing()
        h.settle()
        h.hold(6)
        assertEquals(GyroRingPhase.COMPLETE, h.state.ring?.phase)
        assertTrue(h.state.hasSavedCalibration)
        // The machine saw the saved calibration: the next armed inputs report it.
        val inputs = org.json.JSONObject(h.native.calls("armingUpdate").last().args[1] as String)
        assertTrue(inputs.getBoolean("hasSavedCalibration"))
        h.cleanup()
    }

    @Test
    fun motionThatCannotStartIsVisibleAndNotRetried() = runTest {
        val h = GyroCaptureHarness(this)
        h.sensors.motionStarts = false
        h.arm(stabilization = IBIS_OFF)
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        assertEquals(GyroNotice.SENSOR_UNAVAILABLE, h.state.notice)
        assertEquals(GyroRingPhase.INTRO, h.state.ring?.phase)
        assertTrue(h.native.openOwners("ring").isEmpty())
        assertEquals(1, h.sensors.motionStartAttempts)
        h.coordinator.startRing()
        h.advance(200)
        assertEquals(1, h.sensors.motionStartAttempts)
        assertEquals(GyroRingPhase.INTRO, h.state.ring?.phase)
        h.cleanup()
    }

    @Test
    fun noLevelHidesCalibration() = runTest {
        val h = GyroCaptureHarness(this, adapter = FakeGyroCameraAdapter(providesLevel = false))
        h.arm(stabilization = IBIS_OFF)
        assertTrue(h.state.isArmed)
        assertFalse(h.state.canCalibrate)
        assertTrue(h.state.setupSteps.none { it is GyroArmingStep.Calibration })
        h.coordinator.beginCalibration()
        h.settle()
        assertNull(h.state.ring)
        h.cleanup()

        val noGravity = GyroCaptureHarness(this, sensors = FakeMotionSensors(hasGravity = false))
        noGravity.arm(stabilization = IBIS_OFF)
        assertFalse(noGravity.state.canCalibrate)
        assertTrue(noGravity.state.setupSteps.none { it is GyroArmingStep.Calibration })
        noGravity.cleanup()
    }

    @Test
    fun ringOwnerClosedExactlyOnce() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.coordinator.startRing()
        h.settle()
        h.hold(6)
        assertEquals(GyroRingPhase.COMPLETE, h.state.ring?.phase)
        h.coordinator.cancelCalibration()
        h.coordinator.finishCalibration()
        h.coordinator.beginCalibration()
        h.coordinator.startRing()
        h.settle()
        h.coordinator.cancelCalibration()
        h.coordinator.cancelCalibration()
        h.settle()
        h.coordinator.close()
        h.settle()
        val created = h.native.calls("ringCreate").size
        val closed = h.native.calls("ringClose").map { it.args[0] }
        assertEquals(3, created)
        assertEquals(listOf<Any?>("ring-1", "ring-2", "ring-3"), closed)
        assertTrue(h.native.openOwners("ring").isEmpty())
        h.root.deleteRecursively()
    }
}
