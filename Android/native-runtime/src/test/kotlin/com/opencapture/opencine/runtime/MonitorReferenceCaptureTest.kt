package com.opencapture.opencine.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest

class MonitorReferenceCaptureTest {
    @Test fun onlyTheRequestedFrameCanFulfillTheReadback() = runTest {
        val capture = MonitorReferenceCapture<String>()
        val result = async(start = CoroutineStart.UNDISPATCHED) { capture.capture(accepts = { it == 10L }) }
        var copiedPrevious = false
        capture.offer(9L) { copiedPrevious = true; "previous" }
        assertFalse(copiedPrevious)
        assertTrue(capture.needsFrame(10))
        capture.offer(10) { "visible frame" }
        assertEquals("visible frame", result.await())
        assertFalse(capture.needsFrame(10))
    }

    @Test fun cancellationRetiresTheCurrentRequestAndTheNextRequestWorks() = runTest {
        val capture = MonitorReferenceCapture<String>()
        val first = async(start = CoroutineStart.UNDISPATCHED) { capture.capture() }
        assertNull(capture.capture())
        capture.cancel()
        assertNull(first.await())
        val next = async(start = CoroutineStart.UNDISPATCHED) { capture.capture() }
        capture.offer(42) { "replacement" }
        assertEquals("replacement", next.await())
    }
}
