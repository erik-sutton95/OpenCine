package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.monitorReadoutShadow
import com.opencapture.opencine.media.ExposureCompensation
import com.opencapture.opencine.vocabulary.EvComp
import kotlin.math.cos
import kotlin.math.sin
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.monitorui.MonitorRect

/**
 * Camera telemetry only; this never reads the configured compensation or sampled picture. [stops] is
 * the metered exposure (a camera meters in thirds or sixths), null while unknown.
 */
public class MonitorOperatorExposureReading(stops: Double?, available: Boolean = true) {
    /** The vocabulary's raw metered byte, `0x10` plus thirds. */
    public constructor(raw: Int, available: Boolean = true) : this(EvComp.fromRaw(raw)?.thirds?.div(3.0), available)

    public val stops: Double? = stops?.takeIf { available && it.isFinite() }
    public val label: String = this.stops?.let(ExposureCompensation::label) ?: "\u2014"
    /** Top is +3, bottom is −3. Scaled through thirds so a reported third lands exactly. */
    public val needleFraction: Float? = this.stops?.let { (9f - (it.coerceIn(-3.0, 3.0) * 3).toFloat()) / 18f }
    public val accessibilityLabel: String =
        if (this.stops == null) "Camera exposure meter, unavailable" else "Camera exposure meter, $label EV"

    public companion object {
        public fun frame(feed: MonitorRect, mode: MonitorDisplayMode, avoid: MonitorRect? = null): MonitorRect? {
            if (mode != MonitorDisplayMode.LIVE || feed.width < 40f || feed.height < 84f) return null
            val x = feed.minX + 6f
            val top = feed.minY + 6f
            val bottom = feed.maxY - 6f
            val preferredCenter = feed.midY - 16f
            fun fit(lower: Float, upper: Float): MonitorRect? {
                val height = minOf(180f, upper - lower)
                if (height < 72f) return null
                // Not coerceIn: upper - height can round an ULP below lower, and coerceIn throws.
                val y = maxOf(lower, minOf(preferredCenter - height / 2f, upper - height))
                return MonitorRect(x, y, 28f, height)
            }
            val preferred = fit(top, bottom) ?: return null
            if (avoid == null || avoid.isEmpty || avoid.minX >= preferred.maxX || avoid.maxX <= x ||
                avoid.minY >= preferred.maxY + 12f || avoid.maxY <= preferred.minY - 12f) return preferred
            return fit(top, minOf(bottom, avoid.minY - 12f))
                ?: fit(maxOf(top, avoid.maxY + 12f), bottom)
        }
    }
}

/** Fixed to the visible feed's left edge in DISP 1; it has no pointer handlers or saved placement. */
@Composable
public fun MonitorOperatorExposureMeter(
    stops: Double?,
    available: Boolean,
    feed: MonitorRect,
    mode: MonitorDisplayMode,
    modifier: Modifier = Modifier,
    avoid: MonitorRect? = null,
): Unit {
    val frame = MonitorOperatorExposureReading.frame(feed, mode, avoid) ?: return
    val reading = MonitorOperatorExposureReading(stops, available)
    val measurer = rememberTextMeasurer()
    Canvas(
        modifier.offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)
            .monitorReadoutShadow()
            .semantics { contentDescription = reading.accessibilityLabel },
    ) {
        val scale = size.width / 28f
        val foreground = LiveDesign.text
        val style = TextStyle(
            color = foreground,
            fontSize = (10f * scale / density).sp,
            fontFamily = com.opencapture.monitorui.MonitorTypography.text(10f).fontFamily,
            fontWeight = FontWeight.SemiBold,
        )
        val number = measurer.measure(reading.label, style)
        drawText(number, topLeft = Offset((size.width - number.size.width) / 2, 6f * scale - number.size.height / 2))
        val captionStyle = style.copy(fontSize = (8f * scale / density).sp)
        for ((label, y) in listOf("+3" to 23f * scale, "−3" to size.height - 5f * scale)) {
            val text = measurer.measure(label, captionStyle)
            drawText(text, topLeft = Offset((size.width - text.size.width) / 2, y - text.size.height / 2))
        }
        val top = 34f * scale
        val bottom = size.height - 18f * scale
        val span = bottom - top
        val axisX = size.width / 2
        val markerY = reading.needleFraction?.let { top + span * it }
        fun axis(from: Float, to: Float) {
            drawLine(foreground, Offset(axisX, from), Offset(axisX, to), scale)
        }
        if (markerY == null) {
            axis(top, bottom)
        } else {
            val gap = 8.5f * scale
            if (markerY - gap > top) axis(top, markerY - gap)
            if (markerY + gap < bottom) axis(markerY + gap, bottom)
            val center = Offset(axisX, markerY)
            drawCircle(foreground, radius = 2.5f * scale, center = center)
            for (ray in 0..7) {
                val angle = ray * Math.PI / 4
                val direction = Offset(cos(angle).toFloat(), sin(angle).toFloat())
                drawLine(foreground, center + direction * (4f * scale), center + direction * (6.5f * scale),
                    1.2f * scale, StrokeCap.Round)
            }
        }
    }
}

/** Original raw-byte API retained while hosts adopt metered stops. */
@Deprecated("Use metered stops")
@Composable
public fun MonitorOperatorExposureMeter(
    raw: Int, available: Boolean, feed: MonitorRect, mode: MonitorDisplayMode,
    modifier: Modifier = Modifier, avoid: MonitorRect? = null,
): Unit = MonitorOperatorExposureMeter(EvComp.fromRaw(raw)?.thirds?.div(3.0), available,
    feed, mode, modifier, avoid)
