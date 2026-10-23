package com.opencapture.opencine.appkit.diagnostics

import android.content.SharedPreferences
import com.opencapture.opencine.appkit.MonitorStartupConsentAdmission
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
    private var storedInstallId: String? = null
    private var persistInstallId: ((String?) -> Unit)? = null

    public val isOptedIn: Boolean
        get() = optedIn

    public val hasDecision: Boolean
        get() = decided

    /**
     * The anonymous install id reports count users by: a random UUID made on first use while the
     * operator has opted in, never derived from the device or personal data. Null without
     * consent; withdrawing consent deletes it, so a later opt-in starts a new one.
     */
    public val installId: String?
        @Synchronized get() {
            if (!optedIn) return null
            // Only a value this store made is sent: anything else in the slot is replaced.
            storedInstallId?.takeIf { isInstallId(it) }?.let { return it }
            val created = UUID.randomUUID().toString()
            storedInstallId = created
            persistInstallId?.invoke(created)
            return created
        }

    @Synchronized
    public fun setOptedIn(on: Boolean) {
        optedIn = on
        decided = true
        persist?.invoke(on)
        if (!on) {
            storedInstallId = null
            persistInstallId?.invoke(null)
        }
    }

    public fun shouldOfferAutomaticPrompt(): Boolean =
        MonitorStartupConsentAdmission.allows(available = dsn.isAvailable, hasDecision = decided)

    public fun bind(prefs: SharedPreferences) {
        restorePersistedChoice(
            hasChoice = prefs.contains(KEY),
            optedIn = prefs.getBoolean(KEY, false),
            persist = { value -> prefs.edit().putBoolean(KEY, value).apply() },
            installId = prefs.getString(INSTALL_ID_KEY, null),
            persistInstallId = { value ->
                if (value == null) {
                    prefs.edit().remove(INSTALL_ID_KEY).apply()
                } else {
                    prefs.edit().putString(INSTALL_ID_KEY, value).apply()
                }
            },
        )
    }

    /** Absence of [KEY] is undecided; a stored false is an explicit decline. */
    @Synchronized
    public fun restorePersistedChoice(
        hasChoice: Boolean,
        optedIn: Boolean = false,
        persist: ((Boolean) -> Unit)? = null,
        installId: String? = null,
        persistInstallId: ((String?) -> Unit)? = null,
    ) {
        decided = hasChoice
        this.optedIn = hasChoice && optedIn
        this.persist = persist
        this.persistInstallId = persistInstallId
        storedInstallId = installId?.takeIf { this.optedIn }
        if (installId != null && !this.optedIn) persistInstallId?.invoke(null)
    }

    @Synchronized
    public fun resetForTests() {
        optedIn = false
        decided = false
        persist = null
        storedInstallId = null
        persistInstallId = null
    }

    public companion object {
        /** A lowercase canonical UUID, as [installId] makes it. */
        internal fun isInstallId(value: String): Boolean =
            runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

        public const val KEY: String = "opc.reliabilityReporting.optIn"
        public const val INSTALL_ID_KEY: String = "opc.reliabilityReporting.installID"
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

    /** Allowlisted tags, each bounded by [value]; null when none is left. */
    public fun tags(tags: Map<String, String>): Map<String, String>? {
        val kept = tags.filterKeys { tagAllowlist.contains(it) }.toMutableMap()
        for (key in kept.keys) {
            kept[key] = value(key, kept[key].orEmpty(), 32, redact)
        }
        return if (kept.isEmpty()) null else kept
    }

    /** Allowlisted extras, string values bounded like tags ([value]); null when none is left. */
    public fun extras(extras: Map<String, Any>): Map<String, Any>? {
        val kept =
            extras.filterKeys { extraAllowlist.contains(it) }
                .mapValues { (key, raw) -> if (raw is String) value(key, raw, 96, redact) else raw }
        return if (kept.isEmpty()) null else kept.toMutableMap()
    }

    /**
     * A metric as it may leave the phone, or null: an allow-listed name, a finite value, a known
     * unit, and only allow-listed attributes with their values bounded like tags.
     */
    public fun metric(metric: ReliabilityMetric): ReliabilityMetric? {
        if (metric.name !in metricAllowlist || !metric.value.isFinite()) return null
        if (metric.unit != null && metric.unit != "second") return null
        val attributes =
            metric.attributes.filterKeys { it in metricAttributeAllowlist }.mapValues { (key, raw) -> value(key, raw, 32, redact) }
        return metric.copy(attributes = attributes)
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
                val raw = values[key] ?: continue
                filtered[keyName] = if (raw is String) value(keyName, raw, 96, redact) else raw
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
                "trigger",
                "recoveredBy",
                "background",
                "awaitingIrap",
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
                        "trigger",
                        "recoveredBy",
                        "worstGapSeconds",
                        "decoderCall",
                        "keyframeWait",
                        "irapAge",
                        "decodeFlow",
                    ),
            )

        /** The metrics reporting records ([ReliabilityReporting.sessionMetrics]). */
        public val metricAllowlist: Set<String> =
            setOf("feed.session.healthy_exposure", "feed.session.incidents")

        /** The attributes those metrics may carry. */
        public val metricAttributeAllowlist: Set<String> =
            setOf("outcome", "testSource", "buildIdentity", "sourceRevision", "appBuild")

        /**
         * Keys whose value must come from a closed vocabulary; anything else reads `other`. The
         * host redaction keeps bare SSIDs and camera names (`ZR_6002199`), so free text that could
         * carry them is closed instead. Swift twin: `closedValues`.
         */
        public val closedValues: Map<String, Set<String>> =
            mapOf(
                "trigger" to FeedIncidentNativeBreadcrumb.allowedValues.getValue("repairReason") + setOf("none", "other"),
                "recoveredBy" to FeedIncidentNativeBreadcrumb.allowedValues.getValue("repairAction") + setOf("none", "other"),
                // The decode state an incident opened on (FeedIncidentExport); buckets, never counts.
                "decoderCall" to FeedIncidentExport.decoderCalls + setOf("none", "other"),
                "keyframeWait" to setOf("awaiting", "none", "unknown", "other"),
                "irapAge" to setOf("never", "0-1s", "1-5s", "5-30s", "30s+", "unknown", "other"),
                "decodeFlow" to setOf("idle", "rejecting", "partial", "flowing", "unknown", "other"),
                // Incident diagnostics (FeedIncidentVendorEnvelope.background / awaitingIrap).
                "background" to setOf("yes", "no", "unknown", "other"),
                "awaitingIrap" to setOf("yes", "no", "unknown", "other"),
                // MonitorGlesUpscaler labels (Swift MonitorUpscaler raw values).
                "feedUpscaler" to setOf("Off", "Fast", "Quality", "AI", "other"),
                // Incident outcomes and the session summary's own.
                "outcome" to
                    setOf(
                        "open", "recovered", "interrupted", "exhausted", "suppressed", "userEnded", "live",
                        "ended", "healthy", "no-exposure", "other",
                    ),
            )

        /**
         * Build-pipeline values with a fixed shape (the source revision stamp, `build-identity.py`,
         * the build number); anything else reads `unknown`. Swift twin: `shapes`.
         */
        public val shapes: Map<String, Regex> =
            mapOf(
                "sourceRevision" to Regex("""([0-9a-f]{7,40}(\+|-dirty)?|unknown)"""),
                "buildIdentity" to Regex("""((ios|android|watchos|wearos|macos)-[0-9a-z]{8,64}|unknown)"""),
                "appBuild" to Regex("""[0-9]{1,10}"""),
            )

        /**
         * A string as it may leave the phone under [key]: a closed vocabulary or a fixed shape where
         * one is registered, otherwise clipped to [limit] and redacted by [redact].
         */
        public fun value(
            key: String,
            raw: String,
            limit: Int = 96,
            redact: (String) -> String = { com.opencapture.opencine.media.PrivacyRedactor.redact(it) },
        ): String {
            val trimmed = raw.trim()
            closedValues[key]?.let { return if (trimmed in it) trimmed else "other" }
            shapes[key]?.let { return if (it.matches(trimmed)) trimmed else "unknown" }
            return redact(trimmed.take(limit))
        }

        private val sdkLifecycleMessages =
            listOf(
                Regex("""App hanging (for at least [0-9]+ ms|between [0-9.]+ and [0-9.]+ seconds)\."""),
                Regex(
                    "The user or the OS watchdog terminated your app while it blocked the main thread for " +
                        """(at least [0-9]+ ms|between [0-9.]+ and [0-9.]+ seconds|\?)\.""",
                ),
                Regex("""The OS watchdog terminated your app, possibly because it overused RAM\."""),
                Regex("""(Background )?(ANR|Application Not Responding for at least [0-9]+ ms\.)"""),
            )

        /**
         * An exception value as it may leave the phone: the SDK's own lifecycle messages (hang
         * duration, watchdog kill, ANR) carry no app data and say what happened, so they stay;
         * anything else may hold user or app text and is replaced. Swift twin: `exceptionValue`.
         */
        public fun exceptionValue(raw: String): String =
            if (sdkLifecycleMessages.any { it.matches(raw) }) raw else "Native exception"

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
                "testSource",
                "buildIdentity",
                "trigger",
                "recoveredBy",
                "gap",
                "feedUpscaler",
                "decoderCall",
                "keyframeWait",
                "irapAge",
                "decodeFlow",
                "background",
                "awaitingIrap",
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
            // Repairs are closed at recording; a bundle built elsewhere is closed here too, and the
            // build values are bounded as tags are.
            val header =
                from.header.copy(
                    sourceRevision = value("sourceRevision", from.header.sourceRevision),
                    buildIdentity = value("buildIdentity", from.header.buildIdentity),
                )
            val closed = from.copy(header = header, repairs = from.repairs.map { it.closed() })
            val data = runCatching { FeedIncidentJson.encode(closed) }.getOrNull() ?: return null
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

    /**
     * The receipt file of [incidentID], or null for an ID that could name a file outside the
     * receipts directory (a path separator or `..`).
     */
    public fun file(incidentID: String, root: File): File? {
        if (incidentID.contains('/') || incidentID.contains('\\') || incidentID.contains("..")) return null
        return File(directory(root), "$incidentID.json")
    }

    public fun load(incidentID: String, root: File): ReliabilityReportingReceipt? {
        val file = file(incidentID, root) ?: return null
        if (!file.isFile) return null
        return runCatching { decode(file.readText()) }.getOrNull()
    }

    public fun store(receipt: ReliabilityReportingReceipt, root: File) {
        val file = file(receipt.incidentID, root) ?: return
        val dir = directory(root)
        dir.mkdirs()
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
