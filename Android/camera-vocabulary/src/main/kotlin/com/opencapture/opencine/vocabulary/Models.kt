package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading

data class CameraModel(
    val name: String,
    val datalinkPort: Int = 9004,
    val tcpPoke: Boolean = false,
    val wpa3: Boolean = false,
    val verified: Boolean = false,
    val isDrone: Boolean = false,
    val pairingToken: String = "",
    val family: String = "other",
    val liveViewEnableReceiver: Int = 0x08,
    val usesNanoLiveViewGate: Boolean = false,
    val supportsTapFocus: Boolean = false,
    val supportsFocusMode: Boolean = false,
    val usesCapturedLiveEnable: Boolean = false,
    val needsFirstPictureFormatPoke: Boolean = false,
    val zoomStops: List<Double> = listOf(1.0),
    val hasGimbal: Boolean = false,
    val supportsZoom: Boolean = false,
    val sendsLiveViewPrepare: Boolean = false,
    val supportsAperture: Boolean = false,
    val captureProfile: CameraCaptureProfile? = null,
) {
    val zoomMax: Double get() = activeZoomStops().lastOrNull() ?: 1.0
    val isoAutoRangeFloor: Int? get() = captureProfile?.isoAutoRangeFloor

    fun activeZoomStops(resolutionCode: Int = -1, shootingMode: Int = -1): List<Double> =
        captureProfile?.zoom?.choices(VideoResolution.fromRaw(resolutionCode), shootingMode) ?: listOf(1.0)

    companion object {}
}

data class FoundCamera(
    val id: String,
    val address: String,
    val name: String,
    val model: CameraModel,
    val modelId: Int?,
)

/** Core `AutoExposureLock`: the Manual values an AE lock pinned. `isoIndex` is the wire byte. */
data class AutoExposureLock(val isoIndex: Int, val shutterDenom: Int, val shootingMode: Int)

data class CameraStatus(
    val batteryPercent: Int = -1,
    val batteryMilliVolts: Int = 0,
    val batteryMilliAmps: Int = 0,
    val docked: Boolean = false,
    val charging: Boolean = false,
    val storageTotalMb: Int = 0,
    val storageFreeMb: Int = 0,
    val sdTotalMb: Int = 0,
    val sdFreeMb: Int = 0,
    val internalTotalMb: Int = -1,
    val internalFreeMb: Int = -1,
    val inPlayback: Boolean = false,
    val firmware: String? = null,
    val isRecording: Boolean = false,
    val shootingMode: Int = -1,
    val recordElapsedSec: Int = 0,
    val recordRemainingSec: Int = 0,
    /** `timecode_info` (`@3-6` = HH MM SS FF) as the Swift decoder read it from the bytes. */
    @Deprecated("Use timecodeValue")
    val timecode: String? = null,
    val iso: Int = -1,
    val shutterDenom: Int = -1,
    val fps: Int = 0,
    /** `cam_expo_param` `@7`; `01` auto / `04` manual. `-1` unknown. */
    val expoMode: Int = -1,
    /** `cam_expo_param` `@5` ISO index (`00` Auto, `03`=100 … `0B`=25600). `-1` unknown. */
    val isoIndex: Int = -1,
    /** `cam_image_effect` `@2`; `3F` Normal, `3C` HDR, `17` D-Log, `41` D-Log2. `-1` unknown. */
    val colorMode: Int = -1,
    /** `cam_video_param_v2` `@0`; `0A` 1080p / `10` 4K. `-1` unknown. */
    val resolutionCode: Int = -1,
    /** `cam_video_param_v2` `@1` fps index. `-1` unknown. */
    val fpsIndex: Int = -1,
    /** `cam_image_effect` `@4`; `00` Auto / `06` Custom. `-1` unknown. */
    val wbMode: Int = -1,
    /** Last Custom Kelvin. Auto does not clear this. `-1` unknown. */
    val wbKelvin: Int = -1,
    val wbTint: Int = 0,
    /** Live Auto WB, `cam_image_effect` `@5` K/100 while Auto. `-1` unknown / not Auto. */
    val autoWbKelvin: Int = -1,
    /** `01` Single / `02` Continuous from `cam_lens_state` `@0` `B1`/`B2`. `-1` unknown. */
    val focusMode: Int = -1,
    /** `0x8E` pid `0x0020`; `01` Mono / `02` Stereo / `03` Spatial. `-1` unknown. */
    val audioChannel: Int = -1,
    /** Wind NR from audio DSP blob `@2` (`1A` on / `18` off). `-1` unknown. */
    val windNr: Int = -1,
    /** Directional from the same `@2` (`0` All / `1` Front / `2` Front+back). `-1` unknown. */
    val directionalAudio: Int = -1,
    /** Vocal Boost `0x8E` pid `0x004C`; `00` off / `01` on. `-1` unknown. */
    val vocalBoost: Int = -1,
    /** Last `0xA0` GET blob as lowercase hex. Empty means we have not GETted yet. */
    val audioDspBlob: String = "",
    /** Shared audio-DSP `@2`. `-1` unknown. */
    val audioDspAt2: Int = -1,
    /** `cam_fov` u32-LE `@0`. 0 = unknown. 12287 is operator 1×, not 12×. */
    val zoomFactorRaw: Int = 0,
    /** Legal 1/N denoms from `camcap_shutter`, camera order. */
    val availableShutterDenoms: List<Int> = emptyList(),
    /** Legal ISO indices from `camcap_iso`. */
    val availableIsoIndices: List<Int> = emptyList(),
    /** `cam_expo_param` `@6` EV raw (`0x10` = 0.0). `-1` unknown. */
    val evComp: Int = -1,
    /** Camera-meter indication at `cam_expo_param` `@15`; independent of configured EV `@6`. */
    val meteredEv: Int = -1,
    /** `0x8E` pid `0x000F` Auto ISO ceiling. `-1` unknown. */
    val isoLimit: Int = -1,
    /** Legal `0x02/0x42` values from `camcap_color_mode`. */
    val availableColorModes: List<Int> = emptyList(),
    /** Legal `0x02/0x18` pairs from `camcap_video_format`. Empty until that push. */
    val availableVideoFormats: List<VideoFormat> = emptyList(),
    /** AF point from `cam_lens_state`. 0.5, 0.5 until a tap. */
    val focusX: Double = 0.5,
    val focusY: Double = 0.5,
    val hasCameraFocusPoint: Boolean = false,
    /** `0x8E` pid `0x003B` AF-C track. `-1` unknown. */
    val focusTrack: Int = -1,
    /** `cam_lens_state` u16-LE `@14`. `-1` unknown. */
    val zoomLens: Int = -1,
    /** Hybrid zoom (1.0×…12×). Null until lens/`cam_fov` lands. */
    val zoomFactor: Double? = null,
    /** Last `0x8E` pid `0x0039` blob `@5` non-zero. Null unknown. */
    val glamourEnabled: Boolean? = null,
    /** `0x8E` pid `0x0038` (`00`/`01`). Control Center Selfie Flip. */
    val selfieFlip: Boolean? = null,
    /** `0x04/0x27` `@2` bit `0x40`. `0` front / `1` selfie / `-1` unknown. */
    val gimbalFace: Int = CameraCommands.GIMBAL_FACE_UNKNOWN,
    /** Pocket `0x04/0x05` mode family: 0 Direction Lock, 1 FPV, 2 Follow; -1 unknown. */
    val gimbalModeFamily: Int = -1,
    /** `0x04/0x50` param `04`. `0` Follow / `1` Tilt locked. `-1` unknown. */
    val gimbalTiltLock: Int = -1,
    /** `0x04/0x50` param `05`. `0` Fast / `1` Default / `2` Slow. `-1` unknown. */
    val gimbalSpeed: Int = -1,
    /** Live VU from `cam_audio_status_v2`, dBFS. Floor is −60. */
    val audioMetersLeft: Double = -60.0,
    val audioMetersRight: Double = -60.0,
    val audioPeakLeft: Double = -60.0,
    val audioPeakRight: Double = -60.0,
    /** The camera has sent `cam_audio_status_v2`; until then the meters above are unknown, not silence. */
    val audioMetersReported: Boolean = false,
    /** Action 6 iris, hundredths of an f-number (`cam_expo_param` `@13`). `-1` unknown. */
    val irisHundredths: Int = -1,
    /** Action 6 `cam_aperture_ctrl_strategy` ([ApertureStrategy]). `-1` unknown. */
    val apertureStrategy: Int = -1,
    /** Action 6 `camcap_aperture_ctrl_strategy`. Empty until pushed. */
    val availableApertureStrategies: List<Int> = emptyList(),
    private val decodedTimecode: CameraStatusTimecode? = null,
    /** Charging is unknown until a source actually reports it, including explicit false. */
    val chargingObservation: Boolean? = null,
    val chargingObservationDeclared: Boolean = false,
) {
    /** The charging fact: the declared report (null when the report was invalid), else the legacy
     *  flag only when it says charging. Never false from an absent report. */
    val chargingReading: Boolean? get() = if (chargingObservationDeclared) chargingObservation else true.takeIf { charging }


    /** Typed wire components. Only a legacy caller changing text enters the parsing boundary. */
    @Suppress("DEPRECATION")
    val timecodeValue: CameraTimecode?
        get() = timecodeReading?.frameTimecode

    /** Components including seconds-only text, without inventing a frame. */
    @Suppress("DEPRECATION")
    val timecodeReading: CameraTimecodeReading?
        get() = decodedTimecode?.takeIf { it.text == timecode }?.value ?: parseLegacyTimecode(timecode)

    /** Decode once, refreshing the original text API without disturbing generated field order. */
    fun withTimecodeValue(value: CameraTimecode?): CameraStatus {
        return withTimecodeReading(value?.let { CameraTimecodeReading(it) })
    }

    fun withTimecodeReading(value: CameraTimecodeReading?): CameraStatus {
        val decoded = value?.let(::CameraStatusTimecode)
        return copy(timecode = decoded?.text, decodedTimecode = decoded)
    }

    @Suppress("DEPRECATION")
    @Deprecated("Use timecodeValue and declared precision")
    val timecodeClock: String? get() = legacyTimecodeClock(timecode)
    val shootingModeLabel: String
        get() =
            CameraCommands.shootingModeLabel(shootingMode)
                ?: when (shootingMode) {
                    -1 -> if (inPlayback) "Playback" else "Capture"
                    else -> "0x%02X".format(shootingMode)
                }

    val expoLabel: String
        get() =
            when (expoMode) {
                CameraCommands.EXPO_AUTO -> "Auto"
                CameraCommands.EXPO_MANUAL -> "Manual"
                else -> "—"
            }

    val isoLabel: String
        get() =
            when {
                isoIndex == 0 -> "Auto"
                iso > 0 -> "$iso"
                else -> "—"
            }

    val shutterLabel: String
        get() = if (shutterDenom > 0) "1/$shutterDenom" else "—"

    val colorLabel: String
        get() = CameraCommands.colorLabel(colorMode)

    /** Still capture: Photo `05`/`17` and Live Photo `4D`. SuperNight is video. */
    val isPhoto: Boolean
        get() = CameraCommands.isPhotoMode(shootingMode)

    /** Live LUT/scope color. Photo/Live Photo is Rec.709 even if `@2` still reports log. */
    val monitorColorMode: Int
        get() = if (isPhoto) CameraCommands.COLOR_NORMAL else colorMode

    val resolutionLabel: String
        get() = CameraCommands.resolutionLabel(resolutionCode)

    val recFormatLabel: String
        get() = VideoFormat.chipLabel(this)

    val videoFormat: VideoFormat?
        get() = VideoFormat.parse(resolutionCode, fpsIndex)

    val wbLabel: String
        get() =
            when {
                wbMode == CameraCommands.WB_AUTO -> "Auto"
                wbKelvin > 0 -> "${wbKelvin}K"
                else -> "—"
            }

    val focusLabel: String
        get() = FocusOption.resolve(focusMode, focusTrack)?.chip ?: "—"

    val audioLabel: String
        get() = CameraCommands.audioChannelLabel(audioChannel) ?: "—"

    val hasHudFields: Boolean
        get() =
            expoMode >= 0 ||
                isoIndex >= 0 ||
                colorMode >= 0 ||
                resolutionCode >= 0 ||
                wbMode >= 0 ||
                focusMode >= 0 ||
                audioChannel >= 0 ||
                audioDspBlob.isNotEmpty() ||
                zoomFactorRaw > 0 ||
                evComp >= 0 ||
                meteredEv >= 0 ||
                isoLimit >= 0 ||
                availableColorModes.isNotEmpty() ||
                availableVideoFormats.isNotEmpty() ||
                hasCameraFocusPoint ||
                focusTrack >= 0 ||
                zoomLens >= 0 ||
                zoomFactor != null ||
                glamourEnabled != null ||
                selfieFlip != null

    @Deprecated("Use common storage observations and StorageReadout")
    val storageLabel: String get() = storageReadout?.label ?: StorageReadout.UNAVAILABLE

    fun clearedModeDependentCapabilities(): CameraStatus =
        copy(
            availableVideoFormats = emptyList(),
            availableShutterDenoms = emptyList(),
            availableIsoIndices = emptyList(),
            availableColorModes = emptyList(),
        )

    /**
     * Keep camcap wheels across the first unknown → mode report. A later mode
     * change must not resurrect the previous mode's ISO / shutter / color / FORMAT lists.
     */
    fun droppingStaleModeDependentCaps(previous: CameraStatus): CameraStatus {
        if (shouldPreserveModeDependentCaps(previous.shootingMode, shootingMode)) return this
        fun stale(current: List<*>, prior: List<*>): Boolean = current == prior && current.isNotEmpty()
        return copy(
            availableVideoFormats =
                if (stale(availableVideoFormats, previous.availableVideoFormats)) emptyList()
                else availableVideoFormats,
            availableShutterDenoms =
                if (stale(availableShutterDenoms, previous.availableShutterDenoms)) emptyList()
                else availableShutterDenoms,
            availableIsoIndices =
                if (stale(availableIsoIndices, previous.availableIsoIndices)) emptyList()
                else availableIsoIndices,
            availableColorModes =
                if (stale(availableColorModes, previous.availableColorModes)) emptyList()
                else availableColorModes,
        )
    }

    /** First unknown→mode keeps initial wheels; a later mode hop does not restore them. */
    fun mergingModeDependentCaps(previous: CameraStatus): CameraStatus {
        if (!shouldPreserveModeDependentCaps(previous.shootingMode, shootingMode)) {
            return droppingStaleModeDependentCaps(previous)
        }
        var next = this
        if (next.availableShutterDenoms.isEmpty()) {
            next = next.copy(availableShutterDenoms = previous.availableShutterDenoms)
        }
        if (next.availableIsoIndices.isEmpty()) {
            next = next.copy(availableIsoIndices = previous.availableIsoIndices)
        }
        if (next.availableColorModes.isEmpty()) {
            next = next.copy(availableColorModes = previous.availableColorModes)
        }
        if (next.availableVideoFormats.isEmpty()) {
            next = next.copy(availableVideoFormats = previous.availableVideoFormats)
        }
        return next
    }

    /**
     * `camcap_video_format` is per shooting mode. Keep a new table from this
     * apply; drop a leftover Video list when the mode changed without a fresh cap.
     */
    fun droppingStaleVideoFormats(previous: CameraStatus): CameraStatus =
        droppingStaleModeDependentCaps(previous)

    fun preservingExtras(prev: CameraStatus): CameraStatus =
        copy(
            expoMode = prev.expoMode,
            isoIndex = prev.isoIndex,
            colorMode = prev.colorMode,
            resolutionCode = prev.resolutionCode,
            fpsIndex = prev.fpsIndex,
            wbMode = prev.wbMode,
            wbKelvin = prev.wbKelvin,
            wbTint = prev.wbTint,
            autoWbKelvin = prev.autoWbKelvin,
            focusMode = prev.focusMode,
            audioChannel = prev.audioChannel,
            windNr = prev.windNr,
            directionalAudio = prev.directionalAudio,
            vocalBoost = prev.vocalBoost,
            audioDspBlob = prev.audioDspBlob,
            audioDspAt2 = prev.audioDspAt2,
            zoomFactorRaw = prev.zoomFactorRaw,
            availableShutterDenoms = prev.availableShutterDenoms,
            availableIsoIndices = prev.availableIsoIndices,
            evComp = prev.evComp,
            meteredEv = prev.meteredEv,
            isoLimit = prev.isoLimit,
            availableColorModes = prev.availableColorModes,
            availableVideoFormats = prev.availableVideoFormats,
            focusX = prev.focusX,
            focusY = prev.focusY,
            hasCameraFocusPoint = prev.hasCameraFocusPoint,
            focusTrack = prev.focusTrack,
            zoomLens = prev.zoomLens,
            zoomFactor = prev.zoomFactor,
            glamourEnabled = prev.glamourEnabled,
            selfieFlip = prev.selfieFlip,
            gimbalFace = prev.gimbalFace,
            audioMetersLeft = prev.audioMetersLeft,
            audioMetersRight = prev.audioMetersRight,
            audioPeakLeft = prev.audioPeakLeft,
            audioPeakRight = prev.audioPeakRight,
            audioMetersReported = prev.audioMetersReported,
        )

    /** The JNI status JSON does not carry the Action 6 aperture fields; keep them across it. */
    fun carryingAperture(prev: CameraStatus): CameraStatus =
        copy(
            irisHundredths = prev.irisHundredths,
            apertureStrategy = prev.apertureStrategy,
            availableApertureStrategies = prev.availableApertureStrategies,
        )

    companion object {
        fun shouldPreserveModeDependentCaps(previousMode: Int, nextMode: Int): Boolean =
            previousMode < 0 || previousMode == nextMode
    }
}


/** The typed decode and its compatibility text, computed together once at the wire boundary. */
data class CameraStatusTimecode(val value: CameraTimecodeReading) {
    internal val text: String? = com.opencapture.opencine.media.MonitorTimecodeFormat.label(
        value.hours, value.minutes, value.seconds, value.frames, value.dropFrame)
}

@Deprecated("Use the shared component formatter")
fun timecodeClock(value: String?): String? = legacyTimecodeClock(value)

private fun legacyTimecodeClock(value: String?): String? = value?.takeIf { it.isNotBlank() }?.let {
    val parts = it.split(':')
    if (parts.size >= 4) parts.take(3).joinToString(":") else it
}

private fun parseLegacyTimecode(value: String?): CameraTimecodeReading? {
    if (value == null) return null
    val parts = value.split(':', ';')
    if (parts.size !in 3..4) return null
    val numbers = parts.map { it.toIntOrNull() ?: return null }
    if (com.opencapture.opencine.media.MonitorTimecodeFormat.label(numbers[0], numbers[1], numbers[2], numbers.getOrNull(3)) == null) return null
    return CameraTimecodeReading(numbers[0], numbers[1], numbers[2], numbers.getOrNull(3), if (';' in value) true else null)
}
