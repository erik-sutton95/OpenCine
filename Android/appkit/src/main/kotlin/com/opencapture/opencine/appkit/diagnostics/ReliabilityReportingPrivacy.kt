package com.opencapture.opencine.appkit.diagnostics

import android.content.SharedPreferences
import com.opencapture.opencine.media.DiagnosticWire
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentExport
import com.opencapture.opencine.media.FeedIncidentFailingStage
import com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb
import com.opencapture.opencine.media.FeedIncidentVendorEnvelope
import java.io.File
import java.util.UUID
import org.json.JSONObject

/** The operator's automatic-report choice. Absent is undecided; a stored false is a decline. */
public class ReliabilityReportingConsent(private val dsn: ReliabilityReportingDSN) {
    @Volatile private var optedIn: Boolean = false
    @Volatile private var decided: Boolean = false
    @Volatile private var persist: ((Boolean) -> Unit)? = null

    public val isOptedIn: Boolean
        get() = optedIn

    public val hasDecision: Boolean
        get() = decided

    public fun setOptedIn(on: Boolean) {
        optedIn = on
        decided = true
        persist?.invoke(on)
    }

    public fun shouldOfferAutomaticPrompt(): Boolean =
        dsn.isAvailable && !decided

    public fun bind(prefs: SharedPreferences) {
        restorePersistedChoice(
            hasChoice = prefs.contains(KEY),
            optedIn = prefs.getBoolean(KEY, false),
            persist = { value -> prefs.edit().putBoolean(KEY, value).apply() },
        )
    }

    /** Absence of [KEY] is undecided; a stored false is an explicit decline. */
    public fun restorePersistedChoice(
        hasChoice: Boolean,
        optedIn: Boolean = false,
        persist: ((Boolean) -> Unit)? = null,
    ) {
        decided = hasChoice
        this.optedIn = hasChoice && optedIn
        this.persist = persist
    }

    public fun resetForTests() {
        optedIn = false
        decided = false
        persist = null
    }

    public companion object {
        public const val KEY: String = "opc.reliabilityReporting.optIn"
    }
}

/** The automatic-report destination: the host build's DSN, then the environment's. */
public class ReliabilityReportingDSN(
    buildDsn: String? = null,
    environment: Map<String, String> = System.getenv(),
) {
    @Volatile public var buildDsn: String? = buildDsn
    @Volatile public var environment: Map<String, String> = environment

    public fun configured(): String? {
        val candidates =
            listOf(
                buildDsn,
                environment["SENTRY_DSN_ANDROID"],
                environment["SENTRY_DSN"],
            )
        for (raw in candidates) {
            val value = validated(raw) ?: continue
            return value
        }
        return null
    }

    public val isAvailable: Boolean
        get() = configured() != null

    public companion object {
        public fun validated(raw: String?): String? {
            if (raw == null) return null
            val trimmed = raw.trim()
            if (trimmed.isEmpty() || trimmed.contains("YOUR_") || trimmed.contains("example")) {
                return null
            }
            val uri = DiagnosticWire.uri(trimmed) ?: return null
            if (uri.scheme?.lowercase() != "https") return null
            val host = uri.host
            if (host.isNullOrEmpty()) return null
            val userInfo = uri.userInfo
            if (userInfo.isNullOrEmpty() || userInfo.contains(':')) return null
            if (uri.query != null || uri.fragment != null) return null
            val project = uri.path.orEmpty().split('/').lastOrNull().orEmpty()
            if (project.isEmpty() || !project.all { it.isDigit() }) return null
            return trimmed
        }
    }
}

/** How sure the reporting SDK should be: only an exhausted incident is an error. */
public enum class ReliabilityEventLevel {
    INFO,
    WARNING,
    ERROR,
}

/**
 * One typed event, already scrubbed, for the host's reporting SDK. [eventId] is 32 hex digits.
 * The host sends it as is, with the attachment it is captured with.
 */
public data class ReliabilityEvent(
    public val eventId: String,
    public val level: ReliabilityEventLevel,
    public val timestampMs: Long,
    public val release: String,
    public val dist: String?,
    public val message: String,
    public val fingerprints: List<String>,
    public val tags: Map<String, String>?,
    public val extras: Map<String, Any>?,
    public val contexts: Map<String, Map<String, Any>>,
)

/**
 * What may leave the phone. The SDK adapter applies these rules to every event and breadcrumb
 * (crashes included); typed events are built here and scrubbed with the same rules. [redact] is
 * the host's redaction policy.
 */
public class ReliabilityReportingPrivacy(private val redact: (String) -> String) {
    public fun token(raw: String, max: Int = 32): String {
        val clipped = raw.trim().take(max)
        return redact(clipped)
    }

    public fun fingerprint(schema: Int, kind: String, stage: String, errorClass: String): List<String> =
        listOf(
            "feed-incident",
            "schema:$schema",
            "kind:${token(kind, 32)}",
            "stage:${token(stage, 32)}",
            "errorClass:${token(errorClass, 32)}",
        )

    /** The kept message: typed feed events keep theirs, redacted; anything else is generic. */
    public fun message(formatted: String, firstFingerprint: String?): String {
        val isTypedFeedEvent = firstFingerprint == "feed-incident" || firstFingerprint == "feed-session"
        return if (isTypedFeedEvent) redact(formatted) else "Application diagnostic"
    }

    /** Allowlisted tags, each clipped and redacted; null when none is left. */
    public fun tags(tags: Map<String, String>): Map<String, String>? {
        val kept = tags.filterKeys { tagAllowlist.contains(it) }.toMutableMap()
        for (key in kept.keys) {
            val limit = if (key == "sourceRevision" || key == "buildIdentity") 64 else 32
            kept[key] = token(kept[key].orEmpty(), limit)
        }
        return if (kept.isEmpty()) null else kept
    }

    /** Allowlisted extras; null when none is left. */
    public fun extras(extras: Map<String, Any>): Map<String, Any>? {
        val kept = extras.filterKeys { extraAllowlist.contains(it) }
        return if (kept.isEmpty()) null else kept.toMutableMap()
    }

    /** Allowlisted context sections and keys, read through [section]. */
    public fun contexts(section: (String) -> Any?): Map<String, Map<String, Any>> {
        val keptSections = mutableMapOf<String, Map<String, Any>>()
        for ((name, allow) in contextAllowlist) {
            val values = section(name) as? Map<*, *> ?: continue
            val filtered = mutableMapOf<String, Any>()
            for (key in values.keys) {
                val keyName = key as? String ?: continue
                if (!allow.contains(keyName)) continue
                val value = values[key] ?: continue
                filtered[keyName] = value
            }
            if (filtered.isNotEmpty()) keptSections[name] = filtered
        }
        return keptSections
    }

    /** A stack frame's file or function name. */
    public fun frameText(text: String): String = redact(text)

    /** The data a breadcrumb keeps, or null to drop it: only typed feed breadcrumbs survive. */
    public fun breadcrumbData(category: String?, message: String?, data: Map<String, Any?>): Map<String, String>? {
        if (category != "feed") return null
        if (message == null) return null
        if (!FeedIncidentNativeBreadcrumb.isAllowedMessage(message)) return null
        val strings = mutableMapOf<String, String>()
        data.forEach { (key, value) ->
            if (value is String) strings[key] = value
        }
        return FeedIncidentNativeBreadcrumb.sanitized(strings)
    }

    /** The scrub the SDK adapter applies, for an event built here. */
    public fun scrub(event: ReliabilityEvent): ReliabilityEvent =
        event.copy(
            message = message(event.message, event.fingerprints.firstOrNull()),
            tags = event.tags?.let { tags(it) },
            extras = event.extras?.let { extras(it) },
            contexts = contexts { event.contexts[it] },
        )

    public companion object {
        public val extraAllowlist: Set<String> =
            setOf(
                "schemaVersion",
                "failingStage",
                "errorClass",
                "outcome",
                "kind",
                "incidentCount",
                "sourceRevision",
                "hardwareClass",
                "cameraFirmware",
                "assistState",
                "decoderGeneration",
                "socketGeneration",
                "worstGapSeconds",
                "healthyExposureSeconds",
                "testSource",
                "buildIdentity",
            )

        public val contextAllowlist: Map<String, Set<String>> =
            mapOf(
                "os" to setOf("name", "version", "build"),
                "device" to setOf("family", "model", "arch"),
                "app" to setOf("app_version", "app_build", "build_type"),
                "feed" to
                    setOf(
                        "schemaVersion",
                        "failingStage",
                        "errorClass",
                        "outcome",
                        "kind",
                        "assistState",
                        "hardwareClass",
                        "testSource",
                        "buildIdentity",
                        "cameraFamily",
                    ),
            )

        public val tagAllowlist: Set<String> =
            setOf(
                "failingStage",
                "errorClass",
                "outcome",
                "kind",
                "sourceRevision",
                "cameraFamily",
                "cameraFirmware",
                "hardwareClass",
                "soc",
                "testSource",
                "buildIdentity",
            )

        /** 32 hex digits from an incident or session id, as the SDK prints its event id. */
        public fun eventId(fromIncidentId: String): String {
            val hex = fromIncidentId.filter { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
            if (hex.length >= 32) return hex.take(32)
            runCatching { UUID.fromString(fromIncidentId) }.getOrNull()?.let { uuid ->
                return uuid.toString().replace("-", "")
            }
            return hex.padEnd(32, '0').take(32)
        }

        public fun validatedEnvelope(from: FeedIncidentBundle): FeedIncidentVendorEnvelope? {
            val envelope = FeedIncidentExport.envelope(from)
            if (envelope.schemaVersion < 1) return null
            if (envelope.eventName != "feed.incident") return null
            val id = envelope.incidentID.trim()
            if (id.isEmpty() || id == "unknown") return null
            if (!FeedIncidentFailingStage.isKnown(envelope.grouping.failingStage)) return null
            return envelope
        }

        public fun typedJson(from: FeedIncidentBundle): ByteArray? {
            if (validatedEnvelope(from) == null) return null
            val data = runCatching { FeedIncidentJson.encode(from) }.getOrNull() ?: return null
            if (data.size > 262_144) return null
            return data
        }
    }
}

public enum class ReliabilityReportingReceiptState {
    QUEUED,
    CONFIRMED,
}

public data class ReliabilityReportingReceipt(
    public val incidentID: String,
    public val eventID: String,
    public val state: ReliabilityReportingReceiptState,
    public val updatedAt: Long,
)

/** Delivery receipts under the SDK cache root: queued is not delivered; only HTTP 2xx confirms. */
public object ReliabilityReportingReceipts {
    public fun directory(root: File): File = File(root, "receipts")

    public fun load(incidentID: String, root: File): ReliabilityReportingReceipt? {
        val file = File(directory(root), "$incidentID.json")
        if (!file.isFile) return null
        return runCatching { decode(file.readText()) }.getOrNull()
    }

    public fun store(receipt: ReliabilityReportingReceipt, root: File) {
        val dir = directory(root)
        dir.mkdirs()
        val file = File(dir, "${receipt.incidentID}.json")
        val tmp = File(dir, "${receipt.incidentID}.json.tmp")
        tmp.writeText(encode(receipt))
        if (!tmp.renameTo(file)) {
            file.writeText(encode(receipt))
            tmp.delete()
        }
    }

    public fun markConfirmed(eventID: String, root: File, now: Long = System.currentTimeMillis()) {
        val needle = eventID.filter { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }.lowercase()
        for (receipt in loadAll(root)) {
            if (receipt.state != ReliabilityReportingReceiptState.QUEUED) continue
            val stored =
                receipt.eventID.filter { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
                    .lowercase()
            if (stored != needle) continue
            store(receipt.copy(state = ReliabilityReportingReceiptState.CONFIRMED, updatedAt = now), root)
            return
        }
    }

    public fun applyTTL(root: File, now: Long = System.currentTimeMillis(), ttlMs: Long = 604_800_000L) {
        val files = directory(root).listFiles() ?: return
        for (file in files) {
            if (file.extension != "json") continue
            if (now - file.lastModified() > ttlMs) file.delete()
        }
    }

    public fun loadAll(root: File): List<ReliabilityReportingReceipt> {
        val files = directory(root).listFiles() ?: return emptyList()
        return files.mapNotNull { file ->
            if (file.extension != "json") return@mapNotNull null
            runCatching { decode(file.readText()) }.getOrNull()
        }
    }

    public fun purge(root: File) {
        root.deleteRecursively()
    }

    private fun encode(receipt: ReliabilityReportingReceipt): String =
        JSONObject()
            .put("incidentID", receipt.incidentID)
            .put("eventID", receipt.eventID)
            .put("state", receipt.state.name.lowercase())
            .put("updatedAt", DiagnosticWire.isoSeconds(receipt.updatedAt))
            .toString()

    private fun decode(raw: String): ReliabilityReportingReceipt? {
        val json = JSONObject(raw)
        val stateRaw = json.optString("state")
        val state =
            when (stateRaw.lowercase()) {
                "queued" -> ReliabilityReportingReceiptState.QUEUED
                "confirmed" -> ReliabilityReportingReceiptState.CONFIRMED
                else -> return null
            }
        val updatedAt = parseIso(json.optString("updatedAt")) ?: return null
        return ReliabilityReportingReceipt(
            incidentID = json.optString("incidentID"),
            eventID = json.optString("eventID"),
            state = state,
            updatedAt = updatedAt,
        )
    }

    private fun parseIso(raw: String): Long? =
        DiagnosticWire.parseIsoSeconds(raw)
}
