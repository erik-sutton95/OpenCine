package com.opencapture.opencine.gyro

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * What the feature host presents from the coordinator (Swift twin: GyroCaptureCoordinator's
 * logsPresented and the share failure notice): the logs screen flag and the share failure path.
 */
class GyroCapturePresentationTest {
    @Test
    fun logsPresentedFollowsPresentAndDismiss() = runTest {
        val h = GyroCaptureHarness(this)
        assertFalse(h.state.logsPresented)
        h.coordinator.presentLogs()
        h.settle()
        assertTrue(h.state.logsPresented)
        h.coordinator.presentLogs()
        h.settle()
        assertTrue(h.state.logsPresented)
        h.coordinator.dismissLogs()
        h.settle()
        assertFalse(h.state.logsPresented)
        h.cleanup()
    }

    @Test
    fun logsStayPresentableWhileGyroIsOff() = runTest {
        val h = GyroCaptureHarness(this)
        assertFalse(h.state.enabled)
        h.coordinator.presentLogs()
        h.settle()
        assertTrue(h.state.logsPresented, "Saved logs stay reachable with the toggle off")
        h.coordinator.setEnabled(true)
        h.settle()
        assertTrue(h.state.logsPresented, "Turning Gyro on from the empty state keeps the logs open")
        h.cleanup()
    }

    @Test
    fun shareFailureRaisesTheShareNotice() = runTest {
        val h = GyroCaptureHarness(this)
        assertNull(h.state.notice)
        h.coordinator.reportShareFailed()
        h.settle()
        assertEquals(GyroNotice.SHARE_FAILED, h.state.notice)
        h.coordinator.clearNotice()
        h.settle()
        assertNull(h.state.notice)
        h.cleanup()
    }

    @Test
    fun unknownShareIdsGiveNoFilesAndTheShareNotice() = runTest {
        val h = GyroCaptureHarness(this)
        assertEquals(emptyList(), h.coordinator.shareFiles(listOf(UUID.randomUUID().toString())))
        h.settle()
        assertEquals(GyroNotice.SHARE_FAILED, h.state.notice)
        h.cleanup()
    }
}
