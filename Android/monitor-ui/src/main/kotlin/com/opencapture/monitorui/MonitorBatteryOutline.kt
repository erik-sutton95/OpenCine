package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.min

/** iOS `MultiviewBatteryRow` outline: 26×15 body, nub drawn outside the trailing edge. */
const val MONITOR_BATTERY_CELL_W_DP = 26f
const val MONITOR_BATTERY_CELL_H_DP = 15f

/**
 * Uniform scale-to-fit, centered. Floor matches iOS `minimumScaleFactor(0.65)` on the battery
 * readout so "100" and the bolt stay inside the outline.
 */
fun monitorScaleToFitFactor(
    contentWidth: Int,
    contentHeight: Int,
    maxWidth: Int,
    maxHeight: Int,
    minScale: Float = 0.65f,
): Float {
    if (contentWidth <= 0 || contentHeight <= 0 || maxWidth <= 0 || maxHeight <= 0) return 1f
    val scaleX = if (contentWidth > maxWidth) maxWidth / contentWidth.toFloat() else 1f
    val scaleY = if (contentHeight > maxHeight) maxHeight / contentHeight.toFloat() else 1f
    return min(scaleX, scaleY).coerceIn(minScale, 1f)
}

@Composable
internal fun MonitorScaleToFit(
    minScale: Float,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Layout(content, modifier) { measurables, constraints ->
        val measurable = measurables.firstOrNull() ?: return@Layout layout(0, 0) {}
        val placeable = measurable.measure(Constraints())
        val maxW = if (constraints.hasBoundedWidth) constraints.maxWidth else placeable.width
        val maxH = if (constraints.hasBoundedHeight) constraints.maxHeight else placeable.height
        val scale = monitorScaleToFitFactor(placeable.width, placeable.height, maxW, maxH, minScale)
        layout(maxW, maxH) {
            placeable.placeWithLayer(
                ((maxW - placeable.width * scale) / 2f).toInt(),
                ((maxH - placeable.height * scale) / 2f).toInt(),
            ) {
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0f)
            }
        }
    }
}

/**
 * A device glyph beside a battery-shaped outline with the percent inside; negative is unknown.
 * A camera that reports a coarse gauge passes [bars] of [barCount]: the outline holds the bars.
 */
@Composable
fun MonitorBatteryOutlineRow(percent: Int, charging: Boolean, camera: Boolean, bars: Int? = null, barCount: Int = 5) {
    val level = bars?.let { (it.toDouble() * 100 / barCount.coerceAtLeast(1)).toInt() } ?: percent
    val tint =
        when {
            level < 0 -> MonitorPalette.faint
            level <= 20 -> MonitorPalette.recording
            level <= 40 -> Color(0.914f, 0.674f, 0.208f)
            else -> Color(0.18f, 0.78f, 0.42f)
        }
    val readout = if (percent < 0) "\u2014" else "$percent"
    // Phone and camera are told apart only by the glyph, so both rows speak a
    // bare number without this. The dash for "unknown" reads as nothing.
    val source = if (camera) "Camera battery" else "Phone battery"
    val spoken = bars?.let { "$it of $barCount bars" } ?: if (percent < 0) "level unknown" else "$percent percent"
    val power = if (charging) ", charging" else ""
    Row(
        Modifier.clearAndSetSemantics { contentDescription = "$source $spoken$power" },
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MonitorIcon(if (camera) MonitorIcon.CAMERA else MonitorIcon.SMARTPHONE, null, Modifier.size(10.dp),
            MonitorPalette.muted)
        Box(Modifier.size((bars?.let { monitorGaugeReadoutWidth(it, barCount, MONITOR_BATTERY_CELL_W_DP,
            if (charging) 13f else 6f) } ?: MONITOR_BATTERY_CELL_W_DP).dp, MONITOR_BATTERY_CELL_H_DP.dp), contentAlignment = Alignment.Center) {
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(horizontal = 2.dp, vertical = 1.dp)
                    .clip(RoundedCornerShape(2.5.dp)),
                contentAlignment = Alignment.Center,
            ) {
                MonitorScaleToFit(minScale = if (bars != null && barCount > 10) 0.5f else 0.65f, modifier = Modifier.fillMaxSize()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        if (charging) MonitorIcon(MonitorIcon.ZAP, null, Modifier.size(7.dp), tint)
                        if (bars != null) MonitorGaugeBars(bars, barCount, tint)
                        else Text(
                            readout,
                            color = tint,
                            style =
                                MonitorTypography.text(10f, FontWeight.Medium).copy(
                                    color = tint,
                                    fontFeatureSettings = "tnum",
                                    lineHeight = 10.sp,
                                    lineHeightStyle =
                                        LineHeightStyle(
                                            alignment = LineHeightStyle.Alignment.Center,
                                            trim = LineHeightStyle.Trim.Both,
                                        ),
                                    platformStyle = PlatformTextStyle(includeFontPadding = false),
                                ),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Clip,
                        )
                    }
                }
            }
            Canvas(Modifier.fillMaxSize()) {
                drawRoundRect(
                    tint.copy(alpha = 0.85f),
                    cornerRadius = CornerRadius(3.5.dp.toPx()),
                    style = Stroke(1.2.dp.toPx()),
                )
            }
            Box(
                Modifier
                    .align(Alignment.CenterEnd)
                    .offset(x = 3.dp)
                    .size(1.6.dp, 6.dp)
                    .background(tint.copy(alpha = 0.85f), RoundedCornerShape(1.dp)),
            )
        }
    }
}
