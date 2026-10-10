package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorWatcherTapSourceTest {
    private fun context(revision: Long = 1, source: String = "first", control: Boolean = true, recording: Boolean = false) =
        MonitorWatcherContext(source, revision, control, recording)

    @Test fun currentSourceAndLeaseAdmitTheCapturedTap() {
        val captured = context().tapSource
        assertTrue(captured.admits(context().tapSource))
    }

    @Test fun anotherProducerCannotBorrowTheCapturedTap() {
        val captured = context().tapSource
        assertFalse(captured.admits(context(source = "second").tapSource))
    }

    @Test fun sourceAndLeaseABARefuseTheOldRevision() {
        val captured = context().tapSource
        assertFalse(captured.admits(context(3).tapSource))
    }

    @Test fun readOnlyCaptureAndCurrentLeaseBothRefuse() {
        val controlled = context().tapSource
        val readOnly = context(control = false).tapSource
        assertFalse(controlled.admits(readOnly))
        assertFalse(readOnly.admits(controlled))
    }

    @Test fun recordingOnlyReportsDoNotRetireAPictureGesture() {
        val captured = context().tapSource
        assertEquals(captured, context(recording = true).tapSource)
        assertTrue(captured.admits(context(recording = true).tapSource))
    }

    @Test fun lateFocusCannotReplaceOrClearTheSuccessorFocus() {
        val owner = MonitorWatcherInteraction()
        val current = context(2).tapSource
        val successor = MonitorWatcherFocus(current, 0.8, 0.2)
        assertTrue(owner.applyFocus(successor, current))
        assertFalse(owner.applyFocus(MonitorWatcherFocus(context().tapSource, 0.1, 0.9), current))
        assertEquals(successor, owner.focus)
    }

    @Test fun retirementOnlyClearsANonCurrentFocus() {
        val owner = MonitorWatcherInteraction()
        val first = context().tapSource
        val mark = MonitorWatcherFocus(first, 0.4, 0.6)
        assertTrue(owner.applyFocus(mark, first))
        owner.retireFocus(first)
        assertEquals(mark, owner.focus)
        owner.retireFocus(context(2).tapSource)
        assertNull(owner.focus)
    }

    @Test fun recordingDialogCancellationDoesNotClearCurrentFocus() {
        val owner = MonitorWatcherInteraction()
        val current = context()
        val mark = MonitorWatcherFocus(current.tapSource, 0.3, 0.7)
        assertTrue(owner.applyFocus(mark, current.tapSource))
        assertNull(owner.requestRecording(current, true))
        owner.update(context(recording = true), true)
        assertNull(owner.pendingRecording)
        assertEquals(mark, owner.focus)
    }
}
