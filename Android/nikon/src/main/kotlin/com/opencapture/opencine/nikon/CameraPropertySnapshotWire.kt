package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.vocabulary.ControlCapability

/** Stable semantic outcomes emitted by the Swift property-readback wire. */
enum class NativePropertyRefreshResult {
    ACCEPTED,
    NO_SESSION,
    MEDIA_BUSY,
    UNSUPPORTED,
    TRANSPORT_FAILED,
}

/** One decoded semantic property-refresh wire result. */
data class CameraPropertyRefreshWireResult(
    val result: NativePropertyRefreshResult,
    val snapshot: CameraPropertySnapshot,
    /** True only when the native payload had a parseable semantic result field. */
    val isValid: Boolean,
)

/**
 * Kotlin mirror of `AndroidCameraPropertyReadbackWire`.
 *
 * This parses only semantic names and already decoded values. It deliberately
 * contains no Nikon property identifiers, packet formats, or byte decoding.
 */
object CameraPropertySnapshotWire {
    fun decode(payload: String?): CameraPropertyRefreshWireResult {
        val fields = payload?.let(::fields)
        val result = fields?.let { result(it.optionalString("result")) }
        if (fields == null || result == null) {
            return CameraPropertyRefreshWireResult(
                NativePropertyRefreshResult.TRANSPORT_FAILED,
                CameraPropertySnapshot(),
                isValid = false,
            )
        }
        val snapshot = snapshot(fields)
        if (snapshot == null) {
            return CameraPropertyRefreshWireResult(
                NativePropertyRefreshResult.TRANSPORT_FAILED,
                CameraPropertySnapshot(),
                isValid = false,
            )
        }
        return CameraPropertyRefreshWireResult(
            result = result,
            snapshot = snapshot,
            isValid = true,
        )
    }

    private fun result(value: String?): NativePropertyRefreshResult? =
        when (value) {
            "accepted" -> NativePropertyRefreshResult.ACCEPTED
            "noSession" -> NativePropertyRefreshResult.NO_SESSION
            "mediaBusy" -> NativePropertyRefreshResult.MEDIA_BUSY
            "unsupported" -> NativePropertyRefreshResult.UNSUPPORTED
            "transportFailed" -> NativePropertyRefreshResult.TRANSPORT_FAILED
            else -> null
        }

    private fun snapshot(value: Map<String, String>): CameraPropertySnapshot? {
        val storage = storage(value) ?: return null
        val storageSlots = storageSlots(value) ?: return null
        return CameraPropertySnapshot(
            iso = value.optionalLong("iso"),
            baseIso = value.optionalString("baseIso"),
            isoAuto = value.optionalBoolean("isoAuto"),
            exposureMode = value.optionalString("exposureMode"),
            shutterMode = shutterMode(value.optionalString("shutterMode")),
            shutterLocked = value.optionalBoolean("shutterLocked"),
            shutterSpeed = value.optionalString("shutterSpeed"),
            shutterAngle = value.optionalString("shutterAngle"),
            iris = value.optionalString("iris"),
            whiteBalanceMode = value.optionalString("whiteBalanceMode"),
            stillWhiteBalanceMode = value.optionalString("stillWhiteBalanceMode"),
            whiteBalanceKelvin = value.optionalInt("whiteBalanceKelvin"),
            resolution = value.optionalString("resolution"),
            frameRate = value.optionalInt("frameRate"),
            codec = value.optionalString("codec"),
            tone = value.optionalString("tone"),
            resolutionFrameRate = value.optionalString("resolutionFrameRate"),
            codecSelection = value.optionalString("codecSelection"),
            codecBitDepth = value.optionalString("codecBitDepth"),
            movieTone = value.optionalString("movieTone"),
            whiteBalanceTint = value.optionalString("whiteBalanceTint"),
            batteryPercent = value.optionalInt("batteryPercent"),
            externalPower = value.optionalBoolean("externalPower"),
            warningRaw = value.optionalInt("warningRaw"),
            temperatureStatus = temperatureStatus(value.optionalString("temperatureStatus")),
            storage = storage.value,
            storageSlots = storageSlots,
            lens = value.optionalString("lens"),
            focalLength = value.optionalString("focalLength"),
            focusMode = value.optionalString("focusMode"),
            stillFocusMode = value.optionalString("stillFocusMode"),
            focusArea = value.optionalString("focusArea"),
            focusSubject = value.optionalString("focusSubject"),
            microphoneSensitivity = value.optionalString("microphoneSensitivity"),
            microphoneLevel = value.optionalString("microphoneLevel"),
            windFilter = value.optionalString("windFilter"),
            inputAttenuator = value.optionalString("inputAttenuator"),
            audioInput = value.optionalString("audioInput"),
            audioSensitivity = value.optionalString("audioSensitivity"),
            audio32BitFloat = value.optionalString("audio32BitFloat"),
            vibrationReduction = value.optionalString("vibrationReduction"),
            electronicVr = value.optionalString("electronicVr"),
            cameraGrid = value.optionalString("cameraGrid"),
            captureSelector = value.optionalString("captureSelector"),
            stillCaptureMode = value.optionalString("stillCaptureMode"),
            stillToneMode = value.optionalString("stillToneMode")?.takeIf { it == "SDR" || it == "HLG" },
            imageSize = value.optionalString("imageSize"),
            compression = value.optionalString("compression"),
            meteringMode = value.optionalString("meteringMode"),
            flashMode = value.optionalString("flashMode"),
            exposureBias = value.optionalString("exposureBias"),
            shotsRemaining = value.optionalInt("shotsRemaining"),
            imageArea = value.optionalString("imageArea"),
            rawCompression = value.optionalString("rawCompression"),
            userModeProgram = value.optionalString("userModeProgram"),
            pictureControl = value.optionalString("pictureControl"),
            evIndicatorSixths = value.optionalInt("evIndicatorSixths"),
            evIndicatorLit = value.optionalBoolean("evIndicatorLit"),
            autoExposurePoll = value.optionalBoolean("autoExposurePoll") == true,
            controlCapabilities =
                CameraControlCapabilities(
                    isoValues = value.options("options.iso"),
                    shutterValues = value.options("options.shutter"),
                    irisValues = value.options("options.iris"),
                    advertisedIrisValues = value.options("options.advertisedIris"),
                    whiteBalanceValues = value.options("options.whiteBalance"),
                    focusModes = value.options("options.focusMode"),
                    focusAreas = value.options("options.focusArea"),
                    focusSubjects = value.options("options.focusSubject"),
                    audioSensitivities = value.options("options.audioSensitivity"),
                    audioInputs = value.options("options.audioInput"),
                    windFilters = value.options("options.windFilter"),
                    attenuators = value.options("options.attenuator"),
                    audio32BitFloat = value.options("options.audio32BitFloat"),
                    baseIso = value.options("options.baseIso"),
                    shutterModes = value.options("options.shutterMode"),
                    shutterLocks = value.options("options.shutterLock"),
                    whiteBalanceTints = value.options("options.whiteBalanceTint"),
                    resolutionFrameRates = value.options("options.resolutionFrameRate"),
                    codecs = value.options("options.codec"),
                    vibrationReduction = value.options("options.vibrationReduction"),
                    electronicVr = value.options("options.electronicVr"),
                    imageSizes = value.options("options.imageSize"),
                    exposureModes = value.options("options.exposureMode"),
                    userModePrograms = value.options("options.userModeProgram"),
                    driveModes = value.options("options.drive"),
                    meteringModes = value.options("options.metering"),
                    pictureControls = value.options("options.pictureControl"),
                    rawCompressions = value.options("options.rawCompression"),
                    codecBitDepths = value.codecBitDepths("options.codecBitDepth"),
                    movieTones = value.options("options.movieTone"),
                    movieToneEditable = value.optionalBoolean("movieToneEditable") == true,
                    recordingFormats = value.recordingFormats("options.recordingFormat"),
                    vibrationReductionDescriptor = value.descriptor("descriptor.vibrationReduction"),
                    electronicVrDescriptor = value.descriptor("descriptor.electronicVr"),
                ),
        )
    }

    private fun Map<String, String>.descriptor(key: String): NikonDescriptorEvidence =
        NikonDescriptorEvidence(
            observation = descriptorObservation(key),
            latestAttempt = descriptorObservation(key, prefix = "latest"),
            lastValidObservation = descriptorObservation(key, prefix = "lastValid").takeIf {
                it.outcome == NikonDescriptorReadOutcome.DESCRIBED &&
                    it.form != NikonDescriptorForm.UNKNOWN && it.capability.support == SupportStatus.SUPPORTED
            },
            optionOrigin = when (get("$key.origin")) {
                "descriptor" -> NikonDescriptorOptionOrigin.DESCRIPTOR
                "legacyFallback" -> NikonDescriptorOptionOrigin.LEGACY_FALLBACK
                else -> NikonDescriptorOptionOrigin.UNKNOWN
            },
        )

    private fun Map<String, String>.descriptorObservation(
        key: String, prefix: String = "",
    ): NikonDescriptorObservation {
        // Each attempt owns its metadata, even when its outcome matches the retained generation.
        fun field(name: String): String = "$key." + if (prefix.isEmpty()) name else prefix + name.replaceFirstChar { it.uppercase() }
        val form = when (get(field("form"))) {
            "none" -> NikonDescriptorForm.NONE
            "range" -> NikonDescriptorForm.RANGE
            "enumeration" -> NikonDescriptorForm.ENUMERATION
            else -> NikonDescriptorForm.UNKNOWN
        }
        val access = when (get(field("access"))) {
            "readOnly" -> SettingAccess.READ_ONLY
            "readWrite" -> SettingAccess.READ_WRITE
            else -> null
        }
        val choices = if (form == NikonDescriptorForm.ENUMERATION) {
            get(field("choices"))?.split(OPTION_SEPARATOR)?.filter(String::isNotBlank)?.distinct()
        } else null
        val capability: ControlCapability<List<String>> = when (get(field("support"))) {
            "supported" -> if (access != null) ControlCapability.supported(choices, access) else ControlCapability.unknown()
            "unsupported" -> ControlCapability.unsupported()
            else -> ControlCapability.unknown()
        }
        return NikonDescriptorObservation(
            outcome = descriptorOutcome(get(field("outcome"))),
            capability = capability,
            form = form,
            operation = get(field("operation")),
            response = optionalInt(field("response"))?.takeIf { it in 0..65_535 },
        )
    }

    private fun descriptorOutcome(value: String?): NikonDescriptorReadOutcome = when (value) {
        "notAttempted" -> NikonDescriptorReadOutcome.NOT_ATTEMPTED
        "pending" -> NikonDescriptorReadOutcome.PENDING
        "described" -> NikonDescriptorReadOutcome.DESCRIBED
        "missing" -> NikonDescriptorReadOutcome.MISSING
        "unsupported" -> NikonDescriptorReadOutcome.UNSUPPORTED
        "rejected" -> NikonDescriptorReadOutcome.REJECTED
        "malformed" -> NikonDescriptorReadOutcome.MALFORMED
        "transportFailed" -> NikonDescriptorReadOutcome.TRANSPORT_FAILED
        "mediaBusy" -> NikonDescriptorReadOutcome.MEDIA_BUSY
        else -> NikonDescriptorReadOutcome.UNKNOWN
    }

    private data class OptionalStorage(val value: CameraStorageStatus?)

    /** Strictly decodes the legacy first-card fields as one atomic pair. */
    private fun storage(value: Map<String, String>): OptionalStorage? {
        val hasTotal = "storageTotalCapacityBytes" in value
        val hasFree = "storageFreeSpaceBytes" in value
        if (!hasTotal && !hasFree) return OptionalStorage(null)
        if (hasTotal != hasFree) return null
        val total = value["storageTotalCapacityBytes"]?.toLongOrNull() ?: return null
        val free = value["storageFreeSpaceBytes"]?.toLongOrNull() ?: return null
        if (total < 0 || free < 0 || (total > 0 && free > total)) return null
        return OptionalStorage(CameraStorageStatus(totalCapacityBytes = total, freeSpaceBytes = free))
    }

    /**
     * Strictly decodes one complete indexed slot generation or rejects it atomically.
     * Slot numbers are the PHYSICAL body slots; strictly increasing but possibly
     * gapped (a lone card in slot 2 arrives as slot 2), never re-derived from index.
     */
    private fun storageSlots(value: Map<String, String>): List<CameraStorageSlotStatus>? {
        val indexedKeys = value.keys.filter { it.startsWith(STORAGE_SLOT_PREFIX) }.toSet()
        val countText = value[STORAGE_SLOT_COUNT]
        if (countText == null) {
            return emptyList<CameraStorageSlotStatus>().takeIf { indexedKeys.isEmpty() }
        }
        val count =
            countText.toIntOrNull()?.takeIf { it in 0..MAXIMUM_STORAGE_SLOT_COUNT }
                ?: return null
        val expectedKeys =
            (0 until count).flatMapTo(linkedSetOf()) { index ->
                val prefix = "$STORAGE_SLOT_PREFIX$index"
                listOf(
                    "$prefix.storageId",
                    "$prefix.slotNumber",
                    "$prefix.totalCapacityBytes",
                    "$prefix.freeSpaceBytes",
                )
            }
        if (indexedKeys != expectedKeys) return null

        val seenStorageIds = mutableSetOf<Long>()
        var previousSlotNumber = 0
        return (0 until count).map { index ->
            val prefix = "$STORAGE_SLOT_PREFIX$index"
            val storageId =
                value["$prefix.storageId"]?.toLongOrNull()
                    ?.takeIf { it in 1..MAXIMUM_USABLE_STORAGE_ID } ?: return null
            val slotNumber =
                value["$prefix.slotNumber"]?.toIntOrNull()
                    ?.takeIf { it > previousSlotNumber } ?: return null
            previousSlotNumber = slotNumber
            val total =
                value["$prefix.totalCapacityBytes"]?.toLongOrNull()
                    ?.takeIf { it >= 0 } ?: return null
            val free =
                value["$prefix.freeSpaceBytes"]?.toLongOrNull()
                    ?.takeIf { it >= 0 && (total == 0L || it <= total) } ?: return null
            if (!seenStorageIds.add(storageId)) return null
            CameraStorageSlotStatus(
                storageId = storageId,
                slotNumber = slotNumber,
                totalCapacityBytes = total,
                freeSpaceBytes = free,
            )
        }
    }

    private fun shutterMode(value: String?): CameraShutterMode? =
        when (value) {
            "speed" -> CameraShutterMode.SPEED
            "angle" -> CameraShutterMode.ANGLE
            else -> null
        }

    private fun temperatureStatus(value: String?): CameraTemperatureStatus? =
        when (value) {
            "OK" -> CameraTemperatureStatus.NORMAL
            "CHECK" -> CameraTemperatureStatus.WARNING
            "HOT" -> CameraTemperatureStatus.HOT
            else -> null
        }

    private fun fields(payload: String): Map<String, String>? {
        val fields = linkedMapOf<String, String>()
        for (line in payload.lineSequence()) {
            val separator = line.indexOf('\t')
            if (separator <= 0) return null
            val key = line.substring(0, separator)
            val value = line.substring(separator + 1)
            if (fields.put(key, value) != null) return null
        }
        return fields.takeIf { "result" in it }
    }

    private fun Map<String, String>.optionalString(key: String): String? = get(key)

    private fun Map<String, String>.optionalLong(key: String): Long? = get(key)?.toLongOrNull()

    private fun Map<String, String>.optionalInt(key: String): Int? =
        optionalLong(key)?.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()

    private fun Map<String, String>.optionalBoolean(key: String): Boolean? =
        when (get(key)) {
            "true" -> true
            "false" -> false
            else -> null
        }

    private fun Map<String, String>.options(key: String): List<String> =
        get(key)
            ?.split(OPTION_SEPARATOR)
            ?.filter(String::isNotBlank)
            ?.distinct()
            .orEmpty()

    private const val OPTION_SEPARATOR: Char = '\u001F'
    /**
     * `row`/`caption`/`writeValue` triples from `options.codecBitDepth`, separated by U+001E
     * inside each U+001F-separated option. Anything that is not a complete triple is dropped
     * rather than half-decoded; a depth button must always know the exact advertised label it
     * writes.
     */
    private fun Map<String, String>.codecBitDepths(key: String): List<CodecBitDepthOption> =
        options(key).mapNotNull { entry ->
            val parts = entry.split(FIELD_SEPARATOR)
            if (parts.size != 3 || parts.any(String::isBlank)) {
                null
            } else {
                CodecBitDepthOption(codec = parts[0], label = parts[1], writeValue = parts[2])
            }
        }

    /** Grouping is transported as source-decoded axes; labels are never parsed to recover facts. */
    private fun Map<String, String>.recordingFormats(key: String): List<NikonRecordingFormatPresentation> =
        options(key).mapNotNull { entry ->
            val parts = entry.split(FIELD_SEPARATOR)
            if (parts.size != 4 || parts[0].isBlank()) null else
                NikonRecordingFormatPresentation(parts[0], parts[1].takeIf(String::isNotBlank),
                    parts[2].takeIf(String::isNotBlank), parts[3].takeIf(String::isNotBlank))
        }

    /** Record separator between the fields of one `options.codecBitDepth` entry. */
    private val FIELD_SEPARATOR: Char = Char(0x1E)
    private const val STORAGE_SLOT_COUNT: String = "storageSlotCount"
    private const val STORAGE_SLOT_PREFIX: String = "storageSlot."
    private const val MAXIMUM_STORAGE_SLOT_COUNT: Int = 32
    private const val MAXIMUM_USABLE_STORAGE_ID: Long = 4_294_967_294L
}
