package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeDevice
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

internal fun iso(value: Int) = SettingValue.Iso(ISOValue.Manual(value))

/** A session that records every close it receives, over a fake. */
internal class Counted(val fake: FakeCameraSession) : CameraSession by fake {
    val closes = mutableListOf<SessionCloseReason>()

    override suspend fun close(reason: SessionCloseReason) {
        closes += reason
        fake.close(reason)
    }

    override fun closeNow(reason: SessionCloseReason) {
        closes += reason
        fake.closeNow(reason)
    }
}

/**
 * Swift suite `MonitorControlModelTests`, same method names: the monitor's common controls against
 * fake sessions; virtual time is the manual clock of the coalescing window.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorControlModelTest {
    private val notes = mutableListOf<String>()

    private fun TestScope.model() = MonitorControlModel(backgroundScope).also { it.onNote = { note -> notes += note } }

    private fun TestScope.tick() {
        advanceTimeBy(120)
        runCurrent()
    }

    @Test fun canceledEditCannotWakeSuccessorEarlyOrRetireOtherSetting() = runTest {
        val model = model()
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val old = assertNotNull(model.edit(SettingKey.ZOOM))
        val unrelated = assertNotNull(model.edit(SettingKey.ISO))
        assertTrue(model.commit(SettingValue.Zoom(2.0), old, "Zoom 2"))
        assertTrue(model.commit(iso(800), unrelated, "ISO 800"))
        runCurrent()
        advanceTimeBy(60); runCurrent()
        model.cancelEdit(SettingKey.ZOOM)
        assertFalse(model.isCurrent(old))
        assertTrue(model.isCurrent(unrelated))
        assertFalse(model.commit(SettingValue.Zoom(2.0), old, "Retired zoom"))
        val successor = assertNotNull(model.edit(SettingKey.ZOOM))
        assertTrue(model.commit(SettingValue.Zoom(3.0), successor, "Zoom 3"))
        runCurrent()
        advanceTimeBy(60); runCurrent()
        assertEquals(listOf("set ${iso(800)}"), camera.wire)
        assertEquals(SettingValue.Zoom(3.0), model.state.value.pending[SettingKey.ZOOM])
        advanceTimeBy(60); runCurrent()
        assertEquals(listOf("set ${iso(800)}", "set ${SettingValue.Zoom(3.0)}"), camera.wire)
    }

    @Test fun canceledInFlightReceiptCannotClearSuccessorPending() = runTest {
        val model = model()
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        assertTrue(model.commit(SettingValue.Zoom(2.0), assertNotNull(model.edit(SettingKey.ZOOM)), "Zoom 2"))
        tick()
        assertEquals(1, camera.wire.size)
        model.cancelEdit(SettingKey.ZOOM)
        assertTrue(model.commit(SettingValue.Zoom(3.0), assertNotNull(model.edit(SettingKey.ZOOM)), "Zoom 3"))
        tick()
        assertEquals(2, camera.wire.size)
        assertEquals(SettingValue.Zoom(3.0), model.state.value.pending[SettingKey.ZOOM])
        camera.advance(3.seconds); runCurrent()
        assertNull(model.state.value.pending[SettingKey.ZOOM])
        assertEquals(SettingValue.Zoom(3.0), camera.current.value(SettingKey.ZOOM).value)
    }

    @Test
    fun retiredBindingDoesNotReadNativeSnapshots() = runTest {
        val owner = CoroutineScope(Job() + StandardTestDispatcher(testScheduler))
        val model = MonitorControlModel(owner)
        val camera = FakeCameraSession.djiLike()
        var reads = 0
        val counted = object : CameraSession by camera {
            override val snapshots get() = camera.snapshots.also { reads += 1 }
        }
        owner.cancel()
        model.bind(counted)
        runCurrent()
        assertEquals(0, reads)
        assertNull(model.state.value.snapshot)
    }

    @Test
    fun shownIsThePendingTargetOverTheReport() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        assertEquals(iso(200), model.shown(SettingKey.ISO))
        model.set(iso(800), "ISO 800")
        assertEquals(iso(800), model.shown(SettingKey.ISO))
        assertEquals(iso(200), camera.current.value(SettingKey.ISO).value, "never written into the snapshot")
        tick()
        assertEquals(listOf("set ${iso(800)}"), camera.wire)
        camera.advance(3.seconds)
        runCurrent()
        assertTrue(model.state.value.pending.isEmpty())
        assertEquals(iso(800), model.shown(SettingKey.ISO))
    }

    @Test
    fun editsCoalescePerSettingLatestWins() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        model.set(iso(400), "ISO 400")
        model.set(iso(800), "ISO 800")
        model.set(iso(1600), "ISO 1600")
        tick()
        assertEquals(listOf("set ${iso(1600)}"), camera.wire)
    }

    @Test
    fun recordUnknownDoesNotBecomeIdle() = runTest {
        val model = model()
        val luna = FakeCameraSession.lunaLike()
        val camera = FakeCameraSession(luna.behavior, FakeDevice(0x01, mapOf(SettingKey.ISO to iso(200)), recording = null))
        camera.cameraReportsStatus()
        model.bind(camera)
        assertTrue(model.recording == null && model.isRecording == null)
        model.record(null)
        assertTrue(model.state.value.recordPending)
        runCurrent()
        assertFalse(model.state.value.recordPending)
        assertTrue(camera.wire.isEmpty(), "no blind toggle")
        assertEquals(listOf(MonitorControlModel.RECORDING_UNKNOWN), notes)
        assertNull(model.isRecording)
    }

    @Test
    fun recordResolvesStartOrStopFromAFreshReport() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        assertEquals(false, model.isRecording)
        val finished = mutableListOf<CommandReceipt>()
        model.onRecordFinished = { finished += it }
        model.record(null)
        runCurrent()
        assertEquals(listOf("record-start"), camera.wire)
        camera.advance(3.seconds)
        runCurrent()
        assertTrue(!model.state.value.recordPending && model.isRecording == true)
        assertEquals(listOf<CommandStage>(CommandStage.Confirmed), finished.map { it.stage })
        // A confirmed start while the camera already records sends nothing.
        model.record(true)
        runCurrent()
        assertEquals(2, finished.size)
        assertEquals(listOf("record-start"), camera.wire)
    }

    @Test
    fun domainOrAuthorityChangeInvalidatesTheEditor() = runTest {
        val model = model()
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val shutter = assertNotNull(model.edit(SettingKey.SHUTTER))
        val isoEditor = assertNotNull(model.edit(SettingKey.ISO))
        assertTrue(model.isCurrent(shutter) && model.isCurrent(isoEditor))
        // The mode dial changes the shutter domain: that editor is obsolete, ISO's is not.
        camera.cameraSwitchesMode(0x02)
        runCurrent()
        assertFalse(model.isCurrent(shutter))
        assertTrue(model.isCurrent(isoEditor))
        assertFalse(model.commit(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 500))), shutter, "1/500"))
        assertTrue(model.state.value.pending.isEmpty())
        // Losing authority obsoletes every editor.
        camera.setAuthority(ControlAuthority.ReadOnly)
        runCurrent()
        assertFalse(model.isCurrent(isoEditor))
        assertFalse(model.commit(iso(400), isoEditor, "ISO 400"))
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(camera.wire.isEmpty())
    }

    @Test
    fun aRetiredBindingDropsLateOutcomes() = runTest {
        val model = model()
        val a = FakeCameraSession.lunaLike()
        val b = FakeCameraSession.lunaLike()
        a.cameraReportsStatus()
        b.cameraReportsStatus()
        model.bind(a)
        model.set(iso(800), "ISO 800")
        tick()
        assertEquals(1, a.wire.size)
        model.record(true)
        runCurrent()
        assertEquals(2, a.wire.size)
        model.bind(b)
        assertEquals(b.id, model.state.value.snapshot?.session)
        // A answers late: its outcomes never reach B's controls.
        a.advance(10.seconds)
        a.close(SessionCloseReason.LINK_LOST)
        runCurrent()
        assertTrue(model.state.value.pending.isEmpty() && !model.state.value.recordPending)
        assertTrue(notes.isEmpty())
        assertEquals(b.id, model.state.value.session?.id)
    }

    @Test
    fun aHostKeepsItsOwnNoteCopy() = runTest {
        val model = model()
        model.noteFor = { stage, label -> if (stage == CommandStage.Confirmed) null else "$label host" }
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        camera.refuseNextCommand()
        model.set(iso(800), "ISO 800")
        tick()
        camera.refuseNextCommand()
        model.record(true)
        runCurrent()
        assertEquals(listOf("ISO 800 host", "Record host"), notes)
    }

    @Test
    fun notesNameTheOutcome() {
        assertNull(MonitorControlModel.note(CommandStage.Confirmed, "ISO 800"))
        assertNull(MonitorControlModel.note(CommandStage.Failed(CommandFailure.SUPERSEDED), "ISO 800"))
        assertEquals(
            "ISO 800: the camera refused it.",
            MonitorControlModel.note(CommandStage.Rejected(CommandRejection.CameraRefused), "ISO 800"),
        )
        assertEquals(
            MonitorControlModel.CONNECT_FIRST,
            MonitorControlModel.note(CommandStage.Rejected(CommandRejection.NoAuthority), "ISO 800"),
        )
        assertEquals("Stop: the camera link dropped before it confirmed.", MonitorControlModel.note(CommandStage.OutcomeUnknown, "Stop"))
    }
}
