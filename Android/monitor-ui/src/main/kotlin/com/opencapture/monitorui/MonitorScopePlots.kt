package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeChroma
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeLevelAxis
import com.opencapture.opencine.media.WaveformIre
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt
import kotlin.math.cos
import kotlin.math.sin

private val Boundary = Color(220 / 255f, 235 / 255f, 225 / 255f, 0.8f)
private val ClipColor = Color(255 / 255f, 150 / 255f, 142 / 255f, 0.8f)
private val MiddleColor = Color(246 / 255f, 241 / 255f, 226 / 255f, 0.8f)
private val GridFaint = Color(220 / 255f, 235 / 255f, 225 / 255f, 0.10f)
private val LumaGhost = Color(182 / 255f, 190 / 255f, 186 / 255f, 0.08f)
private val LumaTrace = Color(222 / 255f, 230 / 255f, 224 / 255f, 1f)
private val LumaHot = Color(1f, 1f, 1f, 1f)
private val OverlayRed = Color(255 / 255f, 64 / 255f, 54 / 255f, 0.55f)
private val OverlayGreen = Color(70 / 255f, 240 / 255f, 110 / 255f, 0.55f)
private val OverlayBlue = Color(72 / 255f, 148 / 255f, 255 / 255f, 0.62f)
private val ParadeRed = Color(255 / 255f, 86 / 255f, 78 / 255f, 1f)
private val ParadeGreen = Color(102 / 255f, 232 / 255f, 132 / 255f, 1f)
private val ParadeBlue = Color(92 / 255f, 156 / 255f, 255 / 255f, 1f)
private val VectorRing = Color(220 / 255f, 235 / 255f, 225 / 255f, 0.55f)
private val VectorFaint = Color(220 / 255f, 235 / 255f, 225 / 255f, 0.30f)

@Composable
fun MonitorWaveformScopePlot(bundle: ScopeAssistBundle, transfer: MonitorTransfer, table: FloatArray,
    mode: MonitorWaveformMode = MonitorWaveformMode.RGB, intensity: Double = 0.25,
    guides: MonitorScopeGuides = MonitorScopeGuides(), modifier: Modifier = Modifier) =
    MonitorWaveformScopePlot(bundle, ScopeLevelAxis(table, WaveformIre.middleGrayIRE(transfer)), mode,
        intensity, guides, modifier)

/** A source with its own measured code placement passes its axis directly. */
@Composable
fun MonitorWaveformScopePlot(bundle: ScopeAssistBundle, axis: ScopeLevelAxis,
    mode: MonitorWaveformMode = MonitorWaveformMode.RGB, intensity: Double = 0.25,
    guides: MonitorScopeGuides = MonitorScopeGuides(), modifier: Modifier = Modifier) {
    val table = axis.table
    val measurer = rememberTextMeasurer()
    var trace by remember { mutableStateOf<ImageBitmap?>(null) }
    val layers = remember { MonitorScopeTraceRaster.TraceLayers() }
    LaunchedEffect(bundle.revision, mode, intensity, table) {
        val live = bundle.samples.points
        val trail = bundle.trailSamples.points
        val mode = mode
        val next =
            withContext(Dispatchers.Default) {
                layers.waveform(live, trail, table, mode, intensity)
            }
        trace = next
    }
    Canvas(modifier.fillMaxSize()) {
        val livePlot = MonitorScopeGeometry.waveformPlot(this.size.width, this.size.height, this.density)
        blitScopePlot(trace, livePlot)
        drawWaveGuides(livePlot, if (axis.supportsCalibratedReferences) guides else MonitorScopeGuides(false, false, false), axis.middleGrayIre, this.density)
        drawScopeTitle(measurer, "WAVE", mode.label.uppercase())
    }
}

@Composable
fun MonitorParadeScopePlot(bundle: ScopeAssistBundle, transfer: MonitorTransfer, table: FloatArray,
    mode: MonitorParadeMode = MonitorParadeMode.RGB, intensity: Double = 1.0,
    guides: MonitorScopeGuides = MonitorScopeGuides(), modifier: Modifier = Modifier) =
    MonitorParadeScopePlot(bundle, ScopeLevelAxis(table, WaveformIre.middleGrayIRE(transfer)), mode,
        intensity, guides, modifier)

@Composable
fun MonitorParadeScopePlot(bundle: ScopeAssistBundle, axis: ScopeLevelAxis,
    mode: MonitorParadeMode = MonitorParadeMode.RGB, intensity: Double = 1.0,
    guides: MonitorScopeGuides = MonitorScopeGuides(), modifier: Modifier = Modifier) {
    val table = axis.table
    val measurer = rememberTextMeasurer()
    var trace by remember { mutableStateOf<ImageBitmap?>(null) }
    val layers = remember { MonitorScopeTraceRaster.TraceLayers() }
    LaunchedEffect(bundle.revision, mode, intensity, table) {
        val live = bundle.samples.points
        val trail = bundle.trailSamples.points
        val mode = mode
        val next =
            withContext(Dispatchers.Default) {
                layers.parade(live, trail, table, mode, intensity)
            }
        trace = next
    }
    Canvas(modifier.fillMaxSize()) {
        val livePlot = MonitorScopeGeometry.waveformPlot(this.size.width, this.size.height, this.density)
        blitScopePlot(trace, livePlot)
        // iOS ParadeOverlay does not paint lane letters or vertical dividers.
        drawWaveGuides(livePlot, if (axis.supportsCalibratedReferences) guides else MonitorScopeGuides(false, false, false), axis.middleGrayIre, this.density)
        drawScopeTitle(measurer, "PARADE", mode.label.uppercase())
    }
}

@Composable
fun MonitorVectorscopeScopePlot(bundle: ScopeAssistBundle,
    zoom: MonitorVectorscopeZoom = MonitorVectorscopeZoom.X1, brightness: Int = 100,
    modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    val intensity = brightness.coerceIn(0, 200) / 100.0
    val gain = zoom.gain
    var trace by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(bundle.revision, gain, intensity) {
        val trailPts = bundle.trailVectorscopePoints
        val livePts = bundle.vectorscopePoints
        val next =
            withContext(Dispatchers.Default) {
                MonitorScopeTraceRaster.vectorscope(livePts, trailPts, gain, intensity)
            }
        trace = next
    }
    Canvas(modifier.fillMaxSize()) {
        val d = density
        val plot = MonitorVectorscopeGraticule.plotSquare(this.size.width, this.size.height, d)
        blitScopePlot(trace, plot)
        val arm = MonitorVectorscopeGraticule.CROSS_ARM * d
        drawCircle(VectorRing, radius = plot.width / 2f, center = Offset(plot.midX, plot.midY), style = Stroke(1.25f))
        drawLine(
            VectorFaint,
            Offset(plot.midX - arm, plot.midY),
            Offset(plot.midX + arm, plot.midY),
            1f,
        )
        drawLine(
            VectorFaint,
            Offset(plot.midX, plot.midY - arm),
            Offset(plot.midX, plot.midY + arm),
            1f,
        )
        val skin = MonitorVectorscopeGraticule.skinEnd(plot)
        drawLine(
            MiddleColor,
            Offset(plot.midX, plot.midY),
            Offset(skin.x, skin.y),
            1f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f)),
        )
        val box = MonitorVectorscopeGraticule.BOX_SIDE * d
        for (target in MonitorVectorscopeGraticule.targets) {
            val pt = MonitorVectorscopeGraticule.targetCenter(target.red, target.green, target.blue, plot)
            drawRect(VectorRing, Offset(pt.x - box / 2f, pt.y - box / 2f), Size(box, box), style = Stroke(1f))
            val dx = pt.x - plot.midX
            val dy = pt.y - plot.midY
            val len = maxOf(1f, kotlin.math.hypot(dx, dy))
            val push = MonitorVectorscopeGraticule.LABEL_PUSH * d
            drawText(
                measurer,
                target.label,
                Offset(pt.x + dx / len * push - 4f * d, pt.y + dy / len * push - 4f * d),
                TextStyle(color = VectorRing, fontSize = 6.5.sp, fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Bold),
            )
        }
        drawScopeTitle(measurer, "VECTOR", "MON · ${zoom.label.uppercase()}")
    }
}

private fun DrawScope.drawWaveGuides(plot: MonitorScopeRect, guides: MonitorScopeGuides, gray: Double, density: Float) {
    val dash = floatArrayOf(floatArrayOf(3f, 3f)[0] * density, floatArrayOf(3f, 3f)[1] * density)
    for (stroke in guideStrokes(guides, gray)) {
        val y = MonitorScopeGeometry.plotY(stroke.ire, plot, density)
        val isGray = kotlin.math.abs(stroke.ire - gray) < 0.05
        val color = if (stroke.crushClip) ClipColor else if (isGray) MiddleColor else Boundary
        val effect = if (stroke.dashed) PathEffect.dashPathEffect(dash) else null
        drawLine(color, Offset(plot.minX, y), Offset(plot.maxX, y), if (isGray) 1f else 1.25f, pathEffect = effect)
    }
}

private fun DrawScope.blitScopePlot(trace: ImageBitmap?, dstPlot: MonitorScopeRect) {
    if (trace == null) return
    drawImage(
        trace,
        dstOffset = IntOffset(dstPlot.minX.roundToInt(), dstPlot.minY.roundToInt()),
        dstSize =
            IntSize(
                dstPlot.width.roundToInt().coerceAtLeast(1),
                dstPlot.height.roundToInt().coerceAtLeast(1),
            ),
        filterQuality = FilterQuality.None,
        blendMode = BlendMode.Plus,
    )
}

private fun DrawScope.drawScopeTitle(measurer: TextMeasurer, title: String, chip: String) {
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

private data class GuideStroke(val ire: Double, val dashed: Boolean, val crushClip: Boolean)
private fun guideStrokes(guides: MonitorScopeGuides, gray: Double): List<GuideStroke> = buildList {
    add(GuideStroke(0.0, false, false)); add(GuideStroke(100.0, false, false))
    if (guides.crush) add(GuideStroke(5.0, true, true))
    if (guides.clip) add(GuideStroke(95.0, true, true))
    if (guides.middle) add(GuideStroke(gray, false, false))
}

object MonitorVectorscopeGraticule {
    const val SKIN_ANGLE_DEGREES = 123.0
    const val SKIN_LENGTH = 0.92
    const val BOX_SIDE = 7f
    const val LABEL_PUSH = 10f
    const val CROSS_ARM = 8f
    data class Target(val label: String, val red: Int, val green: Int, val blue: Int)

    val targets =
        listOf(
            Target("R", 191, 0, 0),
            Target("Mg", 191, 0, 191),
            Target("B", 0, 0, 191),
            Target("Cy", 0, 191, 191),
            Target("G", 0, 191, 0),
            Target("Yl", 191, 191, 0),
        )

    fun plotSquare(width: Float, height: Float, density: Float = 1f): MonitorScopeRect {
        val sidePad = 6f * density
        val title = 26f * density
        val bottom = 8f * density
        val plot =
            MonitorScopeRect(
                sidePad,
                title,
                width - sidePad * 2f,
                maxOf(1f, height - title - bottom),
            )
        val side = minOf(plot.width, plot.height)
        return MonitorScopeRect(plot.midX - side / 2f, plot.midY - side / 2f, side, side)
    }

    fun skinEnd(rect: MonitorScopeRect): MonitorScopePoint {
        val radius = rect.width / 2f
        val angle = Math.toRadians(SKIN_ANGLE_DEGREES)
        return MonitorScopePoint(
            rect.midX + (cos(angle) * radius * SKIN_LENGTH).toFloat(),
            rect.midY - (sin(angle) * radius * SKIN_LENGTH).toFloat(),
        )
    }

    fun rec709Chroma(red: Double, green: Double, blue: Double): Pair<Double, Double> {
        return ScopeChroma.rec709(red, green, blue)
    }

    fun targetCenter(red: Int, green: Int, blue: Int, rect: MonitorScopeRect): MonitorScopePoint {
        val chroma = rec709Chroma(red / 255.0, green / 255.0, blue / 255.0)
        return MonitorScopePoint(
            rect.midX + chroma.first.toFloat() * rect.width,
            rect.midY - chroma.second.toFloat() * rect.height,
        )
    }
}
