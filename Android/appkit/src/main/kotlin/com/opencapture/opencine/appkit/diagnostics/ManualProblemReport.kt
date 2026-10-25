package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.appkit.diagnostics.ManualReportImages
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.opencapture.opencine.media.DiagnosticWire
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import kotlin.math.pow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

public enum class ManualProblemReportDelivery {
    IDLE,
    WAITING,
    SENT,
    FAILED,
}

public data class ManualProblemReportSnapshot(
    public val delivery: ManualProblemReportDelivery = ManualProblemReportDelivery.IDLE,
    public val eventId: String? = null,
    public val detail: String? = null,
    public val expiredMetadataOnly: Boolean = false,
) {
    public val statusLabel: String
        get() =
            when (delivery) {
                ManualProblemReportDelivery.IDLE -> detail.orEmpty()
                ManualProblemReportDelivery.WAITING -> "Waiting to send"
                ManualProblemReportDelivery.SENT -> "Sent"
                ManualProblemReportDelivery.FAILED -> "Failed"
            }

    public val allowsDiscard: Boolean
        get() =
            delivery == ManualProblemReportDelivery.WAITING ||
                delivery == ManualProblemReportDelivery.FAILED

    public val allowsNewSubmit: Boolean
        get() =
            delivery == ManualProblemReportDelivery.IDLE ||
                delivery == ManualProblemReportDelivery.SENT
}

public data class ManualEnvelopeItem(
    public val header: JSONObject,
    public val payload: ByteArray,
)

public data class ManualEnvelope(
    public val header: JSONObject,
    public val items: List<ManualEnvelopeItem>,
)

/** The host's HTTP client: one POST of a queued envelope. */
public fun interface ManualReportUpload {
    /** A call for [body] (of [contentType]) to [url] with [headers]; nothing is sent before [ManualReportCall.execute]. */
    public fun call(url: String, contentType: String, body: ByteArray, headers: Map<String, String>): ManualReportCall
}

public interface ManualReportCall {
    /** Sends and waits for the response; throws when the transport fails or the call is cancelled. */
    public fun execute(): ManualReportResponse

    public fun cancel()

    public val isCanceled: Boolean
}

public data class ManualReportResponse(public val code: Int, public val retryAfter: String?)

/**
 * Dedicated one-at-a-time operator feedback envelope. Independent of automatic
 * SDK consent and does not start the reporting SDK. [host] names the release, client and
 * support contact; [upload] is the host's HTTP client.
 */
public class ManualProblemReport(
    private val host: DiagnosticsHost,
    private val dsn: ReliabilityReportingDSN,
    private val gate: ReliabilityReportingGate,
    private val upload: ManualReportUpload,
) {
    @Volatile public var filesRoot: File? = null
    @Volatile public var envelopeUrlOverride: String? = null
    @Volatile public var sentryKeyOverride: String? = null
    @Volatile public var nowMs: () -> Long = { System.currentTimeMillis() }
    @Volatile public var appInForeground: Boolean = true
    @Volatile public var executeInlineForTests: Boolean = false

    private val executor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opc.manual-report").apply { isDaemon = true }
        }
    private val sending = AtomicBoolean(false)
    private val generation = AtomicLong(0)
    private val pollScheduled = AtomicBoolean(false)
    private val lock = Any()
    private val _snapshot = MutableStateFlow(ManualProblemReportSnapshot())
    public val snapshot: StateFlow<ManualProblemReportSnapshot> = _snapshot.asStateFlow()

    @Volatile private var activeCall: ManualReportCall? = null
    @Volatile private var activeEventId: String? = null
    @Volatile private var activeGeneration: Long = -1

    public fun current(): ManualProblemReportSnapshot = _snapshot.value

    public fun currentGeneration(): Long = generation.get()

    public fun isConfigured(): Boolean = endpointFromConfigured() != null || envelopeUrlOverride != null

    public fun install(context: Context) {
        filesRoot = File(context.applicationContext.noBackupFilesDir, "opc-manual-report")
        loadFromDisk()
        schedulePoll()
        tick()
    }

    public fun setForeground(on: Boolean) {
        appInForeground = on
        if (!on) cancelUpload()
        else tick()
    }

    public fun noteCameraPathClear() {
        tick()
    }

    public fun submit(
        message: String,
        replyEmail: String,
        diagnostics: String?,
        images: List<ByteArray> = emptyList(),
    ): ManualSubmitResult =
        try {
            storeSubmission(message, replyEmail, diagnostics, images)
        } catch (_: Exception) {
            ManualSubmitResult.STORAGE_ERROR
        }

    private fun storeSubmission(
        message: String,
        replyEmail: String,
        diagnostics: String?,
        images: List<ByteArray>,
    ): ManualSubmitResult {
        val trimmed = ManualProblemReportEnvelope.sanitizeMessage(message)
        val email = ManualProblemReportEnvelope.sanitizeEmail(replyEmail)
        if (trimmed.isEmpty()) return ManualSubmitResult.INVALID
        if (replyEmail.isNotBlank() && email == null) return ManualSubmitResult.INVALID
        val acceptedImages = ManualReportImages.accept(images) ?: return ManualSubmitResult.INVALID
        val resolved = endpointFromConfigured() ?: return ManualSubmitResult.UNAVAILABLE
        val dsn = dsn.configured() ?: envelopeUrlOverride ?: return ManualSubmitResult.UNAVAILABLE
        synchronized(lock) {
            loadFromDiskLocked()
            if (!_snapshot.value.allowsNewSubmit) return ManualSubmitResult.PENDING_EXISTS
            generation.incrementAndGet()
            cancelUploadLocked()
            val eventId = ManualProblemReportEnvelope.newEventId()
            val envelope =
                ManualProblemReportEnvelope.compose(
                    eventId = eventId,
                    timestampMs = nowMs(),
                    release = host.currentRelease,
                    message = trimmed,
                    contactEmail = email,
                    diagnostics = diagnostics,
                    images = acceptedImages,
                    host = host,
                )
            val bytes = ManualProblemReportEnvelope.serialize(envelope)
            val dir = directory() ?: return ManualSubmitResult.UNAVAILABLE
            dir.mkdirs()
            envelopeFile(dir).writeBytes(bytes)
            writeMeta(
                ManualReportMeta(
                    eventId = eventId,
                    createdAtMs = nowMs(),
                    status = "waiting",
                    attempts = 0,
                    nextAttemptAtMs = 0L,
                    lastHttp = 0,
                    dsn = dsn,
                    url = resolved.url,
                    host = resolved.host,
                    sentryKey = resolved.sentryKey,
                    detail = null,
                    envelopePresent = true,
                ),
            )
            publishLocked()
        }
        tick()
        return ManualSubmitResult.QUEUED
    }

    public fun discard() {
        synchronized(lock) {
            generation.incrementAndGet()
            cancelUploadLocked()
            val removed = runCatching { directory()?.deleteRecursively() != false }.getOrDefault(false)
            publishLocked(detail = if (removed) "Report removed from this phone" else "Could not remove this report. Please try again.")
        }
    }

    public fun tick() {
        if (executeInlineForTests) {
            tickOnce()
            return
        }
        try {
            executor.execute { tickOnce() }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
        }
    }

    public fun flush(): Unit = tick()

    public fun finishForTests(eventId: String, gen: Long, code: Int, retryAfter: String? = null) {
        applyFinished(eventId, gen, code, retryAfter, cancelled = false)
    }

    public fun resetForTests() {
        synchronized(lock) {
            generation.incrementAndGet()
            cancelUploadLocked()
            filesRoot?.deleteRecursively()
            envelopeUrlOverride = null
            sentryKeyOverride = null
            nowMs = { System.currentTimeMillis() }
            appInForeground = true
            executeInlineForTests = false
            _snapshot.value = ManualProblemReportSnapshot()
        }
    }

    private fun tickOnce() {
        val prepared: Triple<ManualReportMeta, ManualReportEndpoint, ByteArray>
        val gen: Long
        synchronized(lock) {
            loadFromDiskLocked()
            val meta = readMeta() ?: return
            if (nowMs() - meta.createdAtMs > TTL_MS) {
                expireLocked(meta)
                return
            }
            if (meta.status == "sent") return
            if (meta.status == "failed") {
                publishLocked()
                return
            }
            if (!appInForeground) {
                cancelUploadLocked()
                meta.detail = "Waiting to send. Keep the app open after leaving camera Wi-Fi"
                writeMeta(meta)
                publishLocked()
                return
            }
            if (gate.shouldBlockUpload) {
                cancelUploadLocked()
                meta.detail = "Waiting to send. Keep the app open after leaving camera Wi-Fi"
                writeMeta(meta)
                publishLocked()
                return
            }
            if (nowMs() < meta.nextAttemptAtMs) {
                publishLocked()
                return
            }
            if (sending.get() || activeCall != null) return
            val currentDsn = dsn.configured()
            if (envelopeUrlOverride == null && currentDsn != null && currentDsn != meta.dsn) {
                meta.status = "failed"
                meta.detail = "Reporting destination changed. Remove this report and send again."
                deleteEnvelopeLocked()
                meta.envelopePresent = false
                writeMeta(meta)
                publishLocked()
                return
            }
            val endpoint =
                ManualReportEndpoint(url = meta.url, host = meta.host, sentryKey = meta.sentryKey)
            val decision = ReliabilityReportingNetwork.decision(endpoint.url, endpoint.host, gate)
            if (decision == ReliabilityReportingLoadDecision.REJECT_HOST) {
                meta.status = "failed"
                meta.detail = "Reporting is unavailable in this build"
                deleteEnvelopeLocked()
                meta.envelopePresent = false
                writeMeta(meta)
                publishLocked()
                return
            }
            if (decision != ReliabilityReportingLoadDecision.FORWARD) {
                writeMeta(meta)
                publishLocked()
                return
            }
            val bytes = envelopeFile(directory()).takeIf { it.isFile }?.readBytes()
            if (bytes == null) {
                meta.status = "failed"
                meta.detail = "The queued report is missing"
                meta.envelopePresent = false
                writeMeta(meta)
                publishLocked()
                return
            }
            gen = generation.get()
            prepared = Triple(meta, endpoint, bytes)
        }
        post(prepared.first, prepared.second, prepared.third, gen)
    }

    private fun post(
        meta: ManualReportMeta,
        endpoint: ManualReportEndpoint,
        bytes: ByteArray,
        gen: Long,
    ) {
        if (!sending.compareAndSet(false, true)) return
        var registered: ReliabilityReportingCancellable? = null
        var requestCall: ManualReportCall? = null
        try {
            if (gen != generation.get() || !appInForeground) return
            if (gate.shouldBlockUpload || !gate.hasValidInternet) {
                return
            }
            val call =
                upload.call(
                    endpoint.url,
                    "application/x-sentry-envelope",
                    bytes,
                    linkedMapOf(
                        "Content-Type" to "application/x-sentry-envelope",
                        "Accept" to "application/json",
                        "X-Sentry-Auth" to
                            "Sentry sentry_version=7, sentry_client=${host.reportingClient}/${host.versionName}, sentry_key=${endpoint.sentryKey}",
                    ),
                )
            requestCall = call
            val cancellable =
                object : ReliabilityReportingCancellable {
                    override val independentOfAutomaticConsent = true
                    override fun cancel() {
                        call.cancel()
                    }
                }
            synchronized(lock) {
                if (gen != generation.get() || !appInForeground) {
                    call.cancel()
                    return
                }
                activeCall = call
                activeEventId = meta.eventId
                activeGeneration = gen
            }
            registered = cancellable
            gate.register(cancellable)
            if (gen != generation.get() || !appInForeground ||
                gate.shouldBlockUpload ||
                !gate.hasValidInternet
            ) {
                call.cancel()
                return
            }
            val response = call.execute()
            applyFinished(
                eventId = meta.eventId,
                gen = gen,
                code = response.code,
                retryAfter = response.retryAfter,
                cancelled = false,
            )
        } catch (_: Exception) {
            val cancelled = requestCall?.isCanceled == true
            applyFinished(meta.eventId, gen, 0, null, cancelled = cancelled)
        } finally {
            registered?.let { gate.unregister(it) }
            synchronized(lock) {
                if (activeGeneration == gen) {
                    activeCall = null
                    activeEventId = null
                    activeGeneration = -1
                }
            }
            sending.set(false)
            schedulePoll()
        }
    }

    public fun applyFinished(
        eventId: String,
        gen: Long,
        code: Int,
        retryAfter: String?,
        cancelled: Boolean,
    ) {
        synchronized(lock) {
            if (gen != generation.get()) return
            val meta = readMeta() ?: return
            if (meta.eventId != eventId) return
            if (cancelled) {
                meta.detail = "Waiting to send"
                writeMeta(meta)
                publishLocked()
                return
            }
            meta.attempts += 1
            meta.lastHttp = code
            when {
                code in 200..299 -> {
                    meta.status = "sent"
                    meta.detail = "Report sent. Thank you for helping improve ${host.product}."
                    deleteEnvelopeLocked()
                    meta.envelopePresent = false
                    writeMeta(meta)
                    directory()?.let { dir ->
                        envelopeFile(dir).delete()
                    }
                }
                code == 429 || code == 408 -> {
                    meta.status = "waiting"
                    meta.nextAttemptAtMs = nowMs() + retryDelayMs(retryAfter, meta.attempts)
                    meta.detail = "Waiting for a connection. Your report is saved on this phone"
                }
                code in 400..499 -> {
                    meta.status = "failed"
                    meta.detail =
                        "Report couldn't be sent. Remove it and try again, or contact ${host.supportEmail}."
                }
                else -> {
                    meta.status = "waiting"
                    meta.nextAttemptAtMs = nowMs() + retryDelayMs(retryAfter, meta.attempts)
                    meta.detail = "Waiting for a connection. Your report is saved on this phone"
                }
            }
            writeMeta(meta)
            publishLocked()
        }
    }

    private fun retryDelayMs(retryAfter: String?, attempts: Int): Long {
        val backoff =
            min(MAX_RETRY_MS.toDouble(), MIN_RETRY_MS * 2.0.pow(min(attempts, 4).toDouble())).toLong()
        val header = parseRetryAfter(retryAfter, nowMs()) - nowMs()
        return maxOf(MIN_RETRY_MS, backoff, header)
    }

    private fun cancelUpload() {
        synchronized(lock) { cancelUploadLocked() }
    }

    private fun cancelUploadLocked() {
        activeCall?.cancel()
        activeCall = null
        activeEventId = null
        activeGeneration = -1
    }

    private fun expireLocked(meta: ManualReportMeta) {
        deleteEnvelopeLocked()
        meta.status = "failed"
        meta.envelopePresent = false
        meta.detail = "Report expired before it could be sent. Please create a new report."
        writeMeta(meta)
        publishLocked()
    }

    private fun deleteEnvelopeLocked() {
        envelopeFile(directory()).delete()
    }

    private fun schedulePoll() {
        if (executeInlineForTests) return
        if (!pollScheduled.compareAndSet(false, true)) return
        val looper = runCatching { Looper.getMainLooper() }.getOrNull() ?: run {
            pollScheduled.set(false)
            return
        }
        Handler(looper).postDelayed(
            {
                pollScheduled.set(false)
                if (_snapshot.value.allowsDiscard) {
                    tick()
                    schedulePoll()
                }
            },
            POLL_MS,
        )
    }

    private fun loadFromDisk() {
        synchronized(lock) { loadFromDiskLocked() }
    }

    private fun loadFromDiskLocked() {
        val meta = readMeta() ?: run {
            publishLocked()
            return
        }
        if (nowMs() - meta.createdAtMs > TTL_MS) {
            expireLocked(meta)
            return
        }
        publishLocked()
    }

    private fun publishLocked(detail: String? = null) {
        val meta = readMeta()
        _snapshot.value =
            if (meta == null) {
                ManualProblemReportSnapshot(detail = detail)
            } else {
                ManualProblemReportSnapshot(
                    delivery =
                        when (meta.status) {
                            "waiting" -> ManualProblemReportDelivery.WAITING
                            "sent" -> ManualProblemReportDelivery.SENT
                            "failed" -> ManualProblemReportDelivery.FAILED
                            else -> ManualProblemReportDelivery.IDLE
                        },
                    eventId = meta.eventId,
                    detail = detail ?: meta.detail,
                    expiredMetadataOnly = !meta.envelopePresent && meta.status == "failed",
                )
            }
    }

    private fun directory(): File? = filesRoot

    private fun metaFile(dir: File? = directory()): File = File(dir ?: File("."), "pending.json")

    private fun envelopeFile(dir: File? = directory()): File = File(dir ?: File("."), "pending.envelope")

    private fun readMeta(): ManualReportMeta? {
        val file = metaFile()
        if (!file.isFile) return null
        return runCatching { ManualReportMeta.from(JSONObject(file.readText())) }.getOrNull()
    }

    private fun writeMeta(meta: ManualReportMeta) {
        val dir = directory() ?: return
        dir.mkdirs()
        val file = metaFile(dir)
        val tmp = File(dir, "pending.json.tmp")
        tmp.writeText(meta.toJson().toString())
        if (!tmp.renameTo(file)) {
            file.writeText(meta.toJson().toString())
            tmp.delete()
        }
    }

    private fun endpointFromConfigured(): ManualReportEndpoint? {
        envelopeUrlOverride?.let { url ->
            val host = DiagnosticWire.uri(url)?.host ?: return null
            val key = sentryKeyOverride ?: "testkey"
            return ManualReportEndpoint(url = url, host = host, sentryKey = key)
        }
        val dsn = dsn.configured() ?: return null
        return ManualReportEndpoint.fromDsn(dsn, gate.hostPolicy.requireHttps)
    }

    public companion object {
        public const val MESSAGE_MAX: Int = 4_000
        public const val EMAIL_MAX: Int = 254
        public const val ATTACHMENT_MAX_CHARS: Int = 32_000
        public const val ATTACHMENT_MAX_BYTES: Int = 128 * 1_024
        public const val TTL_MS: Long = 7L * 24 * 60 * 60 * 1_000
        public const val MIN_RETRY_MS: Long = 30_000L
        public const val MAX_RETRY_MS: Long = 300_000L
        public const val POLL_MS: Long = 2_000L
    }
}

public enum class ManualSubmitResult {
    QUEUED,
    INVALID,
    UNAVAILABLE,
    PENDING_EXISTS,
    STORAGE_ERROR,
}

public data class ManualReportEndpoint(
    public val url: String,
    public val host: String,
    public val sentryKey: String,
) {
    public companion object {
        public fun fromDsn(dsn: String, requireHttps: Boolean = true): ManualReportEndpoint? {
            val valid = ReliabilityReportingDSN.validated(dsn) ?: return null
            val uri = DiagnosticWire.uri(valid) ?: return null
            val host = uri.host ?: return null
            val key = uri.userInfo ?: return null
            val segments = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
            val project = segments.lastOrNull() ?: return null
            val prefix = segments.dropLast(1).joinToString("/")
            val scheme = if (requireHttps) "https" else (uri.scheme ?: "https")
            val path = (if (prefix.isEmpty()) "" else "/$prefix") + "/api/$project/envelope/"
            return ManualReportEndpoint(
                url = "$scheme://$host$path",
                host = host,
                sentryKey = key,
            )
        }
    }
}

public object ManualProblemReportEnvelope {
    public fun newEventId(): String =
        UUID.randomUUID().toString().replace("-", "").lowercase(Locale.US)

    public fun sanitizeMessage(raw: String): String = raw.trim().take(ManualProblemReport.MESSAGE_MAX)

    public fun sanitizeEmail(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length > ManualProblemReport.EMAIL_MAX) return null
        if (!trimmed.contains('@') || trimmed.any { it.isWhitespace() }) return null
        return trimmed
    }

    public fun utf8Prefix(text: String, maxBytes: Int): String {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var end = maxBytes.coerceAtLeast(0)
        while (end > 0 && bytes[end - 1].toInt() and 0xC0 == 0x80) end--
        if (end > 0 && bytes[end - 1].toInt() and 0x80 != 0) end--
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    public fun compose(
        eventId: String,
        timestampMs: Long,
        release: String,
        message: String,
        contactEmail: String?,
        diagnostics: String?,
        images: List<ByteArray> = emptyList(),
        host: DiagnosticsHost,
    ): ManualEnvelope {
        val environment = host.environment
        val dist = host.versionCode.toString()
        val sourceRevision = host.sourceRevision.take(64)
        val iso = isoMs(timestampMs)
        val acceptedImages = ManualReportImages.accept(images) ?: emptyList()
        val feedbackFields =
            JSONObject()
                .put("message", message)
                .put("source", "custom")
        if (contactEmail != null) feedbackFields.put("contact_email", contactEmail)
        val payload =
            JSONObject()
                .put("type", "feedback")
                .put("event_id", eventId)
                .put("timestamp", iso)
                .put("platform", "java")
                .put("release", release)
                .put("environment", environment)
                .put("dist", dist)
                .put("tags", JSONObject().put("sourceRevision", sourceRevision))
                .put("contexts", JSONObject().put("feedback", feedbackFields))
        val items = mutableListOf(
            ManualEnvelopeItem(
                header =
                    JSONObject()
                        .put("type", "feedback")
                        .put("content_type", "application/json"),
                payload = payload.toString().toByteArray(Charsets.UTF_8),
            ),
        )
        if (diagnostics != null) {
            val clipped = diagnostics.take(ManualProblemReport.ATTACHMENT_MAX_CHARS)
            val redacted =
                utf8Prefix(
                    host.redact(clipped),
                    ManualProblemReport.ATTACHMENT_MAX_BYTES,
                )
            items +=
                ManualEnvelopeItem(
                    header =
                        JSONObject()
                            .put("type", "attachment")
                            .put("filename", "diagnostics.txt")
                            .put("content_type", "text/plain")
                            .put("attachment_type", "event.attachment"),
                    payload = redacted.toByteArray(Charsets.UTF_8),
                )
        }
        for ((index, jpeg) in acceptedImages.withIndex()) {
            items +=
                ManualEnvelopeItem(
                    header =
                        JSONObject()
                            .put("type", "attachment")
                            .put("filename", ManualReportImages.generatedName(index))
                            .put("content_type", "image/jpeg")
                            .put("attachment_type", "event.attachment"),
                    payload = jpeg,
                )
        }
        return ManualEnvelope(
            header = JSONObject().put("event_id", eventId).put("sent_at", iso),
            items = items,
        )
    }

    public fun serialize(envelope: ManualEnvelope): ByteArray {
        val out = ByteArrayOutputStream()
        fun writeLine(obj: JSONObject) {
            out.write(obj.toString().toByteArray(Charsets.UTF_8))
            out.write('\n'.code)
        }
        writeLine(envelope.header)
        for (item in envelope.items) {
            val header = JSONObject(item.header.toString()).put("length", item.payload.size)
            writeLine(header)
            out.write(item.payload)
            out.write('\n'.code)
        }
        return out.toByteArray()
    }

    public fun parse(bytes: ByteArray): ManualEnvelope {
        var offset = 0
        fun readLine(): ByteArray {
            val start = offset
            while (offset < bytes.size && bytes[offset] != '\n'.code.toByte()) offset++
            val line = bytes.copyOfRange(start, offset)
            if (offset < bytes.size) offset++
            return line
        }
        val header = JSONObject(String(readLine(), Charsets.UTF_8))
        val items = mutableListOf<ManualEnvelopeItem>()
        while (offset < bytes.size) {
            val itemHeader = JSONObject(String(readLine(), Charsets.UTF_8))
            val length = itemHeader.getInt("length")
            val payload = bytes.copyOfRange(offset, (offset + length).coerceAtMost(bytes.size))
            offset += length
            if (offset < bytes.size && bytes[offset] == '\n'.code.toByte()) offset++
            items += ManualEnvelopeItem(itemHeader, payload)
        }
        return ManualEnvelope(header, items)
    }

    private fun isoMs(timestampMs: Long): String = DiagnosticWire.isoMillis(timestampMs)
}

public data class ManualReportMeta(
    public val eventId: String,
    public val createdAtMs: Long,
    public var status: String,
    public var attempts: Int,
    public var nextAttemptAtMs: Long,
    public var lastHttp: Int,
    public val dsn: String,
    public val url: String,
    public val host: String,
    public val sentryKey: String,
    public var detail: String?,
    public var envelopePresent: Boolean,
) {
    public fun toJson(): JSONObject =
        JSONObject()
            .put("eventId", eventId)
            .put("createdAtMs", createdAtMs)
            .put("status", status)
            .put("attempts", attempts)
            .put("nextAttemptAtMs", nextAttemptAtMs)
            .put("lastHttp", lastHttp)
            .put("dsn", dsn)
            .put("url", url)
            .put("host", host)
            .put("sentryKey", sentryKey)
            .put("detail", detail ?: JSONObject.NULL)
            .put("envelopePresent", envelopePresent)

    public companion object {
        public fun from(json: JSONObject): ManualReportMeta =
            ManualReportMeta(
                eventId = json.getString("eventId"),
                createdAtMs = json.getLong("createdAtMs"),
                status = json.getString("status"),
                attempts = json.optInt("attempts"),
                nextAttemptAtMs = json.optLong("nextAttemptAtMs"),
                lastHttp = json.optInt("lastHttp"),
                dsn = json.optString("dsn"),
                url = json.getString("url"),
                host = json.getString("host"),
                sentryKey = json.getString("sentryKey"),
                detail = json.optString("detail").ifEmpty { null },
                envelopePresent = json.optBoolean("envelopePresent", true),
            )
    }
}

public fun parseRetryAfter(raw: String?, nowMs: Long): Long {
    if (raw.isNullOrBlank()) return nowMs + ManualProblemReport.MIN_RETRY_MS
    raw.trim().toLongOrNull()?.let { seconds ->
        return nowMs + (seconds.coerceIn(1L, ManualProblemReport.TTL_MS / 1_000L) * 1_000L)
    }
    val parsed = DiagnosticWire.parseHttpDate(raw.trim())
    return parsed?.coerceAtLeast(nowMs + ManualProblemReport.MIN_RETRY_MS)
        ?: (nowMs + ManualProblemReport.MIN_RETRY_MS)
}
