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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.AlignmentLine
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
import androidx.compose.ui.unit.sp
import java.util.Locale

/** Reported status only. Absence remains unknown; presentation never invents a clock or timer. */
data class MonitorStatusPresentation(
    val recording: Boolean?, val elapsedSeconds: Int? = null, val timecode: String? = null,
    /** What the clock shows without a value, at the source's declared precision. */
    val timecodePlaceholder: String = MonitorTimecodeFormat.placeholder(frames = false),
) {
    /** The clock as shown: the reported label, or the placeholder at the declared precision. */
    val clock: String get() = timecode ?: timecodePlaceholder
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
    MonitorStatusChrome(layout, status, showsTimecode, showsRecording, true, modifier,
        recordingModifier, clockModifier, storage, format, color, mode, link)
}

/** A composed occupied row may own compact telemetry while the status content keeps its original slot. */
@Composable
fun MonitorStatusChrome(layout: MonitorFieldLayout, status: MonitorStatusPresentation,
    showsTimecode: Boolean, showsRecording: Boolean, showsCompactTelemetry: Boolean,
    modifier: Modifier = Modifier, recordingModifier: Modifier = Modifier, clockModifier: Modifier = Modifier,
    storage: @Composable () -> Unit = {}, format: @Composable () -> Unit,
    color: @Composable () -> Unit = {}, mode: @Composable () -> Unit = {}, link: @Composable () -> Unit = {}) {
    MonitorStatusChrome(layout, status, showsTimecode, showsRecording, showsCompactTelemetry, 0f,
        modifier, recordingModifier, clockModifier, storage, format, color, mode, link)
}

/** A native occupied boundary extends the original viewport clearance without changing content calls. */
@Composable
fun MonitorStatusChrome(layout: MonitorFieldLayout, status: MonitorStatusPresentation,
    showsTimecode: Boolean, showsRecording: Boolean, showsCompactTelemetry: Boolean,
    minimumOccupiedTop: Float, modifier: Modifier = Modifier, recordingModifier: Modifier = Modifier,
    clockModifier: Modifier = Modifier, storage: @Composable () -> Unit = {}, format: @Composable () -> Unit,
    color: @Composable () -> Unit = {}, mode: @Composable () -> Unit = {}, link: @Composable () -> Unit = {}) {
    Box(modifier.fillMaxWidth().then(if (layout.portrait) Modifier else Modifier.height(layout.status.height.dp))) {
        // iOS `MonitorStatusChrome`: the readouts carry the shared glow; telemetry pills keep their own glass.
        if (layout.portrait) {
            MonitorPortraitStatusRow(
                maxOf(layout.status.height, LocalViewConfiguration.current.minimumTouchTargetSize.height.value), layout.status.y,
                minimumOccupiedTop,
                recording = { if (showsRecording) MonitorRecordingReadout(status, recordingModifier) },
                clock = { if (showsTimecode) MonitorClock(status.timecode, layout.tablet, clockModifier, placeholder = status.timecodePlaceholder) },
                format = { Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(
                    (LocalMonitorPortraitPrimaryFit.current?.spacing ?: 8f).dp)) { format(); color() } })
        } else {
            Row(Modifier.fillMaxSize().monitorReadoutShadow(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                FlowRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(24.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)) { storage(); format(); color(); mode() }
                Row(Modifier.padding(end = MonitorLayoutPolicy.recordingReadoutTrailingInset(layout.status.maxX, layout.picture.maxX).dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (showsRecording) MonitorRecordingReadout(status, recordingModifier)
                    if (showsTimecode) MonitorClock(status.timecode, layout.tablet, clockModifier, placeholder = status.timecodePlaceholder)
                }
            }
        }
        if (layout.portrait && showsCompactTelemetry) {
            if (layout.tablet) Row(Modifier.offset(y = (52f - layout.status.y).dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.monitorReadoutShadow()) { storage() }
            }
            else MonitorPortraitTelemetryRow(Modifier.offset(y = (layout.telemetry.y - 13f - layout.status.y).dp)
                .width(maxOf(0f, layout.telemetry.x - layout.status.x - 8f).dp).heightIn(min = 48.dp), storage, link)
        }
    }
}

/** Performance stays next to intrinsic storage, bounded before measurement. */
@Composable
private fun MonitorPortraitTelemetryRow(modifier: Modifier, storage: @Composable () -> Unit, link: @Composable () -> Unit) {
    Layout(content = { Box(Modifier.monitorReadoutShadow()) { storage() }; Box { link() } }, modifier = modifier) { children, constraints ->
        val gap = 8.dp.roundToPx()
        val linkView = children[1].measure(constraints.copy(minWidth = 0, minHeight = 0))
        val storageView = children[0].measure(constraints.copy(minWidth = 0, minHeight = 0,
            maxWidth = (constraints.maxWidth - linkView.width - gap).coerceAtLeast(0)))
        val height = maxOf(constraints.minHeight, storageView.height, linkView.height)
        layout(constraints.maxWidth, height) {
            storageView.placeRelative(0, (height - storageView.height) / 2)
            linkView.placeRelative(storageView.width + gap, (height - linkView.height) / 2)
        }
    }
}

/** Keep complete intrinsic values on one row while a complete typed fit owns it.
 *  Without such a fit context the original fallback applies: an impossible single row
 *  wraps complete groups to intrinsic rows below instead of placing them beyond the
 *  width, so nothing is clipped and no glyph is dropped or ellipsized. */
@Composable
private fun MonitorPortraitStatusRow(minimumHeight: Float, availableTop: Float, minimumOccupiedTop: Float, recording: @Composable () -> Unit,
    clock: @Composable () -> Unit, format: @Composable () -> Unit) {
    val spacing = LocalMonitorPortraitPrimaryFit.current?.spacing ?: 8f
    val allowsFallbackRows = LocalMonitorPortraitPrimaryFit.current?.completeSingleRow != true
    Layout(content = { Box { recording() }; Box { clock() }; Box { format() } },
        modifier = Modifier.fillMaxWidth().monitorReadoutShadow()) {
            measurables, constraints ->
        val gap = spacing.dp.roundToPx()
        val intrinsic = measurables.map { it.maxIntrinsicWidth(Constraints.Infinity) }
        val needed = intrinsic.sum() + (intrinsic.count { it > 0 } - 1).coerceAtLeast(0) * gap
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else needed.coerceAtLeast(1)
        val childConstraints = Constraints(maxWidth = Constraints.Infinity)
        val children = measurables.map { it.measure(childConstraints) }
        val rec = children[0]; val time = children[1]; val values = children[2]
        val wraps = allowsFallbackRows && needed > width
        val secondRow = wraps && values.width > 0 && (rec.width > 0 || time.width > 0)
        val separatesClock = wraps && rec.width > 0 && time.width > 0 &&
            rec.width + gap + time.width > width
        val lower = if (rec.width > 0 && !separatesClock) rec.width + gap else 0
        val upper = width - time.width -
            if (values.width > 0 && !secondRow) values.width + gap else 0
        val clockX = if (time.width > 0) maxOf(lower, minOf((width - time.width) / 2, upper)) else 0
        val minimumPx = minimumHeight.dp.roundToPx()
        val firstHeight = maxOf(minimumPx, rec.height, if (separatesClock) 0 else time.height,
            if (secondRow) 0 else values.height)
        val clockY = if (separatesClock) firstHeight + gap else 0
        val clockFloor = if (separatesClock) clockY + time.height else firstHeight
        val formatRowHeight = if (secondRow) maxOf(minimumPx, values.height) else values.height
        val formatY = if (secondRow) clockFloor + gap else 0
        val afterClock = if (time.width > 0) clockX + time.width + gap else lower
        val formatX = if (secondRow) maxOf(0, width - values.width)
            else maxOf(afterClock, width - values.width)
        val height = maxOf(minimumPx, firstHeight, values.height,
            if (separatesClock) clockFloor else 0,
            if (secondRow) formatY + formatRowHeight else 0)
        val targetTop = values[MonitorPortraitCaptureTargetTop].takeUnless { it == AlignmentLine.Unspecified } ?: 0
        // Consume unshifted native target geometry, never an already-offset global position.
        val occupiedTop = minOf(0, formatY + targetTop)
        val clearance = maxOf(0, kotlin.math.ceil(minimumOccupiedTop.dp.toPx()).toInt() - (availableTop.dp.roundToPx() + occupiedTop))
        layout(width, height + clearance) {
            rec.placeRelative(0, clearance)
            time.placeRelative(clockX, clockY + clearance)
            values.placeRelative(formatX, formatY + clearance)
        }
    }
}

@Composable
fun MonitorClock(
    timecode: String?, tablet: Boolean = false, modifier: Modifier = Modifier, compact: Boolean = false,
    placeholder: String = MonitorTimecodeFormat.placeholder(frames = false),
) {
    val fontSizeOverride = LocalMonitorPortraitPrimaryFit.current?.clockSize
    val displayed = timecode ?: placeholder
    val (base, accent) = MonitorTimecodeFormat.accentComponents(displayed)
    Text(buildAnnotatedString {
        withStyle(SpanStyle(color = MonitorPalette.text)) { append(base) }
        withStyle(SpanStyle(color = MonitorPalette.accent)) { append(accent) }
    }, style = MonitorTypography.readout(fontSizeOverride ?: (if (compact) 15f else if (tablet) 25f else 23f), FontWeight.Medium)
        .let { if (fontSizeOverride != null) it.copy(letterSpacing = (LocalMonitorPortraitPrimaryFit.current?.tracking ?: 0f).sp) else it },
        maxLines = 1, softWrap = false,
        modifier = modifier.then(if (fontSizeOverride != null) Modifier.wrapContentWidth(unbounded = true) else Modifier)
            .clearAndSetSemantics { contentDescription = timecode?.let { "Timecode $it" } ?: "Timecode not available" })
}

/** Camera telemetry supplies elapsed time. Unknown recording never displays Standby. */
@Composable
fun MonitorRecordingReadout(status: MonitorStatusPresentation, modifier: Modifier = Modifier) {
    val fit = LocalMonitorPortraitPrimaryFit.current
    Row(modifier.background(Color.Black.copy(alpha = .65f), RoundedCornerShape(50))
        .clearAndSetSemantics {
            contentDescription = if (status.recording != null && (status.recording == true || (status.elapsedSeconds ?: 0) > 0))
                "${status.recordingAccessibilityLabel}, ${status.elapsedAccessibilityLabel}"
                else status.recordingAccessibilityLabel
            if (status.elapsedSeconds == null) stateDescription = "Elapsed time unknown"
        }.padding(horizontal = (fit?.recordingPadding ?: 8f).dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy((fit?.recordingSpacing ?: 5f).dp)) {
        Text(status.recordingLabel + (if (fit?.recordingSpacing == 0f) " " else ""), color = if (status.recording == true) MonitorPalette.recording else MonitorPalette.text,
            style = MonitorTypography.text(10f, FontWeight.SemiBold)
                .let { if (fit != null) it.copy(letterSpacing = fit.tracking.sp) else it }, maxLines = 1)
        Text(status.elapsedLabel, color = MonitorPalette.muted,
            style = MonitorTypography.text(10f, FontWeight.SemiBold)
                .let { if (fit != null) it.copy(letterSpacing = fit.tracking.sp) else it }, maxLines = 1)
    }
}

@Composable
fun MonitorRecordingBorder(recording: Boolean?, modifier: Modifier = Modifier, cornerRadius: Float = 32f) {
    if (recording == true) Box(modifier.fillMaxSize().border(4.dp, MonitorPalette.recording, RoundedCornerShape(cornerRadius.dp)))
}
