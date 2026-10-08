package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.media.MonitorAudioMeterLevels
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
import com.opencapture.monitorui.MonitorScopePoint
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
    onOpenOptions: ((MonitorRect) -> Unit)? = null,
    panelPlacement: MonitorAssistPanelPlacement? = null, feed: MonitorScopeRect? = null,
    portraitOverride: Boolean? = null) {
    val base = MonitorScopeSize(MonitorAudioMetrics.panelWidth(state.audioOrientation),
        MonitorAudioMetrics.panelHeight(state.audioOrientation))
    AssistAudioPanel(state, base, canvas, placement, locked, onOpenOptions, panelPlacement, feed,
        portraitOverride) {
        MonitorAudioMeter(left.levelDB, left.peakDB, right.levelDB, right.peakDB,
            state.audioOrientation, state.audioShowDB, Modifier.fillMaxSize())
    }
}

/** A missing native audio publication is shown as unavailable, never measured silence. */
@Composable
public fun AssistAudioOverlay(state: MonitorAssistState, levels: MonitorAudioMeterLevels?,
    canvas: MonitorScopeRect, placement: MonitorScopeRect, locked: Boolean = false,
    panelPlacement: MonitorAssistPanelPlacement? = null, feed: MonitorScopeRect? = null,
    portraitOverride: Boolean? = null, caption: String? = null, unavailableLabel: String? = null,
    provenance: String? = null, spokenValue: String? = null): Unit {
    val base = MonitorScopeSize(if (provenance == null) 28f else 104f, 168f)
    AssistAudioPanel(state, base, canvas, placement, locked, null, panelPlacement, feed,
        portraitOverride) {
        Column(Modifier.fillMaxSize().clearAndSetSemantics {
            contentDescription = "Audio levels"
            if (spokenValue != null) stateDescription = spokenValue
            else if (levels == null) stateDescription = "Audio levels unavailable"
        }, horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                // The floor is a drawing baseline only; absence is explicitly labelled no data.
                MonitorAudioMeter(levels?.left?.levelDB ?: -60.0, levels?.left?.peakDB ?: -60.0,
                    levels?.right?.levelDB ?: -60.0, levels?.right?.peakDB ?: -60.0,
                    MonitorAudioOrientation.VERTICAL, showDB = false, modifier = Modifier.matchParentSize())
                if (levels == null) unavailableLabel?.let { Text(it, style = MonitorTypography.text(6f, FontWeight.Bold),
                    color = MonitorPalette.muted.copy(alpha = .74f)) }
            }
            Column(Modifier.padding(bottom = 5.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (provenance != null) Text(provenance, style = MonitorTypography.text(6f, FontWeight.Bold),
                    color = MonitorPalette.accent.copy(alpha = .88f), maxLines = 2)
                else caption?.let { Text(it, style = MonitorTypography.text(8f, FontWeight.Bold),
                    color = MonitorPalette.text.copy(alpha = .72f), maxLines = 2) }
            }
        }
    }
}

@Composable
private fun AssistAudioPanel(state: MonitorAssistState, base: MonitorScopeSize,
    canvas: MonitorScopeRect, placement: MonitorScopeRect, locked: Boolean,
    onOpenOptions: ((MonitorRect) -> Unit)?, panelPlacement: MonitorAssistPanelPlacement?,
    feed: MonitorScopeRect?, portraitOverride: Boolean?, content: @Composable () -> Unit) {
    val density = LocalDensity.current.density
    val portrait = portraitOverride ?: (canvas.height > canvas.width)
    val sizePx = MonitorScopeSize(base.width * density, base.height * density)
    val stored = if (panelPlacement == null) state.audioCenterFor(portrait)
        else panelPlacement.read(MonitorAssistTool.AUDIO, portrait)
    val trailingGap = if (portrait) panelPlacement?.portraitAudioTrailingGapDp
        else panelPlacement?.landscapeAudioTrailingGapDp
    val picture = feed ?: canvas
    val bottomGap = panelPlacement?.audioBottomGapDp
    val defaultCenter = if (trailingGap == null) AudioAssist.defaultCenter(canvas, placement, sizePx)
        else MonitorScopePoint(picture.maxX - trailingGap * density - sizePx.width / 2,
            if (bottomGap == null) placement.midY else
                minOf(picture.maxY, placement.maxY) - bottomGap * density - sizePx.height / 2)
    MovableAssistPanel(MonitorAssistTool.AUDIO, base, 1.0, stored,
        canvas, placement, defaultCenter,
        enabled = !locked, onStore = {
            if (panelPlacement == null) state.storeAudioCenter(it, portrait)
            else panelPlacement.write(MonitorAssistTool.AUDIO, it, portrait)
        },
        onOpenOptions = onOpenOptions) {
        content()
    }
}
