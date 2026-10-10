package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIngressMetrics
import java.util.concurrent.atomic.AtomicLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DatalinkIngressMetricsTest {
    @Test
    fun producerResetsCountsAndRejectsRetiredReceiveAndSendCompletions() {
        val epoch = AtomicLong(0)
        val producer = DatalinkIngressMetrics(epoch)
        assertNull(producer.snapshot(0.0, false))
        val first = producer.retireGeneration()
        assertEquals(1L, epoch.get())
        producer.record(FeedIngressMetrics.Event.Datagram(true), 1.0, first)
        producer.record(FeedIngressMetrics.Event.RegistrationSubmission, 1.0, first)
        val replacement = producer.retireGeneration()
        assertEquals(2L, replacement)
        assertFalse(producer.record(FeedIngressMetrics.Event.Datagram(true), 10.0, first))
        assertFalse(producer.record(FeedIngressMetrics.Event.RegistrationSubmission, 10.0, first))
        assertFalse(producer.record(FeedIngressMetrics.Event.ReceiveError, 10.0, first))
        val empty = assertNotNull(producer.snapshot(11.0, true))
        assertEquals(2, empty.socketGeneration)
        assertEquals(0, empty.receivedDatagrams)
        assertEquals(0, empty.registrationSubmissions)
        assertEquals(0, empty.receiveErrors)
        assertNull(empty.lastVideoDatagramAge)
        assertTrue(producer.record(FeedIngressMetrics.Event.Datagram(true), 12.0, replacement))
        assertEquals(1, producer.snapshot(13.0, true)?.videoDatagrams)
    }

    @Test
    fun unrepresentableNativeEpochRemainsUnsupportedInsteadOfWrapping() {
        val epoch = AtomicLong(Int.MAX_VALUE.toLong())
        val producer = DatalinkIngressMetrics(epoch)
        val generation = producer.retireGeneration()
        assertEquals(Int.MAX_VALUE.toLong() + 1, generation)
        assertNull(producer.snapshot(1.0, true))
        assertFalse(producer.record(FeedIngressMetrics.Event.Datagram(true), 1.0, generation))
        assertFalse(producer.record(FeedIngressMetrics.Event.Datagram(true), 1.0, generation.toInt().toLong()))
    }
}
