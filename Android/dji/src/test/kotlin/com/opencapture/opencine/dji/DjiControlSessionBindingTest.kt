package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

class DjiControlSessionBindingTest {
    @Test fun ownedCloseReleasesNativeOwnerExactlyOnce() = runTest {
        val port = BindingPort()
        val closes = mutableListOf<SessionCloseReason>()
        val binding = DjiControlSessionBinding(port, backgroundScope, closes::add, clock)
        assertNull(binding.cached)
        val session = binding.session
        assertSame(session, binding.session)
        session.closeNow(SessionCloseReason.REQUESTED)
        session.closeNow(SessionCloseReason.REPLACED)
        assertEquals(listOf(SessionCloseReason.REQUESTED), closes)
        assertNull(binding.cached)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), session.current.connection)
        assertTrue(port.fired.isEmpty())
    }

    @Test fun replacementAndLateCloseCannotReleaseSuccessor() = runTest {
        val port = BindingPort()
        val closes = mutableListOf<SessionCloseReason>()
        val binding = DjiControlSessionBinding(port, backgroundScope, closes::add, clock)
        val first = binding.session
        val oldCommand = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(first.current))
        binding.beginConnection()
        port.state = port.state.copy(cameraId = "camera-b")
        val successor = binding.session
        assertNotEquals(first.id, successor.id)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REPLACED), first.current.connection)
        first.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), first.send(oldCommand).stage)
        assertSame(successor, binding.session)
        assertEquals(ConnectionState.Ready, successor.current.connection)
        assertTrue(closes.isEmpty())
        assertTrue(port.fired.isEmpty())
        successor.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(listOf(SessionCloseReason.REQUESTED), closes)
    }

    @Test fun recoveryKeepsIdentityButRejectsOldLinkCommand() = runTest {
        val port = BindingPort()
        val closes = mutableListOf<SessionCloseReason>()
        val binding = DjiControlSessionBinding(port, backgroundScope, closes::add, clock)
        val session = binding.session
        val before = session.current
        port.state = port.state.copy(recovering = true)
        session.linkDidChange()
        assertSame(session, binding.session)
        assertNotEquals(before.epoch, session.current.epoch)
        port.state = port.state.copy(recovering = false)
        val command = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(before))
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), session.send(command).stage)
        assertTrue(closes.isEmpty())
        assertTrue(port.fired.isEmpty())
    }

    @Test fun nativeTeardownAndBorrowedReturnRetireWithoutClosingOwner() = runTest {
        val port = BindingPort()
        var nativeCloses = 0
        val binding = DjiControlSessionBinding(port, backgroundScope, { nativeCloses++ }, clock)
        val borrowed = binding.session
        binding.retire(SessionCloseReason.REQUESTED)
        binding.retire(SessionCloseReason.REQUESTED)
        borrowed.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), borrowed.current.connection)
        assertEquals(0, nativeCloses)
        assertTrue(port.fired.isEmpty())
        assertNotEquals(borrowed.id, binding.session.id)
    }

    @Test fun reentrantNativeTeardownCannotCloseAgain() = runTest {
        val port = BindingPort()
        var nativeCloses = 0
        var teardown: (() -> Unit)? = null
        val binding = DjiControlSessionBinding(port, backgroundScope, { nativeCloses++; teardown?.invoke() }, clock)
        val session = binding.session
        teardown = { binding.retire(SessionCloseReason.REQUESTED) }
        session.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(1, nativeCloses)
        assertNull(binding.cached)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), session.current.connection)
    }

    @Test fun closeWhileRecordingNeverSendsStopRecord() = runTest {
        val port = BindingPort()
        port.state = port.state.copy(recording = true)
        var nativeCloses = 0
        val binding = DjiControlSessionBinding(port, backgroundScope, { nativeCloses++ }, clock)
        val session = binding.session
        assertEquals(RecordingState.RECORDING, session.current.recording.value)
        session.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(1, nativeCloses)
        assertTrue(port.fired.isEmpty())
        assertEquals(true, port.state.recording)
    }

    private val clock = { MonotonicInstant(10.seconds) }

    private class BindingPort : PocketControlPort {
        var state = PocketControlState(linkReady = true, phase = ConnectionPhase.LIVE,
            cameraId = "camera-a", shootingMode = CameraCommands.SHOOT_VIDEO, recording = false)
        val fired = mutableListOf<String>()
        override fun controlState() = state
        override fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)?) { fired += "iso" }
        override fun setWhiteBalanceAuto(tint: Int?, onStage: ((ControlWireEvent) -> Unit)?) { fired += "wb" }
        override fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)?) { fired += "wb" }
        override fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)?) { fired += "record $start" }
        override fun takePhoto() { fired += "photo" }
        override fun noteControlRejection(note: String) = Unit
    }
}
