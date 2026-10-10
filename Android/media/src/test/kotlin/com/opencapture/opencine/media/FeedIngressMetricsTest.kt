package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FeedIngressMetricsTest {
    @Test
    fun distinguishesArrivingButRejectedVideoFromSocketSilence() {
        val arriving = FeedIngressMetrics().apply { reset(7) }
        arriving.record(FeedIngressMetrics.Event.Datagram(video = false), 1.0, 7)
        arriving.record(FeedIngressMetrics.Event.Datagram(video = true), 2.0, 7)
        arriving.record(FeedIngressMetrics.Event.VideoGateDrop, 2.0, 7)
        arriving.record(FeedIngressMetrics.Event.Datagram(video = true), 3.0, 7)
        arriving.record(FeedIngressMetrics.Event.InjectedVideoDrop, 3.0, 7)
        arriving.record(FeedIngressMetrics.Event.RegistrationSubmission, 4.0, 7)
        arriving.record(FeedIngressMetrics.Event.ReceiveError, 4.5, 7)
        val snapshot = assertNotNull(arriving.snapshot(5.0, videoGateOpen = false))
        assertEquals(3, snapshot.receivedDatagrams)
        assertEquals(2, snapshot.videoDatagrams)
        assertEquals(1, snapshot.videoGateDrops)
        assertEquals(1, snapshot.injectedVideoDrops)
        assertEquals(1, snapshot.registrationSubmissions)
        assertEquals(1, snapshot.receiveErrors)
        assertEquals(2.0, snapshot.lastDatagramAge)
        assertEquals(2.0, snapshot.lastVideoDatagramAge)
        assertEquals(1.0, snapshot.lastRegistrationSubmissionAge)
        assertFalse(snapshot.videoGateOpen)

        val silent = FeedIngressMetrics().apply { reset(7) }
        val silence = assertNotNull(silent.snapshot(5.0, videoGateOpen = true))
        assertEquals(0, silence.receivedDatagrams)
        assertNull(silence.lastDatagramAge)
        assertNull(silence.lastVideoDatagramAge)
        assertTrue(silence.videoGateOpen)
    }

    @Test
    fun retiredCallbacksCannotRefreshReplacementEndpoint() {
        val metrics = FeedIngressMetrics().apply { reset(1) }
        metrics.record(FeedIngressMetrics.Event.Datagram(video = true), 1.0, 1)
        metrics.reset(2)
        assertFalse(metrics.record(FeedIngressMetrics.Event.Datagram(video = true), 100.0, 1))
        assertFalse(metrics.record(FeedIngressMetrics.Event.RegistrationSubmission, 100.0, 1))
        assertFalse(metrics.record(FeedIngressMetrics.Event.ReceiveError, 100.0, 1))
        val replacement = assertNotNull(metrics.snapshot(101.0, videoGateOpen = true))
        assertEquals(2, replacement.socketGeneration)
        assertEquals(0, replacement.receivedDatagrams)
        assertEquals(0, replacement.registrationSubmissions)
        assertEquals(0, replacement.receiveErrors)
        assertNull(replacement.lastDatagramAge)
        assertNull(replacement.lastRegistrationSubmissionAge)
        assertTrue(metrics.record(FeedIngressMetrics.Event.Datagram(video = true), 102.0, 2))
        assertEquals(1.0, metrics.snapshot(103.0, true)?.lastVideoDatagramAge)
    }

    @Test
    fun missingLegacyObservationAndInvalidClocksRemainUnknown() {
        val metrics = FeedIngressMetrics()
        assertNull(metrics.snapshot(1.0, videoGateOpen = false))
        metrics.reset(3)
        listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0).forEach {
            assertFalse(metrics.record(FeedIngressMetrics.Event.Datagram(video = true), it, 3))
        }
        assertNull(metrics.snapshot(5.0, true)?.lastDatagramAge)
        metrics.record(FeedIngressMetrics.Event.Datagram(video = true), 6.0, 3)
        listOf(5.0, Double.NaN, Double.POSITIVE_INFINITY, -1.0).forEach {
            val snapshot = assertNotNull(metrics.snapshot(it, true))
            assertEquals(1, snapshot.receivedDatagrams)
            assertNull(snapshot.lastDatagramAge)
            assertNull(snapshot.lastVideoDatagramAge)
        }
        assertEquals(0.0, metrics.snapshot(6.0, true)?.lastDatagramAge)
    }
}
