package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

/** SIMULATED actual adapter producer ports and manual clocks, not an Android native SET claim. */
@OptIn(ExperimentalCoroutinesApi::class)
public class DjiRemoteProducerAdmissionTest {
    @Test public fun suppliedISOKeepsItsReceiptAtDeferredPort(): Unit = runTest {
        val port = Port()
        val session = adapter(port)
        val admission = DjiCommandAdmission(port.owner) { true }
        val receipt = session.setIsoIndex(0x06, admission)
        assertEquals(CommandStage.Admitted, receipt.stage)
        assertEquals(listOf("ISO 6"), port.pending.map { it.name })
        assertEquals(listOf(admission.source), port.pending.map { it.admission.source })
        assertTrue(port.enterNext())
        assertEquals(listOf("ISO 6"), port.entered)
        assertEquals(CommandStage.Sent, session.receipt(receipt.operation)?.stage)
        assertEquals(0, port.direct)
    }

    @Test public fun whiteBalanceAndTintWritesKeepTheSameCapturedReceipt(): Unit = runTest {
        val port = Port()
        val session = adapter(port)
        val admission = DjiCommandAdmission(port.owner) { true }
        val receipt = session.setWhiteBalanceCustom(5679, 7, admission)
        assertEquals(listOf("WB 5700 0", "WB 5700 7"), port.pending.map { it.name })
        assertEquals(listOf(admission.source, admission.source), port.pending.map { it.admission.source })
        assertTrue(port.enterNext())
        port.owner.replaceSource()
        assertFalse(port.enterNext())
        assertEquals(listOf("WB 5700 0"), port.entered)
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), session.receipt(receipt.operation)?.stage)
        assertEquals(0, port.direct)
    }

    @Test public fun autoWhiteBalanceWithNilTintPreservesThePendingTint(): Unit = runTest {
        val port = Port()
        port.state = port.state.copy(
            whiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, 5600, 1),
            pendingWhiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, 5600, -12),
        )
        val session = adapter(port)
        session.setWhiteBalanceAuto(admission = DjiCommandAdmission(port.owner) { true })
        assertEquals(listOf("WB Auto -12"), port.pending.map { it.name })
        assertTrue(port.enterNext())
        assertEquals(listOf("WB Auto -12"), port.entered)
    }

    @Test public fun confirmationKeepsApprovedTargetAndRefusesARepairedLink(): Unit = runTest {
        val port = Port()
        val session = adapter(port)
        val shown = session.current
        val approved = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(shown))
        port.state = port.state.copy(linkReady = false, recovering = true)
        session.linkDidChange()
        session.sessionDidChange()
        port.state = port.state.copy(linkReady = true, recovering = false)
        session.sessionDidChange()
        assertNotEquals(shown.epoch, session.current.epoch)
        val refused = session.submit(approved, DjiCommandAdmission(port.owner) { true })
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), refused.stage)
        assertTrue(port.pending.isEmpty())
        assertTrue(port.entered.isEmpty())
        assertEquals(0, port.direct)
    }

    @Test public fun currentConfirmationDispatchesOnceAndEnteredCompletionSurvivesRetirement(): Unit = runTest {
        val port = Port()
        val session = adapter(port)
        val approved = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(session.current))
        val receipt = session.submit(approved, DjiCommandAdmission(port.owner) { true })
        assertTrue(port.enterNext())
        port.owner.replaceSource()
        port.enteredStage?.invoke(ControlWireEvent.ACKNOWLEDGED)
        assertEquals(CommandStage.AwaitingObservation, session.receipt(receipt.operation)?.stage)
        port.state = port.state.copy(recording = true)
        session.sessionDidChange()
        assertEquals(listOf("Record true"), port.entered)
        assertEquals(CommandStage.Confirmed, session.receipt(receipt.operation)?.stage)
        assertTrue(port.pending.isEmpty())
    }

    @Test public fun photoRefusesExpiredReceiptAndDirectPhotoStillUsesTheOriginalPort(): Unit = runTest {
        val port = Port()
        port.state = port.state.copy(shootingMode = CameraCommands.SHOOT_PHOTO)
        val session = adapter(port)
        val old = DjiCommandAdmission(port.owner) { true }
        port.owner.replaceSource()
        assertNull(session.shutter(old))
        assertEquals(0, port.photos)
        assertNull(session.shutter())
        assertEquals(1, port.direct)
        assertNull(session.shutter(DjiCommandAdmission(port.owner) { true }))
        assertEquals(1, port.photos)
        assertEquals(1, port.direct)
        assertTrue(port.pending.isEmpty())
    }

    private fun TestScope.adapter(port: Port): DjiCameraSessionAdapter =
        DjiCameraSessionAdapter(port, backgroundScope) { MonotonicInstant(testScheduler.currentTime.milliseconds) }

    private class Port : PocketControlPort {
        data class Pending(
            val name: String,
            val admission: DjiCommandAdmission,
            val stage: ((ControlWireEvent) -> Unit)?,
        )
        val owner = DjiCommandOwner()
        override val commandOwner: DjiCommandOwner get() = owner
        var state = PocketControlState(
            linkReady = true, phase = ConnectionPhase.LIVE, shootingMode = CameraCommands.SHOOT_VIDEO,
            isoChoices = listOf(0x00, 0x03, 0x04, 0x05, 0x06, 0x07), isoIndex = 0x03,
            whiteBalance = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, 0), recording = false,
        )
        val pending = mutableListOf<Pending>()
        val entered = mutableListOf<String>()
        var enteredStage: ((ControlWireEvent) -> Unit)? = null
        var direct = 0
        var photos = 0
        fun enterNext(): Boolean {
            val next = pending.removeAt(0)
            if (!next.admission.admits(owner)) {
                next.stage?.invoke(ControlWireEvent.NOT_SENT)
                return false
            }
            entered += next.name
            enteredStage = next.stage
            next.stage?.invoke(ControlWireEvent.SENT)
            return true
        }
        override fun controlState(): PocketControlState = state
        override fun setIsoIndex(index: Int, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?) {
            pending += Pending("ISO $index", admission, onStage)
        }
        override fun setWhiteBalanceAuto(tint: Int?, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?) {
            val value = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0,
                tint ?: state.pendingWhiteBalance?.tint ?: state.whiteBalance?.tint ?: 0)
            state = state.copy(pendingWhiteBalance = value)
            pending += Pending("WB Auto ${value.tint}", admission, onStage)
        }
        override fun setWhiteBalance(kelvin: Int, tint: Int, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?) {
            state = state.copy(pendingWhiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, kelvin, tint))
            pending += Pending("WB $kelvin $tint", admission, onStage)
        }
        override fun setRecording(start: Boolean, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?) {
            pending += Pending("Record $start", admission, onStage)
        }
        override fun takePhoto(admission: DjiCommandAdmission) { if (admission.admits(owner)) photos++ }
        override fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)?) { direct++ }
        override fun setWhiteBalanceAuto(tint: Int?, onStage: ((ControlWireEvent) -> Unit)?) { direct++ }
        override fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)?) { direct++ }
        override fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)?) { direct++ }
        override fun takePhoto() { direct++ }
        override fun noteControlRejection(note: String): Unit = Unit
    }
}
