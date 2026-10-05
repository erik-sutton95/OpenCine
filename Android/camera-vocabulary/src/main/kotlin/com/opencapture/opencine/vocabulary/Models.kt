package com.opencapture.opencine.vocabulary

data class CameraModel(
    val name: String,
    val datalinkPort: Int = 9004,
    val tcpPoke: Boolean = true,
    val wpa3: Boolean = false,
    val verified: Boolean = false,
    val isDrone: Boolean = false,
    val pairingToken: String = "osmo",
    /** `"pocket"` / `"nano"` / `"other"`. Missing JSON defaults to Pocket. */
    val family: String = "pocket",
    /** `0x09/0xa8` receiver. Pocket `0x08`; Nano `0x41`. */
    val liveViewEnableReceiver: Int = 0x08,
    val usesNanoLiveViewGate: Boolean = false,
    val supportsTapFocus: Boolean = true,
    val supportsFocusMode: Boolean = true,
    val usesCapturedLiveEnable: Boolean = true,
    /** Pocket 3 first picture: SET 1080 then boot 4K. Not Pocket 4. */
    val needsFirstPictureFormatPoke: Boolean = false,
    /** Video-mode chip cycle. 4 Pro 1/3/6/12; Pocket 4/3 1/2/4; Nano 1. */
    val zoomStops: List<Double> = listOf(1.0, 2.0, 4.0),
    /** Portable `CameraModel.hasGimbal`. Pocket 3-axis gimbal; Nano has none. */
    val hasGimbal: Boolean = family == "pocket",
    /** Portable `CameraModel.supportsZoom`. Nano is a fixed 1× prime. */
    val supportsZoom: Boolean = family == "pocket",
    /** Pocket `0x02/0x68 08` before `0x09/0xa8`. Not Nano (own gate), not Action 6. */
    val sendsLiveViewPrepare: Boolean = !usesNanoLiveViewGate && !looksLikeAction6(name),
    /** Action 6 aperture strategy (`0x8E` pid `0x44`) and iris readback. */
    val supportsAperture: Boolean = looksLikeAction6(name),
) {
    val zoomMax: Double get() = activeZoomStops().lastOrNull() ?: 1.0

    val isoAutoRangeFloor: Int get() = Companion.isoAutoRangeFloorFor(name)

    /**
     * Chip cycle for this body, current FORMAT, and shooting mode.
     * SlowMo / TimeLapse / SuperNight lock digital zoom (Pro keeps 1×/3×).
     *
     * Pocket 3 is per-FORMAT: the ceiling follows the capture size class, so
     * 1080 keeps 1×/2×/4× while 2.7K and 2160 1:1 stop at 3× and 4K and 3K 1:1
     * stop at 2×; see [VideoResolution.pocket3ZoomMax]. With no FORMAT known
     * yet, offer the body's absolute range.
     */
    fun activeZoomStops(resolutionCode: Int = -1, shootingMode: Int = -1): List<Double> {
        val n = name.lowercase().replace(" ", "")
        val isPro = n.contains("pocket4p") || n.contains("4pro")
        val isPocket4 = n.contains("pocket4")
        val isPocket3 = n.contains("pocket3") || n.contains("muse")
        val digitalLocked =
            shootingMode == CameraCommands.SHOOT_SLOWMO ||
                shootingMode == CameraCommands.SHOOT_TIMELAPSE ||
                shootingMode == CameraCommands.SHOOT_SUPER_NIGHT
        if (isPro) return if (digitalLocked) listOf(1.0, 3.0) else listOf(1.0, 3.0, 6.0, 12.0)
        if (digitalLocked) return listOf(1.0)
        if (isPocket4) return listOf(1.0, 2.0, 4.0)
        if (isPocket3) {
            return when (VideoResolution.fromRaw(resolutionCode)?.pocket3ZoomMax) {
                2.0 -> listOf(1.0, 2.0)
                3.0 -> listOf(1.0, 2.0, 3.0)
                else -> listOf(1.0, 2.0, 4.0)
            }
        }
        if (family != "pocket") return listOf(1.0)
        return zoomStops.ifEmpty { listOf(1.0, 2.0, 4.0) }
    }

    companion object {
        val default = CameraModel(name = "DJI Osmo camera")

        fun looksLikePocket3(name: String): Boolean {
            val n = name.lowercase().replace(" ", "")
            return n.contains("pocket3") || n.contains("muse")
        }

        fun looksLikePocket4Pro(name: String): Boolean {
            val n = name.lowercase().replace(" ", "")
            return n.contains("pocket4p")
        }

        /** SlowMo `0x02/0x18` trailer context. Regular Pocket 4 stays unqualified. */
        fun supportsSlowMoFormatTrailer(name: String): Boolean =
            looksLikePocket3(name) || looksLikePocket4Pro(name)

        /** Osmo Action 6 (BLE `0x0018`). Handbook `devices/action-6/`. */
        fun looksLikeAction6(name: String): Boolean =
            name.lowercase().replace(" ", "").contains("action6")

        fun looksLikeNano(name: String, family: String = ""): Boolean {
            if (family == "nano") return true
            return name.lowercase().contains("nano")
        }

        /**
         * Rec.709 / HDR / D-Log M Auto ISO range floor. Pocket 3 and Pocket 4
         * start at 50 (DJI spec; #180). Pocket 4 Pro wide is 100 (captured
         * `camcap_iso_auto_max`). Unknown bodies keep 100.
         */
        fun isoAutoRangeFloorFor(name: String): Int {
            val n = name.lowercase().replace(" ", "")
            if (n.contains("pocket4p") || n.contains("4pro")) return 100
            if (n.contains("pocket4") || n.contains("pocket3") || n.contains("muse")) return 50
            return 100
        }

        /** DJI color wheel. D-Log2 is Pocket 4 Pro only. Pocket 3 is HLG / D-Log M. */
        fun colorModesFor(name: String, family: String): List<Int> {
            if (family == "nano") {
                return listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M)
            }
            if (looksLikeAction6(name)) {
                return listOf(CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M)
            }
            val n = name.lowercase().replace(" ", "")
            if (n.contains("pocket4p") || n.contains("4pro")) {
                return listOf(
                    CameraCommands.COLOR_NORMAL,
                    CameraCommands.COLOR_HDR,
                    CameraCommands.COLOR_DLOG,
                    CameraCommands.COLOR_DLOG2,
                )
            }
            if (n.contains("pocket4")) {
                return listOf(
                    CameraCommands.COLOR_NORMAL,
                    CameraCommands.COLOR_HDR,
                    CameraCommands.COLOR_DLOG,
                )
            }
            if (n.contains("pocket3") || n.contains("muse")) {
                return listOf(
                    CameraCommands.COLOR_NORMAL,
                    CameraCommands.COLOR_HDR,
                    CameraCommands.COLOR_DLOG_M,
                )
            }
            return listOf(
                CameraCommands.COLOR_NORMAL,
                CameraCommands.COLOR_HDR,
                CameraCommands.COLOR_DLOG,
            )
        }

        fun zoomStopsFor(name: String, family: String): List<Double> {
            val n = name.lowercase().replace(" ", "")
            if (n.contains("pocket4p") || n.contains("4pro")) return listOf(1.0, 3.0, 6.0, 12.0)
            if (n.contains("pocket4") || n.contains("pocket3") || n.contains("muse")) {
                return listOf(1.0, 2.0, 4.0)
            }
            return if (family == "pocket") listOf(1.0, 2.0, 4.0) else listOf(1.0)
        }

    }
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
) {
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

    /** Display-only clock; the raw timecode retains its frame field for protocol/state. */
    val timecodeClock: String? get() = timecodeClock(timecode)

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

    val storageLabel: String
        get() {
            val total = if (sdTotalMb > 0) sdTotalMb else storageTotalMb
            val free = if (sdTotalMb > 0) sdFreeMb else storageFreeMb
            if (total <= 0) return "—"
            val gb = free / 1024
            val pct = ((free.toLong() * 100L) / total).toInt().coerceIn(0, 100)
            return "$gb GB · $pct%"
        }

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

/** Shared by the single-camera and Multiview readouts; never rewrites decoded status. */
fun timecodeClock(value: String?): String? = value?.takeIf { it.isNotBlank() }?.let {
    val parts = it.split(':')
    if (parts.size >= 4) parts.take(3).joinToString(":") else it
}
