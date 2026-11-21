package com.opencapture.monitorui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.waterfall
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlin.math.abs
import kotlin.math.ceil
import kotlinx.coroutines.delay

/**
 * Space the zoom ruler keeps clear above and below it, in dp from the window's top and bottom
 * edges: the status row and the capture bar in portrait, the safe area in landscape.
 */
data class MonitorZoomClearance(val top: Float = 0f, val bottom: Float = 0f) {
    companion object {
        /**
         * Portrait: from 8 dp under the status row to 12 dp above the capture bar, the system rail
         * and the record button. Landscape: the safe area, at least 12 dp from each edge.
         */
        fun forLayout(layout: LiveMonitorLayout): MonitorZoomClearance {
            val height = layout.viewportHeight
            val edgeTop = maxOf(layout.safeTop, 12f)
            val edgeBottom = maxOf(layout.safeBottom, 12f)
            if (height <= layout.viewportWidth) return MonitorZoomClearance(edgeTop, edgeBottom)
            val top = if (layout.topDeck.height > 1f) layout.topDeck.maxY + 8f else edgeTop
            val floor = listOf(layout.capture, layout.rail, layout.record)
                .filter { it.height > 1f && it.minY > height / 2f }
                .minOfOrNull { it.minY - 12f } ?: (height - edgeBottom)
            return MonitorZoomClearance(top, maxOf(edgeBottom, height - floor))
        }
    }
}

/** Ruler sizes in dp (Swift `MonitorZoomDial` uses the same values in points). */
internal object MonitorZoomRulerMetrics {
    const val WIDTH = 44f
    const val EDGE = 12f
    /** The scale's ends sit this far inside the capsule so the end ticks stay on the glass. */
    const val INSET = 14f
    /** Room left of the ruler for the whole-step labels. */
    const val LABEL_GUTTER = 28f
    /** Extra touch width on the picture side of the ruler. */
    const val TOUCH_MARGIN = 12f
    const val GAP = 8f
    /** Labels closer than this are thinned so they never collide. */
    const val LABEL_SPACING = 18f
}

private data class ZoomRulerGeometry(
    val width: Int,
    val height: Int,
    val density: Float,
    val fontScale: Float,
    val layoutDirection: LayoutDirection,
    val safeInsets: IntRect,
    val clearance: MonitorZoomClearance,
    val maximum: Double,
)

/** Native insets are available before Compose's lazy inset holder first dispatch. */
@Suppress("DEPRECATION")
private fun physicalZoomInsets(view: android.view.View, observed: IntRect): IntRect {
    val insets = view.rootWindowInsets ?: return observed
    val bars = if (android.os.Build.VERSION.SDK_INT >= 30) {
        insets.getInsetsIgnoringVisibility(android.view.WindowInsets.Type.systemBars() or
            android.view.WindowInsets.Type.displayCutout())
    } else android.graphics.Insets.of(insets.stableInsetLeft, insets.stableInsetTop,
        insets.stableInsetRight, insets.stableInsetBottom)
    val cutout = insets.displayCutout
    val waterfall = if (android.os.Build.VERSION.SDK_INT >= 30) cutout?.waterfallInsets else null
    return IntRect(maxOf(bars.left, cutout?.safeInsetLeft ?: 0, waterfall?.left ?: 0),
        maxOf(bars.top, cutout?.safeInsetTop ?: 0, waterfall?.top ?: 0),
        maxOf(bars.right, cutout?.safeInsetRight ?: 0, waterfall?.right ?: 0),
        maxOf(bars.bottom, cutout?.safeInsetBottom ?: 0, waterfall?.bottom ?: 0))
}

/**
 * The vertical zoom ruler on the trailing edge: linear in zoom factor, the camera's maximum at the
 * top, dragged anywhere in 0.1x steps ([onStep] fires on each new step). Presets sit in a column
 * beside it and the value readout beside its top. Tapping outside closes it. Camera limits,
 * captions and writes belong to the adapter. Swift twin: `MonitorZoomDial`.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MonitorZoomRuler(initial: Double, maximum: Double, onChange: (Double) -> Unit, onDismiss: () -> Unit,
    opticalStops: List<Double> = listOf(1.0), caption: (Double) -> String = { "ZOOM" },
    clearance: MonitorZoomClearance = MonitorZoomClearance(), onStep: () -> Unit = {},
    presets: MonitorZoomPresetControls? = null, driven: Double? = null,
    label: (Double) -> String = { MonitorZoomRulerScale.readout(it) }) {
    val maxZoom = maximum.takeIf { it.isFinite() }?.coerceAtLeast(1.0) ?: 1.0
    var value by remember { mutableDoubleStateOf(initial.takeIf { it.isFinite() }?.coerceIn(1.0, maxZoom) ?: 1.0) }
    var entering by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }
    val motion by animateFloatAsState(if (entering && !closing) 1f else 0f,
        tween(if (closing) MonitorMotion.ZOOM_OUT_MS else MonitorMotion.ZOOM_IN_MS,
            easing = if (closing) MonitorMotion.ZoomOut else MonitorMotion.Soft), label = "zoom-ruler")
    val send by rememberUpdatedState(onChange)
    val dismiss by rememberUpdatedState(onDismiss)
    val step by rememberUpdatedState(onStep)
    LaunchedEffect(Unit) { entering = true }
    LaunchedEffect(closing) { if (closing) { delay(MonitorMotion.ZOOM_HOST_MS.toLong()); dismiss() } }
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val layoutDirection = LocalLayoutDirection.current
    // A focused overlay may reveal transient system bars. Physical geometry ignores that
    // visibility change while still observing cutout and waterfall changes.
    val safeInsets = WindowInsets.systemBarsIgnoringVisibility
        .union(WindowInsets.displayCutout).union(WindowInsets.waterfall)
    val geometry = ZoomRulerGeometry(configuration.screenWidthDp, configuration.screenHeightDp,
        density.density, density.fontScale, layoutDirection,
        physicalZoomInsets(LocalView.current,
            IntRect(safeInsets.getLeft(density, layoutDirection), safeInsets.getTop(density),
                safeInsets.getRight(density, layoutDirection), safeInsets.getBottom(density))),
        clearance, maxZoom)
    val openingGeometry = remember { geometry }
    if (geometry != openingGeometry) {
        // A pointer belongs to the geometry where it began. Close before another event maps
        // through a different ruler; the adapter ends its existing camera transaction.
        LaunchedEffect(geometry) { dismiss() }
        return
    }
    val m = MonitorZoomRulerMetrics
    val screenWidth = configuration.screenWidthDp.toFloat()
    val screenHeight = configuration.screenHeightDp.toFloat()
    val trailingInset = geometry.safeInsets.right / density.density
    val rulerRight = screenWidth - trailingInset - m.EDGE
    val rulerLeft = rulerRight - m.WIDTH
    val top = clearance.top.takeIf { it.isFinite() }?.coerceIn(0f, screenHeight) ?: 0f
    val bottom = (screenHeight - (clearance.bottom.takeIf { it.isFinite() } ?: 0f)).coerceIn(top, screenHeight)
    val rulerHeight = bottom - top
    val scale = MonitorZoomRulerScale(1.0, maxZoom, (rulerHeight - 2 * m.INSET).toDouble())
    // A host-driven move (a preset ramp) moves the marker without sending it back.
    LaunchedEffect(driven) { driven?.takeIf { it.isFinite() }?.let { value = it.coerceIn(1.0, maxZoom) } }
    val optical = opticalStops.any { abs(it - value) < .05 }
    val accent = if (optical) MonitorPalette.accent else MonitorPalette.digitalCrop
    val opticalMax = opticalStops.filter { it.isFinite() && it > 0.0 }.maxOrNull() ?: 1.0
    val textMeasurer = rememberTextMeasurer()
    fun update(next: Double) {
        if (!next.isFinite() || closing) return
        val stepped = scale.quantized(next)
        if (stepped == value) return
        step()
        value = stepped
        send(stepped)
    }
    val provider = remember { object : PopupPositionProvider {
        override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize,
            layoutDirection: LayoutDirection, popupContentSize: IntSize) = IntOffset(0, 0)
    } }
    Popup(popupPositionProvider = provider, onDismissRequest = { closing = true },
        properties = PopupProperties(focusable = true, dismissOnClickOutside = true, clippingEnabled = false)) {
        // A focused modal window owns input above every underlying control (the picture's
        // SurfaceView included); a tap anywhere off the ruler closes it.
        Box(Modifier.size(screenWidth.dp, screenHeight.dp)
            .pointerInput(Unit) { detectTapGestures { closing = true } }) {
            val slide = Modifier.graphicsLayer {
                alpha = motion
                translationX = 24.dp.toPx() * (1f - motion)
            }
            val besideRight = rulerLeft - m.LABEL_GUTTER - m.GAP
            val presetHeight = (MonitorZoomPresets.SLOT_COUNT + 1) * 44f + MonitorZoomPresets.SLOT_COUNT * 10f
            val readoutTop = top + rulerHeight * .08f
            // The readout moves past the preset column when a short ruler would stack them.
            val readoutRight = if (presets != null && top + (rulerHeight - presetHeight) / 2f < readoutTop + 48f)
                besideRight - 44f - 12f else besideRight
            if (presets != null) {
                Box(Modifier.offset(0.dp, top.dp).size(besideRight.coerceAtLeast(0f).dp, rulerHeight.dp)
                    .then(slide), contentAlignment = Alignment.CenterEnd) {
                    MonitorZoomPresetStrip(presets, maxZoom, vertical = true, label = label, onSaved = step)
                }
            }
            Column(Modifier.offset(0.dp, readoutTop.dp).width(readoutRight.coerceAtLeast(0f).dp).then(slide),
                horizontalAlignment = Alignment.End) {
                Text(MonitorZoomRulerScale.readout(value), style = MonitorTypography.readout(22f, FontWeight.Bold),
                    textAlign = TextAlign.End, maxLines = 1)
                Text(caption(value), style = MonitorTypography.text(10f, FontWeight.Medium), color = accent,
                    textAlign = TextAlign.End, maxLines = 1)
            }
            // Whole-step labels left of the ruler, thinned where they would collide.
            Canvas(Modifier.offset((rulerLeft - m.LABEL_GUTTER).dp, top.dp)
                .size(m.LABEL_GUTTER.dp, rulerHeight.dp).then(slide)) {
                val majors = scale.ticks.filter { it.kind == MonitorZoomRulerTick.Kind.MAJOR }
                val spacing = if (scale.maximum > scale.minimum) scale.length / (scale.maximum - scale.minimum) else 0.0
                val every = if (spacing > 0) ceil(m.LABEL_SPACING / spacing).toInt().coerceAtLeast(1) else 1
                for (tick in majors) {
                    val whole = Math.round(tick.value).toInt()
                    if ((whole - 1) % every != 0) continue
                    val digital = tick.value > opticalMax + .02
                    val measured = textMeasurer.measure("$whole×", MonitorTypography.readout(12f, FontWeight.SemiBold))
                    val y = (m.INSET + tick.offset.toFloat()).dp.toPx()
                    drawText(measured, (if (digital) MonitorPalette.digitalCrop else Color.White).copy(alpha = .78f),
                        topLeft = Offset(size.width - 4.dp.toPx() - measured.size.width, y - measured.size.height / 2f))
                }
            }
            Box(Modifier.offset((rulerLeft - m.TOUCH_MARGIN).dp, top.dp)
                .size((m.WIDTH + m.TOUCH_MARGIN).dp, rulerHeight.dp)
                .then(slide)
                .testTag("monitor.zoom.dial")
                .semantics {
                    contentDescription = "Zoom"
                    stateDescription = "${MonitorZoomRulerScale.readout(value)}, ${caption(value)}"
                    val steps = ((scale.maximum - scale.minimum) / MonitorZoomRulerScale.STEP).let {
                        Math.round(it).toInt() - 1 }.coerceAtLeast(0)
                    progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(),
                        scale.minimum.toFloat()..scale.maximum.toFloat(), steps)
                    setProgress { update(it.toDouble()); true }
                    customActions = listOf(CustomAccessibilityAction("Close zoom") { closing = true; true })
                }
                .pointerInput(geometry, closing) {
                    if (closing) return@pointerInput
                    fun valueAt(y: Float) = scale.valueAtOffset((y.toDp().value - m.INSET).toDouble())
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        down.consume()
                        var pressed = true
                        try {
                            update(valueAt(down.position.y))
                            while (pressed) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                pressed = change.pressed
                                change.consume()
                                if (pressed) update(valueAt(change.position.y))
                            }
                            pressed = false
                        } finally {
                            // Disposal or a geometry change can interrupt a held finger. Close
                            // exactly this ruler so its adapter releases the zoom transaction.
                            if (pressed) dismiss()
                        }
                    }
                }) {
                Canvas(Modifier.padding(start = m.TOUCH_MARGIN.dp).fillMaxSize()
                    .monitorMaterial(MonitorMaterial.Zoom, RoundedCornerShape(50))) {
                    val inset = m.INSET.dp.toPx()
                    val w = size.width
                    for (tick in scale.ticks) {
                        val y = inset + tick.offset.toFloat().dp.toPx()
                        val digital = tick.value > opticalMax + .02
                        val stop = opticalStops.any { abs(it - tick.value) < .01 }
                        val (from, alpha, stroke) = when (tick.kind) {
                            MonitorZoomRulerTick.Kind.MAJOR -> Triple(.12f, .8f, 2f)
                            MonitorZoomRulerTick.Kind.MID -> Triple(.60f, .55f, 1.5f)
                            MonitorZoomRulerTick.Kind.MINOR -> Triple(.72f, .32f, 1f)
                        }
                        val color = when {
                            digital -> MonitorPalette.digitalCrop.copy(alpha = alpha)
                            stop -> MonitorPalette.accent
                            else -> Color.White.copy(alpha = alpha)
                        }
                        drawLine(color, Offset(w * from, y), Offset(w * .88f, y), stroke.dp.toPx(), StrokeCap.Round)
                    }
                    val marker = inset + scale.offsetFor(value).toFloat().dp.toPx()
                    drawLine(accent, Offset(w * .06f, marker), Offset(w * .94f, marker), 3.dp.toPx(), StrokeCap.Round)
                }
            }
        }
    }
}
