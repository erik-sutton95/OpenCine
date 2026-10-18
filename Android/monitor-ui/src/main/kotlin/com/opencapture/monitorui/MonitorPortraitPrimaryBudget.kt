package com.opencapture.monitorui

import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

public data class MonitorPortraitPrimaryFit(val clockSize: Float, val primarySize: Float,
    val spacing: Float, val completeSingleRow: Boolean, val detailSize: Float = 11f,
    val recordingPadding: Float = 8f, val recordingSpacing: Float = 5f, val tracking: Float = 0f)
public val LocalMonitorPortraitPrimaryFit = staticCompositionLocalOf<MonitorPortraitPrimaryFit?> { null }
public data class MonitorPortraitReadoutLine(val value: String, val leadingWidth: Float = 0f)

private data class PortraitRowTier(val clockFloor: Float, val primaryFloor: Float,
    val spacing: Float, val recordingPadding: Float, val recordingSpacing: Float)

/** Only measurement normalizes tabular digits. Rendered and accessible strings are unchanged. */
private fun portraitClockShape(value: String): String = value.map { if (it in '0'..'9') '0' else it }.joinToString("")

/** Native text measurement follows the active font resolver, direction and sp conversion. */
@Composable
public fun rememberMonitorPortraitPrimaryFit(width: Float, status: MonitorStatusPresentation,
    showsRecording: Boolean, showsTimecode: Boolean, primary: MonitorPortraitReadoutLine,
    details: List<MonitorPortraitReadoutLine>): MonitorPortraitPrimaryFit {
    return rememberPortraitPrimaryFit(width, status, showsRecording, showsTimecode,
        primary, details, inline = false, caption = null, maximumSize = 23f, color = null, primaryIsDetail = false)
}

/**
 * Width of the stacked portrait format group: the primary line above, the detail line (codec,
 * color, caption) below. Every item keeps its [target] width; the group is as wide as its
 * wider line, not the sum of both. Pure so the rule is testable without a text measurer.
 */
public fun monitorPortraitStackedFormatWidth(primaryWidth: Int, lowerWidths: List<Int>,
    target: Int, spacing: Int): Int {
    val lower = lowerWidths.sumOf { maxOf(target, it) } + (lowerWidths.size - 1).coerceAtLeast(0) * spacing
    return maxOf(target, primaryWidth, lower)
}

/** The status row reserves STBY/REC, the clock and the stacked format group with every native target. */
@Composable
public fun rememberMonitorPortraitSingleRowFit(width: Float, status: MonitorStatusPresentation,
    showsRecording: Boolean, showsTimecode: Boolean, primary: MonitorPortraitReadoutLine,
    details: List<MonitorPortraitReadoutLine>, caption: String? = null, maximumSize: Float = 23f,
    color: MonitorPortraitReadoutLine? = null, primaryIsDetail: Boolean = false,
    maximumPrimarySize: Float = 25f, maximumDetailSize: Float = 11f): MonitorPortraitPrimaryFit {
    return rememberPortraitPrimaryFit(width, status, showsRecording, showsTimecode,
        primary, details, inline = true, caption = caption, maximumSize = maximumSize, color = color, primaryIsDetail = primaryIsDetail,
        maximumPrimarySize = maximumPrimarySize, maximumDetailSize = maximumDetailSize)
}

@Composable
private fun rememberPortraitPrimaryFit(width: Float, status: MonitorStatusPresentation,
    showsRecording: Boolean, showsTimecode: Boolean, primary: MonitorPortraitReadoutLine,
    details: List<MonitorPortraitReadoutLine>, inline: Boolean, caption: String?, maximumSize: Float,
    color: MonitorPortraitReadoutLine?, primaryIsDetail: Boolean,
    maximumPrimarySize: Float = 25f, maximumDetailSize: Float = 11f): MonitorPortraitPrimaryFit {
    val baseSize = if (maximumSize.isFinite()) maxOf(23f, maximumSize) else 23f
    val primaryCap = if (maximumPrimarySize.isFinite()) maxOf(10f, maximumPrimarySize) else 25f
    val detailCap = if (maximumDetailSize.isFinite()) maxOf(10f, maximumDetailSize) else 11f
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val minimum = maxOf(44.dp, LocalViewConfiguration.current.minimumTouchTargetSize.width)
    val measurer = rememberTextMeasurer(cacheSize = 128)
    val shape = if (showsTimecode) portraitClockShape(status.timecode ?: "--:--:--") else null
    return remember(width, status.recordingLabel, status.elapsedLabel, showsRecording, shape,
        primary, details, color, primaryIsDetail, inline, caption, baseSize, primaryCap, detailCap, density, direction, minimum, measurer) {
        with(density) {
            fun measured(value: String, size: Float, recording: Boolean = false, tracking: Float = 0f): Int = measurer.measure(
                value, style = (if (recording) MonitorTypography.text(size, FontWeight.SemiBold)
                    else MonitorTypography.readout(size)).copy(letterSpacing = tracking.sp), softWrap = false, maxLines = 1).size.width
            val recordingTextWidth = measured(status.recordingLabel, 10f, true) +
                measured(status.elapsedLabel, 10f, true)
            val detailWidth = maxOf(minimum.roundToPx(), details.sumOf {
                maxOf(minimum.roundToPx(), measured(it.value, 11f) + it.leadingWidth.dp.roundToPx())
            } + (details.size - 1).coerceAtLeast(0) * 24.dp.roundToPx())
            val count = (if (showsRecording) 1 else 0) + (if (shape != null) 1 else 0) + 1
            var selected = if (inline) MonitorPortraitPrimaryFit(10f, 10f, .5f, false,
                detailSize = 10f, recordingPadding = 0f, recordingSpacing = 0f)
                else MonitorPortraitPrimaryFit(13.5f, 14f, 4f, false)
            val available = if (width.isFinite() && width > 0f) width.dp.roundToPx() else 0
            // Prefer regular legibility, then admit a compact text-only tier. Targets retain their floor.
            val tiers = if (inline) listOf(
                PortraitRowTier(15f, 16f, 8f, 8f, 5f),
                PortraitRowTier(15f, 16f, 4f, 4f, 3f),
                PortraitRowTier(13.5f, 14f, 2f, 2f, 2f),
                PortraitRowTier(11f, 11f, .5f, 0f, 0f),
                PortraitRowTier(10f, 10f, .5f, 0f, 0f))
                else listOf(PortraitRowTier(15f, 16f, 8f, 8f, 5f),
                    PortraitRowTier(15f, 16f, 4f, 8f, 5f),
                    PortraitRowTier(13.5f, 14f, 4f, 8f, 5f))
            data class Candidate(val clockSize: Float, val primarySize: Float, val detailSize: Float,
                val spacing: Float, val recordingPadding: Float, val recordingSpacing: Float, val tracking: Float = 0f)
            val options = if (inline) {
                (0..kotlin.math.ceil((baseSize - 10f) / .25f).toInt()).flatMap { step ->
                    val size = baseSize - .25f * step
                    tiers.mapNotNull { tier ->
                        val detailFloor = if (tier.clockFloor == 10f) 10f else 11f
                        if (size < maxOf(tier.clockFloor, tier.primaryFloor) || size < detailFloor) null
                        else Candidate(size, minOf(primaryCap, size), minOf(detailCap, size), tier.spacing, tier.recordingPadding, tier.recordingSpacing)
                    }
                } + (1..7).map { step ->
                    // Compact tracking follows the complete natural-width 10sp floor, never a smaller font.
                    Candidate(10f, 10f, 10f, .5f, 0f, 0f, -.125f * step)
                }
            } else tiers.flatMap { tier ->
                (0..38).map { step ->
                    val size = baseSize - .25f * step
                    Candidate(maxOf(tier.clockFloor, size), maxOf(tier.primaryFloor, size), 11f,
                        tier.spacing, tier.recordingPadding, tier.recordingSpacing)
                }
            }
            // Choose the largest complete text first, then the most comfortable spacing that fits.
            for ((clockSize, primarySize, detailSize, spacing, recordingPadding, recordingSpacing, tracking) in options) {
                val targetWidth = minimum.roundToPx()
                val separatorWidth = if (inline && recordingSpacing == 0f)
                    measured(status.recordingLabel + " ", 10f, true, tracking) - measured(status.recordingLabel, 10f, true, tracking) else 0
                val trackedRecordingWidth = if (tracking == 0f) recordingTextWidth else
                    measured(status.recordingLabel, 10f, true, tracking) + measured(status.elapsedLabel, 10f, true, tracking)
                val recordingWidth = if (showsRecording) trackedRecordingWidth + separatorWidth +
                    2 * recordingPadding.dp.roundToPx() + recordingSpacing.dp.roundToPx() else 0
                val clockWidth = shape?.let { measured(it, clockSize, tracking = tracking) + 1 } ?: 0
                val formatWidth = if (inline) {
                    // The format group stacks: the primary line above, codec, color and caption on
                    // the detail line below, so the group is as wide as its wider line.
                    val primaryWidth = measured(primary.value, if (primaryIsDetail) detailSize else primarySize, tracking = tracking) +
                        primary.leadingWidth.dp.roundToPx() + 1
                    val lowerWidths = (details + listOfNotNull(color)).map {
                        measured(it.value, detailSize, tracking = tracking) + it.leadingWidth.dp.roundToPx() + 1
                    } + listOfNotNull(caption?.let { measured(it, detailSize, tracking = tracking) + 1 })
                    monitorPortraitStackedFormatWidth(primaryWidth, lowerWidths, targetWidth, spacing.dp.roundToPx())
                } else maxOf(minimum.roundToPx(), detailWidth, measured(primary.value, primarySize) +
                    primary.leadingWidth.dp.roundToPx() + 1)
                if (recordingWidth + clockWidth + formatWidth +
                    (count - 1).coerceAtLeast(0) * spacing.dp.roundToPx() <= available - 2) {
                    selected = MonitorPortraitPrimaryFit(clockSize, primarySize, spacing, true,
                        detailSize, recordingPadding, recordingSpacing, tracking)
                    break
                }
            }
            selected
        }
    }
}

/** A complete inline label never wraps or substitutes a shorter source value. */
@Composable
public fun MonitorPortraitInlineReadoutText(value: String, modifier: Modifier = Modifier,
    detail: Boolean = false, color: Color = MonitorPalette.text) {
    val fit = LocalMonitorPortraitPrimaryFit.current
    val size = if (detail) fit?.detailSize ?: 11f else fit?.primarySize ?: 23f
    BasicText(value, modifier = modifier.width(IntrinsicSize.Max),
        style = MonitorTypography.readout(size).copy(color = color, letterSpacing = (fit?.tracking ?: 0f).sp),
        maxLines = 1, softWrap = false, overflow = TextOverflow.Visible)
}

/** Failed row budgets wrap complete format/codec text at the declared font floor. */
@Composable
public fun MonitorPortraitReadoutText(value: String, modifier: Modifier = Modifier,
    detail: Boolean = false, color: Color = MonitorPalette.text) {
    val size = if (detail) 11f else LocalMonitorPortraitPrimaryFit.current?.primarySize ?: 23f
    BasicText(value, modifier = modifier, style = MonitorTypography.readout(size).copy(color = color),
        softWrap = true, overflow = TextOverflow.Visible)
}
