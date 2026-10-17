package com.opencapture.opencine.appkit.sentry

import io.sentry.Hint
import io.sentry.RequestDetails
import io.sentry.SentryEnvelope
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.cache.IEnvelopeCache
import io.sentry.protocol.SentryId
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class ReliabilityTransportRetryTest {
    private class NativeHint : io.sentry.hints.DiskFlushNotification,
        io.sentry.hints.Retryable, io.sentry.hints.SubmissionResult {
        var flushed = false
        private var retry = false
        private var success = false
        override fun markFlushed() { flushed = true }
        override fun isFlushable(id: SentryId?) = true
        override fun setFlushable(id: SentryId) = Unit
        override fun isRetry() = retry
        override fun setRetry(value: Boolean) { retry = value }
        override fun isSuccess() = success
        override fun setResult(value: Boolean) { success = value }
    }

    private class Cache : IEnvelopeCache {
        val entries = ConcurrentHashMap<String, SentryEnvelope>()
        override fun store(envelope: SentryEnvelope, hint: Hint) {
            entries[envelope.header.eventId.toString()] = envelope
        }
        override fun discard(envelope: SentryEnvelope) {
            entries.remove(envelope.header.eventId.toString())
        }
        override fun iterator(): MutableIterator<SentryEnvelope> = entries.values.iterator()
    }

    @Test
    fun nativeCacheResumesAfterGateOpensAcrossTransportRestart() {
        val server = MockWebServer()
        server.start()
        val cache = Cache()
        val options = SentryOptions().apply { setEnvelopeDiskCache(cache) }
        val details = RequestDetails(server.url("/envelope/").toString(), emptyMap())
        Fixture.consent.setOptedIn(true)
        Fixture.gate.resetForTests()
        Fixture.gate.hostPolicy.requireHttps = false
        Fixture.reporting.dsnHost = server.hostName
        var transport = ReliabilityReportingTransport(Fixture.reporting, options, details)
        try {
            val cameraPath = Fixture.gate.beginCameraPath()
            val event = SentryEvent().apply {
                eventId = SentryId("98989898989898989898989898989898")
            }
            val envelope = SentryEnvelope.from(options.serializer, event, null)
            val nativeHint = NativeHint()
            transport.send(envelope, io.sentry.util.HintUtils.createWithTypeCheckHint(nativeHint))
            assertTrue(nativeHint.flushed)
            assertTrue(nativeHint.isRetry)
            assertFalse(nativeHint.isSuccess)
            assertNull(server.takeRequest(100, TimeUnit.MILLISECONDS))
            assertEquals(1, cache.entries.size)
            transport.close()
            transport = ReliabilityReportingTransport(Fixture.reporting, options, details)
            server.enqueue(MockResponse().setResponseCode(200))
            cameraPath.end()
            transport.flush(2000)
            assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertTrue(cache.entries.isEmpty())
            transport.flush(1000)
            assertEquals(1, server.requestCount)
        } finally {
            transport.close()
            server.shutdown()
            Fixture.consent.resetForTests()
            Fixture.gate.resetForTests()
        }
    }

    @Test
    fun rateLimitedEnvelopeStaysCachedAndFlushDoesNotHammerServer() {
        val server = MockWebServer()
        server.start()
        val cache = Cache()
        val options = SentryOptions().apply { setEnvelopeDiskCache(cache) }
        val details = RequestDetails(server.url("/envelope/").toString(), emptyMap())
        Fixture.consent.setOptedIn(true)
        Fixture.gate.resetForTests()
        Fixture.gate.hostPolicy.requireHttps = false
        Fixture.reporting.dsnHost = server.hostName
        val transport = ReliabilityReportingTransport(Fixture.reporting, options, details)
        try {
            server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "60"))
            val event = SentryEvent().apply {
                eventId = SentryId("97979797979797979797979797979797")
            }
            transport.send(SentryEnvelope.from(options.serializer, event, null), Hint())
            transport.flush(2000)
            assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertEquals(1, cache.entries.size)
            transport.flush(1000)
            assertEquals(1, server.requestCount)
        } finally {
            transport.close()
            server.shutdown()
            Fixture.consent.resetForTests()
            Fixture.gate.resetForTests()
        }
    }
}
