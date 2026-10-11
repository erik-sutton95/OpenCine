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
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.Constraints
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
    val recordingLabel: String get() = when (recording) { true -> "REC"; false -> "STBY"; null -> "--" }
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
    Box(modifier.fillMaxWidth().then(if (layout.portrait) Modifier else Modifier.height(layout.status.height.dp))) {
        if (layout.portrait) {
            MonitorPortraitStatusRow(
                maxOf(layout.status.height, LocalViewConfiguration.current.minimumTouchTargetSize.height.value),
                recording = { if (showsRecording) MonitorRecordingReadout(status, recordingModifier) },
                clock = { if (showsTimecode) MonitorClock(status.timecode, layout.tablet, clockModifier) },
                format = format)
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

/** Measures each native slot once, preserving values and actions as the format moves to a second row. */
@Composable
private fun MonitorPortraitStatusRow(minimumHeight: Float, recording: @Composable () -> Unit,
    clock: @Composable () -> Unit, format: @Composable () -> Unit) {
    Layout(content = { Box { recording() }; Box { clock() }; Box { format() } }, modifier = Modifier.fillMaxWidth()) {
            measurables, constraints ->
        val gap = 8.dp.roundToPx()
        val intrinsic = measurables.map { it.maxIntrinsicWidth(Constraints.Infinity) }
        val needed = intrinsic.sum() + (intrinsic.count { it > 0 } - 1).coerceAtLeast(0) * gap
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else needed.coerceAtLeast(1)
        val childConstraints = Constraints(maxWidth = width)
        val children = measurables.map { it.measure(childConstraints) }
        val rec = children[0]; val time = children[1]; val values = children[2]
        val secondRow = needed > width && values.width > 0 && (rec.width > 0 || time.width > 0)
        val separatesClock = rec.width > 0 && time.width > 0 && rec.width + gap + time.width > width
        val firstHeight = maxOf(minimumHeight.dp.roundToPx(), rec.height,
            if (separatesClock) 0 else time.height, if (secondRow) 0 else values.height)
        val clockY = if (separatesClock) firstHeight + gap else (firstHeight - time.height) / 2
        val clockFloor = if (separatesClock) clockY + time.height else firstHeight
        val formatRowHeight = if (secondRow) maxOf(minimumHeight.dp.roundToPx(), values.height) else values.height
        val formatY = if (secondRow) clockFloor + gap + (formatRowHeight - values.height) / 2
            else (firstHeight - values.height) / 2
        val lower = if (rec.width > 0 && !separatesClock) rec.width + gap else 0
        val upper = width - time.width - if (values.width > 0 && !secondRow) values.width + gap else 0
        val clockX = if (time.width > 0) maxOf(lower, minOf((width - time.width) / 2, upper)) else 0
        val formatFloor = if (secondRow) clockFloor + gap + formatRowHeight else formatY + values.height
        val height = maxOf(firstHeight, clockFloor, formatFloor)
        layout(width, height) {
            rec.placeRelative(0, (firstHeight - rec.height) / 2)
            time.placeRelative(clockX, clockY)
            values.placeRelative(width - values.width, formatY)
        }
    }
}

@Composable
fun MonitorClock(timecode: String?, tablet: Boolean = false, modifier: Modifier = Modifier, compact: Boolean = false) {
    val displayed = timecode ?: "--:--:--"
    val (base, accent) = MonitorTimecodeFormat.accentComponents(displayed)
    Text(buildAnnotatedString {
        withStyle(SpanStyle(color = MonitorPalette.text)) { append(base) }
        withStyle(SpanStyle(color = MonitorPalette.accent)) { append(accent) }
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
