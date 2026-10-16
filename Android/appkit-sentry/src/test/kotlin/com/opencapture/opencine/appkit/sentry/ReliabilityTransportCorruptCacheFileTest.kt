package com.opencapture.opencine.appkit.sentry

import io.sentry.SentryEnvelope
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.RequestDetails
import io.sentry.cache.EnvelopeCache
import io.sentry.protocol.SentryId
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

/**
 * PA-12 (OPENPOCKETCINE-ANDROID-12): one unreadable file in the SDK's real disk cache made
 * EnvelopeCache iteration throw on every drain. SIMULATED corrupt file; real SDK cache,
 * real transport drain, HTTP receipt from a local server.
 */
class ReliabilityTransportCorruptCacheFileTest {
    private fun envelope(options: SentryOptions, id: String): SentryEnvelope =
        SentryEnvelope.from(options.serializer, SentryEvent().apply { eventId = SentryId(id) }, null)

    private fun write(options: SentryOptions, dir: File, name: String, envelope: SentryEnvelope): File =
        File(dir, name).also { file -> file.outputStream().use { options.serializer.serialize(envelope, it) } }

    @Test
    fun unreadableSettledFileIsRemovedSoHealthyCachedReportsDeliver() {
        val dir = Files.createTempDirectory("opc-envelope-cache").toFile()
        val server = MockWebServer()
        server.start()
        val options = SentryOptions().apply {
            cacheDirPath = dir.absolutePath
            maxCacheItems = 30
        }
        options.setEnvelopeDiskCache(EnvelopeCache.create(options))
        val details = RequestDetails(server.url("/envelope/").toString(), emptyMap())
        val previousHost = Fixture.reporting.dsnHost
        Fixture.consent.setOptedIn(true)
        Fixture.gate.resetForTests()
        Fixture.gate.hostPolicy.requireHttps = false
        Fixture.reporting.dsnHost = server.hostName
        val settled = System.currentTimeMillis() - 10 * 60_000L
        val healthy = write(options, dir, "healthy.envelope", envelope(options, "93939393939393939393939393939393"))
            .apply { setLastModified(settled) }
        // A header the SDK's reader rejects with IllegalArgumentException, as in the field event.
        val corrupt = File(dir, "corrupt.envelope").apply {
            writeText("{}\n{\"type\":\"event\",\"length\":-5}\n{}\n")
            setLastModified(settled)
        }
        // A file still being written by the SDK must never be removed.
        val fresh = File(dir, "fresh.envelope").apply { writeText("{}\n{\"type\":\"event\",\"length\":-5}\n") }
        val transport = ReliabilityReportingTransport(Fixture.reporting, options, details)
        try {
            server.enqueue(MockResponse().setResponseCode(200))
            transport.flush(2000)
            val request = server.takeRequest(2, TimeUnit.SECONDS)
            assertNotNull("the healthy cached report must still be delivered", request)
            assertFalse("the unreadable settled file is removed", corrupt.exists())
            assertTrue("a file that may still be written is kept", fresh.exists())
            assertFalse("the delivered report leaves the cache", healthy.exists())
        } finally {
            transport.close()
            server.shutdown()
            Fixture.consent.resetForTests()
            Fixture.gate.resetForTests()
            Fixture.reporting.dsnHost = previousHost
            dir.deleteRecursively()
        }
    }

    @Test
    fun fileReaderSkipsUnreadableFilesAndRemovesOnlySettledOnes() {
        val dir = Files.createTempDirectory("opc-envelope-read").toFile()
        val options = SentryOptions()
        try {
            val now = 1_000_000_000L
            val good = write(options, dir, "good.envelope", envelope(options, "92929292929292929292929292929292"))
                .apply { setLastModified(now - 120_000L) }
            val newer = write(options, dir, "newer.envelope", envelope(options, "91919191919191919191919191919191"))
                .apply { setLastModified(now - 90_000L) }
            val bad = File(dir, "bad.envelope").apply { writeText("not an envelope\u0000\u0001"); setLastModified(now - 120_000L) }
            val recent = File(dir, "recent.envelope").apply { writeText("partial"); setLastModified(now - 1_000L) }
            val session = File(dir, "session.json").apply { writeText("garbage"); setLastModified(now - 120_000L) }
            val read = CachedEnvelopeFiles.read(dir, options.serializer, now, limit = 30)
            assertEquals(listOf(good, newer), read.entries.map { it.first })
            assertEquals(1, read.removed)
            assertFalse(bad.exists())
            assertTrue("a file that may still be written is kept", recent.exists())
            assertTrue("only envelope files are the transport's to judge", session.exists())
            assertEquals(listOf(good), CachedEnvelopeFiles.read(dir, options.serializer, now, limit = 1).entries.map { it.first })
            assertEquals(0, CachedEnvelopeFiles.read(null, options.serializer, now, limit = 30).entries.size)
        } finally {
            dir.deleteRecursively()
        }
    }
}
