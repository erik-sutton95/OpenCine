package com.opencapture.opencine.dji

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

    fun parse(raw: String?): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return "unknown"
        return FeedIncidentPrivacy.token(trimmed, MAX_LENGTH)
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

data class FeedIncidentRates(
    val packetHz: Double = 0.0,
    val accessUnitHz: Double = 0.0,
    val decodeSubmitHz: Double = 0.0,
    val decodeAcceptHz: Double = 0.0,
    val decodedOutputHz: Double = 0.0,
    val assistOutputHz: Double = 0.0,
    val presentHz: Double = 0.0,
    val ackHz: Double = 0.0,
)

data class FeedIncidentAges(
    val packetAge: Double? = null,
    val accessUnitAge: Double? = null,
    val decodeAcceptAge: Double? = null,
    val decodedOutputAge: Double? = null,
    val assistOutputAge: Double? = null,
    val presentAge: Double? = null,
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
    val errorCount: Int = 0,
    val decoderFailed: Boolean = false,
    val errorAge: Double? = null,
    val receivedIrap: Boolean = false,
    val awaitingIrap: Boolean = false,
    val hasDecodableReferences: Boolean = true,
    val lastIrapAge: Double? = null,
    val lastSuccessfulOutputAge: Double? = null,
    val rebuildReason: String? = null,
)

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
)

data class FeedIncidentBreadcrumb(
    val monotonicAt: Double,
    val kind: FeedIncidentBreadcrumbKind,
    val detail: String = "",
)

object FeedIncidentNativeBreadcrumb {
    val allowedValues: Map<String, Set<String>> =
        com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb.allowedValues

    fun isAllowedMessage(message: String): Boolean =
        com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb.isAllowedMessage(message)

    fun details(kind: FeedIncidentBreadcrumbKind, detail: String): Map<String, String> =
        com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb.details(
            com.opencapture.opencine.media.FeedIncidentBreadcrumbKind.valueOf(kind.name), detail,
        )

    fun details(repair: FeedRepairRecord): Map<String, String> =
        com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb.details(
            com.opencapture.opencine.media.FeedRepairRecord(
                repair.monotonicAt, repair.action,
                com.opencapture.opencine.media.FeedRepairPhase.valueOf(repair.phase.name), repair.reason,
            ),
        )

    fun sanitized(raw: Map<String, String>): Map<String, String> =
        com.opencapture.opencine.media.FeedIncidentNativeBreadcrumb.sanitized(raw)
}

data class FeedRepairRecord(
    val monotonicAt: Double,
    val action: String,
    val phase: FeedRepairPhase,
    val reason: String? = null,
)

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
    fun token(raw: String, max: Int = FeedIncidentBounds.STRING_LENGTH): String =
        com.opencapture.opencine.media.FeedIncidentPrivacy.token(raw, max, PrivacyRedactor::redact)
    fun rate(value: Double): Double = com.opencapture.opencine.media.FeedIncidentPrivacy.rate(value)
    fun stamp(value: Double): Double = com.opencapture.opencine.media.FeedIncidentPrivacy.stamp(value)
    fun age(value: Double?): Double? = com.opencapture.opencine.media.FeedIncidentPrivacy.age(value)
    fun isFresh(age: Double?, threshold: Double): Boolean =
        com.opencapture.opencine.media.FeedIncidentPrivacy.isFresh(age, threshold)
    fun isStale(age: Double?, hertz: Double, flowingAlternative: Boolean, threshold: Double): Boolean =
        com.opencapture.opencine.media.FeedIncidentPrivacy.isStale(age, hertz, flowingAlternative, threshold)
    fun gapSeconds(snapshot: FeedIncidentSnapshot, stage: FeedIncidentFailingStage): Double =
        com.opencapture.opencine.media.FeedIncidentPrivacy.gapSeconds(
            snapshot.toMedia(), com.opencapture.opencine.media.FeedIncidentFailingStage.valueOf(stage.name),
        )
}

object FeedIncidentClassifier {
    fun suppression(snapshot: FeedIncidentSnapshot): FeedIncidentSuppression? =
        com.opencapture.opencine.media.FeedIncidentClassifier.suppression(snapshot.toMedia())?.let {
            FeedIncidentSuppression.valueOf(it.name)
        }

    fun classify(snapshot: FeedIncidentSnapshot): FeedIncidentVerdict {
        val verdict = com.opencapture.opencine.media.FeedIncidentClassifier.classify(snapshot.toMedia())
        return FeedIncidentVerdict(
            FeedIncidentSuppression.valueOf(verdict.suppression.name),
            verdict.kind?.let { FeedIncidentKind.valueOf(it.name) },
            verdict.failingStage?.let { FeedIncidentFailingStage.valueOf(it.name) },
        )
    }

    fun isRecovered(snapshot: FeedIncidentSnapshot): Boolean =
        com.opencapture.opencine.media.FeedIncidentClassifier.isRecovered(snapshot.toMedia())

    fun isCurrentDecoderFailure(decoder: FeedIncidentDecoder): Boolean =
        com.opencapture.opencine.media.FeedIncidentClassifier.isCurrentDecoderFailure(decoder.toMedia())
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
    fun envelope(from: FeedIncidentBundle): FeedIncidentVendorEnvelope {
        val envelope = com.opencapture.opencine.media.FeedIncidentExport.envelope(
            com.opencapture.opencine.media.FeedIncidentBundle(from.header.toMedia(), emptyList()),
        )
        return FeedIncidentVendorEnvelope(
            schemaVersion = envelope.schemaVersion,
            eventName = envelope.eventName,
            grouping = FeedIncidentGrouping(
                schemaVersion = envelope.grouping.schemaVersion,
                failingStage = envelope.grouping.failingStage,
                errorClass = envelope.grouping.errorClass,
                outcome = envelope.grouping.outcome,
                release = envelope.grouping.release,
                os = envelope.grouping.os,
                hardwareClass = envelope.grouping.hardwareClass,
                cameraFirmware = envelope.grouping.cameraFirmware,
                assistState = envelope.grouping.assistState,
            ),
            incidentID = envelope.incidentID,
            sessionID = envelope.sessionID,
            kind = envelope.kind,
            worstGapSeconds = envelope.worstGapSeconds,
            healthyExposureSeconds = envelope.healthyExposureSeconds,
            decoderGeneration = envelope.decoderGeneration,
            socketGeneration = envelope.socketGeneration,
            startedAtWallClockMs = envelope.startedAtWallClockMs,
            sourceRevision = envelope.sourceRevision,
            appVersion = envelope.appVersion,
            appBuild = envelope.appBuild,
            cameraFamily = envelope.cameraFamily,
            testSource = envelope.testSource,
            buildIdentity = envelope.buildIdentity,
        )
    }
}

object FeedIncidentFileNaming {
    fun incident(id: String): String = com.opencapture.opencine.media.FeedIncidentFileNaming.incident(id)
}

object FeedIncidentSampling {
    fun <T> downsample(items: List<T>, keep: Int): List<T> =
        com.opencapture.opencine.media.FeedIncidentSampling.downsample(items, keep)
}

// Keep the old DJI DTO JVM paths during add/migrate/remove. Policy runs on Media values.
private fun FeedIncidentRates.toMedia(): com.opencapture.opencine.media.FeedIncidentRates =
    com.opencapture.opencine.media.FeedIncidentRates(
        packetHz = packetHz,
        accessUnitHz = accessUnitHz,
        decodeSubmitHz = decodeSubmitHz,
        decodeAcceptHz = decodeAcceptHz,
        decodedOutputHz = decodedOutputHz,
        assistOutputHz = assistOutputHz,
        presentHz = presentHz,
        ackHz = ackHz,
    )

private fun FeedIncidentAges.toMedia(): com.opencapture.opencine.media.FeedIncidentAges =
    com.opencapture.opencine.media.FeedIncidentAges(
        packetAge = packetAge,
        accessUnitAge = accessUnitAge,
        decodeAcceptAge = decodeAcceptAge,
        decodedOutputAge = decodedOutputAge,
        assistOutputAge = assistOutputAge,
        presentAge = presentAge,
    )

private fun FeedIncidentQueue.toMedia(): com.opencapture.opencine.media.FeedIncidentQueue =
    com.opencapture.opencine.media.FeedIncidentQueue(
        bytes = bytes,
        count = count,
        ageMilliseconds = ageMilliseconds,
        incompleteAccessUnits = incompleteAccessUnits,
        drops = drops,
    )

private fun FeedIncidentDecoder.toMedia(): com.opencapture.opencine.media.FeedIncidentDecoder =
    com.opencapture.opencine.media.FeedIncidentDecoder(
        generation = generation,
        formatGeneration = formatGeneration,
        codec = codec,
        width = width,
        height = height,
        lastStatus = lastStatus,
        lastFlags = lastFlags,
        origin = com.opencapture.opencine.media.FeedDecoderErrorOrigin.valueOf(origin.name),
        errorClass = errorClass,
        errorCount = errorCount,
        decoderFailed = decoderFailed,
        errorAge = errorAge,
        receivedIrap = receivedIrap,
        awaitingIrap = awaitingIrap,
        hasDecodableReferences = hasDecodableReferences,
        lastIrapAge = lastIrapAge,
        lastSuccessfulOutputAge = lastSuccessfulOutputAge,
        rebuildReason = rebuildReason,
    )

private fun FeedIncidentLifecycle.toMedia(): com.opencapture.opencine.media.FeedIncidentLifecycle =
    com.opencapture.opencine.media.FeedIncidentLifecycle(
        foreground = foreground,
        settingsCovered = settingsCovered,
        playbackActive = playbackActive,
        connected = connected,
        liveEstablished = liveEstablished,
        thermalState = thermalState,
        memoryWarning = memoryWarning,
        lowPower = lowPower,
        sceneActive = sceneActive,
        assistState = assistState,
        outputObservable = outputObservable,
        presentationExpected = presentationExpected,
    )

private fun FeedIncidentSnapshot.toMedia(): com.opencapture.opencine.media.FeedIncidentSnapshot =
    com.opencapture.opencine.media.FeedIncidentSnapshot(
        monotonicNow = monotonicNow,
        wallClockMs = wallClockMs,
        rates = rates.toMedia(),
        ages = ages.toMedia(),
        queue = queue.toMedia(),
        decoder = decoder.toMedia(),
        lifecycle = lifecycle.toMedia(),
        watchdogAction = watchdogAction,
        diagnoserFailure = diagnoserFailure,
        diagnoserRepair = diagnoserRepair,
    )

private fun FeedIncidentHeader.toMedia(): com.opencapture.opencine.media.FeedIncidentHeader =
    com.opencapture.opencine.media.FeedIncidentHeader(
        schemaVersion = schemaVersion,
        incidentId = incidentId,
        sessionId = sessionId,
        kind = com.opencapture.opencine.media.FeedIncidentKind.valueOf(kind.name),
        failingStage = com.opencapture.opencine.media.FeedIncidentFailingStage.valueOf(failingStage.name),
        errorClass = errorClass,
        outcome = com.opencapture.opencine.media.FeedIncidentOutcome.valueOf(outcome.name),
        startedAtWallClockMs = startedAtWallClockMs,
        startedAtMonotonic = startedAtMonotonic,
        endedAtMonotonic = endedAtMonotonic,
        firstFailureAt = firstFailureAt,
        worstGapSeconds = worstGapSeconds,
        appVersion = appVersion,
        appBuild = appBuild,
        sourceRevision = sourceRevision,
        osName = osName,
        osVersion = osVersion,
        hardwareClass = hardwareClass,
        cameraFamily = cameraFamily,
        cameraFirmware = cameraFirmware,
        decoderGeneration = decoderGeneration,
        socketGeneration = socketGeneration,
        evictions = evictions,
        assistState = assistState,
        healthyExposureSeconds = healthyExposureSeconds,
        testSource = com.opencapture.opencine.media.FeedIncidentTestSource.valueOf(testSource.name),
        buildIdentity = buildIdentity,
    )
