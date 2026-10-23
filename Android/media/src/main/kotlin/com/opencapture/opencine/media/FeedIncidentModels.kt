package com.opencapture.opencine.media

object FeedIncidentSchema {
    const val VERSION = 1
}

enum class FeedIncidentTestSource(val wire: String) {
    MANUAL("manual"),
    AUTOMATION("automation"),
    FAULT_INJECTION("faultInjection"),
    VERIFICATION("verification"),
    UNKNOWN("unknown"),
    ;

    val rank: Int
        get() =
            when (this) {
                UNKNOWN -> 0
                MANUAL -> 1
                AUTOMATION -> 2
                FAULT_INJECTION -> 3
                VERIFICATION -> 4
            }

    companion object {
        fun fromWire(raw: String?): FeedIncidentTestSource =
            entries.firstOrNull { it.wire == raw } ?: UNKNOWN

        fun derive(
            verification: Boolean,
            injectionActivated: Boolean,
            automation: Boolean,
        ): FeedIncidentTestSource =
            when {
                verification -> VERIFICATION
                injectionActivated -> FAULT_INJECTION
                automation -> AUTOMATION
                else -> MANUAL
            }
    }
}

object FeedIncidentBuildIdentity {
    const val MAX_LENGTH = 64

    fun parse(raw: String?, redact: (String) -> String = { PrivacyRedactor.redact(it) }): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return "unknown"
        return FeedIncidentPrivacy.token(trimmed, MAX_LENGTH, redact)
    }
}

object FeedIncidentBounds {
    const val PRELUDE_SECONDS = 60.0
    const val AFTERMATH_SECONDS = 30.0
    const val STALL_SECONDS = 2.0
    const val STRING_LENGTH = 96
    const val RING_COUNT = 60
    const val BREADCRUMB_RING = 32
    const val REPAIR_RING = 32
    const val DURING_COUNT = 60
    const val ERROR_CLASSES = 16
}

data class FeedIncidentLimits(
    val maxBundles: Int = 20,
    val maxBundleBytes: Int = 262_144,
    val maxSpoolBytes: Int = 10_485_760,
    val ttlMs: Long = 604_800_000L,
)

data class FeedIncidentSessionContext(
    val sessionId: String,
    val appVersion: String,
    val appBuild: String,
    val sourceRevision: String,
    val osName: String,
    val osVersion: String,
    val hardwareClass: String,
    val cameraFamily: String,
    val cameraFirmware: String? = null,
    var decoderGeneration: Int = 0,
    var socketGeneration: Int = 0,
    var testSource: FeedIncidentTestSource = FeedIncidentTestSource.UNKNOWN,
    var buildIdentity: String = "unknown",
)

enum class FeedIncidentKind(val wire: String) {
    FRESH_INPUT_STALE_OUTPUT("freshInputStaleOutput"),
    DECODER_ERROR("decoderError"),
    PRESENT_STALLED("presentStalled"),
    ASSIST_STALLED("assistStalled"),
    TRANSPORT_STALL("transportStall"),
    UNEXPECTED_DISCONNECT("unexpectedDisconnect"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: TRANSPORT_STALL
    }
}

enum class FeedIncidentFailingStage(val wire: String) {
    PACKET("packet"),
    ACCESS_UNIT("accessUnit"),
    DECODE_ACCEPT("decodeAccept"),
    DECODED_OUTPUT("decodedOutput"),
    ASSIST_OUTPUT("assistOutput"),
    PRESENTATION("presentation"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: PACKET

        fun isKnown(raw: String): Boolean = entries.any { it.wire == raw }
    }
}

enum class FeedIncidentOutcome(val wire: String) {
    OPEN("open"),
    RECOVERED("recovered"),
    INTERRUPTED("interrupted"),
    EXHAUSTED("exhausted"),
    SUPPRESSED("suppressed"),
    /** Operator disconnected while the incident was open. Not a suppression. */
    USER_ENDED("userEnded"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: OPEN
    }
}

enum class FeedIncidentSuppression { NONE, DISCONNECTED, PLAYBACK, BACKGROUND, NEVER_ESTABLISHED }

enum class FeedDecoderErrorOrigin(val wire: String) {
    NONE("none"),
    SYNC("sync"),
    CALLBACK("callback"),
    CREATE("create"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: NONE
    }
}

enum class FeedIncidentBreadcrumbKind(val wire: String) {
    SETTINGS_ENTER("settingsEnter"),
    SETTINGS_EXIT("settingsExit"),
    ASSIST_CHANGE("assistChange"),
    SCENE_ACTIVITY("sceneActivity"),
    SURFACE_ATTACH("surfaceAttach"),
    SURFACE_DETACH("surfaceDetach"),
    DECODER_CREATE("decoderCreate"),
    DECODER_INVALIDATE("decoderInvalidate"),
    PATH_CHANGE("pathChange"),
    CAMERA_COMMAND("cameraCommand"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: SCENE_ACTIVITY
    }
}

enum class FeedRepairPhase(val wire: String) {
    REQUESTED("requested"),
    BLOCKED("blocked"),
    LOCALLY_SENT("locallySent"),
    PEER_RESPONSE("peerResponse"),
    PICTURE_RESTORED("pictureRestored"),
    ;

    companion object {
        fun fromWire(raw: String) = entries.firstOrNull { it.wire == raw } ?: REQUESTED
    }
}

data class FeedIncidentRates @JvmOverloads constructor(
    val packetHz: Double = 0.0,
    val accessUnitHz: Double = 0.0,
    val decodeSubmitHz: Double = 0.0,
    val decodeAcceptHz: Double = 0.0,
    val decodedOutputHz: Double = 0.0,
    val assistOutputHz: Double = 0.0,
    val presentHz: Double = 0.0,
    val ackHz: Double = 0.0,
    val observed: FeedIncidentRateObservation? = null,
)

data class FeedIncidentAges(
    val packetAge: Double? = null,
    val accessUnitAge: Double? = null,
    val decodeAcceptAge: Double? = null,
    val decodedOutputAge: Double? = null,
    val assistOutputAge: Double? = null,
    val presentAge: Double? = null,
    val statusAge: Double? = null,
)

data class FeedIncidentQueue(
    val bytes: Int = 0,
    val count: Int = 0,
    val ageMilliseconds: Double = 0.0,
    val incompleteAccessUnits: Int = 0,
    val drops: Int = 0,
)

data class FeedIncidentDecoder(
    val generation: Int = 0,
    val formatGeneration: Int = 0,
    val codec: String = "hevc",
    val width: Int = 0,
    val height: Int = 0,
    val lastStatus: Int? = null,
    val lastFlags: Long? = null,
    val origin: FeedDecoderErrorOrigin = FeedDecoderErrorOrigin.NONE,
    val errorClass: String? = null,
    /** The platform call that raised the last error ([FeedIncidentExport.decoderCalls]), else null. */
    val errorCall: String? = null,
    val errorCount: Int = 0,
    val decoderFailed: Boolean = false,
    val errorAge: Double? = null,
    val receivedIrap: Boolean = false,
    val awaitingIrap: Boolean = false,
    val hasDecodableReferences: Boolean = true,
    val lastIrapAge: Double? = null,
    val lastSuccessfulOutputAge: Double? = null,
    val rebuildReason: String? = null,
    /** Bitstream facts behind the first decoder error of the current error episode. */
    val firstError: FeedIncidentDecodeErrorContext? = null,
)

/**
 * The access unit behind the first decoder error of an episode: NAL types in unit order, its
 * size, how long since the last accepted IRAP and the last parameter-set change, and the
 * access-unit rate over the second before it. Types, sizes, ages and rates only: no payload
 * bytes and no user data. Apple fills it from VideoToolbox callbacks; MediaCodec reports
 * failures per codec rather than per access unit, so Android producers leave it null.
 */
class FeedIncidentDecodeErrorContext(
    status: Int,
    nalTypes: List<Int>,
    accessUnitBytes: Int,
    irapAge: Double? = null,
    parameterSetChangeAge: Double? = null,
    inputHz: Double = 0.0,
) {
    private val values = Values(
        status, nalTypes.take(MAX_NAL_TYPES).map { it.coerceIn(0, 63) },
        accessUnitBytes.coerceAtLeast(0), normalizedAge(irapAge),
        normalizedAge(parameterSetChangeAge), FeedIncidentPrivacy.rate(inputHz).let { if (it == 0.0) 0.0 else it },
    )
    val status: Int get() = values.status
    val nalTypes: List<Int> get() = values.nalTypes
    val accessUnitBytes: Int get() = values.accessUnitBytes
    val irapAge: Double? get() = values.irapAge
    val parameterSetChangeAge: Double? get() = values.parameterSetChangeAge
    val inputHz: Double get() = values.inputHz

    override fun equals(other: Any?): Boolean = other is FeedIncidentDecodeErrorContext && values == other.values
    override fun hashCode(): Int = values.hashCode()

    private data class Values(
        val status: Int, val nalTypes: List<Int>, val accessUnitBytes: Int,
        val irapAge: Double?, val parameterSetChangeAge: Double?, val inputHz: Double,
    )

    companion object {
        const val MAX_NAL_TYPES = 16
        private fun normalizedAge(value: Double?): Double? =
            FeedIncidentPrivacy.age(value)?.let { if (it == 0.0) 0.0 else it }
    }
}

data class FeedIncidentLifecycle(
    val foreground: Boolean = true,
    val settingsCovered: Boolean = false,
    val playbackActive: Boolean = false,
    val connected: Boolean = false,
    val liveEstablished: Boolean = false,
    val thermalState: String = "nominal",
    val memoryWarning: Boolean = false,
    val lowPower: Boolean = false,
    val sceneActive: Boolean = true,
    val assistState: String = "off",
    val outputObservable: Boolean = true,
    val presentationExpected: Boolean = true,
)

/**
 * Android thermal status (PowerManager.THERMAL_STATUS_*, 0 none to 6 shutdown) in the iOS
 * producers' scale (ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious,
 * 3 critical), so incidents from both platforms compare. Unknown keeps the model default.
 */
object FeedIncidentThermal {
    fun fromAndroidThermalStatus(status: Int?): String =
        when (status) {
            null -> FeedIncidentLifecycle().thermalState
            0 -> "0"
            1, 2 -> "1"
            3 -> "2"
            else -> if (status > 3) "3" else FeedIncidentLifecycle().thermalState
        }
}

/** Observed counts for one endpoint generation, before native video admission. */
data class FeedIncidentIngress(
    val socketGeneration: Int,
    val receivedDatagrams: Int,
    val videoDatagrams: Int,
    val videoGateDrops: Int,
    val injectedVideoDrops: Int,
    val registrationSubmissions: Int,
    val receiveErrors: Int,
    val lastDatagramAge: Double? = null,
    val lastVideoDatagramAge: Double? = null,
    val lastRegistrationSubmissionAge: Double? = null,
    val videoGateOpen: Boolean,
)

/**
 * The feed watchdog's gating inputs at this sample (Swift `FeedIncidentWatchdogGate`). Each field is
 * null when the producer cannot see it. [hold] is the watchdog's last quiet gate (`FeedWatchdog.Hold`)
 * or the shell's pre-tick hold (`foregroundRecover`, `endpointRebuild`, `repairInFlight`).
 */
data class FeedIncidentWatchdogGate(
    val pathReady: Boolean? = null,
    val repairReady: Boolean? = null,
    val outputExpected: Boolean? = null,
    val hold: String? = null,
) {
    /** The gate as reports carry it: [hold] is a bounded token, an empty one is unknown. */
    fun closed(): FeedIncidentWatchdogGate =
        copy(hold = hold?.let { FeedIncidentPrivacy.token(it, 32) }?.takeIf { it.isNotEmpty() })
}

data class FeedIncidentSnapshot(
    val monotonicNow: Double,
    val wallClockMs: Long = 0L,
    val rates: FeedIncidentRates = FeedIncidentRates(),
    val ages: FeedIncidentAges = FeedIncidentAges(),
    val queue: FeedIncidentQueue = FeedIncidentQueue(),
    val decoder: FeedIncidentDecoder = FeedIncidentDecoder(),
    val lifecycle: FeedIncidentLifecycle = FeedIncidentLifecycle(),
    val watchdogAction: String = "none",
    val diagnoserFailure: String = "none",
    val diagnoserRepair: String = "none",
    val ingress: FeedIncidentIngress? = null,
    /** Absent on legacy records and producers without a feed watchdog. */
    val watchdogGate: FeedIncidentWatchdogGate? = null,
)

data class FeedIncidentBreadcrumb(
    val monotonicAt: Double,
    val kind: FeedIncidentBreadcrumbKind,
    val detail: String = "",
)

object FeedIncidentNativeBreadcrumb {
    val allowedValues: Map<String, Set<String>> =
        mapOf(
            "sceneState" to setOf("active", "inactive"),
            "assistState" to setOf("off", "identity", "replacement"),
            "path" to setOf("unexpectedDisconnect"),
            "repairPhase" to
                setOf("requested", "blocked", "locallySent", "peerResponse", "pictureRestored"),
            "repairAction" to setOf("decoder", "enable", "session", "endpoint", "rejoin"),
            // Producers' reasons: RecoveryReason wires, the Swift SessionRecoveryTrigger cases and
            // the DJI shells' decoder and enable gates. Swift twin: the same set.
            "repairReason" to
                setOf(
                    "bleDropped", "softAPLost", "datalinkLost", "operatorRetry", "feedWatchdogStall",
                    "commandTimeout", "firstPicture", "outputSilence", "referenceLoss", "notReady",
                    "overlap", "playback", "path", "serialGate", "media", "watchdog", "pictureDeadline",
                    "outputResumed", "udpAlive", "keyframeUnanswered", "videoLive", "presentationOnly",
                    "decoderNotReady", "pathNotReady", "cooldown", "enableGate",
                ),
        )

    /** [value] when the [key] vocabulary holds it, else `other`: free text never leaves the phone. */
    fun closed(key: String, value: String): String = if (allowedValues[key]?.contains(value) == true) value else "other"

    fun isAllowedMessage(message: String): Boolean =
        FeedIncidentBreadcrumbKind.entries.any { it.wire == message } || message == "repair"

    fun details(kind: FeedIncidentBreadcrumbKind, detail: String): Map<String, String> =
        when (kind) {
            FeedIncidentBreadcrumbKind.SCENE_ACTIVITY -> sanitized(mapOf("sceneState" to detail))
            FeedIncidentBreadcrumbKind.ASSIST_CHANGE -> sanitized(mapOf("assistState" to detail))
            FeedIncidentBreadcrumbKind.PATH_CHANGE -> sanitized(mapOf("path" to detail))
            FeedIncidentBreadcrumbKind.SETTINGS_ENTER,
            FeedIncidentBreadcrumbKind.SETTINGS_EXIT,
            FeedIncidentBreadcrumbKind.SURFACE_ATTACH,
            FeedIncidentBreadcrumbKind.SURFACE_DETACH,
            FeedIncidentBreadcrumbKind.DECODER_CREATE,
            FeedIncidentBreadcrumbKind.DECODER_INVALIDATE,
            FeedIncidentBreadcrumbKind.CAMERA_COMMAND,
            -> emptyMap()
        }

    fun details(repair: FeedRepairRecord): Map<String, String> =
        sanitized(mapOf("repairPhase" to repair.phase.wire, "repairAction" to repair.action))

    fun sanitized(raw: Map<String, String>): Map<String, String> {
        val out = mutableMapOf<String, String>()
        for ((key, value) in raw) {
            val token = FeedIncidentPrivacy.token(value, 32)
            val allowed = allowedValues[key] ?: continue
            if (token !in allowed) continue
            out[key] = token
        }
        return out
    }
}

data class FeedRepairRecord(
    val monotonicAt: Double,
    val action: String,
    val phase: FeedRepairPhase,
    val reason: String? = null,
) {
    /**
     * The record as reports carry it: action and reason from the closed repair vocabulary. Producers
     * pass free text, and the record reaches reports as trigger and recoveredBy (Swift closes in init).
     */
    fun closed(): FeedRepairRecord =
        copy(
            action = FeedIncidentNativeBreadcrumb.closed("repairAction", FeedIncidentPrivacy.token(action, 32)),
            reason = reason?.let { FeedIncidentNativeBreadcrumb.closed("repairReason", FeedIncidentPrivacy.token(it, 32)) },
        )

    companion object {
        /** The reason a first-picture resend carries (Swift `FeedRepairRecord.firstPictureReason`). */
        const val FIRST_PICTURE_REASON = "firstPicture"
    }
}

data class FeedIncidentErrorCount(
    val errorClass: String,
    val count: Int,
)

data class FeedIncidentHeader(
    var schemaVersion: Int = FeedIncidentSchema.VERSION,
    var incidentId: String,
    var sessionId: String,
    var kind: FeedIncidentKind,
    var failingStage: FeedIncidentFailingStage,
    var errorClass: String? = null,
    var outcome: FeedIncidentOutcome = FeedIncidentOutcome.OPEN,
    var startedAtWallClockMs: Long,
    var startedAtMonotonic: Double,
    var endedAtMonotonic: Double? = null,
    var firstFailureAt: Double,
    var worstGapSeconds: Double,
    var appVersion: String,
    var appBuild: String,
    var sourceRevision: String,
    var osName: String,
    var osVersion: String,
    var hardwareClass: String,
    var cameraFamily: String,
    var cameraFirmware: String? = null,
    var decoderGeneration: Int = 0,
    var socketGeneration: Int = 0,
    var evictions: Int = 0,
    var assistState: String = "off",
    var healthyExposureSeconds: Double = 0.0,
    var testSource: FeedIncidentTestSource = FeedIncidentTestSource.UNKNOWN,
    var buildIdentity: String = "unknown",
) {
    val processInterrupted: Boolean get() = outcome == FeedIncidentOutcome.INTERRUPTED
}

data class FeedIncidentBundle(
    var header: FeedIncidentHeader,
    var prelude: List<FeedIncidentSnapshot>,
    var during: List<FeedIncidentSnapshot> = emptyList(),
    var aftermath: List<FeedIncidentSnapshot> = emptyList(),
    var breadcrumbs: List<FeedIncidentBreadcrumb> = emptyList(),
    var repairs: List<FeedRepairRecord> = emptyList(),
    var aggregatedErrors: List<FeedIncidentErrorCount> = emptyList(),
)

data class FeedIncidentVerdict(
    val suppression: FeedIncidentSuppression,
    val kind: FeedIncidentKind? = null,
    val failingStage: FeedIncidentFailingStage? = null,
) {
    val shouldRecord: Boolean
        get() = suppression == FeedIncidentSuppression.NONE && kind != null && failingStage != null
}

data class FeedIncidentPersistenceJob(
    val bundle: FeedIncidentBundle,
    val reason: Reason,
) {
    enum class Reason { STARTED, CHECKPOINT, REPAIR, OUTCOME }
}

object FeedIncidentPrivacy {
    fun token(
        raw: String, max: Int = FeedIncidentBounds.STRING_LENGTH,
        redact: (String) -> String = { PrivacyRedactor.redact(it) },
    ): String {
        val clipped = raw.trim().take(max)
        return redact(clipped)
    }

    fun rate(value: Double): Double = if (value.isFinite() && value >= 0.0) value else 0.0

    fun stamp(value: Double): Double = if (value.isFinite() && value >= 0.0) value else 0.0

    fun age(value: Double?): Double? {
        if (value == null || !value.isFinite() || value < 0.0) return null
        return value
    }

    fun isFresh(age: Double?, threshold: Double): Boolean {
        if (age == null) return false
        return age < threshold
    }

    fun isStale(age: Double?, hertz: Double, flowingAlternative: Boolean, threshold: Double): Boolean {
        if (age != null) return age >= threshold
        return hertz == 0.0 && flowingAlternative
    }

    fun gapSeconds(snapshot: FeedIncidentSnapshot, stage: FeedIncidentFailingStage): Double {
        val ages = snapshot.ages
        val chosen =
            when (stage) {
                FeedIncidentFailingStage.PACKET -> ages.packetAge
                FeedIncidentFailingStage.ACCESS_UNIT -> ages.accessUnitAge
                FeedIncidentFailingStage.DECODE_ACCEPT -> ages.decodeAcceptAge
                FeedIncidentFailingStage.DECODED_OUTPUT -> ages.decodedOutputAge
                FeedIncidentFailingStage.ASSIST_OUTPUT -> ages.assistOutputAge
                FeedIncidentFailingStage.PRESENTATION -> ages.presentAge
            }
        return age(chosen) ?: 0.0
    }
}

object FeedIncidentClassifier {
    fun suppression(snapshot: FeedIncidentSnapshot): FeedIncidentSuppression? {
        val life = snapshot.lifecycle
        if (life.playbackActive) return FeedIncidentSuppression.PLAYBACK
        if (!life.connected) return FeedIncidentSuppression.DISCONNECTED
        if (!life.foreground || !life.sceneActive) return FeedIncidentSuppression.BACKGROUND
        if (!life.liveEstablished) return FeedIncidentSuppression.NEVER_ESTABLISHED
        return null
    }

    fun classify(snapshot: FeedIncidentSnapshot): FeedIncidentVerdict {
        suppression(snapshot)?.let {
            return FeedIncidentVerdict(it)
        }
        val life = snapshot.lifecycle
        val threshold = FeedIncidentBounds.STALL_SECONDS
        val packetFresh =
            FeedIncidentPrivacy.isFresh(snapshot.ages.packetAge, threshold) ||
                snapshot.rates.packetHz >= 1.0
        val auFresh =
            FeedIncidentPrivacy.isFresh(snapshot.ages.accessUnitAge, threshold) ||
                snapshot.rates.accessUnitHz >= 1.0
        val inputFresh = packetFresh || auFresh
        val outputStale =
            life.outputObservable &&
                FeedIncidentPrivacy.isStale(
                    snapshot.ages.decodedOutputAge,
                    snapshot.rates.decodedOutputHz,
                    snapshot.rates.decodeSubmitHz >= 1.0 || inputFresh,
                    threshold,
                )
        val outputFresh =
            life.outputObservable &&
                FeedIncidentPrivacy.isFresh(snapshot.ages.decodedOutputAge, threshold)
        val presentStale =
            life.presentationExpected &&
                FeedIncidentPrivacy.isStale(
                    snapshot.ages.presentAge,
                    snapshot.rates.presentHz,
                    true,
                    threshold,
                )
        val assistStale =
            FeedIncidentPrivacy.isStale(
                snapshot.ages.assistOutputAge,
                snapshot.rates.assistOutputHz,
                outputFresh,
                threshold,
            )
        val acceptStale =
            FeedIncidentPrivacy.isStale(
                snapshot.ages.decodeAcceptAge,
                snapshot.rates.decodeAcceptHz,
                snapshot.rates.decodeSubmitHz >= 1.0,
                threshold,
            )
        val decodeStage =
            if (acceptStale && snapshot.rates.decodeSubmitHz >= 1.0) {
                FeedIncidentFailingStage.DECODE_ACCEPT
            } else {
                FeedIncidentFailingStage.DECODED_OUTPUT
            }
        if (life.outputObservable && outputStale) {
            val currentError = isCurrentDecoderFailure(snapshot.decoder)
            val stage = decodeStage
            val kind =
                when {
                    currentError -> FeedIncidentKind.DECODER_ERROR
                    inputFresh -> FeedIncidentKind.FRESH_INPUT_STALE_OUTPUT
                    else -> FeedIncidentKind.TRANSPORT_STALL
                }
            return FeedIncidentVerdict(FeedIncidentSuppression.NONE, kind, stage)
        }
        if ((outputFresh || !life.outputObservable) && assistStale && snapshot.ages.assistOutputAge != null) {
            return FeedIncidentVerdict(
                FeedIncidentSuppression.NONE,
                FeedIncidentKind.ASSIST_STALLED,
                FeedIncidentFailingStage.ASSIST_OUTPUT,
            )
        }
        // An unobservable decode path does not make the presenter the stage that stopped
        // (Swift twin; OPENPOCKETCINE-IOS-2E, -K field snapshots).
        if (!life.outputObservable && presentStale) {
            if (isCurrentDecoderFailure(snapshot.decoder)) {
                return FeedIncidentVerdict(FeedIncidentSuppression.NONE, FeedIncidentKind.DECODER_ERROR, decodeStage)
            }
            if (!inputFresh) {
                return FeedIncidentVerdict(
                    FeedIncidentSuppression.NONE,
                    FeedIncidentKind.TRANSPORT_STALL,
                    if (packetFresh) FeedIncidentFailingStage.ACCESS_UNIT else FeedIncidentFailingStage.PACKET,
                )
            }
        }
        if ((outputFresh || !life.outputObservable) && presentStale) {
            return FeedIncidentVerdict(
                FeedIncidentSuppression.NONE,
                FeedIncidentKind.PRESENT_STALLED,
                FeedIncidentFailingStage.PRESENTATION,
            )
        }
        if (!inputFresh) {
            if (life.outputObservable && outputFresh) {
                return FeedIncidentVerdict(FeedIncidentSuppression.NONE)
            }
            if (!life.outputObservable &&
                life.presentationExpected &&
                FeedIncidentPrivacy.isFresh(snapshot.ages.presentAge, threshold)
            ) {
                return FeedIncidentVerdict(FeedIncidentSuppression.NONE)
            }
            return FeedIncidentVerdict(
                FeedIncidentSuppression.NONE,
                FeedIncidentKind.TRANSPORT_STALL,
                if (packetFresh) FeedIncidentFailingStage.ACCESS_UNIT else FeedIncidentFailingStage.PACKET,
            )
        }
        return FeedIncidentVerdict(FeedIncidentSuppression.NONE)
    }

    fun isRecovered(snapshot: FeedIncidentSnapshot): Boolean {
        if (suppression(snapshot) != null) return false
        val life = snapshot.lifecycle
        val threshold = FeedIncidentBounds.STALL_SECONDS
        if (!life.outputObservable && !life.presentationExpected) return false
        if (life.outputObservable) {
            if (!FeedIncidentPrivacy.isFresh(snapshot.ages.decodedOutputAge, threshold)) return false
        }
        if (life.presentationExpected) {
            if (!FeedIncidentPrivacy.isFresh(snapshot.ages.presentAge, threshold)) return false
        }
        return true
    }

    fun isCurrentDecoderFailure(decoder: FeedIncidentDecoder): Boolean {
        if (decoder.decoderFailed) return true
        val errorAge = decoder.errorAge ?: return false
        val success = decoder.lastSuccessfulOutputAge
        return if (success != null) errorAge < success else true
    }
}

data class FeedIncidentGrouping(
    val schemaVersion: Int,
    val failingStage: String,
    val errorClass: String,
    val outcome: String,
    val release: String,
    val os: String,
    val hardwareClass: String,
    val cameraFirmware: String,
    val assistState: String,
)

data class FeedIncidentVendorEnvelope(
    val schemaVersion: Int,
    val eventName: String,
    val grouping: FeedIncidentGrouping,
    val incidentID: String,
    val sessionID: String,
    val kind: String,
    val worstGapSeconds: Double,
    val healthyExposureSeconds: Double,
    val decoderGeneration: Int,
    val socketGeneration: Int,
    val startedAtWallClockMs: Long,
    val sourceRevision: String,
    val appVersion: String,
    val appBuild: String,
    val cameraFamily: String,
    val testSource: String,
    val buildIdentity: String,
    /** First repair reason recorded during this incident (`bleDropped`, ...), else `none`. */
    val trigger: String = "none",
    /** Last repair action before a recovered outcome, else `none`. */
    val recoveredBy: String = "none",
    /** The decoder call behind [FeedIncidentGrouping.errorClass] ([FeedIncidentExport.decoderCalls]), else `none`. */
    val decoderCall: String = "none",
    /** `awaiting` when the decoder held for a keyframe (IRAP) as the incident opened, else `none`. */
    val keyframeWait: String = "unknown",
    /** Age of the last accepted IRAP at onset, bucketed ([FeedIncidentExport.irapAgeBucket]). */
    val irapAge: String = "unknown",
    /** Decoder submits against accepts at onset ([FeedIncidentExport.decodeFlow]). */
    val decodeFlow: String = "unknown",
    /**
     * Diagnostic: `yes` when any snapshot of the incident was taken off screen (not foreground or
     * scene inactive) or a scene-inactive breadcrumb falls inside it, `no` when neither, `unknown`
     * without a snapshot. Sentry carries no bundle
     * attachment, so a long gap (PA-A, 290 s) could not tell an app switch from a dead feed.
     */
    val background: String = "unknown",
    /**
     * Diagnostic: whether the decoder still waited for an IRAP at the incident's newest snapshot
     * (`yes`/`no`/`unknown`). An exhausted decoder repair (PA-1) then says if no keyframe arrived
     * or one arrived and still produced no picture.
     */
    val awaitingIrap: String = "unknown",
)

data class FeedIncidentSessionSummary(
    val sessionID: String,
    val healthyExposureSeconds: Double,
    val incidentCount: Int,
    val outcome: String,
    val sourceRevision: String,
    val recordedAtMs: Long = System.currentTimeMillis(),
    val appVersion: String? = null,
    val appBuild: String? = null,
    val testSource: FeedIncidentTestSource? = null,
    val buildIdentity: String? = null,
)

object FeedIncidentExport {
    /**
     * The decoder calls an incident may name: MediaCodec's on Android, VideoToolbox's and the
     * display layer's on Apple. Swift twin: `FeedIncidentExport.decoderCalls`.
     */
    val decoderCalls: Set<String> =
        DecoderErrorCall.entries.map { it.wire }.toSet() +
            setOf("createSession", "decodeFrame", "outputCallback", "displayLayer")

    /** The snapshot the incident opened on: the last one before it, else its first. */
    fun onset(bundle: FeedIncidentBundle): FeedIncidentSnapshot? =
        bundle.prelude.lastOrNull() ?: bundle.during.firstOrNull()

    /** Coarse, searchable keyframe age. Exact seconds stay in the attachment. */
    fun irapAgeBucket(seconds: Double?): String =
        when {
            seconds == null -> "never"
            seconds < 1 -> "0-1s"
            seconds < 5 -> "1-5s"
            seconds < 30 -> "5-30s"
            else -> "30s+"
        }

    /**
     * Whether the decoder took what it was given: `idle` (nothing submitted), `rejecting` (submits,
     * no accepts), `partial` (under 80 % accepted) or `flowing`. Exact rates stay in the attachment.
     */
    fun decodeFlow(submitHz: Double, acceptHz: Double): String =
        when {
            submitHz < 0.5 -> "idle"
            acceptHz < 0.5 -> "rejecting"
            acceptHz < submitHz * 0.8 -> "partial"
            else -> "flowing"
        }

    /** The call that raised the incident's error class, from the snapshots that carry it. */
    fun decoderCall(bundle: FeedIncidentBundle): String {
        val errorClass = bundle.header.errorClass ?: return "none"
        val call =
            (listOfNotNull(onset(bundle)) + bundle.during + bundle.prelude.asReversed())
                .firstOrNull { it.decoder.errorClass == errorClass && it.decoder.errorCall != null }
                ?.decoder?.errorCall ?: return "none"
        return if (call in decoderCalls) call else "other"
    }

    /** Coarse, searchable picture-gap tag. Exact seconds stay in extras. */
    fun gapBucket(seconds: Double): String {
        val edges = listOf(2.0, 5.0, 10.0, 20.0, 40.0, 120.0)
        val upper = edges.firstOrNull { seconds < it } ?: return "120s+"
        val lower = edges.lastOrNull { it < upper } ?: 0.0
        return "${lower.toInt()}-${upper.toInt()}s"
    }

    fun envelope(from: FeedIncidentBundle): FeedIncidentVendorEnvelope {
        val header = from.header
        val opening = onset(from)
        // The 1 Hz snapshot opens an incident up to a tick after its first repair.
        val own = from.repairs.filter { it.monotonicAt >= header.startedAtMonotonic - 1.5 }.map { it.closed() }
        // The incident's own snapshots: its opening tick and everything recorded while it was open.
        val window = from.prelude.filter { it.monotonicNow >= header.startedAtMonotonic } + from.during
        // A session drop stops the snapshots, so an app switch inside it shows only as a breadcrumb.
        // One recorded after the incident ended (aftermath collection) is not the incident's.
        val incidentEnd = header.endedAtMonotonic
        val sceneInactive = from.breadcrumbs.any {
            it.kind == FeedIncidentBreadcrumbKind.SCENE_ACTIVITY && it.detail == "inactive" &&
                it.monotonicAt >= header.startedAtMonotonic - 1.5 &&
                (incidentEnd == null || it.monotonicAt <= incidentEnd)
        }
        val grouping =
            FeedIncidentGrouping(
                schemaVersion = header.schemaVersion,
                failingStage = header.failingStage.wire,
                errorClass = header.errorClass ?: "none",
                outcome = header.outcome.wire,
                release = "${header.appVersion}(${header.appBuild})",
                os = "${header.osName} ${header.osVersion}",
                hardwareClass = header.hardwareClass,
                cameraFirmware = header.cameraFirmware ?: "none",
                assistState = header.assistState,
            )
        return FeedIncidentVendorEnvelope(
            schemaVersion = header.schemaVersion,
            eventName = "feed.incident",
            grouping = grouping,
            incidentID = header.incidentId,
            sessionID = header.sessionId,
            kind = header.kind.wire,
            worstGapSeconds = header.worstGapSeconds,
            healthyExposureSeconds = header.healthyExposureSeconds,
            decoderGeneration = header.decoderGeneration,
            socketGeneration = header.socketGeneration,
            startedAtWallClockMs = header.startedAtWallClockMs,
            sourceRevision = header.sourceRevision,
            appVersion = header.appVersion,
            appBuild = header.appBuild,
            cameraFamily = header.cameraFamily,
            testSource = header.testSource.wire,
            buildIdentity = header.buildIdentity,
            trigger = own.firstNotNullOfOrNull { it.reason } ?: "none",
            // A first-picture resend inside an endpoint/rejoin repair is on the
            // timeline, but the rung that opened the new session gets the credit.
            recoveredBy =
                if (header.outcome == FeedIncidentOutcome.RECOVERED) {
                    own.lastOrNull { it.reason != FeedRepairRecord.FIRST_PICTURE_REASON }?.action ?: "none"
                } else {
                    "none"
                },
            decoderCall = decoderCall(from),
            keyframeWait = opening?.let { if (it.decoder.awaitingIrap) "awaiting" else "none" } ?: "unknown",
            irapAge = opening?.let { irapAgeBucket(it.decoder.lastIrapAge) } ?: "unknown",
            decodeFlow = opening?.let {
                // Absent observations stay unknown; numeric rates support legacy producers.
                val observed = it.rates.observed
                if (observed != null) {
                    val submitHz = observed.decodeSubmitHz ?: return@let "unknown"
                    val acceptHz = observed.decodeAcceptHz ?: return@let "unknown"
                    decodeFlow(submitHz, acceptHz)
                } else {
                    decodeFlow(it.rates.decodeSubmitHz, it.rates.decodeAcceptHz)
                }
            } ?: "unknown",
            background =
                when {
                    sceneInactive || window.any { !it.lifecycle.foreground || !it.lifecycle.sceneActive } -> "yes"
                    window.isEmpty() -> "unknown"
                    else -> "no"
                },
            awaitingIrap = window.lastOrNull()?.let { if (it.decoder.awaitingIrap) "yes" else "no" } ?: "unknown",
        )
    }
}

object FeedIncidentFileNaming {
    fun incident(id: String): String {
        val safe = id.filter { it.isLetterOrDigit() || it == '-' }
        return "incident-${safe.ifEmpty { "unknown" }}.json"
    }
}

object FeedIncidentSampling {
    fun <T> downsample(items: List<T>, keep: Int): List<T> {
        if (keep <= 0 || items.isEmpty()) return emptyList()
        if (items.size <= keep) return items
        if (keep == 1) return listOf(items.last())
        return (0 until keep).map { i ->
            items[i * (items.size - 1) / (keep - 1)]
        }
    }
}
