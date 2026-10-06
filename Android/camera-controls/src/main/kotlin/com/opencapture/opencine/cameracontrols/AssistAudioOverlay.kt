package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorAudioMeter
import com.opencapture.monitorui.MonitorAudioMetrics
import com.opencapture.monitorui.MonitorAudioOrientation
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorScopeSize
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.vocabulary.CameraStatus

/** Floor telemetry still draws; missing packets use the status fields as silent readouts. */
fun audioOverlayChannels(status: CameraStatus): Pair<AudioMeterReading, AudioMeterReading> {
    val meters = status.audioMetersLeftRight() ?: (status.audioMetersLeft to status.audioMetersRight)
    return meters.asMeterChannels()
}

/** One draggable presentation for camera telemetry and the existing playback meter processor. */
@Composable
fun AssistAudioOverlay(state: MonitorAssistState, left: AudioMeterReading, right: AudioMeterReading,
    canvas: MonitorScopeRect, placement: MonitorScopeRect, locked: Boolean = false,
    onOpenOptions: ((MonitorRect) -> Unit)? = null) {
    val density = LocalDensity.current.density
    val orientation = state.audioOrientation
    val base = MonitorScopeSize(
        MonitorAudioMetrics.panelWidth(orientation),
        MonitorAudioMetrics.panelHeight(orientation),
    )
    val portrait = canvas.height > canvas.width
    val sizePx = MonitorScopeSize(base.width * density, base.height * density)
    MovableAssistPanel(MonitorAssistTool.AUDIO, base, 1.0, state.audioCenterFor(portrait),
        canvas, placement, AudioAssist.defaultCenter(canvas, placement, sizePx),
        enabled = !locked, onStore = { state.storeAudioCenter(it, portrait) },
        onOpenOptions = onOpenOptions) {
        MonitorAudioMeter(left.levelDB, left.peakDB, right.levelDB, right.peakDB,
            state.audioOrientation, state.audioShowDB, Modifier.fillMaxSize())
    }
}
