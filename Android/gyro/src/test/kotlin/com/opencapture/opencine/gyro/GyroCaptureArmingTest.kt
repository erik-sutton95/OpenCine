package com.opencapture.opencine.gyro

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.json.JSONArray

/**
 * Session arming through the shared machine: the setup sheet, the IBIS save, turn-off and exact
 * restore, the restore owed across a dropped link or a process death, and the 3 s disconnect wait.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GyroCaptureArmingTest {
    @Test
    fun ibisOnShowsStabilizationStepFirst() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = GyroStabilizationState(mapOf("ibis" to "ON"), true))
        assertTrue(h.state.isArmed)
        assertEquals(
            listOf(GyroArmingStep.Stabilization(true), GyroArmingStep.Calibration(false)),
            h.state.setupSteps,
        )
        assertFalse(h.state.pill.stabilizationWarning)
        assertEquals(1, h.sensors.gyroStartCount)
        h.cleanup()
    }

    @Test
    fun turnOffWritesOffAfterPersisting() = runTest {
        val h = GyroCaptureHarness(this)
        // Only a committed restore survives a process kill right after the IBIS-off write.
        h.prefs.deferApply = true
        var persistedAtWrite: String? = null
        h.adapter.beforeWrite = { persistedAtWrite = h.prefs.getString(h.keys.pendingRestores, null) }
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        assertEquals(listOf(mapOf("ibis" to "OFF")), h.adapter.writes)
        val persisted = JSONArray(assertNotNull(persistedAtWrite)).getJSONObject(0)
        assertEquals("fake-1", persisted.getString("cameraID"))
        assertEquals("SPORT", persisted.getJSONObject("saved").getString("ibis"))
        assertEquals(listOf<GyroArmingStep>(GyroArmingStep.Calibration(false)), h.state.setupSteps)
        assertFalse(h.state.pill.stabilizationWarning)
        assertEquals(
            listOf<Any?>("turnOff", true),
            h.native.calls("armingWriteFinished").single().args.drop(1),
        )
        h.cleanup()
    }

    @Test
    fun writeThatNeverReturnsTimesOutAsFailed() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.adapter.writeNeverReturns = true
        h.coordinator.setupTurnOffStabilization()
        h.advance(GYRO_WRITE_TIMEOUT_MILLIS - 100)
        assertTrue(h.native.calls("armingWriteFinished").isEmpty())
        h.advance(200)
        assertEquals(
            listOf<Any?>("turnOff", false),
            h.native.calls("armingWriteFinished").single().args.drop(1),
        )
        assertEquals(GyroNotice.TURN_OFF_FAILED, h.state.notice)
        // Arming is not blocked: turning gyro off still ends the session.
        h.adapter.writeNeverReturns = false
        h.coordinator.setEnabled(false)
        h.advance(100)
        assertFalse(h.state.isArmed)
        h.cleanup()
    }

    @Test
    fun keepOnShowsWarning() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupKeepStabilization()
        h.advance(100)
        assertTrue(h.adapter.writes.isEmpty())
        assertEquals(GyroPillKind.ARMED, h.state.pill.kind)
        assertTrue(h.state.pill.stabilizationWarning)
        assertEquals(listOf<GyroArmingStep>(GyroArmingStep.Calibration(false)), h.state.setupSteps)
        h.cleanup()
    }

    @Test
    fun failedTurnOffShowsANotice() = runTest {
        val h = GyroCaptureHarness(this)
        h.adapter.acceptsWrites = false
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        assertEquals(GyroNotice.TURN_OFF_FAILED, h.state.notice)
        assertTrue(h.state.pill.stabilizationWarning)
        h.cleanup()
    }

    @Test
    fun failedRestorePersistRefusesTheTurnOffWrite() = runTest {
        val prefs = MemorySharedPreferences()
        val h = GyroCaptureHarness(this, prefs = prefs)
        h.arm(stabilization = IBIS_SPORT)
        prefs.failingKeys = setOf(h.keys.pendingRestores)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        assertTrue(h.adapter.writes.isEmpty())
        assertEquals(GyroNotice.TURN_OFF_FAILED, h.state.notice)
        assertTrue(h.state.pill.stabilizationWarning)
        h.cleanup()
    }

    @Test
    fun toggleOffRestoresExactValue() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        h.coordinator.setEnabled(false)
        h.advance(100)
        assertEquals(listOf(mapOf("ibis" to "OFF"), mapOf("ibis" to "SPORT")), h.adapter.writes)
        assertEquals("[]", h.prefs.getString(h.keys.pendingRestores, null))
        assertFalse(h.state.isArmed)
        assertTrue(h.state.setupSteps.isEmpty())
        assertEquals(GyroPillKind.HIDDEN, h.state.pill.kind)
        assertEquals(listOf<Any?>("disabled"), h.reasons())
        assertFalse(h.sensors.gyroRunning)
        h.cleanup()
    }

    @Test
    fun linkDropOwesRestoreAndNextConnectRestoresFirst() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        h.adapter.disconnect()
        h.advance(100)
        assertFalse(h.state.isArmed)
        assertEquals(listOf<Any?>("disconnected"), h.reasons())
        assertEquals(1, h.adapter.writes.size)
        assertTrue(h.prefs.getString(h.keys.pendingRestores, null)!!.contains("SPORT"))

        var armedAtRestore: Boolean? = null
        var gyroAtRestore: Boolean? = null
        h.adapter.beforeWrite = {
            armedAtRestore = h.state.isArmed
            gyroAtRestore = h.sensors.gyroRunning
        }
        h.adapter.connect(stabilization = IBIS_OFF)
        h.advance(200)
        assertEquals(mapOf("ibis" to "SPORT"), h.adapter.writes.last())
        assertEquals(false, armedAtRestore)
        assertEquals(false, gyroAtRestore)
        assertTrue(h.state.isArmed)
        // The restore turned IBIS back on, so the new session offers the stabilization step.
        assertEquals(
            listOf(GyroArmingStep.Stabilization(null), GyroArmingStep.Calibration(false)),
            h.state.setupSteps,
        )
        assertEquals("[]", h.prefs.getString(h.keys.pendingRestores, null))
        h.cleanup()
    }

    @Test
    fun connectingDuringRecordingDefersSheet() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT, recording = true)
        assertTrue(h.state.isArmed)
        assertTrue(h.state.setupSteps.isEmpty())
        h.adapter.recording.value = false
        h.advance(100)
        assertEquals(GyroArmingStep.Stabilization(null), h.state.setupSteps.first())
        h.cleanup()
    }

    @Test
    fun backgroundingEndsTheSessionAndClosesTheSheet() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        assertTrue(h.state.setupSteps.isNotEmpty())
        h.coordinator.setForeground(false)
        h.advance(100)
        assertFalse(h.state.isArmed)
        assertTrue(h.state.setupSteps.isEmpty())
        assertEquals(listOf<Any?>("backgrounded"), h.reasons())
        h.cleanup()
    }

    @Test
    fun prepareForDisconnectAwaitsRestore() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        h.adapter.writeDelayMillis = 1_000
        val start = testScheduler.currentTime
        h.coordinator.prepareForDisconnect()
        val waited = testScheduler.currentTime - start
        assertEquals(mapOf("ibis" to "SPORT"), h.adapter.writes.last())
        assertTrue(waited in 1_000 until 3_000, "waited $waited ms")
        assertEquals("[]", h.prefs.getString(h.keys.pendingRestores, null))
        assertFalse(h.state.isArmed)
        h.cleanup()

        val slow = GyroCaptureHarness(this)
        slow.arm(stabilization = IBIS_SPORT)
        slow.coordinator.setupTurnOffStabilization()
        slow.advance(100)
        slow.adapter.writeDelayMillis = 10_000
        val slowStart = testScheduler.currentTime
        slow.coordinator.prepareForDisconnect()
        assertEquals(3_000, testScheduler.currentTime - slowStart)
        slow.cleanup()
    }

    @Test
    fun prepareForDisconnectThenReconnectArmsAgain() = runTest {
        val h = GyroCaptureHarness(this)
        h.arm(stabilization = IBIS_SPORT)
        h.coordinator.setupTurnOffStabilization()
        h.advance(100)
        h.coordinator.prepareForDisconnect()
        assertFalse(h.state.isArmed)
        h.adapter.disconnect()
        h.advance(100)
        h.adapter.connect(stabilization = IBIS_SPORT)
        h.advance(200)
        assertTrue(h.state.isArmed)
        assertTrue(h.sensors.gyroRunning)

        // An abandoned disconnect (the link stayed up) does not block the same adapter either.
        h.coordinator.prepareForDisconnect()
        assertFalse(h.state.isArmed)
        h.coordinator.bind(h.adapter)
        h.advance(200)
        assertTrue(h.state.isArmed)
        h.cleanup()
    }

    @Test
    fun processDeathRecoversTakeAndOwesRestore() = runTest {
        val first = GyroCaptureHarness(this)
        first.saveCalibration()
        first.arm(stabilization = IBIS_SPORT)
        first.coordinator.setupTurnOffStabilization()
        first.advance(100)
        first.adapter.recording.value = true
        first.advance(300)
        assertTrue(first.state.logs.single().active)
        first.steady(3)
        assertEquals(GyroPillKind.MOUNT_MOVED, first.state.pill.kind)
        // Process death: nothing finishes, the native registry and every owner are gone.
        first.scope.coroutineContext[kotlinx.coroutines.Job]!!.cancel()
        first.settle()

        val second = GyroCaptureHarness(this, root = first.root, prefs = first.prefs)
        val recovered = second.state.logs.single()
        assertFalse(recovered.active)
        assertEquals("recovered", recovered.summary?.getString("termination"))
        // The mount-moved sidecar written mid-take is merged into the recovered summary.
        val offset = recovered.summary!!.getDouble("mountMovedOffset")
        assertEquals(GyroTakeStatus.MountMoved(offset), recovered.status)
        assertTrue(second.native.calls("armingCreate").single().args[0].toString().contains("SPORT"))

        second.arm(stabilization = IBIS_OFF)
        assertEquals(listOf(mapOf("ibis" to "SPORT")), second.adapter.writes)
        assertEquals("[]", second.prefs.getString(second.keys.pendingRestores, null))
        assertTrue(second.state.isArmed)
        second.cleanup()
    }
}
