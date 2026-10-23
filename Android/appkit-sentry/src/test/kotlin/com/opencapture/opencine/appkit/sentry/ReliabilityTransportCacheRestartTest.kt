package com.opencapture.opencine.appkit.sentry

import io.sentry.Hint
import io.sentry.RequestDetails
import io.sentry.SentryEnvelope
import io.sentry.SentryEnvelopeHeader
import io.sentry.SentryEnvelopeItem
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.cache.EnvelopeCache
import io.sentry.protocol.SentryId
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Duplicate uploads: the SDK's `EnvelopeCache.discard` finds a file only through the in-memory
 * name map of the process that stored it. A report cached before a restart and reloaded from
 * disk was therefore never deleted after its HTTP 2xx, and every later drain sent it again.
 * Real SDK disk cache, real transport drain, HTTP receipts from a local server.
 */
class ReliabilityTransportCacheRestartTest {
    private lateinit var dir: File
    private lateinit var server: MockWebServer
    private var previousHost: String? = null

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("opc-envelope-restart").toFile()
        server = MockWebServer()
        server.start()
        previousHost = Fixture.reporting.dsnHost
        Fixture.consent.setOptedIn(true)
        Fixture.gate.resetForTests()
        Fixture.gate.hostPolicy.requireHttps = false
        Fixture.reporting.dsnHost = server.hostName
    }

    @After
    fun tearDown() {
        server.shutdown()
        Fixture.consent.resetForTests()
        Fixture.gate.resetForTests()
        Fixture.reporting.dsnHost = previousHost
        dir.deleteRecursively()
    }

    /** One app process: its own SDK cache instance (and so its own name map) over the same directory. */
    private fun process(): Pair<SentryOptions, ReliabilityReportingTransport> {
        val options = SentryOptions().apply {
            cacheDirPath = dir.absolutePath
            maxCacheItems = 30
        }
        options.setEnvelopeDiskCache(EnvelopeCache.create(options))
        val details = RequestDetails(server.url("/envelope/").toString(), emptyMap())
        return options to ReliabilityReportingTransport(Fixture.reporting, options, details)
    }

    private fun event(options: SentryOptions, id: String): SentryEnvelope =
        SentryEnvelope.from(options.serializer, SentryEvent().apply { eventId = SentryId(id) }, null)

    /** An envelope without an event id in its header, as metrics and client reports are sent. */
    private fun anonymous(options: SentryOptions): SentryEnvelope =
        SentryEnvelope(SentryEnvelopeHeader(), listOf(SentryEnvelopeItem.fromEvent(options.serializer, SentryEvent())))

    private fun envelopeFiles(): List<File> =
        dir.listFiles { _, name -> name.endsWith(".envelope") }?.toList().orEmpty()

    /** Stores [envelopes] in a process whose camera path keeps them off the network, then ends it. */
    private fun cacheBeforeRestart(build: (SentryOptions) -> List<SentryEnvelope>) {
        val (options, transport) = process()
        val cameraPath = Fixture.gate.beginCameraPath()
        try {
            for (envelope in build(options)) transport.send(envelope, Hint())
            assertNull(server.takeRequest(100, TimeUnit.MILLISECONDS))
        } finally {
            transport.close()
            cameraPath.end()
        }
    }

    @Test
    fun reportReloadedAfterRestartLeavesTheCacheOnceDelivered() {
        cacheBeforeRestart { listOf(event(it, "90909090909090909090909090909090")) }
        assertEquals(1, envelopeFiles().size)

        val (_, transport) = process()
        try {
            server.enqueue(MockResponse().setResponseCode(200))
            server.enqueue(MockResponse().setResponseCode(200))
            transport.flush(2000)
            assertNotNull("the cached report is delivered", server.takeRequest(2, TimeUnit.SECONDS))
            assertEquals("a delivered report leaves the disk cache", emptyList<File>(), envelopeFiles())
            transport.flush(1000)
            assertEquals("a delivered report is never sent again", 1, server.requestCount)
        } finally {
            transport.close()
        }
        // The next launch finds nothing to send again either.
        val (_, relaunched) = process()
        try {
            relaunched.flush(1000)
            assertEquals(1, server.requestCount)
        } finally {
            relaunched.close()
        }
    }

    @Test
    fun anonymousEnvelopeReloadedAfterRestartIsSentOnce() {
        cacheBeforeRestart { listOf(anonymous(it), anonymous(it)) }
        assertEquals(2, envelopeFiles().size)

        val (_, transport) = process()
        try {
            repeat(4) { server.enqueue(MockResponse().setResponseCode(200)) }
            transport.flush(2000)
            transport.flush(1000)
            assertEquals("each cached envelope is sent exactly once", 2, server.requestCount)
            assertEquals(emptyList<File>(), envelopeFiles())
        } finally {
            transport.close()
        }
    }

    @Test
    fun anonymousEnvelopeSentInProcessIsNotSentAgainFromItsOwnFile() {
        val (options, transport) = process()
        try {
            repeat(3) { server.enqueue(MockResponse().setResponseCode(200)) }
            transport.send(anonymous(options), Hint())
            transport.flush(2000)
            transport.flush(1000)
            assertEquals("the stored copy is the same report, not a second one", 1, server.requestCount)
            assertEquals(emptyList<File>(), envelopeFiles())
        } finally {
            transport.close()
        }
    }
}
