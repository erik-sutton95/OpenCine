package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentRecorder
import com.opencapture.opencine.media.FeedIncidentSink
import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentPersistenceJob
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSessionSummary
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedRepairRecord
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService

/** Captured authority for one incident session, distinct even when a context ID is reused. */
public class FeedIncidentSessionSource internal constructor(
    private val runtime: FeedIncidentRuntime,
    public val sessionID: String,
) : FeedIncidentSource {
    override val isCurrent: Boolean get() = runtime.isCurrent(this)
    override fun ingestSnapshot(snapshot: FeedIncidentSnapshot): Unit = runtime.ingest(this, snapshot)
    override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb): Unit = runtime.breadcrumb(this, breadcrumb)
    override fun recordRepair(repair: FeedRepairRecord): Unit = runtime.repair(this, repair)
    override fun noteTestSource(origin: FeedIncidentTestSource): Unit = runtime.origin(this, origin)
    override fun noteDecoderGeneration(generation: Int): Unit = runtime.decoderGeneration(this, generation)
    override fun noteSocketGeneration(generation: Int): Unit = runtime.socketGeneration(this, generation)
    override fun noteExhausted(nowSeconds: Double): Unit = runtime.exhausted(this, nowSeconds)
    override fun noteUnexpectedDisconnect(nowSeconds: Double): Unit = runtime.disconnected(this, nowSeconds)
    override fun endSession(nowSeconds: Double): Unit = runtime.end(this, nowSeconds)
}

/**
 * Shell owner for feed-incident persistence. Recorder stays in memory; this
 * type writes on a dedicated utility thread. Never call persist from receive,
 * decode, display, or fatal-signal handlers. Finalized incidents and session
 * summaries go to [reporting]; its host names the listing and redacts.
 */
public class FeedIncidentRuntime internal constructor(
    private val reporting: ReliabilityReporting,
    private val writer: ExecutorService,
    private val clock: () -> Double = { android.os.SystemClock.elapsedRealtime() / 1_000.0 },
) : FeedIncidentSink {
    public constructor(reporting: ReliabilityReporting) : this(reporting,
        Executors.newSingleThreadExecutor { thread ->
            Thread(thread, "opc.feed-incident").apply { isDaemon = true }
        })
    public constructor(reporting: ReliabilityReporting, clock: () -> Double) : this(reporting,
        Executors.newSingleThreadExecutor { thread ->
            Thread(thread, "opc.feed-incident").apply { isDaemon = true }
        }, clock)
    private val product = reporting.host.product
    private val redact = reporting.host.redact
    private val recorder = FeedIncidentRecorder(redact = redact)
    private var store: FeedIncidentStore? = null
    private data class Pending(
        val source: FeedIncidentSessionSource,
        var snapshot: FeedIncidentSnapshot? = null,
        var decoderGeneration: Int? = null,
        var socketGeneration: Int? = null,
    )
    private val gate = Any()
    private var submittedSource: FeedIncidentSessionSource? = null
    private var pending: Pending? = null
    // Only the serial writer reads or mutates the active recorder source.
    private var activeSource: FeedIncidentSessionSource? = null
    private var sessionContext: FeedIncidentSessionContext? = null
    private var lastSummaryCheckpoint = 0.0

    public fun install(directory: File) {
        writer.execute {
            val created = FeedIncidentStore(File(directory, "incidents"), product, redact)
            store = created
            created.markInterrupted()
            FeedSessionSummaryStore.markInterrupted(created.directory)
        }
    }

    public fun deleteStoredReports(completion: (Boolean) -> Unit) {
        writer.execute {
            val deleted = runCatching {
                val saved = store ?: return@runCatching false
                val incidentsDeleted = saved.deleteAll()
                val summariesDeleted = FeedSessionSummaryStore.deleteAll(saved.directory)
                incidentsDeleted && summariesDeleted
            }.getOrDefault(false)
            android.os.Handler(android.os.Looper.getMainLooper()).post { completion(deleted) }
        }
    }

    /** Legacy producers capture the current source per call; asynchronous owners should retain a binding. */
    override fun beginSession(context: FeedIncidentSessionContext) { beginBoundSession(context) }

    public fun sessionContext(sessionId: String = java.util.UUID.randomUUID().toString(), cameraFamily: String,
        cameraFirmware: String? = null, decoderGeneration: Int = 0, socketGeneration: Int = 0,
    ): FeedIncidentSessionContext = FeedIncidentProducerContext(reporting.host).make(sessionId,
        cameraFamily, cameraFirmware, decoderGeneration, socketGeneration,
        reporting.origin.currentTestSource(), reporting.origin.currentBuildIdentity())

    override fun beginBoundSession(context: FeedIncidentSessionContext): FeedIncidentSessionSource = synchronized(gate) {
        val captured = context.copy()
        val source = FeedIncidentSessionSource(this, captured.sessionId)
        val replacedAt = clock()
        submittedSource = source
        pending = null
        // Enqueue the begin event before returning authority to any producer.
        writer.execute {
            if (activeSource != null) {
                persist(recorder.endSession(replacedAt))
                persistSessionSummary(summaryOutcome(recorder.incidentCount, recorder.healthyExposure))
                reporting.enqueueFinalizedFromSpool()
            }
            persist(recorder.beginSession(captured))
            activeSource = source
            sessionContext = captured
            lastSummaryCheckpoint = 0.0
            persistSessionSummary("live")
        }
        source
    }

    override fun endSession(nowSeconds: Double) { currentSource()?.endSession(nowSeconds) }
    override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) { currentSource()?.ingestSnapshot(snapshot) }
    override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) { currentSource()?.recordBreadcrumb(breadcrumb) }
    override fun recordRepair(repair: FeedRepairRecord) { currentSource()?.recordRepair(repair) }
    override fun noteTestSource(source: FeedIncidentTestSource) { currentSource()?.noteTestSource(source) }
    override fun noteDecoderGeneration(generation: Int) { currentSource()?.noteDecoderGeneration(generation) }
    override fun noteSocketGeneration(generation: Int) { currentSource()?.noteSocketGeneration(generation) }
    override fun noteExhausted(nowSeconds: Double) { currentSource()?.noteExhausted(nowSeconds) }
    override fun noteUnexpectedDisconnect(nowSeconds: Double) { currentSource()?.noteUnexpectedDisconnect(nowSeconds) }

    private fun currentSource(): FeedIncidentSessionSource? = synchronized(gate) { submittedSource }
    internal fun isCurrent(source: FeedIncidentSessionSource): Boolean = synchronized(gate) { submittedSource === source }

    private fun enqueue(source: FeedIncidentSessionSource, work: () -> Unit) = synchronized(gate) {
        if (submittedSource !== source) return@synchronized
        writer.execute {
            if (activeSource === source) work()
        }
    }

    internal fun end(source: FeedIncidentSessionSource, nowSeconds: Double) = synchronized(gate) {
        if (submittedSource !== source) return@synchronized
        submittedSource = null
        // A previously admitted drain runs before this end event, under its original source.
        writer.execute {
            if (activeSource !== source) return@execute
            persist(recorder.endSession(nowSeconds))
            persistSessionSummary(summaryOutcome(recorder.incidentCount, recorder.healthyExposure))
            sessionContext = null
            activeSource = null
            reporting.enqueueFinalizedFromSpool()
        }
    }

    internal fun ingest(source: FeedIncidentSessionSource, snapshot: FeedIncidentSnapshot) =
        updatePending(source) { it.snapshot = snapshot }
    internal fun decoderGeneration(source: FeedIncidentSessionSource, generation: Int) =
        updatePending(source) { it.decoderGeneration = generation }
    internal fun socketGeneration(source: FeedIncidentSessionSource, generation: Int) =
        updatePending(source) { it.socketGeneration = generation }
    internal fun breadcrumb(source: FeedIncidentSessionSource, breadcrumb: FeedIncidentBreadcrumb) = enqueue(source) {
        recorder.recordBreadcrumb(breadcrumb)
        reporting.noteBreadcrumb(breadcrumb)
    }
    internal fun repair(source: FeedIncidentSessionSource, repair: FeedRepairRecord) = enqueue(source) {
        persist(recorder.recordRepair(repair))
        reporting.noteRepair(repair)
    }
    internal fun origin(source: FeedIncidentSessionSource, origin: FeedIncidentTestSource) = enqueue(source) {
        recorder.noteTestSource(origin)
        sessionContext?.let { if (origin.rank > it.testSource.rank) it.testSource = origin }
    }
    internal fun exhausted(source: FeedIncidentSessionSource, nowSeconds: Double) = enqueue(source) {
        persist(recorder.noteExhausted(nowSeconds))
    }
    internal fun disconnected(source: FeedIncidentSessionSource, nowSeconds: Double) = enqueue(source) {
        persist(recorder.noteUnexpectedDisconnect(nowSeconds))
    }

    public fun exportText(): String {
        val future = writer.submit<String> { store?.exportText().orEmpty() }
        return runCatching { future.get(2, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault("")
    }

    public fun exportExtras(): List<Pair<String, String>> {
        val future =
            writer.submit<List<Pair<String, String>>> { store?.exportExtras().orEmpty() }
        return runCatching { future.get(2, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(emptyList())
    }

    /** Manual-report extras: typed incidents plus compact session summaries. */
    public fun reportExtras(): List<Pair<String, String>> {
        val extras = exportExtras().toMutableList()
        val summaries = loadSessionSummaries().sortedByDescending { it.recordedAtMs }
        summaries.firstOrNull()?.let { newest ->
            extras += "session-summary.json" to redact(FeedSessionSummaryStore.encodeForReport(newest))
        }
        for (summary in summaries.drop(1).take(4)) {
            extras +=
                "session-${summary.sessionID}.json" to
                    redact(FeedSessionSummaryStore.encodeForReport(summary))
        }
        return extras
    }

    public fun loadFinalized(): List<FeedIncidentBundle> {
        val future =
            writer.submit<List<FeedIncidentBundle>> {
                store?.loadAll()?.filter { reporting.isFinalized(it) }.orEmpty()
            }
        return runCatching { future.get(2, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(emptyList())
    }

    public fun loadSessionSummaries(): List<FeedIncidentSessionSummary> {
        val future =
            writer.submit<List<FeedIncidentSessionSummary>> {
                val root = store?.directory ?: return@submit emptyList()
                FeedSessionSummaryStore.load(root).filter { it.outcome != "live" }
            }
        return runCatching { future.get(2, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(emptyList())
    }


    private fun updatePending(source: FeedIncidentSessionSource, update: (Pending) -> Unit) = synchronized(gate) {
        if (submittedSource !== source) return@synchronized
        val schedule = pending?.source !== source
        if (schedule) pending = Pending(source)
        update(checkNotNull(pending))
        if (schedule) writer.execute { drainSnapshot(source) }
    }

    private fun drainSnapshot(source: FeedIncidentSessionSource) {
        val drained = synchronized(gate) {
            if (pending?.source !== source) return
            pending.also { pending = null }
        } ?: return
        if (activeSource !== source) return
        drained.decoderGeneration?.let(recorder::noteDecoderGeneration)
        drained.socketGeneration?.let(recorder::noteSocketGeneration)
        drained.snapshot?.let { snapshot ->
            persist(recorder.recordSnapshot(snapshot))
            if (snapshot.monotonicNow - lastSummaryCheckpoint >= 30.0) {
                lastSummaryCheckpoint = snapshot.monotonicNow
                persistSessionSummary("live")
            }
        }
    }

    private fun persistSessionSummary(outcome: String) {
        val context = sessionContext ?: return
        val summary =
            FeedIncidentSessionSummary(
                sessionID = context.sessionId,
                healthyExposureSeconds = recorder.healthyExposure,
                incidentCount = recorder.incidentCount,
                outcome = outcome,
                sourceRevision = context.sourceRevision,
                appVersion = context.appVersion,
                appBuild = context.appBuild,
                testSource = context.testSource,
                buildIdentity = context.buildIdentity,
            )
        val root = store?.directory ?: return
        FeedSessionSummaryStore.persist(summary, root)
        if (summary.outcome != "live") reporting.noteSessionSummary(summary)
    }

    private fun persist(job: FeedIncidentPersistenceJob?) {
        if (job == null) return
        runCatching { store?.persist(job) }
        if (reporting.isFinalized(job.bundle)) {
            reporting.enqueueFinalized(job.bundle)
        }
    }

    public companion object {
        public fun summaryOutcome(incidentCount: Int, exposure: Double): String {
            if (incidentCount > 0) return "ended"
            if (exposure > 0.0) return "healthy"
            return "no-exposure"
        }
    }
}
