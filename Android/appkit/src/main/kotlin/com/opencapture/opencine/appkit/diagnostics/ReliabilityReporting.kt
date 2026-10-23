package com.opencapture.opencine.appkit.diagnostics

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.opencapture.opencine.media.DiagnosticWire
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBuildIdentity
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentExport
import com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentSessionSummary
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedIncidentVendorEnvelope
import com.opencapture.opencine.media.FeedRepairRecord
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * The calls the reporting SDK makes, implemented by the host. The SDK applies the privacy rules
 * of [ReliabilityReporting.privacy] to every event and breadcrumb and uploads only through
 * [ReliabilityReporting.gate].
 */
public interface ReliabilityReportingSink {
    /** Starts the SDK for [dsn], caching under [cacheDir]. Main thread. */
    public fun start(context: Context, dsn: String, cacheDir: File)

    /** Stops the SDK; its cache is purged afterwards. */
    public fun close()

    public fun flush(timeoutMillis: Long)

    public fun addBreadcrumb(category: String, message: String, data: Map<String, String>)

    /** Sets these tags on the SDK scope in one update. */
    public fun setTags(tags: Map<String, String>)

    /** Captures [event] with [attachment] (JSON) named [attachmentName] as its only attachment. */
    public fun capture(event: ReliabilityEvent, attachment: ByteArray, attachmentName: String)

    /** Records one distribution sample. Main thread. */
    public fun record(metric: ReliabilityMetric): Unit = Unit
}

/**
 * One measurement for the host SDK's metrics, never an issue event. [unit] is a Sentry unit name
 * (`second`) or null; attributes are low-cardinality strings.
 */
public data class ReliabilityMetric(
    public val name: String,
    public val value: Double,
    public val unit: String? = null,
    public val attributes: Map<String, String> = emptyMap(),
)

/**
 * Opt-in automatic reporting, installed by the app and gated by the camera path.
 * Does not start without persisted consent and a valid https DSN. Does not mark
 * an incident delivered when it is only queued. [sink] is the host's reporting SDK;
 * [onCameraPathClear] runs when the last camera path lease ends.
 */
public class ReliabilityReporting(
    public val host: DiagnosticsHost,
    public val consent: ReliabilityReportingConsent,
    public val dsn: ReliabilityReportingDSN,
    public val gate: ReliabilityReportingGate,
    public val origin: FeedIncidentOrigin,
    sink: (ReliabilityReporting) -> ReliabilityReportingSink,
    private val onCameraPathClear: () -> Unit = {},
) {
    public val privacy: ReliabilityReportingPrivacy = ReliabilityReportingPrivacy(host.redact)
    private val sink: ReliabilityReportingSink = sink(this)
    private val executor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opc.reliability").apply { isDaemon = true }
        }
    private val sdkStarted = AtomicBoolean(false)
    private val epoch = AtomicLong(0)
    private val pendingCaptureIds = mutableSetOf<String>()
    private val pendingEventIds = mutableMapOf<String, String>()
    private val lock = Any()
    private val idlePollScheduled = AtomicBoolean(false)
    private val resumeScheduled = AtomicBoolean(false)
    @Volatile private var resumeAttempt = 0
    @Volatile private var captureHandler: ((ReliabilityEvent, ByteArray) -> Unit)? = null
    @Volatile private var metricHandler: ((ReliabilityMetric) -> Unit)? = null
    @Volatile private var feedUpscaler: String? = null
    @Volatile private var finalizedSpoolLoader: () -> List<FeedIncidentBundle> = { emptyList() }
    @Volatile private var sessionSummaryLoader: () -> List<FeedIncidentSessionSummary> = { emptyList() }
    @Volatile private var appContext: Context? = null
    @Volatile private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile public var dsnHost: String? = null
    @Volatile public var sdkCacheRoot: File =
        File(System.getProperty("java.io.tmpdir") ?: ".", "opc-reliability-sdk")

    public val isOptedIn: Boolean
        get() = consent.isOptedIn

    public val isAvailable: Boolean
        get() = dsn.isAvailable

    public fun noteBreadcrumb(source: FeedIncidentBreadcrumb) {
        if (!isOptedIn) return
        sink.addBreadcrumb("feed", source.kind.wire, FeedIncidentNativeBreadcrumb.details(source.kind, source.detail))
    }

    public fun noteRepair(repair: FeedRepairRecord) {
        if (!isOptedIn) return
        sink.addBreadcrumb("feed", "repair", FeedIncidentNativeBreadcrumb.details(repair))
    }

    /**
     * The feed upscaler in effect, a scope tag on every later event and crash (Swift twin;
     * PI-3M: a super-resolution crash said nothing about the mode). Main thread.
     */
    public fun noteFeedUpscaler(upscaler: String) {
        val value = ReliabilityReportingPrivacy.value("feedUpscaler", upscaler)
        feedUpscaler = value
        if (!isOptedIn || !sdkStarted.get()) return
        sink.setTags(mapOf("feedUpscaler" to value))
    }

    /**
     * The current run's scope tags, set when the SDK starts, bounded by the same rules as event
     * tags (native crashes carry them).
     */
    public fun scopeTags(): Map<String, String> {
        val tags = linkedMapOf(
            "sourceRevision" to host.sourceRevision,
            "testSource" to origin.currentTestSource().wire,
            "buildIdentity" to origin.currentBuildIdentity(),
            // Native crashes carry no device context; these name the phone and SoC.
            "hardwareClass" to (Build.MODEL ?: "unknown"),
        )
        feedUpscaler?.let { tags["feedUpscaler"] = it }
        return privacy.tags(tags).orEmpty()
    }

    public fun noteCurrentTestSource(source: FeedIncidentTestSource) {
        if (!isOptedIn) return
        postOnMain {
            sink.setTags(mapOf("testSource" to source.wire))
        }
    }

    public fun install(context: Context, incidents: FeedIncidentRuntime) {
        val app = context.applicationContext
        appContext = app
        consent.bind(
            app.getSharedPreferences(host.preferencesName, Context.MODE_PRIVATE),
        )
        dsn.buildDsn = host.reportingDsn
        sdkCacheRoot = File(app.cacheDir, "opc-reliability-sdk")
        dsn.configured()?.let { dsn ->
            dsnHost = ReliabilityReportingHostPolicy.host(fromDSN = dsn)
        }
        gate.extraCameraPathProbe = { processBoundToCamera(app) }
        finalizedSpoolLoader = { incidents.loadFinalized() }
        sessionSummaryLoader = { incidents.loadSessionSummaries() }
        applySdkState()
    }

    /**
     * Holds reports back from this connect attempt (recovery included) until the returned lease
     * ends, when its owner retires. Each owner keeps its own lease; uploads resume after the last
     * one ends. Main thread.
     */
    public fun beginCameraPath(): ReliabilityCameraPathLease = gate.beginCameraPath(::cameraPathCleared)

    private fun cameraPathCleared() {
        if (!sdkStarted.get() && consent.isOptedIn) {
            applySdkState()
        }
        enqueueFinalizedFromSpool()
        scheduleResumeIfIdle()
        onCameraPathClear()
    }

    public fun setConsent(on: Boolean) {
        bumpEpoch()
        consent.setOptedIn(on)
        if (!on) gate.cancelPending(includeIndependent = false)
        applySdkState()
    }

    public fun setFinalizedSpoolLoader(loader: () -> List<FeedIncidentBundle>) {
        executor.execute { finalizedSpoolLoader = loader }
    }

    public fun setSessionSummaryLoader(loader: () -> List<FeedIncidentSessionSummary>) {
        executor.execute { sessionSummaryLoader = loader }
    }

    public fun isFinalized(bundle: FeedIncidentBundle): Boolean = Companion.isFinalized(bundle)

    public fun enqueueFinalized(bundle: FeedIncidentBundle) {
        val capturedEpoch = currentEpoch()
        executor.execute { captureIfFinalized(bundle, capturedEpoch) }
    }

    public fun enqueueFinalizedFromSpool() {
        val capturedEpoch = currentEpoch()
        executor.execute {
            if (!consent.isOptedIn ||
                capturedEpoch != currentEpoch() ||
                gate.shouldBlockUpload
            ) {
                return@execute
            }
            for (bundle in finalizedSpoolLoader()) {
                if (isFinalized(bundle)) captureIfFinalized(bundle, capturedEpoch)
            }
            for (summary in sessionSummaryLoader()) {
                captureSessionSummary(summary, capturedEpoch)
            }
        }
    }

    public fun noteSessionSummary(summary: FeedIncidentSessionSummary) {
        val capturedEpoch = currentEpoch()
        executor.execute { captureSessionSummary(summary, capturedEpoch) }
    }

    public fun receipt(forIncidentID: String): ReliabilityReportingReceipt? =
        ReliabilityReportingReceipts.load(forIncidentID, sdkCacheRoot)

    public fun setCaptureHandlerForTests(handler: ((ReliabilityEvent, ByteArray) -> Unit)?) {
        captureHandler = handler
    }

    public fun setMetricHandlerForTests(handler: ((ReliabilityMetric) -> Unit)?) {
        metricHandler = handler
    }

    public fun noteTransportSuccess(eventID: String) {
        if (!consent.isOptedIn) return
        synchronized(lock) {
            for ((id, pendingEventID) in pendingEventIds) {
                if (pendingEventID.equals(eventID, ignoreCase = true)) {
                    ReliabilityReportingReceipts.store(
                        ReliabilityReportingReceipt(
                            incidentID = id,
                            eventID = eventID,
                            state = ReliabilityReportingReceiptState.CONFIRMED,
                            updatedAt = System.currentTimeMillis(),
                        ),
                        sdkCacheRoot,
                    )
                }
            }
        }
        ReliabilityReportingReceipts.markConfirmed(eventID, sdkCacheRoot)
    }

    private fun applySdkState() {
        val consented = consent.isOptedIn
        val dsn = dsn.configured()
        if (consented && dsn != null) {
            dsnHost = ReliabilityReportingHostPolicy.host(fromDSN = dsn)
            scheduleIdlePoll()
            observeInternetIfNeeded()
            startSdk(dsn)
        } else {
            stopAndPurgeSdkOwned()
        }
    }

    private fun observeInternetIfNeeded() {
        val app = appContext ?: return
        if (networkCallback != null) return
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val callback =
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = onPathChanged()
                override fun onLost(network: Network) = onPathChanged()
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    onPathChanged()
            }
        networkCallback = callback
        runCatching {
            cm.registerNetworkCallback(
                NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),
                callback,
            )
        }
    }

    private fun onPathChanged() {
        postOnMain {
            if (!consent.isOptedIn) return@postOnMain
            if (gate.shouldBlockUpload) {
                gate.cancelPending()
            } else {
                dsn.configured()?.let { dsn ->
                    if (!sdkStarted.get()) startSdk(dsn)
                }
                enqueueFinalizedFromSpool()
                scheduleResumeIfIdle()
            }
        }
    }

    private fun startSdk(dsn: String) {
        if (sdkStarted.get()) {
            enqueueFinalizedFromSpool()
            return
        }
        val capturedEpoch = currentEpoch()
        dsnHost = ReliabilityReportingHostPolicy.host(fromDSN = dsn)
        executor.execute {
            if (capturedEpoch != currentEpoch() || !consent.isOptedIn) return@execute
            sdkCacheRoot.mkdirs()
            postOnMain {
                if (capturedEpoch != currentEpoch() || !consent.isOptedIn) {
                    return@postOnMain
                }
                if (sdkStarted.compareAndSet(false, true)) {
                    val app = appContext
                    if (app == null) {
                        sdkStarted.set(false)
                    } else {
                        sink.start(app, dsn, sdkCacheRoot)
                        sink.setTags(scopeTags())
                    }
                }
                enqueueFinalizedFromSpool()
                scheduleResumeIfIdle()
            }
        }
    }

    private fun stopAndPurgeSdkOwned() {
        val callback = networkCallback
        networkCallback = null
        val app = appContext
        if (callback != null && app != null) {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            runCatching { cm?.unregisterNetworkCallback(callback) }
        }
        gate.cancelPending()
        val close = {
            if (sdkStarted.compareAndSet(true, false)) {
                sink.close()
            }
            executor.execute {
                ReliabilityReportingReceipts.purge(sdkCacheRoot)
                sdkCacheRoot.deleteRecursively()
            }
        }
        runOnMain(close)
    }

    private fun runOnMain(block: () -> Unit) {
        val looper = runCatching { Looper.getMainLooper() }.getOrNull()
        if (looper == null || Looper.myLooper() == looper) {
            block()
        } else {
            Handler(looper).post(block)
        }
    }

    private fun postOnMain(delayMs: Long = 0L, block: () -> Unit) {
        val looper = runCatching { Looper.getMainLooper() }.getOrNull()
        if (looper == null) {
            if (delayMs == 0L) block()
            return
        }
        if (delayMs == 0L) Handler(looper).post(block) else Handler(looper).postDelayed(block, delayMs)
    }

    private fun captureIfFinalized(bundle: FeedIncidentBundle, capturedEpoch: Long) {
        if (capturedEpoch != currentEpoch() || !consent.isOptedIn) return
        if (!isFinalized(bundle)) return
        val envelope = ReliabilityReportingPrivacy.validatedEnvelope(bundle) ?: return
        val json = ReliabilityReportingPrivacy.typedJson(bundle) ?: return
        val eventId = ReliabilityReportingPrivacy.eventId(envelope.incidentID)
        val event = makeEvent(envelope, eventId)
        capturePayload(event, json, envelope.incidentID, capturedEpoch)
    }

    /**
     * The feed's denominator as metrics, never an issue event (it was the largest issue by
     * volume, PA-2/II-1/PI-W): healthy exposure seconds and incident count per ended session.
     * Recorded once per session; a confirmed receipt outlives the summary on disk.
     */
    private fun captureSessionSummary(summary: FeedIncidentSessionSummary, capturedEpoch: Long) {
        if (capturedEpoch != currentEpoch() || !consent.isOptedIn || gate.shouldBlockUpload) return
        if (summary.outcome == "live") return
        if (runCatching { UUID.fromString(summary.sessionID) }.getOrNull() == null) return
        if (!summary.healthyExposureSeconds.isFinite() || summary.healthyExposureSeconds < 0.0) return
        val id = "session-" + summary.sessionID
        ReliabilityReportingReceipts.applyTTL(sdkCacheRoot)
        if (ReliabilityReportingReceipts.load(id, sdkCacheRoot) != null) return
        synchronized(lock) {
            if (!pendingCaptureIds.add(id)) return
        }
        val metrics = sessionMetrics(summary, host.redact).mapNotNull { privacy.metric(it) }
        val record = {
            try {
                val handler = metricHandler
                if (capturedEpoch == currentEpoch() && consent.isOptedIn && (sdkStarted.get() || handler != null)) {
                    for (metric in metrics) if (handler != null) handler(metric) else sink.record(metric)
                    executor.execute {
                        if (capturedEpoch == currentEpoch() && consent.isOptedIn) {
                            ReliabilityReportingReceipts.store(
                                ReliabilityReportingReceipt(
                                    incidentID = id,
                                    eventID = "",
                                    state = ReliabilityReportingReceiptState.CONFIRMED,
                                    updatedAt = System.currentTimeMillis(),
                                ),
                                sdkCacheRoot,
                            )
                        }
                    }
                }
            } finally {
                synchronized(lock) { pendingCaptureIds.remove(id) }
            }
        }
        if (metricHandler != null) record() else postOnMain { record() }
    }

    private fun capturePayload(
        event: ReliabilityEvent,
        json: ByteArray,
        id: String,
        capturedEpoch: Long,
    ) {
        if (capturedEpoch != currentEpoch() ||
            !consent.isOptedIn ||
            gate.shouldBlockUpload
        ) {
            return
        }
        ReliabilityReportingReceipts.applyTTL(sdkCacheRoot)
        val existing = ReliabilityReportingReceipts.load(id, sdkCacheRoot)
        if (existing != null) {
            if (existing.state == ReliabilityReportingReceiptState.CONFIRMED) return
            if (System.currentTimeMillis() - existing.updatedAt < 300_000L) return
        }
        synchronized(lock) {
            if (!pendingCaptureIds.add(id)) return
            pendingEventIds[id] = event.eventId
        }
        val handler = captureHandler
        if (handler != null) {
            handler(event, json)
            synchronized(lock) {
                pendingCaptureIds.remove(id)
                pendingEventIds.remove(id)
            }
            if (currentEpoch() == capturedEpoch && consent.isOptedIn) {
                val receipt = ReliabilityReportingReceipts.load(id, sdkCacheRoot)
                if (receipt?.state != ReliabilityReportingReceiptState.CONFIRMED) {
                    ReliabilityReportingReceipts.store(
                        ReliabilityReportingReceipt(
                            incidentID = id,
                            eventID = event.eventId,
                            state = ReliabilityReportingReceiptState.QUEUED,
                            updatedAt = System.currentTimeMillis(),
                        ),
                        sdkCacheRoot,
                    )
                }
            }
            return
        }
        postOnMain {
            try {
                if (capturedEpoch != currentEpoch() ||
                    !consent.isOptedIn ||
                    (!sdkStarted.get() && captureHandler == null)
                ) {
                    return@postOnMain
                }
                sink.capture(event, json, "$id.json")
                executor.execute {
                    if (capturedEpoch != currentEpoch() || !consent.isOptedIn) {
                        return@execute
                    }
                    val receipt = ReliabilityReportingReceipts.load(id, sdkCacheRoot)
                    if (receipt?.state == ReliabilityReportingReceiptState.CONFIRMED) return@execute
                    ReliabilityReportingReceipts.store(
                        ReliabilityReportingReceipt(
                            incidentID = id,
                            eventID = event.eventId,
                            state = ReliabilityReportingReceiptState.QUEUED,
                            updatedAt = System.currentTimeMillis(),
                        ),
                        sdkCacheRoot,
                    )
                }
            } finally {
                executor.execute {
                    synchronized(lock) {
                        pendingCaptureIds.remove(id)
                        pendingEventIds.remove(id)
                    }
                }
            }
        }
    }

    private fun makeEvent(envelope: FeedIncidentVendorEnvelope, eventId: String): ReliabilityEvent =
        privacy.scrub(
            ReliabilityEvent(
                eventId = eventId,
                level = level(envelope.grouping.outcome),
                timestampMs = envelope.startedAtWallClockMs,
                release = host.release(envelope.appVersion, envelope.appBuild),
                dist = envelope.appBuild,
                // Kind is in the fingerprint, so the issue title stays stable per group.
                message = "feed incident ${envelope.grouping.failingStage}: ${envelope.kind}",
                fingerprints =
                    privacy.fingerprint(
                        envelope.schemaVersion,
                        envelope.kind,
                        envelope.grouping.failingStage,
                        envelope.grouping.errorClass,
                    ),
                tags =
                    linkedMapOf(
                        "failingStage" to envelope.grouping.failingStage,
                        "errorClass" to envelope.grouping.errorClass,
                        "outcome" to envelope.grouping.outcome,
                        "kind" to envelope.kind,
                        "sourceRevision" to envelope.sourceRevision,
                        "cameraFamily" to envelope.cameraFamily,
                        "cameraFirmware" to envelope.grouping.cameraFirmware,
                        "hardwareClass" to envelope.grouping.hardwareClass,
                        "testSource" to envelope.testSource,
                        "buildIdentity" to envelope.buildIdentity,
                        "trigger" to envelope.trigger,
                        "recoveredBy" to envelope.recoveredBy,
                        "gap" to FeedIncidentExport.gapBucket(envelope.worstGapSeconds),
                        "decoderCall" to envelope.decoderCall,
                        "keyframeWait" to envelope.keyframeWait,
                        "irapAge" to envelope.irapAge,
                        "decodeFlow" to envelope.decodeFlow,
                        // Diagnostics: no bundle attachment reaches the issue, so these two say
                        // whether the gap spanned an app switch and whether a keyframe was pending.
                        "background" to envelope.background,
                        "awaitingIrap" to envelope.awaitingIrap,
                    ),
                extras =
                    linkedMapOf(
                        "schemaVersion" to envelope.schemaVersion,
                        "failingStage" to envelope.grouping.failingStage,
                        "errorClass" to envelope.grouping.errorClass,
                        "outcome" to envelope.grouping.outcome,
                        "kind" to envelope.kind,
                        "hardwareClass" to envelope.grouping.hardwareClass,
                        "cameraFirmware" to envelope.grouping.cameraFirmware,
                        "assistState" to envelope.grouping.assistState,
                        "decoderGeneration" to envelope.decoderGeneration,
                        "socketGeneration" to envelope.socketGeneration,
                        "worstGapSeconds" to envelope.worstGapSeconds,
                        "healthyExposureSeconds" to envelope.healthyExposureSeconds,
                        "sourceRevision" to envelope.sourceRevision,
                        "testSource" to envelope.testSource,
                        "buildIdentity" to envelope.buildIdentity,
                        "trigger" to envelope.trigger,
                        "recoveredBy" to envelope.recoveredBy,
                        "background" to envelope.background,
                        "awaitingIrap" to envelope.awaitingIrap,
                    ),
                contexts =
                    mapOf(
                        "feed" to
                            mapOf(
                                "schemaVersion" to envelope.schemaVersion,
                                "failingStage" to envelope.grouping.failingStage,
                                "errorClass" to envelope.grouping.errorClass,
                                "outcome" to envelope.grouping.outcome,
                                "kind" to envelope.kind,
                                "assistState" to envelope.grouping.assistState,
                                "hardwareClass" to envelope.grouping.hardwareClass,
                                "testSource" to envelope.testSource,
                                "buildIdentity" to envelope.buildIdentity,
                                "trigger" to envelope.trigger,
                                "recoveredBy" to envelope.recoveredBy,
                                "worstGapSeconds" to envelope.worstGapSeconds,
                                "decoderCall" to envelope.decoderCall,
                                "keyframeWait" to envelope.keyframeWait,
                                "irapAge" to envelope.irapAge,
                                "decodeFlow" to envelope.decodeFlow,
                            ),
                    ),
            ),
        )

    private fun scheduleIdlePoll() {
        if (!idlePollScheduled.compareAndSet(false, true)) return
        postOnMain(30_000L) {
            idlePollScheduled.set(false)
            if (!consent.isOptedIn) return@postOnMain
            val dsn = dsn.configured() ?: return@postOnMain
            startSdk(dsn)
            if (!gate.shouldBlockUpload) {
                enqueueFinalizedFromSpool()
                scheduleResumeIfIdle()
            }
            scheduleIdlePoll()
        }
    }

    private fun scheduleResumeIfIdle() {
        if (gate.shouldBlockUpload ||
            !consent.isOptedIn ||
            !sdkStarted.get() ||
            !resumeScheduled.compareAndSet(false, true)
        ) {
            return
        }
        val attempt = resumeAttempt
        resumeAttempt = minOf(resumeAttempt + 1, 6)
        val jitter = ((attempt * 37) % 100).toDouble() / 100.0
        val delayMs = (ReliabilityReportingBackoff.delaySeconds(attempt, jitter) * 1000).toLong()
        val capturedEpoch = currentEpoch()
        executor.execute {
            try {
                Thread.sleep(delayMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            try {
                if (capturedEpoch != currentEpoch() ||
                    !consent.isOptedIn ||
                    gate.shouldBlockUpload ||
                    !sdkStarted.get()
                ) {
                    return@execute
                }
                sink.flush(2_000)
                postOnMain { resumeAttempt = 0 }
            } finally {
                postOnMain { resumeScheduled.set(false) }
            }
        }
    }

    private fun bumpEpoch() {
        epoch.incrementAndGet()
    }

    private fun currentEpoch(): Long = epoch.get()

    private fun processBoundToCamera(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val bound = cm.boundNetworkForProcess ?: return false
        val caps = cm.getNetworkCapabilities(bound) ?: return false
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return false
        val props = cm.getLinkProperties(bound) ?: return false
        return props.linkAddresses.any { addr ->
            val host = DiagnosticWire.ipv4(addr.address)
            host?.startsWith(gate.cameraIPv4Prefix) == true
        }
    }

    public companion object {
        /** The metrics one ended session records (`ReliabilityReportingPrivacy.metricAllowlist`). */
        public fun sessionMetrics(
            summary: FeedIncidentSessionSummary,
            redact: (String) -> String,
        ): List<ReliabilityMetric> {
            val attributes =
                linkedMapOf(
                    "outcome" to summary.outcome,
                    "testSource" to (summary.testSource ?: FeedIncidentTestSource.UNKNOWN).wire,
                    "buildIdentity" to FeedIncidentBuildIdentity.parse(summary.buildIdentity, redact),
                    "sourceRevision" to summary.sourceRevision,
                )
            summary.appBuild?.let { attributes["appBuild"] = it }
            return listOf(
                ReliabilityMetric("feed.session.healthy_exposure", summary.healthyExposureSeconds, "second", attributes),
                ReliabilityMetric("feed.session.incidents", summary.incidentCount.toDouble(), null, attributes),
            )
        }

        public fun isFinalized(bundle: FeedIncidentBundle): Boolean =
            when (bundle.header.outcome) {
                FeedIncidentOutcome.OPEN -> false
                FeedIncidentOutcome.RECOVERED,
                FeedIncidentOutcome.INTERRUPTED,
                FeedIncidentOutcome.EXHAUSTED,
                FeedIncidentOutcome.SUPPRESSED,
                FeedIncidentOutcome.USER_ENDED,
                -> true
            }

        /**
         * Only an incident the recovery ladder gave up on is an error. Recovered and
         * suppressed ones are the reliability baseline, not failures.
         */
        public fun level(outcome: String): ReliabilityEventLevel =
            when (outcome) {
                FeedIncidentOutcome.EXHAUSTED.wire -> ReliabilityEventLevel.ERROR
                FeedIncidentOutcome.INTERRUPTED.wire, FeedIncidentOutcome.USER_ENDED.wire -> ReliabilityEventLevel.WARNING
                else -> ReliabilityEventLevel.INFO
            }
    }
}
