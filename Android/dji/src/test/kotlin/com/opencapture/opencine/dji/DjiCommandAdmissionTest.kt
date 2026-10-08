package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class DjiCommandAdmissionTest {
    @Test fun sourceReplacementAndPermanentCloseRetireOldReceipts() {
        val owner = DjiCommandOwner()
        val old = DjiCommandAdmission(owner) { true }
        assertTrue(old.admits(owner))
        assertFalse(old.admits(DjiCommandOwner()))
        owner.replaceSource()
        assertFalse(old.isCurrent)
        val current = DjiCommandAdmission(owner) { true }
        assertNotEquals(old.source, current.source)
        assertTrue(current.isCurrent)
        owner.retire(); owner.replaceSource()
        val afterClose = DjiCommandAdmission(owner) { true }
        assertFalse(afterClose.isCurrent)
        assertFailsWith<DjiCommandAdmissionException> { afterClose.requireCurrent() }
    }

    @Test fun anEnteredNativeCallCompletesAfterRevocation() {
        val owner = DjiCommandOwner()
        val active = AtomicBoolean(true)
        val admission = DjiCommandAdmission(owner) { active.get() }
        var entered = 0
        val result = admission.perform {
            entered++; active.set(false); owner.replaceSource()
            "original completion"
        }
        assertEquals("original completion", result)
        assertEquals(1, entered)
        assertFailsWith<DjiCommandAdmissionException> { admission.perform { entered++ } }
        assertEquals(1, entered)
    }

    @Test fun sourceBoundAdmissionIsExplicitAndDirectOperationsRemainUnchanged() = runTest {
        val port = Port()
        val active = AtomicBoolean(true)
        val admission = DjiCommandAdmission(port.nativeOwner) { active.get() }
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val supplied = session.request(iso(800), admission)
        assertEquals(CommandStage.Admitted, supplied.stage)
        assertEquals(listOf(admission.source), port.pending.map { it.admission.source })
        active.set(false); port.deliverNext()
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), session.receipt(supplied.operation)?.stage)
        assertTrue(port.writes.isEmpty())
        val direct = session.request(iso(400))
        assertEquals(CommandStage.Sent, direct.stage)
        assertEquals(listOf(0x05), port.writes)
    }

    @Test fun independentQueuedReceiptsDoNotBorrowEachOthersAuthority() = runTest {
        val port = Port()
        val firstActive = AtomicBoolean(true)
        val secondActive = AtomicBoolean(true)
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val first = session.request(iso(800), DjiCommandAdmission(port.nativeOwner) { firstActive.get() })
        val second = session.request(iso(400), DjiCommandAdmission(port.nativeOwner) { secondActive.get() })
        firstActive.set(false); port.deliverNext(); port.deliverNext()
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), session.receipt(first.operation)?.stage)
        assertEquals(CommandStage.Sent, session.receipt(second.operation)?.stage)
        assertEquals(listOf(0x05), port.writes)
    }

    @Test fun replacedNativeSourceAndWrongOwnerSendNothing() = runTest {
        val port = Port()
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val old = DjiCommandAdmission(port.nativeOwner) { true }
        val pending = session.request(iso(800), old)
        port.nativeOwner.replaceSource(); port.deliverNext()
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), session.receipt(pending.operation)?.stage)
        assertEquals(CommandStage.Rejected(CommandRejection.AuthorityExpired), session.request(iso(400), old).stage)
        assertEquals(
            CommandStage.Rejected(CommandRejection.AuthorityExpired),
            session.request(iso(400), DjiCommandAdmission(DjiCommandOwner()) { true }).stage,
        )
        assertTrue(port.writes.isEmpty())
    }

    @Test fun unavailableSuppliedPortNeverFallsThroughToDirectWrite() = runTest {
        val port = Port()
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val intent = CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)))
        val supplied = session.request(intent, DjiCommandAdmission(port.nativeOwner) { true })
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), supplied.stage)
        assertEquals(0, port.otherDirectWrites)
        session.request(intent)
        assertEquals(1, port.otherDirectWrites)
    }

    @Test fun enteredWriteKeepsItsAcknowledgementAndReadbackAfterRevocation() = runTest {
        val port = Port()
        val active = AtomicBoolean(true)
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val receipt = session.request(iso(800), DjiCommandAdmission(port.nativeOwner) { active.get() })
        port.deliverNext(); active.set(false); port.stage?.invoke(ControlWireEvent.ACKNOWLEDGED)
        assertEquals(CommandStage.AwaitingObservation, session.receipt(receipt.operation)?.stage)
        port.state = port.state.copy(isoIndex = 0x06); session.sessionDidChange()
        assertEquals(CommandStage.Confirmed, session.receipt(receipt.operation)?.stage)
        assertEquals(listOf(0x06), port.writes)
    }

    @Test fun closeDoesNotDispatchQueuedCommands() = runTest {
        val port = Port()
        val session = DjiCameraSessionAdapter(port, backgroundScope)
        val receipt = session.request(iso(800), DjiCommandAdmission(port.nativeOwner) { true })
        session.close(SessionCloseReason.REQUESTED); port.nativeOwner.retire(); port.deliverNext()
        assertTrue(session.receipt(receipt.operation)?.isFinished == true)
        assertTrue(port.writes.isEmpty())
    }

    private fun iso(value: Int): CameraCommandIntent = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(value)))

    private class Port : PocketControlPort {
        data class Pending(val index: Int, val admission: DjiCommandAdmission, val stage: ((ControlWireEvent) -> Unit)?)
        val nativeOwner = DjiCommandOwner()
        override val commandOwner: DjiCommandOwner get() = nativeOwner
        var state = PocketControlState(
            linkReady = true, phase = ConnectionPhase.LIVE, shootingMode = CameraCommands.SHOOT_VIDEO,
            isoChoices = listOf(0x00, 0x03, 0x04, 0x05, 0x06, 0x07), isoIndex = 0x03,
            whiteBalance = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, 0), recording = false,
        )
        val writes = mutableListOf<Int>()
        val pending = mutableListOf<Pending>()
        var otherDirectWrites = 0
        var stage: ((ControlWireEvent) -> Unit)? = null
        fun deliverNext() {
            val next = pending.removeAt(0)
            if (!next.admission.admits(nativeOwner)) { next.stage?.invoke(ControlWireEvent.NOT_SENT); return }
            writes += next.index; stage = next.stage; next.stage?.invoke(ControlWireEvent.SENT)
        }
        override fun controlState(): PocketControlState = state
        override fun setIsoIndex(index: Int, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?) {
            pending += Pending(index, admission, onStage)
        }
        override fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)?) {
            writes += index; stage = onStage; onStage?.invoke(ControlWireEvent.SENT)
        }
        override fun setWhiteBalanceAuto(tint: Int?, onStage: ((ControlWireEvent) -> Unit)?) { otherDirectWrites++ }
        override fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)?) { otherDirectWrites++ }
        override fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)?) { otherDirectWrites++ }
        override fun takePhoto() { otherDirectWrites++ }
        override fun noteControlRejection(note: String) = Unit
    }
}
