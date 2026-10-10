package com.opencapture.opencine.dji

import com.opencapture.opencine.media.*
import com.opencapture.opencine.vocabulary.MediaFile
import com.opencapture.opencine.vocabulary.MediaHTTP
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class DJIMediaHTTPSourceTest {
    private val file = MediaFile(path = "DCIM/DJI_001/a.MP4", thumbPath = "a.scr", storage = 0, sizeBytes = 17)
    @Test fun actualRoutingKeepsStorageAndURLIdentities() {
        val source = DJIMediaHTTPSource()
        assertEquals(listOf(0, 1), source.resources(file.path, 0).map { it.storage })
        assertEquals(listOf(1, 0), source.resources(file.path, 1).map { it.storage })
        assertEquals(listOf(MediaHTTP.pathUrlString(0, file.path), MediaHTTP.pathUrlString(1, file.path)),
            source.resources(file.path, 0).map { it.url })
        source.rememberStorage(1, file.path)
        assertEquals(0, source.resolvedStorage(file, true))
    }
    @Test fun proxyLengthNeverInheritsOriginalSize() {
        val source = DJIMediaHTTPSource()
        val read: suspend (DJIMediaHTTPResource, Long?, MediaByteSink) -> MediaTransferReceipt = { _, _, _ -> MediaTransferReceipt(1) }
        val original = source.transferPlan(file, file.path, false, read)
        val proxy = source.transferPlan(file, "a.LRF", false, read)
        assertEquals(17L, original.expectedByteCount); assertEquals(2, original.attempts.size)
        assertNull(proxy.expectedByteCount); assertEquals(2, proxy.attempts.size)
    }
    @Test fun acceptedStorageWinnerAppliesOnlyToSuccessfulPlan() {
        val source = DJIMediaHTTPSource()
        val plan = source.transferPlan(file, file.path, false) { _, _, _ -> MediaTransferReceipt(1) }
        assertEquals(0, source.resolvedStorage(file, false))
        plan.accepted?.invoke(1, MediaTransferReceipt(1))
        assertEquals(1, source.resolvedStorage(file, false))
        source.reset(); assertEquals(0, source.resolvedStorage(file, false))
    }
    @Test fun cancellationAndRetirementNeverRetry() {
        val source = DJIMediaHTTPSource()
        val original = source.transferPlan(file, file.path, false) { _, _, _ -> MediaTransferReceipt(1) }
        val proxy = source.transferPlan(file, "a.LRF", false) { _, _, _ -> MediaTransferReceipt(1) }
        assertTrue(original.retry(DJIMediaHTTPError.HttpStatus(404)))
        assertTrue(original.retry(DJIMediaHTTPError.HttpStatus(403)))
        assertFalse(original.retry(DJIMediaHTTPError.HttpStatus(500)))
        // Preserve Android's original server refusal, even for a proxy; Swift retries it.
        assertFalse(proxy.retry(DJIMediaHTTPError.HttpStatus(500)))
        assertFalse(proxy.retry(CancellationException()))
        assertFalse(proxy.retry(MediaServiceException(MediaServiceFailure.RETIRED)))
    }
    @Test fun readReentrySuppressesOutgoingSuccess() = runTest {
        val source = DJIMediaHTTPSource(); var current = true; var requests = 0
        val result = runCatching { source.read(file.path, 0, { current }) {
            requests += 1; current = false; byteArrayOf(9)
        } }
        assertIs<MediaServiceException>(result.exceptionOrNull())
        assertEquals(1, requests); assertEquals(0, source.resolvedStorage(file, false))
    }
}
