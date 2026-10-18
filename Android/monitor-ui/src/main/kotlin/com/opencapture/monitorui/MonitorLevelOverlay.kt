package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

/** Source-resolved picture attitude, after freshness and picture-axis transforms. */
sealed interface MonitorLevelDisplay {
    data object Unavailable : MonitorLevelDisplay
    data class Gauges(val rollDeg: Double, val tiltDeg: Double) : MonitorLevelDisplay
    data class Bubble(val xDeg: Double, val yDeg: Double) : MonitorLevelDisplay
    /** A horizon line through the picture's centre, rotated by the roll. */
    data class Horizon(val rollDeg: Double) : MonitorLevelDisplay
}

object MonitorLevelGeometry {
    const val THICKNESS = 28f
    const val MAX_LENGTH = 180f
    const val SPAN = 8.0
    const val THRESHOLD = 0.6
    const val BUBBLE_SPAN = 10.0
    const val BUBBLE_RADIUS = 64f
    const val BAND = 8f
    /** The horizon reads level inside this roll. */
    const val HORIZON_THRESHOLD = 0.8
    /** Roll strip centre above the visible picture's bottom edge; tilt mirrors the offset. */
    const val ROLL_LIFT_LANDSCAPE = 84f
    const val ROLL_LIFT_PORTRAIT = 22f
    val good = Color(0.18f, 0.78f, 0.42f)

    fun visible(feed: MonitorScopeRect, viewport: MonitorScopeRect): MonitorScopeRect {
        val x = maxOf(feed.minX, viewport.minX)
        val y = maxOf(feed.minY, viewport.minY)
        val w = minOf(feed.maxX, viewport.maxX) - x
        val h = minOf(feed.maxY, viewport.maxY) - y
        return if (w <= 0f || h <= 0f) feed else MonitorScopeRect(x, y, w, h)
    }

    data class Frames(val roll: MonitorScopeRect, val tilt: MonitorScopeRect)

    /** Strips in dp against the on-screen part of the feed. */
    fun frames(feed: MonitorScopeRect, viewport: MonitorScopeRect, portrait: Boolean): Frames {
        val v = visible(feed, viewport)
        val rollWidth = minOf(MAX_LENGTH, v.width - 24f).coerceAtLeast(0f)
        val rollMidY = v.maxY - if (portrait) ROLL_LIFT_PORTRAIT else ROLL_LIFT_LANDSCAPE
        val tiltHeight = minOf(MAX_LENGTH, v.height - 12f).coerceAtLeast(0f)
        // Same offset from centre as roll, kept 6 dp inside the picture (portrait fill).
        val tiltMidX = minOf(v.midX + (rollMidY - v.midY), v.maxX - 6f - THICKNESS / 2f)
        return Frames(
            MonitorScopeRect(v.midX - rollWidth / 2f, rollMidY - THICKNESS / 2f, rollWidth, THICKNESS),
            MonitorScopeRect(tiltMidX - THICKNESS / 2f, v.midY - tiltHeight / 2f, THICKNESS, tiltHeight),
        )
    }

    fun label(value: Double?, unknownLabel: String = "?"): String =
        if (value == null) unknownLabel else String.format(Locale.ROOT, "%+.1f°", if (abs(value) < 0.05) 0.0 else value)

    fun accessibilityLabel(display: MonitorLevelDisplay, noDataLabel: String = "No level data"): String = when (display) {
        MonitorLevelDisplay.Unavailable -> "Level, $noDataLabel"
        is MonitorLevelDisplay.Gauges -> String.format(Locale.ROOT, "Level, roll %+.1f°, tilt %+.1f°", display.rollDeg, display.tiltDeg)
        is MonitorLevelDisplay.Bubble -> String.format(Locale.ROOT, "Level, off plumb %+.1f° / %+.1f°", display.xDeg, display.yDeg)
        is MonitorLevelDisplay.Horizon -> String.format(Locale.ROOT, "Level, horizon roll %+.1f°", display.rollDeg)
    }
}

/** Feed/viewport geometry is in dp; this view owns no telemetry or refresh clock. */
@Composable
fun MonitorLevelOverlay(
    display: MonitorLevelDisplay,
    feedDp: MonitorScopeRect,
    viewportDp: MonitorScopeRect,
    portrait: Boolean,
    modifier: Modifier = Modifier,
    noDataLabel: String = "No level data",
    unknownLabel: String = "?",
) {
    val measurer = rememberTextMeasurer()
    Canvas(
        modifier.fillMaxSize()
            .semantics { contentDescription = MonitorLevelGeometry.accessibilityLabel(display, noDataLabel) },
    ) {
        val frames = MonitorLevelGeometry.frames(feedDp, viewportDp, portrait)
        when (val m = display) {
            is MonitorLevelDisplay.Bubble -> {
                val v = MonitorLevelGeometry.visible(feedDp, viewportDp)
                drawBubble(Offset(v.midX.dp.toPx(), v.midY.dp.toPx()), m.xDeg, m.yDeg, measurer)
            }
            is MonitorLevelDisplay.Horizon -> drawHorizon(Offset(feedDp.midX.dp.toPx(), feedDp.midY.dp.toPx()), m.rollDeg)
            is MonitorLevelDisplay.Gauges -> {
                drawStrip(frames.roll, vertical = false, m.rollDeg, measurer, unknownLabel)
                drawStrip(frames.tilt, vertical = true, m.tiltDeg, measurer, unknownLabel)
            }
            MonitorLevelDisplay.Unavailable -> {
                drawStrip(frames.roll, vertical = false, null, measurer, unknownLabel)
                drawStrip(frames.tilt, vertical = true, null, measurer, unknownLabel)
                text(measurer, noDataLabel,
                    Offset(frames.roll.midX.dp.toPx(), (frames.roll.maxY + 6f).dp.toPx()), MonitorPalette.muted, 8f)
            }
        }
    }
}

private val offLevel = Color(0.914f, 0.674f, 0.208f)

private fun DrawScope.text(
    measurer: TextMeasurer, s: String, centre: Offset, color: Color, size: Float,
    bold: Boolean = false, shadow: Boolean = true,
) {
    // Faint text-only shadow (iOS `drawReadout`); the band carries no glow.
    val style = TextStyle(color = color, fontSize = size.sp, fontFamily = MonitorTypography.fontFamily,
        fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Medium,
        shadow = if (shadow) androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.6f), blurRadius = 1.5f.dp.toPx()) else null)
    val layout = measurer.measure(s, style)
    drawText(layout, topLeft = Offset(centre.x - layout.size.width / 2f, centre.y - layout.size.height / 2f))
}

private val bandFill = Color.Black.copy(alpha = 0.32f)

/**
 * Native level gauge: opaque dark band,
 * white centreline, cross-bar marker, zero notches, number at the start. Layout in
 * dp inside [rect]; positive reads up / right. Green when level.
 */
private fun DrawScope.drawStrip(rect: MonitorScopeRect, vertical: Boolean, value: Double?, measurer: TextMeasurer, unknownLabel: String) {
    if (rect.width <= 0f || rect.height <= 0f) return
    val white = MonitorPalette.text
    val isLevel = value != null && abs(value) < MonitorLevelGeometry.THRESHOLD
    val tint = if (isLevel) MonitorLevelGeometry.good else white
    val length = if (vertical) rect.height else rect.width
    val start = if (vertical) 18f else 4f
    val end = maxOf(start, length - 4f)
    val across = if (vertical) rect.width / 2f else rect.height - 8f
    val h = MonitorLevelGeometry.BAND / 2f
    fun p(t: Float, off: Float = 0f) = if (vertical) Offset((rect.x + across + off).dp.toPx(), (rect.y + t).dp.toPx())
        else Offset((rect.x + t).dp.toPx(), (rect.y + across + off).dp.toPx())
    fun position(deg: Double): Float {
        val f = ((deg.coerceIn(-MonitorLevelGeometry.SPAN, MonitorLevelGeometry.SPAN) + MonitorLevelGeometry.SPAN) / (2 * MonitorLevelGeometry.SPAN)).toFloat()
        return if (vertical) end - h - (end - start - 2 * h) * f else start + h + (end - start - 2 * h) * f
    }
    text(measurer, MonitorLevelGeometry.label(value, unknownLabel), Offset((rect.x + rect.width / 2f).dp.toPx(), (rect.y + 6f).dp.toPx()), tint, 10f, bold = true)
    val bandSize = if (vertical) androidx.compose.ui.geometry.Size(MonitorLevelGeometry.BAND.dp.toPx(), (end - start).dp.toPx())
        else androidx.compose.ui.geometry.Size((end - start).dp.toPx(), MonitorLevelGeometry.BAND.dp.toPx())
    drawRoundRect(bandFill, p(start, -h), bandSize, androidx.compose.ui.geometry.CornerRadius(h.dp.toPx()))
    val stroke = 1f.dp.toPx()
    drawLine(if (isLevel) tint else tint.copy(alpha = 0.8f), p(start + h), p(end - h), stroke)
    val zero = position(0.0)
    for (side in listOf(-1f, 1f)) {
        drawLine(white.copy(alpha = 0.8f), p(zero, side * (h + 1f)), p(zero, side * (h + 4f)), stroke)
    }
    if (value != null) {
        val m = position(value)
        drawLine(tint, p(m, -(h + 2f)), p(m, h + 2f), 2f.dp.toPx(), androidx.compose.ui.graphics.StrokeCap.Round)
    }
}

/** iOS `MonitorLevelBubble`: ±10° ring, 5° inner ring, centre cross, solid bead (amber / green). */
private fun DrawScope.drawBubble(centre: Offset, x: Double, y: Double, measurer: TextMeasurer) {
    val r = MonitorLevelGeometry.BUBBLE_RADIUS.dp.toPx()
    drawCircle(Color.White.copy(alpha = 0.22f), radius = r, center = centre, style = Stroke(2f.dp.toPx()))
    drawCircle(Color.White.copy(alpha = 0.34f), radius = r / 2, center = centre, style = Stroke(1f.dp.toPx()))
    val arm = 9f.dp.toPx()
    drawLine(Color.White.copy(alpha = 0.75f), Offset(centre.x - arm, centre.y), Offset(centre.x + arm, centre.y), 2f.dp.toPx())
    drawLine(Color.White.copy(alpha = 0.75f), Offset(centre.x, centre.y - arm), Offset(centre.x, centre.y + arm), 2f.dp.toPx())
    val distance = sqrt(x * x + y * y)
    val isLevel = distance < MonitorLevelGeometry.THRESHOLD
    val clamp = if (distance > MonitorLevelGeometry.BUBBLE_SPAN) MonitorLevelGeometry.BUBBLE_SPAN / distance else 1.0
    val bead = Offset(
        centre.x + (x * clamp / MonitorLevelGeometry.BUBBLE_SPAN).toFloat() * r,
        centre.y - (y * clamp / MonitorLevelGeometry.BUBBLE_SPAN).toFloat() * r,
    )
    drawCircle(Color.Black.copy(alpha = 0.5f), radius = 8f.dp.toPx(), center = bead)
    drawCircle(if (isLevel) MonitorLevelGeometry.good else offLevel, radius = 6.5f.dp.toPx(), center = bead)
    drawCircle(Color.Black.copy(alpha = 0.45f), radius = 6.5f.dp.toPx(), center = bead, style = Stroke(2f.dp.toPx()))
    text(measurer, "${MonitorLevelGeometry.label(x)} / ${MonitorLevelGeometry.label(y)}", Offset(centre.x, centre.y + r + 14f.dp.toPx()),
        if (isLevel) MonitorLevelGeometry.good else MonitorPalette.text.copy(alpha = 0.85f), 11f, bold = true, shadow = false)
}

/** A ring with two wings through the picture's centre, rotated by the roll; green when level. */
private fun DrawScope.drawHorizon(centre: Offset, roll: Double) {
    val color = if (abs(roll) < MonitorLevelGeometry.HORIZON_THRESHOLD) MonitorLevelGeometry.good else MonitorPalette.accent
    val wing = 64f.dp.toPx()
    val gap = 10f.dp.toPx()
    val ring = 5f.dp.toPx()
    rotate(roll.toFloat(), pivot = centre) {
        drawCircle(color, radius = ring, center = centre, style = Stroke(1.6f.dp.toPx()))
        for (side in listOf(-1f, 1f)) {
            drawLine(color, Offset(centre.x + side * (ring + gap), centre.y), Offset(centre.x + side * (ring + gap + wing), centre.y),
                2f.dp.toPx(), androidx.compose.ui.graphics.StrokeCap.Round)
        }
    }
}
