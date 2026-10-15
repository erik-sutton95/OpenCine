package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBreadcrumbKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentRecorder
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
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** SIMULATED writer ordering, using the actual recorder and persisted incident/summary stores. */
class FeedIncidentRuntimeSourceTest {
    @Test fun actualRuntimeFactoryBuildsPrivateIncidentEventThroughFakeCapture() = withHarness { h ->
        h.consent.setOptedIn(true)
        val ready = java.util.concurrent.CountDownLatch(1)
        val captured = java.util.concurrent.atomic.AtomicReference<Pair<ReliabilityEvent, ByteArray>>()
        h.reporting.setCaptureHandlerForTests { event, bytes -> captured.set(event to bytes); ready.countDown() }
        val context = h.runtime.sessionContext(cameraFamily = "simulated",
            cameraFirmware = "SIMULATED-secret@example.invalid")
        val source = h.runtime.beginBoundSession(context)
        source.ingestSnapshot(stall())
        h.writer.runAll()
        source.endSession(5.0)
        h.writer.runAll()
        assertTrue(ready.await(10, TimeUnit.SECONDS))
        val (event, bytes) = checkNotNull(captured.get())
        assertEquals(context.hardwareClass, event.tags?.get("hardwareClass"))
        assertEquals(context.sourceRevision, event.tags?.get("sourceRevision"))
        assertEquals("com.opencapture.host@${context.appVersion}+${context.appBuild}", event.release)
        assertTrue(!String(bytes, Charsets.UTF_8).contains("SIMULATED-secret@example.invalid"))
        assertEquals(FeedIncidentOutcome.USER_ENDED, h.bundles().single().header.outcome)
    }
    @Test fun replacementFinalizesLivePredecessorOnceAndRejectsLateCalls() = withHarness { h ->
        val oldID = "20000000-0000-4000-8000-000000000001"
        val currentID = "20000000-0000-4000-8000-000000000002"
        val old = h.runtime.beginBoundSession(context(oldID))
        old.ingestSnapshot(stall())
        h.writer.runAll()
        val current = h.runtime.beginBoundSession(context(currentID))
        assertTrue(!old.isCurrent)
        assertTrue(current.isCurrent)
        h.writer.runAll()
        old.endSession(100.0)
        old.noteExhausted(100.0)
        old.ingestSnapshot(stall(100.0))
        current.ingestSnapshot(stall(6.0))
        h.writer.runAll()
        val predecessor = h.bundles().single { it.header.sessionId == oldID }
        assertEquals(FeedIncidentOutcome.USER_ENDED, predecessor.header.outcome)
        assertEquals(5.0, predecessor.header.endedAtMonotonic)
        val summaries = FeedSessionSummaryStore.load(h.incidentRoot)
        assertEquals(1, summaries.count { it.sessionID == oldID })
        assertEquals("ended", summaries.single { it.sessionID == oldID }.outcome)
        assertEquals("live", summaries.single { it.sessionID == currentID }.outcome)
        assertEquals(FeedIncidentOutcome.OPEN, h.bundles().single { it.header.sessionId == currentID }.header.outcome)
        current.endSession(7.0)
        h.writer.runAll()
        assertEquals(predecessor, h.bundles().single { it.header.sessionId == oldID })
        assertEquals("ended", FeedSessionSummaryStore.load(h.incidentRoot).single { it.sessionID == currentID }.outcome)
    }

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

    @Test fun retiredCompanionLegacyEndCannotCloseReusedIdSuccessor() {
        val sink = RecorderSink()
        val oldOwner = Any()
        val newOwner = Any()
        var owner = oldOwner
        val retired = FeedIncidentBindings.bind(sink.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))) { owner === oldOwner }
        owner = newOwner
        val current = FeedIncidentBindings.bind(sink.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))) { owner === newOwner }
        current.ingestSnapshot(stall())
        assertEquals(FeedIncidentOutcome.OPEN, sink.recorder.openHeader?.outcome)
        assertFalse(retired.isCurrent)
        retired.endSession(5.0)
        assertEquals(listOf(true, FeedIncidentOutcome.OPEN),
            listOf(sink.recorder.hasSession, sink.recorder.openHeader?.outcome),
            "Retired legacy disposal must leave the actual successor session and incident open")
        current.endSession(6.0)
        assertFalse(sink.recorder.hasSession)
    }

    @Test fun currentCompanionLegacyEndStillFinalizesItsOwnIncident() {
        val sink = RecorderSink()
        val current = FeedIncidentBindings.bind(sink.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))) { true }
        current.ingestSnapshot(stall())
        assertTrue(sink.recorder.hasSession)
        current.endSession(5.0)
        current.endSession(6.0)
        assertFalse(sink.recorder.hasSession)
        assertEquals(1, sink.ended)
        assertEquals(FeedIncidentOutcome.USER_ENDED, sink.finalOutcome)
    }

    @Test fun capturedRuntimeCleanupStillFinalizesAfterHostOwnerRetires() {
        val root = File.createTempFile("opc-bind-review", "").apply { delete(); mkdirs() }
        val writer = ManualWriter()
        try {
            val redact: (String) -> String = PrivacyRedactor::redact
            val host = DiagnosticsHost("Host", "com.opencapture.host", "1", 1, "development",
                "a".repeat(40), null, "host-android", "support@host.invalid", "host.operator", redact)
            val dsn = ReliabilityReportingDSN()
            val consent = ReliabilityReportingConsent(dsn)
            val reporting = ReliabilityReporting(host, consent, dsn,
                ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), "192.0.2."),
                FeedIncidentOrigin({ "test" }, redact), { NoSdk })
            val runtime = FeedIncidentRuntime(reporting, writer, clock = { 5.0 })
            runtime.install(root)
            writer.runAll()
            val captured = runtime.beginBoundSession(context("10000000-0000-4000-8000-000000000001"))
            var ownerIsCurrent = true
            val bound = FeedIncidentBindings.bind(captured) { ownerIsCurrent }
            bound.ingestSnapshot(stall())
            writer.runAll()
            ownerIsCurrent = false
            assertFalse(bound.isCurrent)
            assertTrue(captured.isCurrent)
            bound.endSession(5.0)
            writer.runAll()
            assertFalse(captured.isCurrent)
            val bundle = FeedIncidentStore(File(root, "incidents"), "Host", redact).loadAll().single()
            assertEquals(FeedIncidentOutcome.USER_ENDED, bundle.header.outcome)
            assertEquals(5.0, bundle.header.endedAtMonotonic)
            bound.endSession(6.0)
            writer.runAll()
            assertEquals(bundle, FeedIncidentStore(File(root, "incidents"), "Host", redact).loadAll().single())
        } finally {
            writer.runAll()
            writer.shutdown()
            root.deleteRecursively()
        }
    }

    private class RecorderSink : FeedIncidentSink {
        val recorder = FeedIncidentRecorder()
        var ended = 0
        var finalOutcome: FeedIncidentOutcome? = null
        override fun beginSession(context: FeedIncidentSessionContext) { recorder.beginSession(context) }
        override fun endSession(nowSeconds: Double) {
            ended++
            finalOutcome = recorder.endSession(nowSeconds)?.bundle?.header?.outcome
        }
        override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) { recorder.recordSnapshot(snapshot) }
        override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) { recorder.recordBreadcrumb(breadcrumb) }
        override fun recordRepair(repair: FeedRepairRecord) { recorder.recordRepair(repair) }
        override fun noteDecoderGeneration(generation: Int) { recorder.noteDecoderGeneration(generation) }
        override fun noteSocketGeneration(generation: Int) { recorder.noteSocketGeneration(generation) }
        override fun noteExhausted(nowSeconds: Double) { recorder.noteExhausted(nowSeconds) }
        override fun noteUnexpectedDisconnect(nowSeconds: Double) { recorder.noteUnexpectedDisconnect(nowSeconds) }
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
        val host = DiagnosticsHost("Host", "com.opencapture.host", "1", 1, "development", "a".repeat(40),
            null, "host-android", "support@host.invalid", "host.operator", redact)
        val dsn = ReliabilityReportingDSN()
        val consent = ReliabilityReportingConsent(dsn)
        val reporting = ReliabilityReporting(host, consent, dsn,
            ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), "192.0.2."),
            FeedIncidentOrigin({ "test" }, redact), { NoSdk })
        val runtime = FeedIncidentRuntime(reporting, writer, clock = { 5.0 })
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
