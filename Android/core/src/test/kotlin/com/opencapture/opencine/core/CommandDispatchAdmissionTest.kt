package com.opencapture.opencine.core

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** Same local queued-authority scenarios as Swift; actual wire values are untouched. */
@OptIn(ExperimentalCoroutinesApi::class)
class CommandDispatchAdmissionTest {
    @Test fun currentAdmissionDispatchesExactOperationAndRejectsWrongSessionOrEpoch() = runTest {
        val source = CameraSessionID()
        val command = CameraCommand(CameraCommandIntent.StartRecording,
            CommandPreconditions(source, ControlEpoch(7), CapabilityRevision(2)))
        val commands = mutableListOf<CameraCommand>()
        val admission = CommandDispatchAdmission(source, ControlEpoch(7), { true }) {
            commands += it
            receipt(it)
        }
        val current = admission.dispatch(command, source)
        assertEquals(command.operation, current.operation)
        assertEquals(CommandStage.Accepted, current.stage)
        assertEquals(listOf(command), commands)
        assertEquals(CommandStage.Rejected(CommandRejection.WrongSession), admission.dispatch(command, CameraSessionID()).stage)
        val stale = command.copy(preconditions = command.preconditions.copy(epoch = ControlEpoch(8)))
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), admission.dispatch(stale, source).stage)
        assertEquals(listOf(command), commands)
    }

    @Test fun revokedAdmissionNeverCallsSubmissionPort() = runTest {
        val source = CameraSessionID()
        val command = CameraCommand(CameraCommandIntent.StopRecording,
            CommandPreconditions(source, ControlEpoch(1), CapabilityRevision(1)))
        val commands = mutableListOf<CameraCommand>()
        val admission = CommandDispatchAdmission(source, ControlEpoch(1), { false }) { commands += it; receipt(it) }
        val refused = admission.dispatch(command, source)
        assertEquals(command.operation, refused.operation)
        assertEquals(CommandStage.Rejected(CommandRejection.AuthorityExpired), refused.stage)
        assertTrue(refused.isFinished)
        assertTrue(commands.isEmpty())
        val brokenPredicate = CommandDispatchAdmission(source, ControlEpoch(1), { error("retired producer") }) {
            commands += it; receipt(it)
        }
        assertEquals(refused.stage, brokenPredicate.dispatch(command, source).stage)
        assertTrue(commands.isEmpty())
    }

    @Test fun enteredSubmissionCompletesAfterRevocation() = runTest {
        val source = CameraSessionID()
        val command = CameraCommand(CameraCommandIntent.StartRecording,
            CommandPreconditions(source, ControlEpoch(1), CapabilityRevision(1)))
        val gate = AtomicBoolean(true)
        val finish = CompletableDeferred<Unit>()
        val commands = mutableListOf<CameraCommand>()
        val admission = CommandDispatchAdmission(source, ControlEpoch(1), gate::get) {
            commands += it; finish.await(); receipt(it)
        }
        val submitting = async { admission.dispatch(command, source) }
        runCurrent()
        assertEquals(listOf(command), commands)
        gate.set(false)
        finish.complete(Unit)
        assertEquals(CommandStage.Accepted, submitting.await().stage)
        assertEquals(CommandStage.Rejected(CommandRejection.AuthorityExpired), admission.dispatch(command, source).stage)
        assertEquals(listOf(command), commands)
    }
    private fun receipt(command: CameraCommand): CommandReceipt = CommandReceipt(
        command.operation, command.preconditions.session, command.intent,
        CommandStage.Accepted, SettingSemantics.Confirmation.ACKNOWLEDGEMENT_ONLY,
    )
}
