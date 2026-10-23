package com.opencapture.opencine.appkit.sentry

import android.content.Context
import com.opencapture.opencine.appkit.diagnostics.ReliabilityEvent
import com.opencapture.opencine.appkit.diagnostics.ReliabilityMetric
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReporting
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingBackoff
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingCancellable
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingLoadDecision
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingNetwork
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingPrivacy
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingSink
import io.sentry.Attachment
import io.sentry.Breadcrumb
import io.sentry.Hint
import io.sentry.ITransportFactory
import io.sentry.RequestDetails
import io.sentry.Sentry
import io.sentry.SentryEnvelope
import io.sentry.SentryEvent
import io.sentry.SentryLevel
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid
import io.sentry.android.core.SentryAndroidOptions
import io.sentry.cache.EnvelopeCache
import io.sentry.metrics.SentryMetricsParameters
import io.sentry.protocol.Message
import io.sentry.protocol.SentryId
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.User
import io.sentry.transport.ITransport
import io.sentry.transport.RateLimiter
import java.io.File
import java.io.IOException
import java.util.Date
import java.util.concurrent.CopyOnWriteArrayList
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Sentry for OpenCine's [ReliabilityReporting]: SDK start and options, the shared privacy
 * rules applied to Sentry's events and breadcrumbs, capture with the typed attachment, and the
 * gated OkHttp transport. Scheduling, consent, receipts and payloads are shared. The app passes
 * `::SentryReliabilitySink` as its reporting sink. Moved from the apps' copies (A6-03).
 */
public class SentryReliabilitySink(private val reporting: ReliabilityReporting) : ReliabilityReportingSink {
    override fun start(context: Context, dsn: String, cacheDir: File) {
        SentryAndroid.init(context) { configured ->
            configured.dsn = dsn
            configured.cacheDirPath = cacheDir.absolutePath
            applyPrivacyOptions(configured, reporting)
            configured.isForceInit = true
        }
        // Native crashes and metrics carry the anonymous install id through the scope.
        Sentry.setUser(installUser(reporting.consent.installId))
    }

    override fun close() {
        Sentry.close()
    }

    override fun flush(timeoutMillis: Long) {
        Sentry.flush(timeoutMillis)
    }

    override fun addBreadcrumb(category: String, message: String, data: Map<String, String>) {
        val breadcrumb = Breadcrumb()
        breadcrumb.category = category
        breadcrumb.message = message
        for ((key, value) in data) {
            breadcrumb.setData(key, value)
        }
        Sentry.addBreadcrumb(breadcrumb)
    }

    override fun setTags(tags: Map<String, String>) {
        Sentry.configureScope { scope ->
            for ((key, value) in tags) scope.setTag(key, value)
        }
    }

    /**
     * The event's own tags already win over the scope's when the SDK merges them, so the capture
     * scope only swaps the attachment. Tags set on it would reach every scope observer, the NDK
     * one included, and stamp the incident onto later native crashes (PA-E, PA-16).
     */
    override fun capture(event: ReliabilityEvent, attachment: ByteArray, attachmentName: String) {
        Sentry.captureEvent(event.toSentryEvent()) { scope ->
            scope.clearAttachments()
            scope.addAttachment(Attachment(attachment, attachmentName, "application/json"))
        }
    }

    override fun record(metric: ReliabilityMetric) {
        Sentry.metrics().distribution(
            metric.name,
            metric.value,
            metric.unit,
            SentryMetricsParameters.create(metric.attributes),
        )
    }
}

/** The SDK user: the anonymous install id only, or none. */
internal fun installUser(installId: String?): User? = installId?.let { id -> User().apply { this.id = id } }

internal fun ReliabilityEvent.toSentryEvent(): SentryEvent {
    val event = SentryEvent()
    event.level = SentryLevel.valueOf(level.name)
    event.eventId = SentryId(eventId)
    event.timestamp = Date(timestampMs)
    event.release = release
    event.dist = dist
    val formatted = Message()
    formatted.formatted = message
    event.message = formatted
    event.fingerprints = fingerprints
    tags?.forEach { (key, value) -> event.setTag(key, value) }
    extras?.forEach { (key, value) -> event.setExtra(key, value) }
    for ((section, values) in contexts) event.contexts[section] = values
    return event
}

internal fun applyPrivacyOptions(options: SentryAndroidOptions, reporting: ReliabilityReporting) {
    options.isSendDefaultPii = false
    options.isEnableAutoSessionTracking = false
    options.maxCacheItems = 30
    options.maxAttachmentSize = 256 * 1_024L
    options.shutdownTimeoutMillis = 0
    options.connectionTimeoutMillis = 20_000
    options.readTimeoutMillis = 20_000
    options.maxBreadcrumbs = 32
    options.isEnableUserInteractionTracing = false
    options.isEnableUserInteractionBreadcrumbs = false
    options.isEnableAutoActivityLifecycleTracing = false
    options.isEnableActivityLifecycleTracingAutoFinish = false
    options.isEnableFramesTracking = false
    options.isEnablePerformanceV2 = false
    options.isAttachScreenshot = false
    options.isAttachViewHierarchy = false
    options.isAttachStacktrace = false
    options.release = reporting.host.currentRelease
    options.dist = reporting.host.versionCode.toString()
    options.environment = reporting.host.environment
    options.isAnrEnabled = true
    options.isEnableUncaughtExceptionHandler = true
    options.isEnableNdk = true
    options.isEnableRootCheck = false
    options.isCollectAdditionalContext = false
    options.enableAllAutoBreadcrumbs(false)
    options.sessionReplay.sessionSampleRate = 0.0
    options.sessionReplay.onErrorSampleRate = 0.0
    options.tracesSampleRate = 0.0
    options.setBeforeBreadcrumb { breadcrumb, _ ->
        reporting.privacy.scrubBreadcrumb(breadcrumb)
    }
    options.setBeforeSend { event, _ ->
        if (!reporting.consent.isOptedIn) return@setBeforeSend null
        reporting.privacy.scrub(event).also { it.user = installUser(reporting.consent.installId) }
    }
    // Only the shared metrics leave the phone, and only under consent.
    options.metrics.setBeforeSend { metric, _ ->
        metric.takeIf {
            reporting.consent.isOptedIn && ReliabilityReportingPrivacy.metricAllowlist.contains(it.name)
        }
    }
    options.setBeforeSendTransaction { _, _ -> null }
    options.setTransportGate { reporting.gate.isConnected }
    options.setTransportFactory(ReliabilityReportingTransportFactory(reporting))
    runCatching { options.logs.isEnabled = false }
    runCatching { options.setEnableLegacyProfiling(false) }
    runCatching { options.anrProfilingSampleRate = null }
    runCatching { options.isTombstoneEnabled = false }
    runCatching { options.isEnableAppStartProfiling = false }
}

internal fun makeOptions(dsn: String, reporting: ReliabilityReporting): SentryAndroidOptions {
    val options = SentryAndroidOptions()
    options.dsn = dsn
    options.cacheDirPath = reporting.sdkCacheRoot.absolutePath
    applyPrivacyOptions(options, reporting)
    return options
}

internal fun ReliabilityReportingPrivacy.scrub(event: SentryEvent): SentryEvent {
    event.user = null
    event.request = null
    event.breadcrumbs =
        event.breadcrumbs
            ?.mapNotNull { scrubBreadcrumb(it) }
            ?.takeLast(32)
            ?.toMutableList()
    event.serverName = null
    event.transaction = null
    val formatted = event.message?.formatted
    if (formatted != null) {
        val kept = Message()
        kept.formatted = message(formatted, event.fingerprints?.firstOrNull())
        event.message = kept
    }
    event.tags?.let { current -> event.tags = tags(current)?.toMutableMap() }
    event.extras?.let { current -> event.extras = extras(current)?.toMutableMap() }
    val sentryContexts = event.contexts
    val keptSections = contexts { section -> sentryContexts[section] }
    sentryContexts.clear()
    for ((section, values) in keptSections) {
        sentryContexts[section] = values
    }
    event.exceptions?.forEach { exception ->
        exception.value = exception.value?.let { ReliabilityReportingPrivacy.exceptionValue(it) }
        redactFrames(exception.stacktrace?.frames)
    }
    event.threads?.forEach { thread ->
        redactFrames(thread.stacktrace?.frames)
    }
    return event
}

internal fun ReliabilityReportingPrivacy.scrubBreadcrumb(breadcrumb: Breadcrumb): Breadcrumb? {
    val data = breadcrumb.data
    val kept = breadcrumbData(breadcrumb.category, breadcrumb.message, data) ?: return null
    data.clear()
    for ((key, value) in kept) {
        breadcrumb.setData(key, value)
    }
    return breadcrumb
}

private fun ReliabilityReportingPrivacy.redactFrames(frames: List<SentryStackFrame>?) {
    if (frames == null) return
    for (frame in frames) {
        frame.vars = null
        frame.contextLine = null
        frame.preContext = null
        frame.postContext = null
        frame.filename = frame.filename?.let { frameText(it) }
        frame.function = frame.function?.let { frameText(it) }
    }
}

/**
 * Dedicated Sentry transport. Caches envelopes while the camera path is up, posts
 * only to the DSN host over OkHttp, and cancels in-flight calls when the camera
 * session starts or consent is revoked. HTTP 2xx is the only delivery confirmation.
 */
internal class ReliabilityReportingTransport(
    private val reporting: ReliabilityReporting,
    private val options: SentryOptions,
    private val requestDetails: RequestDetails,
    client: okhttp3.OkHttpClient? = null,
) : ITransport, ReliabilityReportingCancellable {
    private val http =
        client
            ?: okhttp3.OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .connectTimeout(options.connectionTimeoutMillis.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
                .readTimeout(options.readTimeoutMillis.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
                .callTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
                .build()
    private val executor =
        java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opc.reliability.http").apply { isDaemon = true }
        }
    private val inflight = CopyOnWriteArrayList<okhttp3.Call>()
    private val closed = java.util.concurrent.atomic.AtomicBoolean(false)
    private val drainScheduled = java.util.concurrent.atomic.AtomicBoolean(false)
    private val pending = java.util.concurrent.ConcurrentHashMap<String, Pair<SentryEnvelope, Hint>>()
    private val limiter = RateLimiter(options)
    @Volatile private var nextAttemptAt = 0L
    private var failures = 0

    private fun finishHint(hint: Hint, success: Boolean) {
        val sdkHint = io.sentry.util.HintUtils.getSentrySdkHint(hint)
        (sdkHint as? io.sentry.hints.Retryable)?.setRetry(!success)
        (sdkHint as? io.sentry.hints.SubmissionResult)?.setResult(success)
    }

    /** One pending key per report: its event id, else its cache file, else the instance. */
    private fun key(envelope: SentryEnvelope, file: File? = null): String =
        envelope.header.eventId?.toString()
            ?: file?.let { "file:${it.name}" }
            ?: System.identityHashCode(envelope).toString()

    /**
     * Each pending report's cache file, deleted on delivery. The SDK's `discard` finds a file only
     * through the name map of the process that stored it: a report reloaded after a restart kept
     * its file after HTTP 2xx and was sent again on every drain.
     */
    private val cachedFiles = java.util.concurrent.ConcurrentHashMap<String, File>()

    /** The SDK's own file cache, which this transport reads and deletes file by file. */
    private val cacheDirectory: File?
        get() = options.cacheDirPath?.takeIf { options.envelopeDiskCache is EnvelopeCache }?.let(::File)

    /** Admits cached envelopes to the pending queue. */
    private fun reloadDiskCache() {
        // The SDK's file cache is read file by file, so every reloaded report keeps its file.
        if (cacheDirectory != null) {
            reloadCacheFiles()
            return
        }
        // Another cache owns its own discard; only its iterator can be read.
        try {
            for (envelope in options.envelopeDiskCache.take(options.maxCacheItems)) {
                if (envelope == null) continue // The SDK's Java iterator can yield null.
                if (pending.size >= options.maxCacheItems) break
                pending.putIfAbsent(key(envelope), envelope to Hint())
            }
        } catch (error: Exception) {
            // PA-12: the SDK reads the whole cache in one pass, so one malformed file failed
            // every drain and stranded every healthy report behind it. Read file by file.
            options.logger.log(SentryLevel.WARNING,
                "Could not reload cached reliability envelopes (%s); reading files one by one",
                error.javaClass.simpleName)
            reloadCacheFiles()
        }
    }

    private fun reloadCacheFiles() {
        try {
            val read = CachedEnvelopeFiles.read(
                options.cacheDirPath?.let(::File), options.serializer,
                System.currentTimeMillis(), options.maxCacheItems)
            if (read.removed > 0) {
                options.logger.log(SentryLevel.WARNING,
                    "Removed %d unreadable cached reliability envelope(s)", read.removed)
            }
            for ((file, envelope) in read.entries) {
                if (pending.size >= options.maxCacheItems) break
                val id = key(envelope, file)
                if (pending.putIfAbsent(id, envelope to Hint()) == null) cachedFiles[id] = file
            }
        } catch (error: Exception) {
            // Must not terminate the transport worker or block reports already pending.
            options.logger.log(SentryLevel.WARNING,
                "Could not read cached reliability envelope files (%s); retaining disk cache",
                error.javaClass.simpleName)
        }
    }

    private fun forget(id: String, entry: Pair<SentryEnvelope, Hint>) {
        pending.remove(id, entry)
        cachedFiles.remove(id)?.delete()
    }

    private fun scheduleDrain() {
        if (closed.get() || !drainScheduled.compareAndSet(false, true)) return
        try {
            executor.execute {
                try {
                    if (reporting.gate.shouldBlockUpload ||
                        !reporting.consent.isOptedIn ||
                        System.currentTimeMillis() < nextAttemptAt || limiter.isAnyRateLimitActive
                    ) return@execute
                    // Reload disk on every idle flush, including native reports cached
                    // before the camera gate opened. Bound memory and queued work.
                    reloadDiskCache()
                    for ((id, entry) in pending.entries.toList()) {
                        if (closed.get() || reporting.gate.shouldBlockUpload ||
                            !reporting.consent.isOptedIn ||
                            System.currentTimeMillis() < nextAttemptAt || limiter.isAnyRateLimitActive
                        ) break
                        val delivered =
                            try {
                                post(entry.first)
                            } catch (error: Exception) {
                                // An envelope that cannot even be serialized never will be:
                                // drop it rather than let the exception end the process.
                                options.logger.log(SentryLevel.WARNING,
                                    "Dropping a reliability envelope that cannot be sent (%s)",
                                    error.javaClass.simpleName)
                                forget(id, entry)
                                runCatching { options.envelopeDiskCache.discard(entry.first) }
                                val sdkHint = io.sentry.util.HintUtils.getSentrySdkHint(entry.second)
                                (sdkHint as? io.sentry.hints.Retryable)?.setRetry(false)
                                (sdkHint as? io.sentry.hints.SubmissionResult)?.setResult(false)
                                continue
                            }
                        if (delivered) {
                            forget(id, entry)
                            finishHint(entry.second, true)
                            failures = 0
                        } else {
                            finishHint(entry.second, false)
                            failures = minOf(failures + 1, 6)
                            nextAttemptAt = System.currentTimeMillis() +
                                (ReliabilityReportingBackoff.delaySeconds(failures, 0.5) * 1000).toLong()
                            break
                        }
                    }
                } finally {
                    drainScheduled.set(false)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            drainScheduled.set(false)
        }
    }

    @Synchronized
    override fun send(envelope: SentryEnvelope, hint: Hint) {
        if (closed.get()) throw IOException("not connected")
        if (!reporting.consent.isOptedIn) {
            options.envelopeDiskCache.discard(envelope)
            throw IOException("not connected")
        }
        val url = requestDetails.url
        val decision = ReliabilityReportingNetwork.decision(url.toString(), reporting.dsnHost, reporting.gate)
        if (decision == ReliabilityReportingLoadDecision.REJECT_HOST) {
            throw IOException("cannot find host")
        }
        // Own a bounded durable copy even for native/outbox hints. The SDK's
        // original is acknowledged only after HTTP acceptance.
        val directory = cacheDirectory
        val before = CachedEnvelopeFiles.names(directory)
        val stored = options.envelopeDiskCache.storeEnvelope(envelope, hint)
        // The file this report was stored in, so the next reload finds it pending (an envelope
        // without an event id was otherwise sent twice) and delivery deletes it.
        val file =
            if (stored && directory != null) {
                (CachedEnvelopeFiles.names(directory) - before).singleOrNull()?.let { File(directory, it) }
            } else {
                null
            }
        val id = key(envelope, file)
        val diskHint = io.sentry.util.HintUtils.getSentrySdkHint(hint) as?
            io.sentry.hints.DiskFlushNotification
        if (stored && diskHint != null && diskHint.isFlushable(envelope.header.eventId)) {
            diskHint.markFlushed()
        }
        if (pending.size < options.maxCacheItems || pending.containsKey(id)) {
            val admitted = pending.putIfAbsent(id, envelope to hint) == null
            if (file != null) {
                // A report already pending with its own file (resent by the SDK) needs no second copy.
                if (!admitted && cachedFiles[id] != null) file.delete() else cachedFiles.putIfAbsent(id, file)
            }
        }
        if (decision != ReliabilityReportingLoadDecision.FORWARD) {
            finishHint(hint, false)
            return
        }
        scheduleDrain()
    }

    override fun flush(timeoutMillis: Long) {
        if (closed.get() || reporting.gate.shouldBlockUpload ||
            !reporting.consent.isOptedIn) return
        scheduleDrain()
        val done = java.util.concurrent.CountDownLatch(1)
        try {
            executor.execute { done.countDown() }
            done.await(timeoutMillis, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Closing concurrently: cached envelopes remain durable.
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    override fun close() {
        close(false)
    }

    @Synchronized
    override fun close(isRestarting: Boolean) {
        closed.set(true)
        cancel()
        executor.shutdownNow()
        pending.values.forEach { finishHint(it.second, false) }
        pending.clear()
        cachedFiles.clear()
        limiter.close()
    }

    override fun getRateLimiter(): RateLimiter = limiter

    override fun cancel() {
        for (call in inflight.toList()) {
            runCatching { call.cancel() }
        }
        inflight.clear()
    }

    private fun post(envelope: SentryEnvelope): Boolean {
        if (closed.get() ||
            !reporting.consent.isOptedIn ||
            reporting.gate.shouldBlockUpload
        ) {
            return false
        }
        val url = requestDetails.url
        if (ReliabilityReportingNetwork.decision(url.toString(), reporting.dsnHost, reporting.gate) !=
            ReliabilityReportingLoadDecision.FORWARD
        ) {
            return false
        }
        val body =
            java.io.ByteArrayOutputStream().use { raw ->
                java.util.zip.GZIPOutputStream(raw).use { gzip ->
                    options.serializer.serialize(envelope, gzip)
                }
                raw.toByteArray()
            }
        val builder =
            okhttp3.Request.Builder()
                .url(url.toString())
                .post(body.toRequestBody("application/x-sentry-envelope".toMediaType()))
                .header("Content-Encoding", "gzip")
                .header("Content-Type", "application/x-sentry-envelope")
                .header("Accept", "application/json")
        for ((key, value) in requestDetails.headers) {
            builder.header(key, value)
        }
        val call = http.newCall(builder.build())
        inflight.add(call)
        reporting.gate.register(this)
        try {
            if (closed.get() || !reporting.consent.isOptedIn ||
                reporting.gate.shouldBlockUpload) {
                call.cancel()
                return false
            }
            call.execute().use { response ->
                limiter.updateRetryAfterLimits(
                    response.header("X-Sentry-Rate-Limits"), response.header("Retry-After"), response.code)
                if (!reporting.consent.isOptedIn ||
                    reporting.gate.shouldBlockUpload
                ) {
                    return false
                }
                if (response.isSuccessful) {
                    options.envelopeDiskCache.discard(envelope)
                    envelope.header.eventId?.toString()?.let { eventId ->
                        if (eventId.isNotEmpty() && eventId != "00000000000000000000000000000000") {
                            reporting.noteTransportSuccess(eventId)
                        }
                    }
                    return true
                }
            }
        } catch (_: IOException) {
            // Keep the cached envelope. Camera cancel and network loss both land here.
        } finally {
            inflight.remove(call)
            reporting.gate.unregister(this)
        }
        return false
    }
}

internal class ReliabilityReportingTransportFactory(
    private val reporting: ReliabilityReporting,
) : ITransportFactory {
    override fun create(options: SentryOptions, requestDetails: RequestDetails): ITransport {
        return ReliabilityReportingTransport(reporting, options, requestDetails)
    }
}
