package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingValue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED native scheduling through the actual public common Nikon submission port. */
@OptIn(ExperimentalCoroutinesApi::class)
class NikonOpenCineAdmissionTest {
    @Test fun authorityCaptureSurvivesReadbackButNotSurrenderAndRegrant() = runTest {
        val native = Native()
        val session = NikonOpenCineSession(native, backgroundScope)
        val captured = session.captureCommandAuthority()
        native.reportedRecording.value = true
        session.refresh()
        assertTrue(captured(), "Unrelated camera observations do not retire source authority")
        session.setHoldsControl(false)
        session.setHoldsControl(true)
        assertFalse(captured(), "A held native job must not revive after authority returns")
        val current = session.captureCommandAuthority()
        assertTrue(current())
        session.closeNow(SessionCloseReason.REQUESTED)
        assertFalse(current())
    }

    @Test fun currentAndDirectOperationsPreserveNativeLabelsAndRecordingObservation() = runTest {
        val native = Native()
        val session = NikonOpenCineSession(native, backgroundScope)
        val admission = CameraCommandAdmission(native) { true }
        val write = session.submit(command(session, CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(1600)))), admission)
        assertEquals(CommandStage.Confirmed, write.stage)
        assertEquals(listOf(CameraControl.ISO to "1600"), native.writes)
        assertEquals(1, native.receipts.size)
        val record = session.submit(command(session, CameraCommandIntent.StartRecording), admission)
        assertEquals(CommandStage.AwaitingObservation, record.stage)
        native.reportedRecording.value = true
        session.refresh()
        assertEquals(CommandStage.Confirmed, session.receipt(record.operation)?.stage)
        assertEquals(listOf(true), native.records)
        session.submit(command(session, CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800)))))
        assertEquals(listOf(CameraControl.ISO to "1600", CameraControl.ISO to "800"), native.writes)
        assertEquals(2, native.receipts.size)
        session.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(listOf(true), native.records)
    }

    @Test fun revokedAndWrongSourceReceiptsRefuseWithoutNativeDispatchOrOptimisticReports() = runTest {
        val native = Native()
        val session = NikonOpenCineSession(native, backgroundScope)
        val current = AtomicBoolean(true)
        val admission = CameraCommandAdmission(native, current::get)
        val other = CameraCommandAdmission(Native()) { true }
        current.set(false)
        val before = session.refresh()
        for (receipt in listOf(admission, other)) {
            val result = session.submit(command(session, CameraCommandIntent.StartRecording), receipt)
            assertEquals(CommandStage.Rejected(CommandRejection.AuthorityExpired), result.stage)
        }
        assertEquals(before.recording, session.refresh().recording)
        assertTrue(native.receipts.isEmpty() && native.records.isEmpty() && native.writes.isEmpty())
        val direct = session.submit(command(session, CameraCommandIntent.StartRecording))
        assertEquals(CommandStage.AwaitingObservation, direct.stage)
        assertEquals(listOf(true), native.records)
        session.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(listOf(true), native.records)
    }

    @Test fun waitingNativeDispatchRechecksButEnteredWriteCompletionStaysAuthoritative() = runTest {
        for (hold in Hold.entries) {
            val native = Native(hold)
            val session = NikonOpenCineSession(native, backgroundScope)
            val current = AtomicBoolean(true)
            val admission = CameraCommandAdmission(native, current::get)
            val dispatch = async {
                session.submit(command(session, CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(1600)))), admission)
            }
            runCurrent()
            assertTrue(native.entered.isCompleted)
            assertEquals(if (hold == Hold.BEFORE_SEND) 0 else 1, native.writes.size)
            current.set(false)
            native.release.complete(Unit)
            runCurrent()
            assertEquals(if (hold == Hold.BEFORE_SEND) CommandStage.Rejected(CommandRejection.CameraRefused)
                else CommandStage.Confirmed, dispatch.await().stage)
            assertEquals(if (hold == Hold.BEFORE_SEND) emptyList() else listOf(CameraControl.ISO to "1600"), native.writes)
            assertFalse(admission.admits(Native()))
            val beforeClose = native.writes.toList()
            session.closeNow(SessionCloseReason.REQUESTED)
            assertEquals(beforeClose, native.writes)
        }
    }

    @Test fun enteredRecordStillWaitsForRealObservationAfterReceiptRetirement() = runTest {
        val native = Native(Hold.AFTER_SEND)
        val session = NikonOpenCineSession(native, backgroundScope)
        val current = AtomicBoolean(true)
        val admission = CameraCommandAdmission(native, current::get)
        val dispatch = async { session.submit(command(session, CameraCommandIntent.StartRecording), admission) }
        runCurrent()
        assertEquals(listOf(true), native.records)
        current.set(false)
        native.release.complete(Unit)
        runCurrent()
        val receipt = dispatch.await()
        assertEquals(CommandStage.AwaitingObservation, receipt.stage)
        native.reportedRecording.value = true
        session.refresh()
        assertEquals(CommandStage.Confirmed, session.receipt(receipt.operation)?.stage)
        session.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(listOf(true), native.records)
    }

    private fun command(session: NikonOpenCineSession, intent: CameraCommandIntent): CameraCommand =
        CameraCommand(intent, CommandPreconditions(session.refresh()))

    private enum class Hold { BEFORE_SEND, AFTER_SEND }
    private class Native(private val hold: Hold? = null) : CameraSession {
        override val state = MutableStateFlow<CameraSessionState>(
            CameraSessionState.Connected(CameraIdentity("ZR", "ZR", "same-serial")))
        override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(
            iso = 800, isoAuto = false, exposureMode = "M", captureSelector = "video", codec = "H.265 10-bit MOV",
            controlCapabilities = CameraControlCapabilities(isoValues = listOf("800", "1600"))))
        val records = mutableListOf<Boolean>()
        val writes = mutableListOf<Pair<CameraControl, String>>()
        val receipts = mutableListOf<CameraCommandAdmission>()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        override suspend fun connect() = Unit
        override suspend fun disconnect() = Unit
        override suspend fun setRecording(recording: Boolean) { records += recording }
        override suspend fun applyControl(control: CameraControl, label: String) { writes += control to label }
        override suspend fun setRecording(recording: Boolean, admission: CameraCommandAdmission) {
            receipts += admission
            if (hold == Hold.BEFORE_SEND) pause()
            if (!admission.admits(this)) throw CameraRecordingException.CommandRejected
            setRecording(recording)
            if (hold == Hold.AFTER_SEND) pause()
        }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            receipts += admission
            if (hold == Hold.BEFORE_SEND) pause()
            if (!admission.admits(this)) throw CameraControlException.CommandRejected
            applyControl(control, label)
            if (hold == Hold.AFTER_SEND) pause()
        }
        private suspend fun pause() { entered.complete(Unit); release.await() }
    }
}
