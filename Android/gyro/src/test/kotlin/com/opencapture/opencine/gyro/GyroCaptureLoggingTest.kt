package com.opencapture.opencine.gyro

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * The moved OpenZCine logging pipeline driven by a camera adapter: the toggle, REC-only takes,
 * eligibility from the arming machine, and visible sensor and disk failures.
 */
class GyroCaptureLoggingTest {
    @Test
    fun optInDefaultsOffAndPersists() = runTest {
        val first = GyroCaptureHarness(this)
        assertFalse(first.state.enabled)
        assertEquals(GyroPillKind.HIDDEN, first.state.pill.kind)
        assertTrue(first.state.available)
        first.coordinator.setEnabled(true)
        first.settle()
        assertTrue(first.state.enabled)
        assertTrue(first.prefs.getBoolean(first.keys.enabled, false))
        assertEquals(GyroPillKind.OFFLINE, first.state.pill.kind)
        first.coordinator.close()
        first.settle()

        val second = GyroCaptureHarness(this, root = first.root, prefs = first.prefs)
        assertTrue(second.state.enabled)
        assertEquals(0, second.sensors.gyroStartCount)
        second.cleanup()
    }

    @Test
    fun onlyReportedRecOpensATake() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF, recording = null)
        assertTrue(h.state.isArmed)
        assertTrue(h.sensors.gyroRunning)
        assertEquals(GyroPillKind.ARMED, h.state.pill.kind)
        assertTrue(h.state.logs.isEmpty())

        h.adapter.recording.value = false
        h.advance(200)
        assertTrue(h.state.logs.isEmpty())
        assertEquals(GyroPillKind.ARMED, h.state.pill.kind)

        h.adapter.recording.value = true
        h.advance(200)
        val active = h.state.logs.single()
        assertTrue(active.active)
        assertEquals("Test camera", active.cameraLabel)
        assertEquals(GyroPillKind.RECORDING, h.state.pill.kind)
        assertEquals(1, h.native.calls("loggingObserve").count { it.args[1] == true })

        h.adapter.recording.value = false
        h.advance(200)
        assertEquals(GyroPillKind.SAVING, h.state.pill.kind)
        h.advance(2_100)
        val done = h.state.logs.single()
        assertFalse(done.active)
        assertNotNull(done.summary)
        assertEquals("normal", done.summary?.getString("termination"))
        assertEquals(GyroPillKind.ARMED, h.state.pill.kind)
        h.cleanup()
    }

    @Test
    fun unknownRecKeepsTheTakeOpenUntilTheSessionEnds() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)
        h.adapter.recording.value = true
        h.advance(200)
        assertTrue(h.state.logs.single().active)
        // REC going unknown is not a take boundary; Swift decides from Bool observations only.
        h.adapter.recording.value = null
        h.advance(300)
        assertTrue(h.state.logs.single().active)
        assertTrue(h.reasons().isEmpty())
        assertEquals(1, h.native.calls("loggingCreate").size)
        h.adapter.disconnect()
        h.advance(100)
        assertEquals(listOf<Any?>("disconnected"), h.reasons())
        assertEquals("disconnected", h.state.logs.single().summary?.getString("termination"))
        h.cleanup()
    }

    @Test
    fun photoModeAndUnknownSelectorWait() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF, videoMode = false)
        assertFalse(h.state.isArmed)
        assertEquals(0, h.sensors.gyroStartCount)
        assertEquals(GyroPillKind.OFFLINE, h.state.pill.kind)

        h.adapter.videoMode.value = null
        h.advance(200)
        assertFalse(h.state.isArmed)
        assertEquals(0, h.sensors.gyroStartCount)

        h.adapter.videoMode.value = true
        h.advance(200)
        assertTrue(h.state.isArmed)
        assertEquals(1, h.sensors.gyroStartCount)

        h.adapter.videoMode.value = false
        h.advance(200)
        assertFalse(h.state.isArmed)
        assertFalse(h.sensors.gyroRunning)
        assertEquals(listOf<Any?>("disconnected"), h.reasons())
        h.cleanup()
    }

    @Test
    fun ineligibleSourcesNeverStartSensors() = runTest {
        val h = GyroCaptureHarness(this)
        h.coordinator.setEnabled(true)
        h.coordinator.bind(h.adapter)
        h.adapter.connect(stabilization = IBIS_OFF)
        h.advance(200)
        // Monitor hidden, multicam or relay: the host reports not eligible.
        assertEquals(0, h.sensors.gyroStartCount)
        h.coordinator.setForeground(false)
        h.coordinator.setHostEligible(true)
        h.advance(200)
        assertEquals(0, h.sensors.gyroStartCount)
        h.coordinator.bind(null)
        h.coordinator.setForeground(true)
        h.advance(200)
        assertEquals(0, h.sensors.gyroStartCount)
        assertFalse(h.state.isArmed)

        h.coordinator.bind(h.adapter)
        h.advance(200)
        assertEquals(1, h.sensors.gyroStartCount)
        assertTrue(h.state.isArmed)
        h.cleanup()
    }

    @Test
    fun sensorLossIsVisible() = runTest {
        val missing = GyroCaptureHarness(this, sensors = FakeMotionSensors(hasGyroscope = false))
        assertFalse(missing.state.available)
        missing.arm(stabilization = IBIS_OFF)
        assertEquals(GyroNotice.SENSOR_UNAVAILABLE, missing.state.notice)
        assertEquals(GyroPillKind.ERROR, missing.state.pill.kind)
        assertNull(missing.native.calls("loggingCreate").firstOrNull())
        missing.cleanup()

        val stalled = GyroCaptureHarness(this)
        stalled.arm(stabilization = IBIS_OFF)
        assertEquals(GyroPillKind.ARMED, stalled.state.pill.kind)
        stalled.advanceSilently(700)
        assertEquals(GyroNotice.SENSOR_STALLED, stalled.state.notice)
        assertEquals(GyroPillKind.ERROR, stalled.state.pill.kind)
        assertFalse(stalled.sensors.gyroRunning)
        stalled.coordinator.clearNotice()
        stalled.settle()
        assertNull(stalled.state.notice)
        stalled.cleanup()
    }

    @Test
    fun writeFailureAbortsAndRecovers() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_OFF)
        h.adapter.recording.value = true
        h.advance(200)
        assertTrue(h.state.logs.single().active)

        h.failWrites = true
        h.advance(200)
        assertEquals(GyroNotice.SAVE_FAILED, h.state.notice)
        assertEquals(GyroPillKind.ERROR, h.state.pill.kind)
        assertFalse(h.sensors.gyroRunning)
        val entry = h.state.logs.single()
        assertFalse(entry.active)
        assertEquals("recovered", entry.summary?.getString("termination"))
        assertEquals(GyroTakeStatus.CutShort, entry.status)
        assertTrue(h.root.listFiles().orEmpty().none { it.name.endsWith(".partial") })
        assertTrue(h.native.openOwners("logging").isEmpty())
        h.cleanup()
    }
}
