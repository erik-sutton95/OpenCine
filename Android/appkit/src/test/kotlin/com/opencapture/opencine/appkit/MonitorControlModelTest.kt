package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandDispatchAdmission
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
import kotlin.time.Duration.Companion.milliseconds
import java.util.concurrent.atomic.AtomicBoolean

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

    @Test fun confirmedRecordingDurationReachesTheActualStatusProjection() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        assertEquals(false, model.isRecording)
        model.record(true)
        runCurrent()
        assertEquals(listOf("record-start"), camera.wire)
        camera.advance(3.seconds)
        runCurrent()
        assertTrue(model.isRecording == true && !model.state.value.recordPending)
        assertEquals(17, model.statusPresentation(elapsedSeconds = 17).elapsedSeconds)
        assertEquals(0, model.statusPresentation().elapsedSeconds)
        model.unbind()
        assertNull(model.statusPresentation().elapsedSeconds)
    }


    private fun TestScope.elapsedModel() = MonitorControlModel(backgroundScope,
        now = { MonotonicInstant(testScheduler.currentTime.milliseconds) })

    /** A reported frame-rate change opens the emulated-angle hold window. Swift twin. */
    @Test fun aReportedFrameRateChangeOpensTheRateChangeWindow() = runTest {
        val model = elapsedModel()
        var changes = 0
        model.onChange = { changes += 1 }
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsSetting(SettingValue.FrameRate(Rational(30)))
        model.bind(camera); runCurrent()
        assertEquals(SettingValue.FrameRate(Rational(30)), model.state.value.snapshot?.value(SettingKey.FRAME_RATE)?.value)
        assertFalse(model.frameRateSettling, "the first report is no change")
        camera.cameraReportsSetting(SettingValue.FrameRate(Rational(60))); runCurrent()
        assertEquals(SettingValue.FrameRate(Rational(60)), model.state.value.snapshot?.value(SettingKey.FRAME_RATE)?.value)
        assertTrue(model.frameRateSettling)
        advanceTimeBy(2000); runCurrent()
        assertTrue(model.frameRateSettling)
        val before = changes
        // The hold ends on its own, without a later snapshot: Compose state and onChange redraw.
        advanceTimeBy(1000); runCurrent()
        assertFalse(model.frameRateSettling)
        assertTrue(changes > before, "the expiry must redraw the held readout")
        camera.cameraReportsSetting(SettingValue.FrameRate(Rational(30))); runCurrent()
        assertTrue(model.frameRateSettling)
        model.unbind()
        assertFalse(model.frameRateSettling)
    }

    @Test fun idleRecordingReportsKeepElapsedObservationStable() = runTest {
        val model = elapsedModel()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val original = model.recordingElapsed
        assertEquals(0, original.value)
        for (index in 1..10) {
            advanceTimeBy(1000); runCurrent()
            camera.cameraReportsTimecodeReading(CameraTimecodeReading(0, 1, index))
            runCurrent()
            assertEquals(index, model.timecodeReading.value?.seconds)
            assertEquals(original, model.recordingElapsed)
        }
        model.unbind()
    }

    @Test fun bodyRecordingTicksWithoutCommandsAndKeepsClockOrigin() = runTest {
        val model = elapsedModel()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus(); model.bind(camera)
        camera.cameraReportsRecording(true); runCurrent()
        assertEquals(0, model.statusPresentation().elapsedSeconds)
        val changes = mutableListOf<String>()
        model.onChange = { changes += "change" }
        advanceTimeBy(1000); runCurrent()
        assertEquals(1, model.statusPresentation().elapsedSeconds)
        assertEquals(ObservationOrigin.CLOCK_DERIVED, model.recordingElapsed.origin)
        advanceTimeBy(60000); runCurrent()
        assertEquals(61, model.statusPresentation().elapsedSeconds)
        assertEquals(17, model.statusPresentation(elapsedSeconds = 17).elapsedSeconds)
        assertEquals(0, model.statusPresentation(elapsedSeconds = 0).elapsedSeconds)
        assertTrue(changes.isEmpty())
        assertTrue(camera.wire.isEmpty())
        camera.cameraReportsRecording(false); runCurrent()
        assertEquals(0, model.recordingElapsed.value)
        advanceTimeBy(60000); runCurrent()
        assertEquals(0, model.statusPresentation().elapsedSeconds)
        model.unbind()
    }

    @Test fun unknownRecordingStartStaysUnknownUntilFreshTransition() = runTest {
        val model = elapsedModel()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsRecording(true); model.bind(camera); runCurrent()
        assertNull(model.statusPresentation().elapsedSeconds)
        assertEquals(17, model.statusPresentation(elapsedSeconds = 17).elapsedSeconds)
        advanceTimeBy(20000); runCurrent()
        assertEquals(null, model.recordingElapsed.value)
        camera.cameraReportsRecording(null); runCurrent()
        assertNull(model.isRecording)
        camera.cameraReportsRecording(true); runCurrent()
        assertNull(model.statusPresentation().elapsedSeconds)
        camera.cameraReportsRecording(false); runCurrent()
        camera.cameraReportsRecording(true); runCurrent()
        assertEquals(0, model.recordingElapsed.value)
        advanceTimeBy(2000); runCurrent()
        assertEquals(2, model.recordingElapsed.value)
        model.unbind()
    }

    @Test fun rebindRetiresElapsedAndOldTicksCannotReachSuccessor() = runTest {
        val model = elapsedModel()
        val first = FakeCameraSession.lunaLike()
        first.cameraReportsStatus(); model.bind(first)
        first.cameraReportsRecording(true); runCurrent()
        advanceTimeBy(3000); runCurrent()
        assertEquals(3, model.recordingElapsed.value)
        val next = FakeCameraSession.lunaLike()
        next.cameraReportsRecording(true); model.bind(next); runCurrent()
        advanceTimeBy(20000); runCurrent()
        assertEquals(next.id, model.state.value.snapshot?.session)
        assertNull(model.statusPresentation().elapsedSeconds)
        next.cameraReportsRecording(false); runCurrent()
        next.cameraReportsRecording(true); runCurrent()
        assertEquals(0, model.recordingElapsed.value)
        advanceTimeBy(1000); runCurrent()
        assertEquals(1, model.recordingElapsed.value)
        first.close(SessionCloseReason.REQUESTED); runCurrent()
        assertEquals(next.id, model.state.value.snapshot?.session)
        assertEquals(1, model.recordingElapsed.value)
        model.unbind()
        advanceTimeBy(20000); runCurrent()
        assertNull(model.statusPresentation().elapsedSeconds)
    }

    @Test fun recoveryRetiresElapsedAndUnknownContinuousRecordingStart() = runTest {
        val model = elapsedModel()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus(); model.bind(camera)
        camera.cameraReportsRecording(true); runCurrent()
        advanceTimeBy(2000); runCurrent()
        assertEquals(2, model.recordingElapsed.value)
        val attempt = camera.loseLink(); runCurrent()
        assertNull(model.statusPresentation().elapsedSeconds)
        camera.completeAttempt(attempt); runCurrent()
        assertEquals(true, model.isRecording)
        assertNull(model.statusPresentation().elapsedSeconds)
        model.unbind()
    }

    private fun TestScope.model() = MonitorControlModel(backgroundScope).also { it.onNote = { note -> notes += note } }

    private fun TestScope.tick() {
        advanceTimeBy(120)
        runCurrent()
    }

    @Test fun coalescedReplacementCarriesItsOwnAdmission() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val first = mutableListOf<CameraCommand>()
        val second = mutableListOf<CameraCommand>()
        model.set(iso(400), "First", admission(camera, AtomicBoolean(false), first))
        model.set(iso(800), "Replacement", admission(camera, AtomicBoolean(true), second))
        tick()
        assertTrue(first.isEmpty())
        assertEquals(1, second.size)
        assertEquals(listOf("set ${iso(800)}"), camera.wire)
        camera.advance(3.seconds)
        runCurrent()
        assertTrue(model.state.value.pending.isEmpty())
        val obsolete = mutableListOf<CameraCommand>()
        val revokedLatest = mutableListOf<CameraCommand>()
        model.set(iso(1600), "Old current", admission(camera, AtomicBoolean(true), obsolete))
        model.set(iso(400), "Latest revoked", admission(camera, AtomicBoolean(false), revokedLatest))
        tick()
        assertTrue(model.state.value.pending.isEmpty())
        assertTrue(obsolete.isEmpty())
        assertTrue(revokedLatest.isEmpty())
        assertEquals(1, camera.wire.size)
    }

    @Test fun revokedWhileCoalescingAndWrongBindingSendNothing() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        val successor = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        successor.cameraReportsStatus()
        model.bind(camera)
        val gate = AtomicBoolean(true)
        val submissions = mutableListOf<CameraCommand>()
        val captured = admission(camera, gate, submissions)
        model.set(iso(800), "Queued", captured)
        runCurrent()
        advanceTimeBy(60)
        gate.set(false)
        advanceTimeBy(60)
        runCurrent()
        assertTrue(model.state.value.pending.isEmpty())
        assertTrue(camera.wire.isEmpty())
        assertTrue(submissions.isEmpty())
        model.bind(successor)
        model.set(iso(800), "Wrong owner", captured)
        tick()
        assertTrue(model.state.value.pending.isEmpty())
        assertTrue(successor.wire.isEmpty())
        assertTrue(submissions.isEmpty())
        model.unbind()
        assertTrue(camera.wire.isEmpty())
        assertTrue(successor.wire.isEmpty())
    }

    @Test fun enteredAdmissionCannotClearSuccessorPending() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val gate = AtomicBoolean(true)
        val first = mutableListOf<CameraCommand>()
        val second = mutableListOf<CameraCommand>()
        model.set(iso(800), "Entered", admission(camera, gate, first))
        tick()
        assertEquals(1, camera.wire.size)
        gate.set(false)
        model.set(iso(1600), "Successor", admission(camera, AtomicBoolean(true), second))
        tick()
        assertEquals(2, camera.wire.size)
        assertEquals(iso(1600), model.state.value.pending[SettingKey.ISO])
        assertEquals(1, first.size)
        assertEquals(1, second.size)
        camera.advance(3.seconds)
        runCurrent()
        assertTrue(model.state.value.pending.isEmpty())
        assertEquals(iso(1600), camera.current.value(SettingKey.ISO).value)
    }

    @Test fun recordConfirmationReusesAdmissionAndCloseSendsNoCommand() = runTest {
        val model = model()
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        model.bind(camera)
        val gate = AtomicBoolean(true)
        val submissions = mutableListOf<CameraCommand>()
        val captured = admission(camera, gate, submissions)
        assertTrue(model.commitRecord(assertNotNull(model.recordEditor()), captured))
        gate.set(false)
        runCurrent()
        assertFalse(model.state.value.recordPending)
        assertTrue(camera.wire.isEmpty())
        assertTrue(submissions.isEmpty())
        val current = admission(camera, AtomicBoolean(true), submissions)
        assertTrue(model.commitRecord(assertNotNull(model.recordEditor()), current))
        runCurrent()
        assertEquals(1, camera.wire.size)
        assertEquals(CameraCommandIntent.StartRecording, submissions.single().intent)
        model.unbind()
        camera.advance(3.seconds)
        camera.close(SessionCloseReason.REQUESTED)
        runCurrent()
        assertFalse(model.state.value.recordPending)
        assertTrue(model.state.value.pending.isEmpty())
        assertEquals(1, camera.wire.size)
    }

    private fun admission(
        camera: FakeCameraSession, gate: AtomicBoolean, submissions: MutableList<CameraCommand>,
    ): CommandDispatchAdmission = CommandDispatchAdmission(camera.id, camera.current.epoch, gate::get) {
        submissions += it
        camera.submit(it)
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
