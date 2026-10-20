package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLabelProfile
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureWheels
import com.opencapture.opencine.vocabulary.EvComp
import com.opencapture.opencine.vocabulary.IsoLimit
import com.opencapture.opencine.vocabulary.ShutterAngle
import com.opencapture.opencine.vocabulary.StorageReadout
import com.opencapture.opencine.vocabulary.VideoAspect
import com.opencapture.opencine.vocabulary.VideoFormat
import com.opencapture.opencine.vocabulary.VideoFrameRate
import com.opencapture.opencine.vocabulary.VideoResolution
import com.opencapture.opencine.vocabulary.storageReadout
import kotlin.math.roundToInt

object CaptureLists {
    /** iOS `ExpoMode.allCases.map(\.label)` — MODE sheet rows. */
    val expoLabels: List<String> = listOf("Auto", "Manual")

    fun expoLabel(mode: Int): String =
        when (mode) {
            CameraCommands.EXPO_AUTO -> "Auto"
            CameraCommands.EXPO_MANUAL -> "Manual"
            else -> "—"
        }

    fun expoSelectedLabel(mode: Int): String? = expoLabel(mode).takeIf { it in expoLabels }

    /** iOS `CaptureLists.aeLock`: EXPOSURE tile and drum entry left of Auto while AE-L holds. */
    const val AE_LOCK = "AE-L"

    fun expoLabels(aeLocked: Boolean): List<String> = if (aeLocked) listOf(AE_LOCK) + expoLabels else expoLabels

    fun expoSelectedLabel(mode: Int, aeLocked: Boolean): String? = if (aeLocked) AE_LOCK else expoSelectedLabel(mode)

    fun expoModeFromLabel(label: String): Int? =
        when (label) {
            "Auto" -> CameraCommands.EXPO_AUTO
            "Manual" -> CameraCommands.EXPO_MANUAL
            else -> null
        }

    /** iOS `isEvSheet`: shutter sheet becomes EV while expo is Auto. */
    fun isEvSheet(sheet: LiveSheet, expoMode: Int): Boolean =
        sheet == LiveSheet.SHUTTER && expoMode == CameraCommands.EXPO_AUTO

    fun isAngleSheet(
        sheet: LiveSheet,
        expoMode: Int,
        selectedMode: Int,
        shootingMode: Int = CameraCommands.SHOOT_VIDEO,
    ): Boolean =
        sheet == LiveSheet.SHUTTER &&
            !isEvSheet(sheet, expoMode) &&
            selectedMode == 1 &&
            !CameraCommands.isPhotoMode(shootingMode)

    /** iOS onChange expoMode: restore Speed/Angle from prefs when leaving Auto. */
    fun shutterTabAfterExpoChange(
        expoMode: Int,
        shutterUsesAngle: Boolean,
        shootingMode: Int = CameraCommands.SHOOT_VIDEO,
    ): Int? =
        if (expoMode != CameraCommands.EXPO_AUTO) {
            if (shutterUsesAngle && !CameraCommands.isPhotoMode(shootingMode)) 1 else 0
        } else {
            null
        }

    fun headerTitle(
        sheet: LiveSheet,
        expoMode: Int,
        shootingMode: Int = CameraCommands.SHOOT_VIDEO,
    ): String =
        when {
            sheet == LiveSheet.SHUTTER -> shutterHeaderTitle(isEvSheet(sheet, expoMode))
            sheet == LiveSheet.FORMAT && CameraCommands.isPhotoMode(shootingMode) -> "FORMAT"
            else -> sheet.headerLabel
        }

    fun headerSubtitle(
        sheet: LiveSheet,
        expoMode: Int,
        selectedMode: Int,
        facePriority: Boolean,
        shootingMode: Int = CameraCommands.SHOOT_VIDEO,
    ): String =
        when {
            sheet == LiveSheet.SHUTTER && !isEvSheet(sheet, expoMode) ->
                if (CameraCommands.isPhotoMode(shootingMode)) "Speed" else sheet.subtitle
            sheet == LiveSheet.SHUTTER ->
                shutterHeaderSubtitle(
                    isEvSheet(sheet, expoMode),
                    isAngleSheet(sheet, expoMode, selectedMode, shootingMode),
                    facePriority,
                )
            sheet == LiveSheet.FORMAT && CameraCommands.isPhotoMode(shootingMode) -> PHOTO_FORMAT_READOUT
            else -> sheet.subtitle
        }

    fun modeTabs(sheet: LiveSheet, expoMode: Int, offersIsoAuto: Boolean): List<String> =
        modeTabs(sheet, CameraStatus(expoMode = expoMode), offersIsoAuto)

    fun modeTabs(
        sheet: LiveSheet,
        status: CameraStatus,
        offersIsoAuto: Boolean,
        selectedAspect: VideoAspect? = null,
    ): List<String> =
        when {
            sheet == LiveSheet.ISO && offersIsoAuto -> listOf("Auto", "Manual")
            sheet == LiveSheet.SHUTTER ->
                shutterModeTabs(isEvSheet(sheet, status.expoMode), status.shootingMode)
            sheet == LiveSheet.WB -> CaptureLists.wbTabs
            sheet == LiveSheet.AUDIO -> CaptureLists.audioTabs
            sheet == LiveSheet.FORMAT ->
                if (CameraCommands.isPhotoMode(status.shootingMode)) emptyList()
                else formatResolutions(status, selectedAspect).map { it.tabTitle }
            else -> emptyList()
        }

    fun formatAspects(status: CameraStatus): List<VideoAspect> =
        VideoFormat.aspects(
            status.availableVideoFormats,
            VideoResolution.fromRaw(status.resolutionCode)?.aspect,
        )

    fun formatResolutions(
        status: CameraStatus,
        selectedAspect: VideoAspect? = null,
    ): List<VideoResolution> {
        if (CameraCommands.isPhotoMode(status.shootingMode)) return emptyList()
        val current = VideoResolution.fromRaw(status.resolutionCode)
        if (!formatPickerEditable(status)) {
            val aspect = selectedAspect
            return listOfNotNull(current).filter { aspect == null || it.aspect == aspect }
        }
        val aspect = if (formatAspects(status).size > 1) selectedAspect else null
        return VideoFormat.resolutions(
            status.availableVideoFormats,
            current,
            aspect,
        )
    }

    fun formatRates(status: CameraStatus, resolution: VideoResolution): List<VideoFrameRate> =
        VideoFormat.frameRates(
            status.availableVideoFormats,
            resolution,
            (VideoFormat.parse(status.resolutionCode, status.fpsIndex)?.frameRate ?: VideoFrameRate.fromFps(status.fps)),
            status.shootingMode,
        )

    fun effectiveVideoFormats(status: CameraStatus, model: CameraModel?): List<VideoFormat> {
        if (CameraCommands.isPhotoMode(status.shootingMode)) return emptyList()
        return VideoFormat.pickerFormats(status.availableVideoFormats, model, status.shootingMode)
    }

    fun withEffectiveVideoFormats(status: CameraStatus, model: CameraModel?): CameraStatus =
        status.copy(availableVideoFormats = effectiveVideoFormats(status, model))

    const val PHOTO_FORMAT_READOUT = "Photo"

    fun formatPickerEditable(status: CameraStatus, model: CameraModel? = null): Boolean {
        if (CameraCommands.isPhotoMode(status.shootingMode)) return false
        return effectiveVideoFormats(status, model).isNotEmpty()
    }

    fun formatDrumLabels(
        status: CameraStatus,
        tab: Int,
        selectedAspect: VideoAspect? = null,
    ): List<String> =
        if (CameraCommands.isPhotoMode(status.shootingMode)) listOf(PHOTO_FORMAT_READOUT)
        else fpsDrumLabels(status, tab, selectedAspect)

    fun fpsDrumLabels(status: CameraStatus, tab: Int, selectedAspect: VideoAspect? = null): List<String> {
        val res =
            formatResolutions(status, selectedAspect).getOrNull(tab)
                ?: VideoResolution.fromRaw(status.resolutionCode) ?: return emptyList()
        return formatRates(status, res).map { it.drumLabel }
    }

    fun nextVideoFormat(
        status: CameraStatus,
        tab: Int,
        drum: String,
        fromDrum: Boolean,
        selectedAspect: VideoAspect? = null,
    ): VideoFormat? {
        if (!formatPickerEditable(status)) return null
        val resolutions = formatResolutions(status, selectedAspect)
        val res = resolutions.getOrNull(tab) ?: return null
        val rates = formatRates(status, res)
        val parsed = VideoFrameRate.fromDrumLabel(drum)
        val rate =
            when {
                fromDrum -> parsed?.takeIf { it in rates } ?: return null
                parsed != null && parsed in rates -> parsed
                else -> rates.firstOrNull() ?: return null
            }
        val next = VideoFormat(res, rate)
        return next.takeIf { it != VideoFormat.current(status) }
    }

    val audioTabs: List<String> = listOf("Channel", "Wind", "Dir", "Vocal")
    val audioChannelLabels: List<String> = listOf("Stereo", "Mono", "Spatial")
    val audioWindLabels: List<String> = listOf("Off", "On")
    val audioDirLabels: List<String> = listOf("All", "Front", "Front+back")
    val audioVocalLabels: List<String> = listOf("Off", "On")

    fun audioChannelLabel(value: Int): String? = CameraCommands.audioChannelLabel(value)

    fun audioChannelValue(label: String): Int? =
        when (label) {
            "Mono" -> CameraCommands.AUDIO_MONO
            "Stereo" -> CameraCommands.AUDIO_STEREO
            "Spatial" -> CameraCommands.AUDIO_SPATIAL
            else -> null
        }

    fun audioWindLabel(value: Int): String? =
        when (value) {
            0 -> "Off"
            1 -> "On"
            else -> null
        }

    fun audioDirLabel(value: Int): String? = CameraCommands.audioDirLabel(value)

    fun audioDirValue(label: String): Int? =
        when (label) {
            "All" -> 0
            "Front" -> 1
            "Front+back" -> 2
            else -> null
        }

    fun audioVocalLabel(value: Int): String? =
        when (value) {
            0 -> "Off"
            1 -> "On"
            else -> null
        }

    /** iOS `seed` AUDIO: Channel tab + `refreshAudioState`. */
    fun audioInitialTab(): Int = 0

    fun shouldRefreshAudio(sheet: LiveSheet): Boolean = sheet == LiveSheet.AUDIO

    const val FACE_PRIORITY_TITLE = "Face Priority"
    const val FACE_PRIORITY_HELP =
        "On: EV follows faces to middle gray. Several faces use the median. First couple of seconds after a face appears are faster, then about 1 s. Off: put EV back to what it was, or 0.0."
    const val NATIVE_ISO_HOP_TITLE = "Auto Native ISO"
    const val NATIVE_ISO_HOP_HELP =
        "On: switching D-Log ↔ D-Log2 hops ISO to that curve's starred native if you were still on native. Off: keep the ISO you set."

    val evLabels: List<String> = EvComp.allCases.map { it.label }

    /** Core `WhiteBalance.kelvinLadder`; AWB lock snaps to it in the core. */
    val kelvinValues: List<Int> = (2_000..10_000 step 100).toList()
    val kelvinLabels: List<String> = kelvinValues.map { "${it}K" }
    val wbTabs: List<String> = listOf("Mode", "Kelvin", "Tint")
    val wbModeRows: List<String> = listOf("Auto", "Custom")
    /** iOS `CaptureLists.awbLock`: WB Mode drum entry left of Auto. */
    const val AWB_LOCK = "AWB Lock"
    /** iOS `CaptureLists.awbLockTile`: WB tile while locked; `AWB Lock` would outgrow `10000K`. */
    const val AWB_LOCK_TILE = "AWB-L"

    /** iOS `whiteBalanceModeLabels`: AWB Lock left of Auto when offered or held. */
    fun wbModeRows(offersLock: Boolean): List<String> = if (offersLock) listOf(AWB_LOCK) + wbModeRows else wbModeRows
    const val WB_TAB_MODE = 0
    const val WB_TAB_KELVIN = 1
    const val WB_TAB_TINT = 2

    val fpsDrumLabels: List<String> get() = VideoFrameRate.drumLabels


    fun shutterDenoms(status: CameraStatus): List<Int> =
        CameraCommands.shutterWheelDenoms(status.availableShutterDenoms, status.shutterDenom)

    fun shutterLabel(denom: Int): String = "1/$denom"

    fun shutterLabels(status: CameraStatus): List<String> = shutterDenoms(status).map(::shutterLabel)

    fun denomFromLabel(label: String): Int? = label.removePrefix("1/").toIntOrNull()

    fun nearestDenom(current: Int, denoms: List<Int>): Int? = CaptureWheels.nearestDenom(current, denoms)

    fun nearestShutterLabel(label: String, status: CameraStatus): String {
        val denoms = shutterDenoms(status)
        val denom = denomFromLabel(label)
        val near = if (denom != null) nearestDenom(denom, denoms) else denoms.firstOrNull()
        return if (near != null) shutterLabel(near) else denoms.firstOrNull()?.let(::shutterLabel).orEmpty()
    }

    fun isEvSheet(expoMode: Int): Boolean = expoMode == CameraCommands.EXPO_AUTO

    fun isAngleSheet(expoMode: Int, selectedMode: Int, shootingMode: Int = CameraCommands.SHOOT_VIDEO): Boolean =
        !isEvSheet(expoMode) && selectedMode == 1 && !CameraCommands.isPhotoMode(shootingMode)

    fun shutterModeTabs(
        isEvSheet: Boolean,
        shootingMode: Int = CameraCommands.SHOOT_VIDEO,
    ): List<String> =
        if (isEvSheet || CameraCommands.isPhotoMode(shootingMode)) emptyList()
        else listOf("Speed", "Angle")

    fun shutterHeaderTitle(isEvSheet: Boolean): String = if (isEvSheet) "EV" else "SHUTTER"

    fun shutterHeaderSubtitle(
        isEvSheet: Boolean,
        isAngleSheet: Boolean,
        facePriority: Boolean,
    ): String =
        when {
            isEvSheet -> if (facePriority) "Face priority" else "Compensation"
            isAngleSheet -> "Angle"
            else -> "Speed"
        }

    fun shutterWheelOptions(
        status: CameraStatus,
        isEvSheet: Boolean,
        isAngleSheet: Boolean,
    ): List<String> =
        when {
            isEvSheet -> evLabels
            isAngleSheet -> ShutterAngle.labels
            else -> shutterLabels(status)
        }

    data class ShutterSeat(
        val selection: String,
        val preferredAngle: Double = ShutterAngle.DEFAULT_DEGREES,
        val persistAngle: Boolean = false,
    )

    sealed class ShutterDrumCommand {
        data class SetEv(val thirds: Int) : ShutterDrumCommand()
        data class SetShutter(val denom: Int) : ShutterDrumCommand()
        data class SetAngle(val degrees: Double, val denom: Int) : ShutterDrumCommand()
        data object Ignored : ShutterDrumCommand()
    }

    enum class ShutterReseatKey {
        AVAILABLE_DENOMS,
        FPS,
        EXPO_MODE,
        EV_COMP,
        FACE_PRIORITY,
        SHUTTER_DENOM,
    }

    /** iOS `CapturePickerPanel` onChange keys. Never reseat on live 1/N ticks. */
    fun shouldReseatShutter(key: ShutterReseatKey, isEvSheet: Boolean): Boolean =
        when (key) {
            ShutterReseatKey.AVAILABLE_DENOMS, ShutterReseatKey.FPS -> !isEvSheet
            ShutterReseatKey.EXPO_MODE -> true
            ShutterReseatKey.EV_COMP, ShutterReseatKey.FACE_PRIORITY -> isEvSheet
            ShutterReseatKey.SHUTTER_DENOM -> false
        }

    fun reseatEv(status: CameraStatus): ShutterSeat {
        val labels = evLabels
        val live = EvComp.fromRaw(status.evComp)?.label ?: "0.0"
        val next = if (live in labels) live else "0.0"
        return ShutterSeat(next)
    }

    fun reseatShutterSpeed(status: CameraStatus): ShutterSeat {
        val labels = shutterLabels(status)
        val live =
            if (status.shutterDenom > 0) shutterLabel(status.shutterDenom)
            else labels.firstOrNull().orEmpty()
        val next = if (live in labels) live else nearestShutterLabel(live, status)
        return ShutterSeat(next)
    }

    /** The angle drum holds the operator's angle while the camera holds it or a change is [settling]. */
    fun reseatShutterAngle(status: CameraStatus, preferredAngle: Double, settling: Boolean = false): ShutterSeat {
        val labels = ShutterAngle.labels
        val fps = status.fps
        val liveDenom = status.shutterDenom
        val preferred = ShutterAngle.label(preferredAngle)
        if (liveDenom > 0) {
            val mapped = ShutterAngle.denom(preferredAngle, fps, shutterDenoms(status))
            if ((mapped == liveDenom || settling) && preferred in labels) {
                return ShutterSeat(preferred, preferredAngle, persistAngle = false)
            }
            val next = ShutterAngle.nearestLabel(liveDenom, fps)
            return ShutterSeat(next, preferredAngle, persistAngle = false)
        }
        return ShutterSeat(preferred, preferredAngle, persistAngle = false)
    }

    fun reseatShutter(
        status: CameraStatus,
        selectedMode: Int,
        isEvSheet: Boolean,
        preferredAngle: Double,
        settling: Boolean = false,
    ): ShutterSeat =
        if (selectedMode == 1 && !isEvSheet) {
            reseatShutterAngle(status, preferredAngle, settling)
        } else {
            reseatShutterSpeed(status)
        }

    fun applyShutterDrum(
        value: String,
        isEvSheet: Boolean,
        isAngleSheet: Boolean,
        facePriority: Boolean,
        status: CameraStatus,
    ): ShutterDrumCommand {
        if (value.isEmpty()) return ShutterDrumCommand.Ignored
        if (isEvSheet) {
            if (facePriority) return ShutterDrumCommand.Ignored
            val ev = EvComp.fromLabel(value) ?: return ShutterDrumCommand.Ignored
            return ShutterDrumCommand.SetEv(ev.thirds)
        }
        if (isAngleSheet) {
            val degrees = ShutterAngle.parse(value) ?: return ShutterDrumCommand.Ignored
            val denom = ShutterAngle.denom(degrees, status.fps, shutterDenoms(status))
            return ShutterDrumCommand.SetAngle(degrees, denom)
        }
        val denom = denomFromLabel(value) ?: return ShutterDrumCommand.Ignored
        if (denom !in shutterDenoms(status)) return ShutterDrumCommand.Ignored
        return ShutterDrumCommand.SetShutter(denom)
    }

    /** iOS `CameraSession.setVideoFormat` angle rematch. Null = no shutter write. */
    fun rematchShutterDenomAfterFps(
        usesAngle: Boolean,
        degrees: Double,
        previousFps: Int,
        nextFps: Int,
        expoMode: Int,
        currentDenom: Int,
        available: List<Int>,
    ): Int? {
        if (!usesAngle || expoMode == CameraCommands.EXPO_AUTO || previousFps == nextFps) return null
        val denom = ShutterAngle.denom(degrees, nextFps, available)
        return denom.takeIf { it != currentDenom }
    }

    fun isoFallback(colorMode: Int): List<Int> = CaptureWheels.isoFallback(colorMode)

    /** Photo must not reuse leftover Video color for Auto ISO / fallback wheels. */
    fun isoPresentationColor(status: CameraStatus): Int = CaptureWheels.isoPresentationColor(status)

    fun isoIndices(status: CameraStatus): List<Int> = CaptureWheels.isoIndices(status)

    fun isoDrumLabels(status: CameraStatus): List<String> =
        isoIndices(status)
            .filter { it != 0 }
            .map { CameraCommands.isoLabel(it) }
            .filter { it != "—" }

    fun isoIndexFromLabel(label: String): Int? =
        CameraCommands.ISO_INDEX_BYTES.firstOrNull { CameraCommands.isoLabel(it) == label }

    fun offersIsoAuto(status: CameraStatus): Boolean = CaptureWheels.offersIsoAuto(status)

    /** GET `0x8E` pid `0x000F` only when Auto ISO exists. Unknown color = Normal. */
    fun shouldGetIsoLimit(status: CameraStatus): Boolean =
        CameraCommands.shouldGetIsoLimit(isoPresentationColor(status))

    fun isoAutoBase(colorMode: Int, bodyName: String = "", isoAutoRangeFloor: Int? = null): Int? =
        when (colorMode) {
            CameraCommands.COLOR_DLOG2 -> null
            CameraCommands.COLOR_DLOG -> 400
            else -> isoAutoRangeFloor
        }

    fun isoAutoLimits(colorMode: Int): List<IsoLimit> =
        when (colorMode) {
            CameraCommands.COLOR_DLOG2 -> emptyList()
            CameraCommands.COLOR_DLOG ->
                listOf(IsoLimit.Max800, IsoLimit.Max1600, IsoLimit.Max3200, IsoLimit.Max6400)
            else ->
                listOf(
                    IsoLimit.Max200,
                    IsoLimit.Max400,
                    IsoLimit.Max800,
                    IsoLimit.Max1600,
                    IsoLimit.Max3200,
                    IsoLimit.Max6400,
                    IsoLimit.Max12800,
                    IsoLimit.Max25600,
                )
        }

    fun isoAutoLabels(status: CameraStatus, bodyName: String = "", isoAutoRangeFloor: Int? = null): List<String> {
        val color = isoPresentationColor(status)
        val base = isoAutoBase(color, bodyName, isoAutoRangeFloor) ?: return emptyList()
        return isoAutoLimits(color).map { it.label(base) }
    }

    fun isoAutoLabel(status: CameraStatus, bodyName: String = "", isoAutoRangeFloor: Int? = null): String {
        val color = isoPresentationColor(status)
        val base = isoAutoBase(color, bodyName, isoAutoRangeFloor) ?: return ""
        val limit = IsoLimit.entries.firstOrNull { it.rawValue == status.isoLimit } ?: return ""
        return limit.label(base)
    }

    fun isoLimit(fromLabel: String, status: CameraStatus, bodyName: String = "", isoAutoRangeFloor: Int? = null): IsoLimit? {
        val color = isoPresentationColor(status)
        val base = isoAutoBase(color, bodyName, isoAutoRangeFloor) ?: return null
        return isoAutoLimits(color).firstOrNull { it.label(base) == fromLabel }
    }

    fun isoMarkedLabels(status: CameraStatus): Set<String> {
        if (CameraCommands.isPhotoMode(status.shootingMode)) return emptySet()
        val base = CameraCommands.markedIsoLabel(status.colorMode) ?: return emptySet()
        return setOf(base)
    }

    fun currentKelvin(status: CameraStatus): Int {
        val k = status.wbKelvin
        return if (k in 2_000..10_000) k else 5_600
    }

    fun currentTint(status: CameraStatus): Int = status.wbTint.coerceIn(-100, 100)

    fun kelvinFromLabel(label: String): Int? = label.removeSuffix("K").toIntOrNull()

    /** AWB Lock is a Mode choice, not an active Kelvin. */
    fun wbInitialTab(status: CameraStatus, awbLocked: Boolean = false): Int =
        if (status.wbMode == CameraCommands.WB_CUSTOM && !awbLocked) WB_TAB_KELVIN else WB_TAB_MODE

    fun wbModeRowSelected(status: CameraStatus, awbLocked: Boolean = false): String =
        if (awbLocked) AWB_LOCK else if (status.wbMode == CameraCommands.WB_CUSTOM) "Custom" else "Auto"

    fun wbSendsAuto(label: String): Boolean = label == "Auto"

    fun wbDrumSelection(status: CameraStatus): String {
        val k = "${currentKelvin(status)}K"
        return if (k in kelvinLabels) k else "5600K"
    }

    fun wbCustomFromStatus(status: CameraStatus): Pair<Int, Int> =
        currentKelvin(status) to currentTint(status)

    fun wbCustomFromKelvinLabel(label: String, status: CameraStatus): Pair<Int, Int>? {
        val kelvin = kelvinFromLabel(label) ?: return null
        return kelvin to currentTint(status)
    }

    fun wbKelvinDrumApply(selectedMode: Int, value: String, status: CameraStatus): Pair<Int, Int>? {
        if (selectedMode != WB_TAB_KELVIN) return null
        return wbCustomFromKelvinLabel(value, status)
    }

    fun roundedTint(value: Float): Int = value.roundToInt().coerceIn(-100, 100)

    fun tintLabel(tint: Int): String {
        val t = tint.coerceIn(-100, 100)
        if (t == 0) return "Neutral"
        return if (t > 0) "+$t" else "$t"
    }

    fun wbCustomFromTint(tint: Float, status: CameraStatus): Pair<Int, Int> =
        currentKelvin(status) to roundedTint(tint)

    fun wbTintStaysAuto(status: CameraStatus): Boolean =
        status.wbMode != CameraCommands.WB_CUSTOM

    fun fpsDrumLabel(status: CameraStatus): String = (VideoFormat.parse(status.resolutionCode, status.fpsIndex)?.frameRate ?: VideoFrameRate.fromFps(status.fps))?.drumLabel.orEmpty()

    fun currentFpsIndex(status: CameraStatus): Int? = (VideoFormat.parse(status.resolutionCode, status.fpsIndex)?.frameRate ?: VideoFrameRate.fromFps(status.fps))?.rawValue

    /**
     * Angle mode is ours: keep the chosen degrees and rewrite 1/N for the new fps.
     * Returns the denom to SET, or null when nothing should change.
     */
    fun shutterDenomAfterFormatChange(
        previousFps: Int,
        nextFps: Int,
        expoMode: Int,
        shutterUsesAngle: Boolean,
        angleDegrees: Double,
        currentDenom: Int,
        available: List<Int>,
    ): Int? {
        if (!shutterUsesAngle || previousFps == nextFps || expoMode == CameraCommands.EXPO_AUTO) {
            return null
        }
        val denom = ShutterAngle.denom(angleDegrees, nextFps, available)
        return denom.takeIf { it != currentDenom }
    }

    fun colorWheelOrder(name: String, family: String, profile: CameraLabelProfile = CameraLabelProfile.standard): List<Pair<Int, String>> =
        CaptureWheels.colorWheelOrder(name, family, profile)

    fun colorWheel(
        family: String,
        available: List<Int> = emptyList(),
        name: String = "",
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): List<Pair<Int, String>> = CaptureWheels.colorWheel(family, available, name, profile)

    fun shootingModeLabels(name: String?, shootingMode: Int = -1, profile: CameraLabelProfile = CameraLabelProfile.standard): List<String> {
        val labels =
            CameraCommands.shootingModeCarousel(profile).map {
                CameraCommands.shootingModeLabel(it, name, profile).orEmpty()
            }
        val live = CameraCommands.shootingModeLabel(shootingMode, name, profile) ?: return labels
        if (shootingMode != CameraCommands.SHOOT_LIVE_PHOTO || live in labels) return labels
        val photoIdx = labels.indexOf("Photo")
        return if (photoIdx >= 0) {
            labels.take(photoIdx + 1) + live + labels.drop(photoIdx + 1)
        } else {
            labels + live
        }
    }

    fun shootingModeRaw(label: String, name: String?, profile: CameraLabelProfile = CameraLabelProfile.standard): Int? {
        if (label == "Live Photo") return null
        val modes = CameraCommands.shootingModeCarousel(profile)
        val labels = modes.map { CameraCommands.shootingModeLabel(it, name, profile).orEmpty() }
        val index = labels.indexOf(label)
        if (index < 0) return null
        return modes.getOrNull(index)
    }

    fun colorWheelLabels(
        status: CameraStatus,
        family: String = "pocket",
        name: String = "",
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): List<String> =
        // The drum keeps the reported current mode the body list lacks; [applyColorDrum] never sends it.
        CaptureWheels.colorDrum(colorWheel(family, status.availableColorModes, name, profile), status.colorMode, family, profile)
            .map { it.second }

    fun colorModeFromLabel(label: String, family: String = "pocket", name: String = "", profile: CameraLabelProfile = CameraLabelProfile.standard): Int? {
        val codes = profile.colorModes ?: listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_HDR,
            CameraCommands.COLOR_DLOG, CameraCommands.COLOR_DLOG2, CameraCommands.COLOR_NORMAL10,
            CameraCommands.COLOR_DLOG_M, CameraCommands.COLOR_ILOG, CameraCommands.COLOR_DOLBY_VISION)
        return codes.firstOrNull { CameraCommands.colorLabel(it, family, profile) == label }
    }

    /**
     * COLOR drum: body wheel only, then hop ISO after the color SET — same
     * order as iOS `CameraSession.setColorMode` + `CamCapIso.nativeISOHop`.
     */
    fun applyColorDrum(
        label: String,
        family: String,
        status: CameraStatus,
        hopEnabled: Boolean,
        name: String = "",
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): ColorDrumCommand? {
        val mode = colorModeFromLabel(label, family, name, profile) ?: return null
        val allowed = colorWheel(family, status.availableColorModes, name, profile).map { it.first }
        if (mode !in allowed) return null
        val hop =
            nativeIsoHop(
                from = status.colorMode,
                to = mode,
                currentIndex = status.isoIndex,
                hopEnabled = hopEnabled,
            )
        return ColorDrumCommand(mode, hop)
    }

    /**
     * If the operator is still on [from]'s native ISO, hop to [to]'s native.
     * Off-base or Auto stays put. Rec.709 / HDR have no native — no hop.
     */
    fun nativeIsoHop(from: Int, to: Int, currentIndex: Int, hopEnabled: Boolean): Int? =
        CameraCommands.nativeIsoHop(from, to, currentIndex, hopEnabled)

    /** Top-deck chip. Photo keeps the slot with a still readout, not leftover video fps. */
    fun recFormatChipLabel(status: CameraStatus): String =
        if (CameraCommands.isPhotoMode(status.shootingMode)) PHOTO_FORMAT_READOUT
        else VideoFormat.chipLabel(status)

    /** Remaining storage through the shared [StorageReadout] and its volume rule, or the remaining minutes. */
    fun storageLabel(status: CameraStatus, showDuration: Boolean): String {
        if (showDuration && !CameraCommands.isPhotoMode(status.shootingMode)) {
            return com.opencapture.monitorui.MonitorStorageReadoutFormat.remainingMinutes(
                status.recordRemainingSec.takeIf { it > 0 }?.div(60))
        }
        return status.storageReadout?.label ?: StorageReadout.UNAVAILABLE
    }

    fun isoChipValue(status: CameraStatus): String =
        when {
            status.isoIndex == 0 -> "Auto"
            status.iso > 0 -> "${status.iso}"
            status.isoIndex > 0 -> CameraCommands.isoLabel(status.isoIndex)
            else -> "—"
        }

    fun wbChipValue(status: CameraStatus, awbLocked: Boolean = false): String =
        if (awbLocked) AWB_LOCK_TILE else when (status.wbMode) {
            CameraCommands.WB_CUSTOM -> if (status.wbKelvin > 0) "${status.wbKelvin}K" else "Custom"
            CameraCommands.WB_AUTO -> "Auto"
            else -> "—"
        }

    /** iOS aperture glyph when mode is not custom (Auto and unknown). */
    fun wbIsAuto(status: CameraStatus): Boolean =
        status.wbMode != CameraCommands.WB_CUSTOM

    const val FOCUS_TAB_SINGLE = "AF-S"
    const val FOCUS_TAB_CONTINUOUS = "AF-C"

    /** Action 6 APERTURE choices: the camera's capability, else the captured fallback. */
    fun apertureLabels(status: CameraStatus): List<String> =
        ApertureStrategy.choices(status).mapNotNull(ApertureStrategy::label)

    fun apertureFromLabel(label: String): Int? =
        (ApertureStrategy.F2..ApertureStrategy.AUTO).firstOrNull { ApertureStrategy.label(it) == label }

    /** iOS `focusMode == .continuous`. Unknown / AF-S is the AF-S tab. */
    fun focusIsContinuous(status: CameraStatus): Boolean =
        status.focusMode == CameraCommands.FOCUS_CONTINUOUS

    /** Horizontal AF-C chips only while continuous, matching iOS `if continuous`. */
    fun focusShowsTrackChips(status: CameraStatus): Boolean = focusIsContinuous(status)

    /** GET `0x8E` pid `0x003B` when FOCUS opens without a track. Nano never GETs. */
    fun shouldRefreshFocusTrack(status: CameraStatus, supportsFocus: Boolean): Boolean =
        supportsFocus && status.focusTrack < 0

    /** Unknown support is not an admission to send focus commands. */
    fun supportsFocusMode(modelName: String?, family: String? = null, flag: Boolean? = null): Boolean =
        flag == true

    fun supportsFocusMode(model: CameraModel): Boolean = model.captureProfile?.supportsFocusMode == true

    fun supportsFocusModeOrDefault(model: CameraModel?): Boolean = model?.captureProfile?.supportsFocusMode == true
}
