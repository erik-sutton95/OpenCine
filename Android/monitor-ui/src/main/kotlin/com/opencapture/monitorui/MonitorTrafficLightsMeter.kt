package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.media.ScopeChannelLight
import com.opencapture.opencine.media.ScopeTrafficLightsReading
import kotlin.math.abs

private val MeterRed = Color(255 / 255f, 92 / 255f, 82 / 255f)
private val MeterGreen = Color(86 / 255f, 235 / 255f, 132 / 255f)
private val MeterBlue = Color(96 / 255f, 158 / 255f, 255 / 255f)

object MonitorTrafficLightsGeometry {
    const val METER_TITLE = "TL"
    const val TITLE_SIZE = 8.5f
    const val TITLE_SPACING = 6f
    const val COLUMN_SPACING = 6f
    const val POST_SPACING = 4f
    const val PANEL_PAD = 8f
    const val TRACK_WIDTH = 11f
    const val COLUMN_HEIGHT = 108f
    const val INDICATOR_SIZE = 8f
    const val TRACK_CORNER = 2f
    const val MIN_BAR_HEIGHT = 1.5f
    const val CENTER_LINE_FACTOR = 0.85f
    const val BALANCE_CENTER = 0.5
    const val BALANCE_DEAD_ZONE = 0.03
    val meterRedRGB = Triple(255.0, 92.0, 82.0)
    val meterGreenRGB = Triple(86.0, 235.0, 132.0)
    val meterBlueRGB = Triple(96.0, 158.0, 255.0)

    enum class BarSide {
        NEUTRAL,
        OVER,
        UNDER,
    }

    data class ChannelDisplay(val side: BarSide, val barFill: Double) {
        companion object {
            val neutral = ChannelDisplay(BarSide.NEUTRAL, 0.0)
        }
    }

    fun channelDisplay(
        level: Double,
        center: Double = BALANCE_CENTER,
        deadZone: Double = BALANCE_DEAD_ZONE,
    ): ChannelDisplay {
        val deviation = level - center
        if (abs(deviation) <= deadZone) return ChannelDisplay.neutral
        return if (deviation > 0) {
            val span = maxOf(1 - center, Double.MIN_VALUE)
            ChannelDisplay(BarSide.OVER, minOf(1.0, deviation / span))
        } else {
            val span = maxOf(center, Double.MIN_VALUE)
            ChannelDisplay(BarSide.UNDER, minOf(1.0, abs(deviation) / span))
        }
    }
}

@Composable
fun MonitorTrafficLightsMeter(reading: ScopeTrafficLightsReading, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier.fillMaxSize()) {
        val ui = minOf(this.size.width / MonitorScopePanelSize.trafficLights.width, this.size.height / MonitorScopePanelSize.trafficLights.height)
        val pad = MonitorTrafficLightsGeometry.PANEL_PAD * ui
        drawText(
            measurer,
            MonitorTrafficLightsGeometry.METER_TITLE,
            Offset(pad, pad),
            TextStyle(
                color = MonitorPalette.text.copy(alpha = 0.58f),
                fontSize = 8.5.sp,
                fontFamily = MonitorTypography.fontFamily,
                fontWeight = FontWeight.Bold,
            ),
        )
        val colW = MonitorTrafficLightsGeometry.TRACK_WIDTH * ui
        val colH = MonitorTrafficLightsGeometry.COLUMN_HEIGHT * ui
        val gap = MonitorTrafficLightsGeometry.COLUMN_SPACING * ui
        val startX = (this.size.width - (colW * 3 + gap * 2)) / 2f
        val top = pad + MonitorTrafficLightsGeometry.TITLE_SIZE * ui + MonitorTrafficLightsGeometry.TITLE_SPACING * ui
        val channels = listOf(MeterRed to reading.red, MeterGreen to reading.green, MeterBlue to reading.blue)
        channels.forEachIndexed { i, pair ->
            val x = startX + i * (colW + gap)
            drawGoalPost(x, top, colW, colH, pair.first, ui, pair.second)
        }
    }
}

private fun DrawScope.drawGoalPost(
    x: Float,
    top: Float,
    colW: Float,
    colH: Float,
    color: Color,
    ui: Float,
    channel: ScopeChannelLight,
) {
    val indicator = MonitorTrafficLightsGeometry.INDICATOR_SIZE * ui
    val postGap = MonitorTrafficLightsGeometry.POST_SPACING * ui
    drawIndicator(x + colW / 2f, top + indicator / 2f, indicator, color, channel.clip, ui)
    val trackTop = top + indicator + postGap
    val trackH = colH
    val centerH = maxOf(1f, ui * MonitorTrafficLightsGeometry.CENTER_LINE_FACTOR)
    val half = (trackH - centerH) / 2f
    val corner = CornerRadius(MonitorTrafficLightsGeometry.TRACK_CORNER * ui)
    val shown = MonitorTrafficLightsGeometry.channelDisplay(channel.level)
    val barH = maxOf(MonitorTrafficLightsGeometry.MIN_BAR_HEIGHT * ui, half * shown.barFill.toFloat())
    drawRoundRect(MonitorPalette.text.copy(alpha = 0.08f), Offset(x, trackTop), Size(colW, half), corner)
    if (shown.side == MonitorTrafficLightsGeometry.BarSide.OVER && shown.barFill > 0) {
        val fillTop = trackTop + half - barH
        drawRect(
            Brush.verticalGradient(
                colors = listOf(color.copy(alpha = 0.92f), color.copy(alpha = 0.35f)),
                startY = fillTop,
                endY = trackTop + half,
            ),
            Offset(x, fillTop),
            Size(colW, barH),
        )
    }
    drawRect(MonitorPalette.text.copy(alpha = 0.14f), Offset(x, trackTop + half), Size(colW, centerH))
    drawRoundRect(MonitorPalette.text.copy(alpha = 0.08f), Offset(x, trackTop + half + centerH), Size(colW, half), corner)
    if (shown.side == MonitorTrafficLightsGeometry.BarSide.UNDER && shown.barFill > 0) {
        val fillTop = trackTop + half + centerH
        drawRect(
            Brush.verticalGradient(
                colors = listOf(color.copy(alpha = 0.35f), color.copy(alpha = 0.92f)),
                startY = fillTop,
                endY = fillTop + barH,
            ),
            Offset(x, fillTop),
            Size(colW, barH),
        )
    }
    val crushY = trackTop + trackH + postGap + indicator / 2f
    drawIndicator(x + colW / 2f, crushY, indicator, color, channel.crush, ui)
}

private fun DrawScope.drawIndicator(cx: Float, cy: Float, size: Float, color: Color, hot: Boolean, ui: Float) {
    if (hot) {
        drawCircle(color, size / 2f, Offset(cx, cy))
    }
    drawCircle(
        color.copy(alpha = if (hot) 1f else 0.75f),
        size / 2f,
        Offset(cx, cy),
        style = Stroke(maxOf(1f, 1.5f * ui)),
    )
}
