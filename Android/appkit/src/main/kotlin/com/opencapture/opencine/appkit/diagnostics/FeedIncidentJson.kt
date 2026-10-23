package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.DiagnosticWire
import com.opencapture.opencine.media.FeedDecoderErrorOrigin
import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBreadcrumbKind
import com.opencapture.opencine.media.FeedIncidentBuildIdentity
import com.opencapture.opencine.media.FeedIncidentBundle
import com.opencapture.opencine.media.FeedIncidentDecodeErrorContext
import com.opencapture.opencine.media.FeedIncidentDecoder
import com.opencapture.opencine.media.FeedIncidentErrorCount
import com.opencapture.opencine.media.FeedIncidentFailingStage
import com.opencapture.opencine.media.FeedIncidentHeader
import com.opencapture.opencine.media.FeedIncidentIngress
import com.opencapture.opencine.media.FeedIncidentKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentOutcome
import com.opencapture.opencine.media.FeedIncidentQueue
import com.opencapture.opencine.media.FeedIncidentRates
import com.opencapture.opencine.media.FeedIncidentRateObservation
import com.opencapture.opencine.media.FeedIncidentSchema
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedIncidentWatchdogGate
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.media.PrivacyRedactor
import org.json.JSONArray
import org.json.JSONObject

public object FeedIncidentJson {
    public fun encode(bundle: FeedIncidentBundle): ByteArray = bundleJson(bundle).toString().toByteArray(Charsets.UTF_8)

    /** [redact] is the host's policy for the stored build identity. */
    public fun decode(
        bytes: ByteArray,
        redact: (String) -> String = { PrivacyRedactor.redact(it) },
    ): FeedIncidentBundle? =
        runCatching { parseBundle(JSONObject(String(bytes, Charsets.UTF_8)), redact) }.getOrNull()

    public fun encodedSize(bundle: FeedIncidentBundle): Int = encode(bundle).size

    public fun formatWall(ms: Long): String = DiagnosticWire.isoSeconds(ms)

    private fun bundleJson(bundle: FeedIncidentBundle): JSONObject =
        JSONObject()
            .put("header", headerJson(bundle.header))
            .put("prelude", snapshotArray(bundle.prelude))
            .put("during", snapshotArray(bundle.during))
            .put("aftermath", snapshotArray(bundle.aftermath))
            .put("breadcrumbs", breadcrumbArray(bundle.breadcrumbs))
            .put("repairs", repairArray(bundle.repairs))
            .put("aggregatedErrors", errorArray(bundle.aggregatedErrors))

    private fun headerJson(header: FeedIncidentHeader): JSONObject =
        JSONObject()
            .put("schemaVersion", header.schemaVersion)
            .put("incidentID", header.incidentId)
            .put("sessionID", header.sessionId)
            .put("kind", header.kind.wire)
            .put("failingStage", header.failingStage.wire)
            .put("outcome", header.outcome.wire)
            .put("startedAtWallClock", DiagnosticWire.isoSeconds(header.startedAtWallClockMs))
            .put("startedAtMonotonic", header.startedAtMonotonic)
            .put("firstFailureAt", header.firstFailureAt)
            .put("worstGapSeconds", header.worstGapSeconds)
            .put("appVersion", header.appVersion)
            .put("appBuild", header.appBuild)
            .put("sourceRevision", header.sourceRevision)
            .put("osName", header.osName)
            .put("osVersion", header.osVersion)
            .put("hardwareClass", header.hardwareClass)
            .put("cameraFamily", header.cameraFamily)
            .put("decoderGeneration", header.decoderGeneration)
            .put("socketGeneration", header.socketGeneration)
            .put("evictions", header.evictions)
            .put("assistState", header.assistState)
            .put("healthyExposureSeconds", header.healthyExposureSeconds)
            .put("testSource", header.testSource.wire)
            .put("buildIdentity", header.buildIdentity)
            .also {
                header.errorClass?.let { value -> it.put("errorClass", value) }
                header.endedAtMonotonic?.let { value -> it.put("endedAtMonotonic", value) }
                header.cameraFirmware?.let { value -> it.put("cameraFirmware", value) }
            }

    private fun snapshotArray(items: List<FeedIncidentSnapshot>): JSONArray {
        val array = JSONArray()
        items.forEach { array.put(snapshotJson(it)) }
        return array
    }

    private fun snapshotJson(snap: FeedIncidentSnapshot): JSONObject =
        JSONObject()
            .put("monotonicNow", snap.monotonicNow)
            .put("wallClock", DiagnosticWire.isoSeconds(snap.wallClockMs))
            .put(
                "rates",
                JSONObject()
                    .put("packetHz", snap.rates.packetHz)
                    .put("accessUnitHz", snap.rates.accessUnitHz)
                    .put("decodeSubmitHz", snap.rates.decodeSubmitHz)
                    .put("decodeAcceptHz", snap.rates.decodeAcceptHz)
                    .put("decodedOutputHz", snap.rates.decodedOutputHz)
                    .put("assistOutputHz", snap.rates.assistOutputHz)
                    .put("presentHz", snap.rates.presentHz)
                    .put("ackHz", snap.rates.ackHz)
                    .put("observed", snap.rates.observed?.let(::observedRatesJson)),
            )
            .put("ages", agesJson(snap.ages))
            .put(
                "queue",
                JSONObject()
                    .put("bytes", snap.queue.bytes)
                    .put("count", snap.queue.count)
                    .put("ageMilliseconds", snap.queue.ageMilliseconds)
                    .put("incompleteAccessUnits", snap.queue.incompleteAccessUnits)
                    .put("drops", snap.queue.drops),
            )
            .put(
                "decoder",
                JSONObject()
                    .put("generation", snap.decoder.generation)
                    .put("formatGeneration", snap.decoder.formatGeneration)
                    .put("codec", snap.decoder.codec)
                    .put("width", snap.decoder.width)
                    .put("height", snap.decoder.height)
                    .put("origin", snap.decoder.origin.wire)
                    .put("errorCount", snap.decoder.errorCount)
                    .put("decoderFailed", snap.decoder.decoderFailed)
                    .put("receivedIrap", snap.decoder.receivedIrap)
                    .put("awaitingIrap", snap.decoder.awaitingIrap)
                    .put("hasDecodableReferences", snap.decoder.hasDecodableReferences)
                    .also { obj ->
                        snap.decoder.lastStatus?.let { obj.put("lastStatus", it) }
                        snap.decoder.lastFlags?.let { obj.put("lastFlags", it) }
                        snap.decoder.errorClass?.let { obj.put("errorClass", it) }
                        snap.decoder.errorCall?.let { obj.put("errorCall", it) }
                        snap.decoder.errorAge?.let { obj.put("errorAge", it) }
                        snap.decoder.lastIrapAge?.let { obj.put("lastIrapAge", it) }
                        snap.decoder.lastSuccessfulOutputAge?.let { obj.put("lastSuccessfulOutputAge", it) }
                        snap.decoder.rebuildReason?.let { obj.put("rebuildReason", it) }
                        snap.decoder.firstError?.let { obj.put("firstError", firstErrorJson(it)) }
                    },
            )
            .put(
                "lifecycle",
                JSONObject()
                    .put("foreground", snap.lifecycle.foreground)
                    .put("settingsCovered", snap.lifecycle.settingsCovered)
                    .put("playbackActive", snap.lifecycle.playbackActive)
                    .put("connected", snap.lifecycle.connected)
                    .put("liveEstablished", snap.lifecycle.liveEstablished)
                    .put("thermalState", snap.lifecycle.thermalState)
                    .put("memoryWarning", snap.lifecycle.memoryWarning)
                    .put("lowPower", snap.lifecycle.lowPower)
                    .put("sceneActive", snap.lifecycle.sceneActive)
                    .put("assistState", snap.lifecycle.assistState)
                    .put("outputObservable", snap.lifecycle.outputObservable)
                    .put("presentationExpected", snap.lifecycle.presentationExpected),
            )
            .put("watchdogAction", snap.watchdogAction)
            .put("diagnoserFailure", snap.diagnoserFailure)
            .put("diagnoserRepair", snap.diagnoserRepair)
            .also { obj -> snap.ingress?.let { obj.put("ingress", ingressJson(it)) } }
            .also { obj -> snap.watchdogGate?.let { obj.put("watchdogGate", watchdogGateJson(it.closed())) } }

    private fun watchdogGateJson(gate: FeedIncidentWatchdogGate): JSONObject =
        JSONObject().also { obj ->
            gate.pathReady?.let { obj.put("pathReady", it) }
            gate.repairReady?.let { obj.put("repairReady", it) }
            gate.outputExpected?.let { obj.put("outputExpected", it) }
            gate.hold?.let { obj.put("hold", it) }
        }

    private fun parseWatchdogGate(json: JSONObject): FeedIncidentWatchdogGate =
        FeedIncidentWatchdogGate(
            pathReady = json.opt("pathReady") as? Boolean,
            repairReady = json.opt("repairReady") as? Boolean,
            outputExpected = json.opt("outputExpected") as? Boolean,
            hold = json.opt("hold") as? String,
        ).closed()

    private fun firstErrorJson(context: FeedIncidentDecodeErrorContext): JSONObject =
        JSONObject()
            .put("status", context.status)
            .put("nalTypes", JSONArray(context.nalTypes))
            .put("accessUnitBytes", context.accessUnitBytes)
            .put("inputHz", context.inputHz)
            .also { obj ->
                context.irapAge?.let { obj.put("irapAge", it) }
                context.parameterSetChangeAge?.let { obj.put("parameterSetChangeAge", it) }
            }

    private fun firstError(json: JSONObject?): FeedIncidentDecodeErrorContext? {
        json ?: return null
        val status = json.optIntOrNull("status") ?: return null
        val types = json.optJSONArray("nalTypes") ?: return null
        return FeedIncidentDecodeErrorContext(
            status = status,
            nalTypes = (0 until minOf(types.length(), FeedIncidentDecodeErrorContext.MAX_NAL_TYPES)).map { types.optInt(it) },
            accessUnitBytes = json.optInt("accessUnitBytes"),
            irapAge = json.optDoubleOrNull("irapAge")?.takeIf { it >= 0.0 },
            parameterSetChangeAge = json.optDoubleOrNull("parameterSetChangeAge")?.takeIf { it >= 0.0 },
            inputHz = json.optDouble("inputHz", 0.0),
        )
    }

    private fun ingressJson(ingress: FeedIncidentIngress): JSONObject =
        JSONObject()
            .put("socketGeneration", ingress.socketGeneration)
            .put("receivedDatagrams", ingress.receivedDatagrams)
            .put("videoDatagrams", ingress.videoDatagrams)
            .put("videoGateDrops", ingress.videoGateDrops)
            .put("injectedVideoDrops", ingress.injectedVideoDrops)
            .put("registrationSubmissions", ingress.registrationSubmissions)
            .put("receiveErrors", ingress.receiveErrors)
            .put("videoGateOpen", ingress.videoGateOpen)
            .also { obj ->
                ingress.lastDatagramAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { obj.put("lastDatagramAge", it) }
                ingress.lastVideoDatagramAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { obj.put("lastVideoDatagramAge", it) }
                ingress.lastRegistrationSubmissionAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { obj.put("lastRegistrationSubmissionAge", it) }
            }

    private fun parseIngress(json: JSONObject): FeedIncidentIngress? {
        val generation = json.optIntOrNull("socketGeneration")?.takeIf { it >= 0 } ?: return null
        val received = json.optIntOrNull("receivedDatagrams")?.takeIf { it >= 0 } ?: return null
        val video = json.optIntOrNull("videoDatagrams")?.takeIf { it >= 0 } ?: return null
        val gated = json.optIntOrNull("videoGateDrops")?.takeIf { it >= 0 } ?: return null
        val injected = json.optIntOrNull("injectedVideoDrops")?.takeIf { it >= 0 } ?: return null
        val registrations = json.optIntOrNull("registrationSubmissions")?.takeIf { it >= 0 } ?: return null
        val errors = json.optIntOrNull("receiveErrors")?.takeIf { it >= 0 } ?: return null
        val gateOpen = json.opt("videoGateOpen") as? Boolean ?: return null
        return FeedIncidentIngress(
            socketGeneration = generation,
            receivedDatagrams = received,
            videoDatagrams = video,
            videoGateDrops = gated,
            injectedVideoDrops = injected,
            registrationSubmissions = registrations,
            receiveErrors = errors,
            lastDatagramAge = json.optDoubleOrNull("lastDatagramAge")?.takeIf { it >= 0.0 },
            lastVideoDatagramAge = json.optDoubleOrNull("lastVideoDatagramAge")?.takeIf { it >= 0.0 },
            lastRegistrationSubmissionAge = json.optDoubleOrNull("lastRegistrationSubmissionAge")?.takeIf { it >= 0.0 },
            videoGateOpen = gateOpen,
        )
    }

    private fun breadcrumbArray(items: List<FeedIncidentBreadcrumb>): JSONArray {
        val array = JSONArray()
        items.forEach {
            array.put(
                JSONObject()
                    .put("monotonicAt", it.monotonicAt)
                    .put("kind", it.kind.wire)
                    .put("detail", it.detail),
            )
        }
        return array
    }

    private fun repairArray(items: List<FeedRepairRecord>): JSONArray {
        val array = JSONArray()
        items.forEach {
            array.put(
                JSONObject()
                    .put("monotonicAt", it.monotonicAt)
                    .put("action", it.action)
                    .put("phase", it.phase.wire)
                    .also { obj -> it.reason?.let { reason -> obj.put("reason", reason) } },
            )
        }
        return array
    }

    private fun errorArray(items: List<FeedIncidentErrorCount>): JSONArray {
        val array = JSONArray()
        items.forEach {
            array.put(JSONObject().put("errorClass", it.errorClass).put("count", it.count))
        }
        return array
    }

    private fun observedRatesJson(rates: FeedIncidentRateObservation): JSONObject = JSONObject()
        .put("packetHz", rates.packetHz ?: JSONObject.NULL)
        .put("accessUnitHz", rates.accessUnitHz ?: JSONObject.NULL)
        .put("decodeSubmitHz", rates.decodeSubmitHz ?: JSONObject.NULL)
        .put("decodeAcceptHz", rates.decodeAcceptHz ?: JSONObject.NULL)
        .put("decodedOutputHz", rates.decodedOutputHz ?: JSONObject.NULL)
        .put("assistOutputHz", rates.assistOutputHz ?: JSONObject.NULL)
        .put("presentHz", rates.presentHz ?: JSONObject.NULL)
        .put("ackHz", rates.ackHz ?: JSONObject.NULL)

    private fun observedRates(json: JSONObject): FeedIncidentRateObservation = FeedIncidentRateObservation(
        json.optDoubleOrNull("packetHz"), json.optDoubleOrNull("accessUnitHz"),
        json.optDoubleOrNull("decodeSubmitHz"), json.optDoubleOrNull("decodeAcceptHz"),
        json.optDoubleOrNull("decodedOutputHz"), json.optDoubleOrNull("assistOutputHz"),
        json.optDoubleOrNull("presentHz"), json.optDoubleOrNull("ackHz"))

    private fun agesJson(ages: FeedIncidentAges): JSONObject {
        val json = JSONObject()
        ages.packetAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("packetAge", it) }
        ages.accessUnitAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("accessUnitAge", it) }
        ages.decodeAcceptAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("decodeAcceptAge", it) }
        ages.decodedOutputAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("decodedOutputAge", it) }
        ages.assistOutputAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("assistOutputAge", it) }
        ages.presentAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("presentAge", it) }
        ages.statusAge?.takeIf { it.isFinite() && it >= 0.0 }?.let { json.put("statusAge", it) }
        return json
    }

    private fun parseBundle(json: JSONObject, redact: (String) -> String): FeedIncidentBundle =
        FeedIncidentBundle(
            header = parseHeader(json.getJSONObject("header"), redact),
            prelude = parseSnapshots(json.optJSONArray("prelude")),
            during = parseSnapshots(json.optJSONArray("during")),
            aftermath = parseSnapshots(json.optJSONArray("aftermath")),
            breadcrumbs = parseBreadcrumbs(json.optJSONArray("breadcrumbs")),
            repairs = parseRepairs(json.optJSONArray("repairs")),
            aggregatedErrors = parseErrors(json.optJSONArray("aggregatedErrors")),
        )

    private fun parseHeader(json: JSONObject, redact: (String) -> String): FeedIncidentHeader =
        FeedIncidentHeader(
            schemaVersion = json.optInt("schemaVersion", FeedIncidentSchema.VERSION),
            incidentId = json.optString("incidentID"),
            sessionId = json.optString("sessionID"),
            kind = FeedIncidentKind.fromWire(json.optString("kind")),
            failingStage = FeedIncidentFailingStage.fromWire(json.optString("failingStage")),
            errorClass = json.optStringOrNull("errorClass"),
            outcome = FeedIncidentOutcome.fromWire(json.optString("outcome")),
            startedAtWallClockMs = parseWall(json.optString("startedAtWallClock")),
            startedAtMonotonic = json.optDouble("startedAtMonotonic", 0.0),
            endedAtMonotonic = json.optDoubleOrNull("endedAtMonotonic"),
            firstFailureAt = json.optDouble("firstFailureAt", 0.0),
            worstGapSeconds = json.optDouble("worstGapSeconds", 0.0),
            appVersion = json.optString("appVersion"),
            appBuild = json.optString("appBuild"),
            sourceRevision = json.optString("sourceRevision"),
            osName = json.optString("osName"),
            osVersion = json.optString("osVersion"),
            hardwareClass = json.optString("hardwareClass"),
            cameraFamily = json.optString("cameraFamily"),
            cameraFirmware = json.optStringOrNull("cameraFirmware"),
            decoderGeneration = json.optInt("decoderGeneration"),
            socketGeneration = json.optInt("socketGeneration"),
            evictions = json.optInt("evictions"),
            assistState = json.optString("assistState", "off"),
            healthyExposureSeconds = json.optDouble("healthyExposureSeconds", 0.0),
            testSource = FeedIncidentTestSource.fromWire(json.optStringOrNull("testSource")),
            buildIdentity = FeedIncidentBuildIdentity.parse(json.optStringOrNull("buildIdentity"), redact),
        )

    private fun parseSnapshots(array: JSONArray?): List<FeedIncidentSnapshot> {
        if (array == null) return emptyList()
        return (0 until array.length()).map { index ->
            val json = array.getJSONObject(index)
            val rates = json.optJSONObject("rates") ?: JSONObject()
            val ages = json.optJSONObject("ages") ?: JSONObject()
            val queue = json.optJSONObject("queue") ?: JSONObject()
            val decoder = json.optJSONObject("decoder") ?: JSONObject()
            val life = json.optJSONObject("lifecycle") ?: JSONObject()
            FeedIncidentSnapshot(
                monotonicNow = json.optDouble("monotonicNow", 0.0),
                wallClockMs = parseWall(json.optString("wallClock")),
                rates =
                    FeedIncidentRates(
                        packetHz = rates.optDouble("packetHz"),
                        accessUnitHz = rates.optDouble("accessUnitHz"),
                        decodeSubmitHz = rates.optDouble("decodeSubmitHz"),
                        decodeAcceptHz = rates.optDouble("decodeAcceptHz"),
                        decodedOutputHz = rates.optDouble("decodedOutputHz"),
                        assistOutputHz = rates.optDouble("assistOutputHz"),
                        presentHz = rates.optDouble("presentHz"),
                        ackHz = rates.optDouble("ackHz"),
                        observed = rates.optJSONObject("observed")?.let(::observedRates),
                    ),
                ages =
                    FeedIncidentAges(
                        packetAge = ages.optDoubleOrNull("packetAge")?.takeIf { it >= 0.0 },
                        accessUnitAge = ages.optDoubleOrNull("accessUnitAge")?.takeIf { it >= 0.0 },
                        decodeAcceptAge = ages.optDoubleOrNull("decodeAcceptAge")?.takeIf { it >= 0.0 },
                        decodedOutputAge = ages.optDoubleOrNull("decodedOutputAge")?.takeIf { it >= 0.0 },
                        assistOutputAge = ages.optDoubleOrNull("assistOutputAge")?.takeIf { it >= 0.0 },
                        presentAge = ages.optDoubleOrNull("presentAge")?.takeIf { it >= 0.0 },
                        statusAge = ages.optDoubleOrNull("statusAge")?.takeIf { it >= 0.0 },
                    ),
                queue =
                    FeedIncidentQueue(
                        bytes = queue.optInt("bytes"),
                        count = queue.optInt("count"),
                        ageMilliseconds = queue.optDouble("ageMilliseconds"),
                        incompleteAccessUnits = queue.optInt("incompleteAccessUnits"),
                        drops = queue.optInt("drops"),
                    ),
                decoder =
                    FeedIncidentDecoder(
                        generation = decoder.optInt("generation"),
                        formatGeneration = decoder.optInt("formatGeneration"),
                        codec = decoder.optString("codec", "hevc"),
                        width = decoder.optInt("width"),
                        height = decoder.optInt("height"),
                        lastStatus = decoder.optIntOrNull("lastStatus"),
                        lastFlags = decoder.optLongOrNull("lastFlags"),
                        origin = FeedDecoderErrorOrigin.fromWire(decoder.optString("origin", "none")),
                        errorClass = decoder.optStringOrNull("errorClass"),
                        errorCall = decoder.optStringOrNull("errorCall"),
                        errorCount = decoder.optInt("errorCount"),
                        decoderFailed = decoder.optBoolean("decoderFailed"),
                        errorAge = decoder.optDoubleOrNull("errorAge"),
                        receivedIrap = decoder.optBoolean("receivedIrap"),
                        awaitingIrap = decoder.optBoolean("awaitingIrap"),
                        hasDecodableReferences = decoder.optBoolean("hasDecodableReferences", true),
                        lastIrapAge = decoder.optDoubleOrNull("lastIrapAge"),
                        lastSuccessfulOutputAge = decoder.optDoubleOrNull("lastSuccessfulOutputAge"),
                        rebuildReason = decoder.optStringOrNull("rebuildReason"),
                        firstError = firstError(decoder.optJSONObject("firstError")),
                    ),
                lifecycle =
                    FeedIncidentLifecycle(
                        foreground = life.optBoolean("foreground", true),
                        settingsCovered = life.optBoolean("settingsCovered"),
                        playbackActive = life.optBoolean("playbackActive"),
                        connected = life.optBoolean("connected"),
                        liveEstablished = life.optBoolean("liveEstablished"),
                        thermalState = life.optString("thermalState", "nominal"),
                        memoryWarning = life.optBoolean("memoryWarning"),
                        lowPower = life.optBoolean("lowPower"),
                        sceneActive = life.optBoolean("sceneActive", true),
                        assistState = life.optString("assistState", "off"),
                        outputObservable = life.optBoolean("outputObservable", true),
                        presentationExpected = life.optBoolean("presentationExpected", true),
                    ),
                watchdogAction = json.optString("watchdogAction", "none"),
                diagnoserFailure = json.optString("diagnoserFailure", "none"),
                diagnoserRepair = json.optString("diagnoserRepair", "none"),
                ingress = json.optJSONObject("ingress")?.let(::parseIngress),
                watchdogGate = json.optJSONObject("watchdogGate")?.let(::parseWatchdogGate),
            )
        }
    }

    private fun parseBreadcrumbs(array: JSONArray?): List<FeedIncidentBreadcrumb> {
        if (array == null) return emptyList()
        return (0 until array.length()).map {
            val json = array.getJSONObject(it)
            FeedIncidentBreadcrumb(
                monotonicAt = json.optDouble("monotonicAt"),
                kind = FeedIncidentBreadcrumbKind.fromWire(json.optString("kind")),
                detail = json.optString("detail"),
            )
        }
    }

    private fun parseRepairs(array: JSONArray?): List<FeedRepairRecord> {
        if (array == null) return emptyList()
        return (0 until array.length()).map {
            val json = array.getJSONObject(it)
            FeedRepairRecord(
                monotonicAt = json.optDouble("monotonicAt"),
                action = json.optString("action"),
                phase = FeedRepairPhase.fromWire(json.optString("phase")),
                reason = json.optStringOrNull("reason"),
            ).closed()
        }
    }

    private fun parseErrors(array: JSONArray?): List<FeedIncidentErrorCount> {
        if (array == null) return emptyList()
        return (0 until array.length()).map {
            val json = array.getJSONObject(it)
            FeedIncidentErrorCount(json.optString("errorClass"), json.optInt("count"))
        }
    }

    private fun parseWall(raw: String): Long =
        DiagnosticWire.parseIsoSeconds(raw)
            ?: raw.toLongOrNull()
            ?: 0L

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        val value = optString(key)
        return value.takeIf { it.isNotEmpty() && it != "null" }
    }

    private fun JSONObject.optIntOrNull(key: String): Int? =
        optLongOrNull(key)?.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()

    private fun JSONObject.optLongOrNull(key: String): Long? {
        val value = opt(key)
        return when (value) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
    }

    private fun JSONObject.optDoubleOrNull(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        val value = optDouble(key, Double.NaN)
        return value.takeIf { it.isFinite() }
    }
}
