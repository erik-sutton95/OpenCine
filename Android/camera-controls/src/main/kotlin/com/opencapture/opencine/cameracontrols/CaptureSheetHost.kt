package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.MonitorCapturePreferences
import com.opencapture.opencine.vocabulary.CameraLabelProfile
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoice
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.CaptureSessionState
import com.opencapture.opencine.vocabulary.CaptureSetting

/** App routing is independent of source support declarations. */
data class CaptureSheetRouting(
    val commonExposureCompensation: Boolean = false,
    val commonFocusMode: Boolean = false,
)

/**
 * What the capture sheets need from an app: mostly values, one commit entry and one refresh entry,
 * plus the drum an app draws for settings it edits through Core. App differences arrive here as
 * values, never as brand branches.
 */
interface CaptureSheetHost {
    /** A native typed body borrows the shared sheet chrome; absent means existing controls. */
    @Composable fun nativeCapturePanel(sheet: LiveSheet, enabled: Boolean): (@Composable () -> Unit)? = null

    /** Coherent native quick choices retain real backend identifiers in the app adapter. */
    fun nativeCaptureQuick(sheet: LiveSheet, status: CameraStatus): com.opencapture.monitorui.MonitorQuickControl? = null
    fun commitNativeCaptureQuick(sheet: LiveSheet, selection: String) {}

    /**
     * What the one codec and colour popup lists: the codec choices the camera offers (none when it
     * has none) and the colour choices valid for the selected codec. The default is a camera
     * without codec choices: the colour modes it offers, by their shown label.
     */
    fun recordingCodecColor(status: CameraStatus): CaptureCodecColorChoices {
        val family = camera?.family ?: "pocket"
        val labels = CaptureLists.colorWheelLabels(status, family, camera?.name.orEmpty(), labelProfile)
        return CaptureCodecColorChoices(
            colors = labels.map { CaptureCodecColorChoice(it, it) },
            selectedColor = CameraCommands.colorLabel(status.colorMode, family, labelProfile),
        )
    }

    /** Sends the codec choice [id] (a [recordingCodecColor] codec identity). */
    fun commitRecordingCodec(id: String) {}

    /** The connected body, or null before one is known. */
    val camera: CameraModel?
    val labelProfile: CameraLabelProfile
    /** Existing hosts retain their pending readout policy; report-only hosts declare it. */
    val captureReadoutSelection: com.opencapture.opencine.appkit.MonitorCaptureSelection get() = com.opencapture.opencine.appkit.MonitorCaptureSelection.PENDING
    val audioService: CaptureAudioService? get() = null
    /** Compatibility route for original hosts; migrated composition supplies it explicitly. */
    val captureRouting: CaptureSheetRouting get() = CaptureSheetRouting(commonExposureCompensation = true, commonFocusMode = true)

    /** The common Core field a sheet edits, opened (and its editor captured) when the sheet opens. */
    fun captureField(sheet: LiveSheet, expoMode: Int): MonitorCaptureField?

    /** Locks, format pin and session capabilities, observed for this composition. */
    @Composable fun captureSessionState(status: CameraStatus): CaptureSessionState

    val capturePreferences: MonitorCapturePreferences
    fun updateCapturePreferences(value: MonitorCapturePreferences)

    /**
     * Sends [setting] to the camera along the app's own path. [field] is the Core field the sheet
     * opened (stale editors are refused), [status] the report the sheet showed.
     */
    fun commit(setting: CaptureSetting, field: MonitorCaptureField?, status: CameraStatus)

    /** The camera GET a sheet asks for on open; ISO limit returns once the reply arrived. */
    suspend fun refresh(what: CaptureRefresh)

    /**
     * The drum for a setting edited through Core (ISO, shutter, white balance Kelvin) and for EV,
     * where an app may draw its own wheel from [wheel] instead.
     */
    @Composable fun CommonDrum(sheet: LiveSheet, status: CameraStatus, field: MonitorCaptureField?,
        enabled: Boolean, wheel: CaptureWheelState)
}

/** A sheet drum's shown value and its settled-value callback, for a host that draws its own wheel. */
class CaptureWheelState(val selection: String, val onSelect: (String) -> Unit)
