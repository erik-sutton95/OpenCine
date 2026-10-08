package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorWatcherInteractionTest {
    private fun context(revision: Long = 1, control: Boolean = true, recording: Boolean = false, source: String = "first") =
        MonitorWatcherContext(source, revision, control, recording)
    private fun value(context: MonitorWatcherContext, choices: List<Int> = listOf(1, 2)) = MonitorWatcherPresentation(
        context, "Camera", null, emptyList(), listOf(MonitorWatcherSettingValue(MonitorWatcherSetting.ISO, "ISO",
            choices.map { MonitorWatcherChoice(it, "Choice $it") })), "Host", false, false, null)
    @Test fun confirmationCapturesExplicitTargetAndConsumesOnce() {
        val owner = MonitorWatcherInteraction(); val current = context()
        assertNull(owner.requestRecording(current, true))
        assertEquals(MonitorWatcherAction.Record(current, true), owner.confirmRecording(current))
        assertNull(owner.confirmRecording(current))
    }
    @Test fun leaseLossAndRegainCannotReplayOldConfirmation() {
        val owner = MonitorWatcherInteraction(); owner.requestRecording(context(), true)
        assertNull(owner.confirmRecording(context(3)))
        assertFalse(value(context(3)).admits(MonitorWatcherAction.Record(context(), true)))
    }
    @Test fun changedRecordingReportCannotTurnStartIntoStop() {
        val owner = MonitorWatcherInteraction(); owner.requestRecording(context(), true)
        assertNull(owner.confirmRecording(context(recording = true)))
        assertFalse(value(context(recording = true)).admits(MonitorWatcherAction.Record(context(), true)))
    }
    @Test fun cleanCancelAndSourceReentryRetirePendingActionWithoutACommand() {
        val owner = MonitorWatcherInteraction(); owner.requestRecording(context(), true)
        owner.update(context(), true); assertNull(owner.confirmRecording(context()))
        owner.requestRecording(context(), true); owner.update(context(source = "second"), false)
        assertNull(owner.pendingRecording)
        val second = context(source = "second")
        assertEquals(MonitorWatcherAction.Record(second, true), owner.requestRecording(second, false))
    }
    @Test fun removedChoiceAndReadOnlySourceRefuseCapturedMenuActions() {
        val command = MonitorWatcherAction.Set(context(), MonitorWatcherSetting.ISO, 2)
        assertTrue(value(context()).admits(command))
        assertFalse(value(context(), listOf(1)).admits(command))
        assertFalse(value(context(control = false)).admits(command))
    }
    @Test fun repeatedLeaseReportKeepsValidPendingConfirmation() {
        val owner = MonitorWatcherInteraction(); owner.requestRecording(context(), true)
        owner.update(context(), false); assertEquals(context(), owner.pendingRecording)
        owner.cancel(); assertNull(owner.pendingRecording)
    }
}
