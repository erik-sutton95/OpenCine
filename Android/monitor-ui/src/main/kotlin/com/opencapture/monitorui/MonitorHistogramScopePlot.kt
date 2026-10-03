package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.media.ScopeHistogramDisplay
import com.opencapture.opencine.media.ScopeTrafficLightsReading

object MonitorHistogramGeometry {
    const val PANEL_TITLE = "Histo"
    const val CHIP = "RGBL"
    const val CLIP_ZONE_IRE = 95.0
    const val TRAFFIC_LAMP_WIDTH = 7.5f
    const val TRAFFIC_LAMP_HEIGHT = 15f
    const val TRAFFIC_OUTER_PAD = 6f
    const val TRAFFIC_LINE_GAP = 4f
    val trafficGutter get() = TRAFFIC_OUTER_PAD + TRAFFIC_LAMP_WIDTH + TRAFFIC_LINE_GAP
    fun plotRect(width: Float, height: Float, density: Float = 1f): Rect {
        val gutter = trafficGutter * density
        val top = 26f * density
        return Rect(gutter, top, gutter + maxOf(1f, width - gutter * 2),
            top + maxOf(1f, height - top - 2f * density))
    }
    fun plotX(ire: Double, rect: Rect, density: Float = 1f): Float {
        val inset = density
        return rect.left + inset + (ire / 100).toFloat() * (rect.width - 2 * inset)
    }
    fun ireX(ire: Double, rect: Rect, density: Float = 1f) = plotX(ire, rect, density)
}

private val Boundary = Color(220 / 255f, 235 / 255f, 225 / 255f, 0.8f)
private val ClipColor = Color(255 / 255f, 150 / 255f, 142 / 255f, 0.8f)
private val HistoRedFill = Color(255 / 255f, 48 / 255f, 44 / 255f, 0.17f)
private val HistoRedStroke = Color(255 / 255f, 48 / 255f, 44 / 255f, 0.96f)
private val HistoGreenFill = Color(0f, 238 / 255f, 70 / 255f, 0.15f)
private val HistoGreenStroke = Color(0f, 238 / 255f, 70 / 255f, 0.92f)
private val HistoBlueFill = Color(45 / 255f, 76 / 255f, 255 / 255f, 0.19f)
private val HistoBlueStroke = Color(45 / 255f, 76 / 255f, 255 / 255f, 0.94f)
private val HistoLumaStroke = Color(245 / 255f, 242 / 255f, 232 / 255f, 0.58f)
private val MeterRed = Color(255 / 255f, 92 / 255f, 82 / 255f)
private val MeterGreen = Color(86 / 255f, 235 / 255f, 132 / 255f)
private val MeterBlue = Color(96 / 255f, 158 / 255f, 255 / 255f)

@Composable
fun MonitorHistogramScopePlot(display: ScopeHistogramDisplay,
    traffic: ScopeTrafficLightsReading = ScopeTrafficLightsReading.NONE,
    showTrafficLights: Boolean = true, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier.fillMaxSize()) {
        val d = density
        val plot = MonitorHistogramGeometry.plotRect(this.size.width, this.size.height, d)
        for (step in 1 until 4) {
            val y = plot.top + plot.height * step / 4f
            drawLine(Color(220 / 255f, 235 / 255f, 225 / 255f, 0.06f), Offset(plot.left, y), Offset(plot.right, y), 1f)
        }
        if (showTrafficLights && traffic.anyClip) {
            val clipStart = MonitorHistogramGeometry.ireX(MonitorHistogramGeometry.CLIP_ZONE_IRE, plot, d)
            val clipEnd = MonitorHistogramGeometry.ireX(100.0, plot, d)
            drawRect(
                ClipColor.copy(alpha = 0.14f),
                Offset(clipStart, plot.top),
                Size((clipEnd - clipStart).coerceAtLeast(0f), plot.height),
            )
        }
        val x0 = MonitorHistogramGeometry.ireX(0.0, plot, d)
        val x100 = MonitorHistogramGeometry.ireX(100.0, plot, d)
        // iOS HistogramScopePlot is SwiftUI Canvas (not Metal). Keep the
        // bezier + shared RGBL peak on Compose even when WAVE/PARADE are GPU.
        clipRect(x0, plot.top, x100, plot.bottom) {
            val peak =
                maxOf(
                    display.red.maxOrNull() ?: 0f,
                    display.green.maxOrNull() ?: 0f,
                    display.blue.maxOrNull() ?: 0f,
                    display.luma.maxOrNull() ?: 0f,
                    1f,
                )
            drawHistogramChannel(display.red, plot, peak, HistoRedFill, HistoRedStroke, 0.92f, d)
            drawHistogramChannel(display.green, plot, peak, HistoGreenFill, HistoGreenStroke, 0.92f, d)
            drawHistogramChannel(display.blue, plot, peak, HistoBlueFill, HistoBlueStroke, 0.92f, d)
            drawHistogramLuma(display.luma, plot, peak, d)
        }
        drawLine(Boundary, Offset(x0, plot.top), Offset(x0, plot.bottom), 1.25f)
        drawLine(Boundary, Offset(x100, plot.top), Offset(x100, plot.bottom), 1.25f)
        if (showTrafficLights) {
            drawTrafficLamps(traffic, d)
        }
        drawHistogramTitle(measurer, MonitorHistogramGeometry.PANEL_TITLE.uppercase(), MonitorHistogramGeometry.CHIP)
    }
}

private fun DrawScope.drawHistogramTitle(measurer: TextMeasurer, title: String, chip: String) {
    val padX = 8.dp.toPx()
    val padY = 4.dp.toPx()
    drawText(
        measurer,
        title,
        Offset(padX, padY),
        TextStyle(color = MonitorPalette.text.copy(alpha = 0.66f), fontSize = 10.5.sp, fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Bold),
    )
    val chipLayout =
        measurer.measure(
            chip,
            TextStyle(color = MonitorPalette.text.copy(alpha = 0.58f), fontSize = 9.5.sp, fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Bold),
        )
    drawText(chipLayout, topLeft = Offset(size.width - chipLayout.size.width - padX, 5.dp.toPx()))
}

private fun DrawScope.drawHistogramChannel(
    bins: FloatArray,
    plot: Rect,
    peak: Float,
    fill: Color,
    stroke: Color,
    alpha: Float,
    density: Float,
) {
    val (fillPath, strokePath) = histogramPaths(bins, plot, peak, density)
    if (fillPath.isEmpty) return
    drawPath(fillPath, fill, alpha = alpha, blendMode = BlendMode.Plus)
    drawPath(
        strokePath,
        stroke,
        alpha = alpha,
        style = Stroke(width = 1.8f, cap = StrokeCap.Round, join = StrokeJoin.Round),
        blendMode = BlendMode.Plus,
    )
}

private fun DrawScope.drawHistogramLuma(bins: FloatArray, plot: Rect, peak: Float, density: Float) {
    val (_, strokePath) = histogramPaths(bins, plot, peak, density)
    if (strokePath.isEmpty) return
    drawPath(
        strokePath,
        HistoLumaStroke,
        alpha = 0.58f,
        style = Stroke(width = 1.4f, cap = StrokeCap.Round, join = StrokeJoin.Round),
    )
}

private fun histogramPaths(bins: FloatArray, plot: Rect, peak: Float, density: Float): Pair<Path, Path> {
    if (bins.size <= 1 || peak <= 0f || bins.none { it > 0f }) return Path() to Path()
    val last = bins.lastIndex
    fun point(index: Int): Offset {
        val x = MonitorHistogramGeometry.plotX(index / last.toDouble() * 100.0, plot, density)
        val height = (bins[index] / peak) * plot.height
        return Offset(x, plot.bottom - height)
    }
    val fill = Path()
    fill.moveTo(MonitorHistogramGeometry.plotX(0.0, plot, density), plot.bottom)
    fill.lineTo(point(0).x, point(0).y)
    val stroke = Path()
    val first = point(0)
    stroke.moveTo(first.x, first.y)
    for (index in 1..last) {
        val previous = point(index - 1)
        val current = point(index)
        val mid = Offset((previous.x + current.x) / 2f, (previous.y + current.y) / 2f)
        fill.quadraticTo(previous.x, previous.y, mid.x, mid.y)
        stroke.quadraticTo(previous.x, previous.y, mid.x, mid.y)
    }
    fill.lineTo(MonitorHistogramGeometry.plotX(100.0, plot, density), plot.bottom)
    fill.close()
    return fill to stroke
}

private fun DrawScope.drawTrafficLamps(traffic: ScopeTrafficLightsReading, density: Float) {
    val w = MonitorHistogramGeometry.TRAFFIC_LAMP_WIDTH * density
    val h = MonitorHistogramGeometry.TRAFFIC_LAMP_HEIGHT * density
    val left = MonitorHistogramGeometry.TRAFFIC_OUTER_PAD * density
    val right = size.width - MonitorHistogramGeometry.TRAFFIC_OUTER_PAD * density - w
    val crush = listOf(traffic.red.crush, traffic.green.crush, traffic.blue.crush)
    val clip = listOf(traffic.red.clip, traffic.green.clip, traffic.blue.clip)
    val colors = listOf(MeterRed, MeterGreen, MeterBlue)
    colors.forEachIndexed { i, color ->
        val y = 12f * density + i * (h + 3f * density)
        drawLamp(left, y, w, h, color, crush[i])
        drawLamp(right, y, w, h, color, clip[i])
    }
}

private fun DrawScope.drawLamp(x: Float, y: Float, w: Float, h: Float, color: Color, hot: Boolean) {
    val corner = CornerRadius(2.dp.toPx())
    if (hot) {
        drawRoundRect(color, Offset(x, y), Size(w, h), corner)
    }
    drawRoundRect(
        color.copy(alpha = if (hot) 1f else 0.8f),
        Offset(x, y),
        Size(w, h),
        corner,
        style = Stroke(1.5.dp.toPx()),
    )
}
