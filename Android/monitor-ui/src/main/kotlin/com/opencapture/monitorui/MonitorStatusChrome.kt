package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import java.util.Locale

/** Reported status only. Absence remains unknown; presentation never invents a clock or timer. */
data class MonitorStatusPresentation(val recording: Boolean?, val elapsedSeconds: Int? = null, val timecode: String? = null) {
    val recordingLabel: String get() = when (recording) { true -> "REC"; false -> "STBY"; null -> "\u2014" }
    val recordingAccessibilityLabel: String get() = when (recording) {
        true -> "Recording"; false -> "Standby"; null -> "Recording state unknown"
    }
    val elapsedLabel: String get() = elapsedSeconds?.coerceAtLeast(0)?.let {
        String.format(Locale.ROOT, "%02d:%02d", it / 60, it % 60)
    } ?: "--:--"
    val elapsedAccessibilityLabel: String get() = elapsedSeconds?.coerceAtLeast(0)?.let {
        val minutes = it / 60
        val seconds = it % 60
        val m = if (minutes == 1) "1 minute" else "$minutes minutes"
        val s = if (seconds == 1) "1 second" else "$seconds seconds"
        when { minutes == 0 -> s; seconds == 0 -> m; else -> "$m $s" }
    } ?: "Elapsed time unknown"
}

/** Integrations fill format, color, mode and telemetry readouts; common status owns orientation. */
@Composable
fun MonitorStatusChrome(layout: MonitorFieldLayout, status: MonitorStatusPresentation,
    showsTimecode: Boolean = true, showsRecording: Boolean = true, modifier: Modifier = Modifier,
    recordingModifier: Modifier = Modifier, clockModifier: Modifier = Modifier,
    storage: @Composable () -> Unit = {}, format: @Composable () -> Unit,
    color: @Composable () -> Unit = {}, mode: @Composable () -> Unit = {}, link: @Composable () -> Unit = {}) {
    Box(modifier.fillMaxWidth().height(layout.status.height.dp)) {
        if (layout.portrait) {
            if (showsTimecode) MonitorClock(status.timecode, layout.tablet, Modifier.align(Alignment.Center).then(clockModifier))
            Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                if (showsRecording) MonitorRecordingReadout(status, recordingModifier)
                Spacer(Modifier.weight(1f))
                format()
            }
        } else {
            Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                FlowRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(24.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)) { storage(); format(); color(); mode() }
                Row(Modifier.padding(end = MonitorLayoutPolicy.recordingReadoutTrailingInset(layout.status.maxX, layout.picture.maxX).dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (showsRecording) MonitorRecordingReadout(status, recordingModifier)
                    if (showsTimecode) MonitorClock(status.timecode, layout.tablet, clockModifier)
                }
            }
        }
        if (layout.portrait) Row(Modifier.offset(y = ((if (layout.tablet) 52f else layout.gauges.y) - layout.status.y).dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            storage(); if (!layout.tablet) link()
        }
    }
}

@Composable
fun MonitorClock(timecode: String?, tablet: Boolean = false, modifier: Modifier = Modifier, compact: Boolean = false) {
    val displayed = timecode ?: "--:--:--"
    val split = displayed.lastIndexOf(':')
    Text(buildAnnotatedString {
        withStyle(SpanStyle(color = MonitorPalette.text)) { append(if (split >= 0) displayed.substring(0, split + 1) else displayed) }
        withStyle(SpanStyle(color = MonitorPalette.accent)) { if (split >= 0) append(displayed.substring(split + 1)) }
    }, style = MonitorTypography.text(if (compact) 15f else if (tablet) 25f else 23f, FontWeight.Medium),
        maxLines = 1, softWrap = false,
        modifier = modifier.clearAndSetSemantics { contentDescription = timecode?.let { "Timecode $it" } ?: "Timecode not available" })
}

/** Camera telemetry supplies elapsed time. Unknown recording never displays Standby. */
@Composable
fun MonitorRecordingReadout(status: MonitorStatusPresentation, modifier: Modifier = Modifier) {
    Row(modifier.background(Color.Black.copy(alpha = .65f), RoundedCornerShape(50))
        .padding(horizontal = 8.dp, vertical = 4.dp).clearAndSetSemantics {
            contentDescription = if (status.recording != null && (status.recording == true || (status.elapsedSeconds ?: 0) > 0))
                "${status.recordingAccessibilityLabel}, ${status.elapsedAccessibilityLabel}"
                else status.recordingAccessibilityLabel
            if (status.elapsedSeconds == null) stateDescription = "Elapsed time unknown"
        }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(status.recordingLabel, color = if (status.recording == true) MonitorPalette.recording else MonitorPalette.text,
            style = MonitorTypography.text(10f, FontWeight.SemiBold), maxLines = 1)
        Text(status.elapsedLabel, color = MonitorPalette.muted,
            style = MonitorTypography.text(10f, FontWeight.SemiBold), maxLines = 1)
    }
}

@Composable
fun MonitorRecordingBorder(recording: Boolean?, modifier: Modifier = Modifier, cornerRadius: Float = 32f) {
    if (recording == true) Box(modifier.fillMaxSize().border(4.dp, MonitorPalette.recording, RoundedCornerShape(cornerRadius.dp)))
}
