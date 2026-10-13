package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.MonitorQuickControl
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLabelProfile
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.EvComp
import com.opencapture.opencine.vocabulary.GamepadShutterSync
import com.opencapture.opencine.vocabulary.VideoFormat

/** One native option list for the persistent picker and the readout preview. */
object CaptureFocusChoices {
    /** The standard focus list; a session's own list is its [CameraLabelProfile.focusLabels], in drum order. */
    val labels: List<String> = CameraLabelProfile.standard.focusLabels
    fun selection(status: CameraStatus, labels: List<String> = this.labels): String = when (status.focusMode) {
        CameraCommands.FOCUS_SINGLE -> "AF-S"
        CameraCommands.FOCUS_CONTINUOUS -> labels.getOrNull(status.focusTrack + 1)
            ?.takeIf { status.focusTrack in 0..3 }.orEmpty()
        else -> ""
    }
    fun track(label: String): Int? = when (label) {
        "AF-C" -> 0
        "Showcase" -> 1
        "Lock" -> 2
        "Priority" -> 3
        else -> null
    }
}

fun captureQuickFocusControl(status: CameraStatus, labels: List<String> = CaptureFocusChoices.labels) =
    MonitorQuickControl(
    labels,
    CaptureFocusChoices.selection(status, labels),
    context = "${status.focusMode}:${status.focusTrack}",
)

fun applyCaptureFocusChoice(label: String, status: CameraStatus,
    setFocusMode: (Boolean) -> Unit, setFocusTrack: (Int) -> Unit, labels: List<String> = CaptureFocusChoices.labels) {
    if (label !in labels || label == CaptureFocusChoices.selection(status, labels)) return
    if (label == "AF-S") setFocusMode(false)
    else CaptureFocusChoices.track(label)?.let { track ->
        if (!CaptureLists.focusIsContinuous(status)) setFocusMode(true)
        if (status.focusTrack != track) setFocusTrack(track)
    }
}

/** Shared full-picker and quick-release boundary: never change shooting mode during a take. */
fun applyCaptureShootingMode(value: String, status: CameraStatus, bodyName: String?,
    profile: CameraLabelProfile = CameraLabelProfile.standard, send: (Int) -> Unit) {
    if (status.isRecording) return
    CaptureLists.shootingModeRaw(value, bodyName, profile)?.let(send)
}

/** Same primary drum the persistent FORMAT / COLOR / MODE pickers use. */
fun recordingCategoryQuickControl(
    sheet: LiveSheet,
    status: CameraStatus,
    bodyName: String = "",
    family: String = "pocket",
    profile: CameraLabelProfile = CameraLabelProfile.standard,
    cameraModel: CameraModel? = null,
): MonitorQuickControl? =
    when (sheet) {
        LiveSheet.FORMAT -> {
            if (CameraCommands.isPhotoMode(status.shootingMode)) {
                MonitorQuickControl(
                    listOf(CaptureLists.PHOTO_FORMAT_READOUT),
                    CaptureLists.PHOTO_FORMAT_READOUT,
                    enabled = false,
                    context = "photo:${status.shootingMode}",
                )
            } else {
                val formatStatus = CaptureLists.withEffectiveVideoFormats(
                    status, cameraModel,
                )
                val resolution = com.opencapture.opencine.vocabulary.VideoResolution.fromRaw(formatStatus.resolutionCode)
                val aspect = resolution?.aspect
                val tab = CaptureLists.formatResolutions(formatStatus, aspect).indexOf(resolution).coerceAtLeast(0)
                val options = CaptureLists.fpsDrumLabels(formatStatus, tab, aspect)
                if (resolution == null || options.isEmpty()) null
                else {
                    val live = CaptureLists.fpsDrumLabel(formatStatus)
                    MonitorQuickControl(
                        options, if (live in options) live else "",
                        enabled = CaptureLists.formatPickerEditable(formatStatus),
                        context = "${resolution.rawValue}:${status.shootingMode}:${options.joinToString()}",
                    )
                }
            }
        }
        LiveSheet.COLOR -> {
            if (CameraCommands.isPhotoMode(status.shootingMode)) null
            else {
                val options = CaptureLists.colorWheelLabels(status, family, bodyName, profile)
                if (options.isEmpty()) null
                else {
                    val live = CameraCommands.colorLabel(status.colorMode, family, profile)
                    MonitorQuickControl(
                        options, if (live in options) live else "",
                        context = "$family:${options.joinToString()}:${status.isRecording}",
                    )
                }
            }
        }
        LiveSheet.MODE -> {
            val options = CaptureLists.shootingModeLabels(bodyName, status.shootingMode, profile)
            val live = CameraCommands.shootingModeLabel(status.shootingMode, bodyName, profile).orEmpty()
            MonitorQuickControl(options, if (live in options) live else "", enabled = !status.isRecording,
                context = "${status.shootingMode}:$bodyName:${status.isRecording}")
        }
        else -> null
    }

/** Angle HUD: preferred only when it maps to live 1/N, else the nearest live label. */
fun captureShutterReadout(
    status: CameraStatus,
    shutterUsesAngle: Boolean,
    preferredAngle: Double,
): String {
    if (status.expoMode == CameraCommands.EXPO_AUTO) {
        return EvComp.fromRaw(status.evComp)?.label ?: "—"
    }
    if (shutterUsesAngle && !CameraCommands.isPhotoMode(status.shootingMode)) {
        if (status.shutterDenom <= 0) return "—"
        return GamepadShutterSync.angleLabel(
            status.shutterDenom,
            status.fps,
            CaptureLists.shutterDenoms(status),
            preferredAngle,
        )
    }
    return if (status.shutterDenom > 0) CaptureLists.shutterLabel(status.shutterDenom) else "—"
}

/** Last synchronous boundary before the existing setter; no delayed command can escape this check. */
fun commitCaptureQuickControl(expected: MonitorQuickControl, current: MonitorQuickControl?,
    value: String, enabled: Boolean, send: () -> Unit) {
    if (enabled && expected == current && expected.enabled && value in expected.options && value != expected.selection) send()
}

/** A remount, lifecycle interruption, or connection phase transition invalidates every old pointer. */
class CaptureQuickLifetime {
    var active by mutableStateOf(false)
        private set
    var epoch by mutableLongStateOf(0L)
        private set
    fun update(active: Boolean) {
        if (this.active != active) { this.active = active; invalidate() }
    }
    fun invalidate() { epoch++ }
}

/** Mount/reseat work has no authority to write while showing a held preview. */
/** A camera GET a capture sheet asks for when it opens. */
enum class CaptureRefresh { AUDIO, FOCUS_TRACK, ISO_LIMIT }

class CapturePanelEffects(private val preview: Boolean) {
    fun run(action: () -> Unit) { if (!preview) action() }

    suspend fun mount(sheet: LiveSheet, status: CameraStatus, supportsFocus: Boolean,
        refresh: suspend (CaptureRefresh) -> Unit, seed: () -> Unit, reseatIso: () -> Unit,
        ceilingSupported: Boolean = true) {
        if (preview) return
        if (CaptureLists.shouldRefreshAudio(sheet)) refresh(CaptureRefresh.AUDIO)
        if (sheet == LiveSheet.FOCUS && CaptureLists.shouldRefreshFocusTrack(status, supportsFocus)) refresh(CaptureRefresh.FOCUS_TRACK)
        seed()
        if (sheet == LiveSheet.ISO && ceilingSupported && CaptureLists.shouldGetIsoLimit(status)) {
            refresh(CaptureRefresh.ISO_LIMIT)
            reseatIso()
        }
    }
}
