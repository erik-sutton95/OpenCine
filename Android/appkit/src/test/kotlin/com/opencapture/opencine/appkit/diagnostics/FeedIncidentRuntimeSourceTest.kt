package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBreadcrumbKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentSink
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.media.PrivacyRedactor
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** SIMULATED writer ordering, using the actual recorder and persisted incident/summary stores. */
class FeedIncidentRuntimeSourceTest {
    @Test fun retiredDrainCannotConsumeSuccessorBeforeBegin() = withHarness { h ->
        val sink: FeedIncidentSink = h.runtime // Actual integration-facing Media contract.
        val old = sink.beginBoundSession(context("old"))
        old.ingestSnapshot(stall())
        val current = sink.beginBoundSession(context("current"))
        current.noteDecoderGeneration(22)
        current.noteSocketGeneration(33)
        current.ingestSnapshot(stall())
        h.writer.runNext() // A begin
        h.writer.runNext() // A drain must neither persist B as A nor consume B's mailbox.
        assertTrue(h.bundles().isEmpty())
        h.writer.runAll()
        val bundle = h.bundles().single()
        assertEquals("current", bundle.header.sessionId)
        assertEquals(22, bundle.header.decoderGeneration)
        assertEquals(33, bundle.header.socketGeneration)
        assertEquals(FeedIncidentOutcome.OPEN, bundle.header.outcome)
    }

    @Test fun retiredCallbacksCannotMutateReusedSessionID() = withHarness { h ->
        val old = h.runtime.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))
        h.writer.runAll()
        val current = h.runtime.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))
        current.ingestSnapshot(stall())
        h.writer.runAll()
        old.ingestSnapshot(stall(100.0))
        old.recordBreadcrumb(FeedIncidentBreadcrumb(5.0, FeedIncidentBreadcrumbKind.SETTINGS_ENTER, "retired"))
        old.recordRepair(FeedRepairRecord(5.0, "session", FeedRepairPhase.REQUESTED))
        old.noteTestSource(FeedIncidentTestSource.FAULT_INJECTION)
        old.noteDecoderGeneration(99)
        old.noteSocketGeneration(99)
        old.noteUnexpectedDisconnect(5.0)
        old.noteExhausted(5.0)
        old.endSession(5.0)
        h.writer.runAll()
        var bundle = h.bundles().single()
        assertEquals(FeedIncidentOutcome.OPEN, bundle.header.outcome)
        assertEquals(FeedIncidentTestSource.MANUAL, bundle.header.testSource)
        assertTrue(bundle.breadcrumbs.isEmpty())
        assertTrue(bundle.repairs.isEmpty())
        current.ingestSnapshot(stall(6.0))
        current.endSession(7.0)
        h.writer.runAll()
        bundle = h.bundles().single()
        assertEquals(FeedIncidentOutcome.USER_ENDED, bundle.header.outcome)
        assertNotEquals(99, bundle.header.decoderGeneration)
        assertNotEquals(99, bundle.header.socketGeneration)
        assertEquals("ended", FeedSessionSummaryStore.load(h.incidentRoot).first().outcome)
        assertEquals(FeedIncidentTestSource.MANUAL, FeedSessionSummaryStore.load(h.incidentRoot).first().testSource)
    }

    @Test fun endPreservesAdmittedSnapshotAndRejectsLateProducer() = withHarness { h ->
        val source = h.runtime.beginBoundSession(context("ending"))
        source.ingestSnapshot(stall())
        source.endSession(5.0)
        source.noteExhausted(6.0)
        source.ingestSnapshot(stall(100.0))
        h.writer.runAll()
        val bundle = h.bundles().single()
        assertEquals("ending", bundle.header.sessionId)
        assertEquals(FeedIncidentOutcome.USER_ENDED, bundle.header.outcome)
        assertEquals(5.0, bundle.header.endedAtMonotonic)
    }

    @Test fun legacySequentialSessionRemainsUsable() = withHarness { h ->
        h.runtime.beginSession(context("legacy"))
        h.runtime.ingestSnapshot(stall())
        h.runtime.endSession(5.0)
        h.writer.runAll()
        val bundle = h.bundles().single()
        assertEquals("legacy", bundle.header.sessionId)
        assertEquals(FeedIncidentOutcome.USER_ENDED, bundle.header.outcome)
    }

    private fun context(id: String) = FeedIncidentSessionContext(id, "1", "1", "test",
        "simulated", "1", "test", "test", testSource = FeedIncidentTestSource.MANUAL)
    private fun stall(now: Double = 4.0) = FeedIncidentSnapshot(now, System.currentTimeMillis(),
        ages = FeedIncidentAges(accessUnitAge = 0.04, decodeAcceptAge = 0.04,
            decodedOutputAge = 3.0, presentAge = 3.0),
        lifecycle = FeedIncidentLifecycle(connected = true, liveEstablished = true))

    private fun withHarness(body: (Harness) -> Unit) {
        val h = Harness()
        try { body(h) } finally { h.writer.runAll(); h.root.deleteRecursively() }
    }
    private class Harness {
        val root = File.createTempFile("opc-bound-runtime", "").apply { delete(); mkdirs() }
        val incidentRoot = File(root, "incidents")
        val writer = ManualWriter()
        val redact: (String) -> String = PrivacyRedactor::redact
        val host = DiagnosticsHost("Host", "com.opencapture.host", "1", 1, "development", "test",
            null, "host-android", "support@host.invalid", "host.operator", redact)
        val dsn = ReliabilityReportingDSN()
        val consent = ReliabilityReportingConsent(dsn)
        val reporting = ReliabilityReporting(host, consent, dsn,
            ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), "192.0.2."),
            FeedIncidentOrigin({ "test" }, redact), { NoSdk })
        val runtime = FeedIncidentRuntime(reporting, writer)
        init { runtime.install(root); writer.runAll() }
        fun bundles() = FeedIncidentStore(incidentRoot, "Host", redact).loadAll()
    }
    private class ManualWriter : AbstractExecutorService() {
        private val work = ArrayDeque<Runnable>()
        private var stopped = false
        override fun execute(command: Runnable) { check(!stopped); work.addLast(command) }
        fun runNext() { checkNotNull(work.pollFirst()).run() }
        fun runAll() { while (work.isNotEmpty()) runNext() }
        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> { stopped = true; return work.toMutableList().also { work.clear() } }
        override fun isShutdown() = stopped
        override fun isTerminated() = stopped && work.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
    }
    private object NoSdk : ReliabilityReportingSink {
        override fun start(context: android.content.Context, dsn: String, cacheDir: File) = Unit
        override fun close() = Unit
        override fun flush(timeoutMillis: Long) = Unit
        override fun addBreadcrumb(category: String, message: String, data: Map<String, String>) = Unit
        override fun setTags(tags: Map<String, String>) = Unit
        override fun capture(event: ReliabilityEvent, attachment: ByteArray, attachmentName: String) = Unit
        override fun record(metric: ReliabilityMetric) = Unit
    }
}
