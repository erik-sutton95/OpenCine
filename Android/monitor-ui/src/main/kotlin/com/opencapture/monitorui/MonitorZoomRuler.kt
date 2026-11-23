package com.opencapture.monitorui

import androidx.compose.animation.core.animateFloatAsState
import kotlin.math.hypot
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
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
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlin.math.abs
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

/** Zoom panel sizes in dp (Swift `MonitorZoomDial` uses the same values in points). */
internal object MonitorZoomRulerMetrics {
    /** The ticks' strip inside the ruler. */
    const val RULER_WIDTH = 40f
    const val EDGE = 12f
    /** Room left of the ticks for the whole-step labels. */
    const val LABEL_GUTTER = 30f
    /** Keeps the end ticks off the ruler's ends. */
    const val INSET = 14f
    /** The column holding the readout, presets and ramp key. */
    const val COLUMN_WIDTH = 56f
    const val PADDING = 8f
    const val GAP = 6f
    const val PANEL_CORNER = 14f
    const val RULER_CORNER = 9f
    /** A press that travels less than this is a tap. */
    const val TAP_TRAVEL = 10f
    /** Ticks fade over this distance before the ruler's ends. */
    const val FADE = 40f
    const val PANEL_WIDTH = PADDING + COLUMN_WIDTH + GAP + LABEL_GUTTER + RULER_WIDTH + PADDING / 2
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
 * The zoom control: one panel on the trailing edge holding the current zoom, the presets, the
 * ramp key and a vertical ruler. The ruler behaves like the other setting dials
 * (`MonitorDurationDial`, `MonitorValueDrum`), only vertical: the scale slides under a fixed
 * center line, higher values above. A drag moves it from the current zoom smoothly (down zooms
 * in), sending every move live with an [onStep] haptic at each 0.1x tick; a tap goes to the step
 * under the finger (a whole step when close to one). The ramp key opens [rampPanel], the host's
 * camera value popup (a plain drum panel when null). Tapping outside closes it. Camera limits,
 * captions and writes belong to the adapter. Swift twin: `MonitorZoomDial`.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MonitorZoomRuler(initial: Double, maximum: Double, onChange: (Double) -> Unit, onDismiss: () -> Unit,
    opticalStops: List<Double> = listOf(1.0), caption: (Double) -> String = { "ZOOM" },
    clearance: MonitorZoomClearance = MonitorZoomClearance(), onStep: () -> Unit = {},
    presets: MonitorZoomPresetControls? = null, driven: Double? = null,
    label: (Double) -> String = { MonitorZoomRulerScale.readout(it) },
    rampPanel: (@Composable (close: () -> Unit) -> Unit)? = null) {
    val maxZoom = maximum.takeIf { it.isFinite() }?.coerceAtLeast(1.0) ?: 1.0
    // The reported zoom (the opening reading, then what was sent or driven) and, while a finger is
    // down, the scrub value drawn under the center line.
    var value by remember { mutableDoubleStateOf(initial.takeIf { it.isFinite() }?.coerceIn(1.0, maxZoom) ?: 1.0) }
    var scrub by remember { mutableStateOf<Double?>(null) }
    var rampOpen by remember { mutableStateOf(false) }
    var entering by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }
    val motion by animateFloatAsState(if (entering && !closing) 1f else 0f,
        tween(if (closing) MonitorMotion.ZOOM_OUT_MS else MonitorMotion.ZOOM_IN_MS,
            easing = if (closing) MonitorMotion.ZoomOut else MonitorMotion.Soft), label = "zoom-ruler")
    val send by rememberUpdatedState(onChange)
    val dismiss by rememberUpdatedState(onDismiss)
    val step by rememberUpdatedState(onStep)
    LaunchedEffect(Unit) { entering = true }
    LaunchedEffect(closing) {
        if (closing) { rampOpen = false; delay(MonitorMotion.ZOOM_HOST_MS.toLong()); dismiss() }
    }
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
    val safeTop = geometry.safeInsets.top / density.density
    val safeBottom = geometry.safeInsets.bottom / density.density
    val panelRight = screenWidth - geometry.safeInsets.right / density.density - m.EDGE
    val panelLeft = panelRight - m.PANEL_WIDTH
    fun finite(v: Float) = v.takeIf { it.isFinite() } ?: 0f
    val top = maxOf(finite(clearance.top), safeTop + m.EDGE).coerceIn(0f, screenHeight)
    val bottom = (screenHeight - maxOf(finite(clearance.bottom), safeBottom + m.EDGE)).coerceIn(top, screenHeight)
    val panelHeight = bottom - top
    val rulerHeight = (panelHeight - m.PADDING * 2).coerceAtLeast(0f)
    val center = rulerHeight / 2f
    val halfSpan = (center - m.INSET).coerceAtLeast(0f)
    val scale = MonitorZoomRulerScale(1.0, maxZoom)
    // A host-driven move (a preset ramp) moves the scale without sending it back.
    LaunchedEffect(driven) { driven?.takeIf { it.isFinite() }?.let { value = it.coerceIn(1.0, maxZoom) } }
    val shown = scrub ?: value
    val ink = if (opticalStops.any { abs(it - value) < .05 }) MonitorPalette.accent else MonitorPalette.digitalCrop
    val opticalMax = opticalStops.filter { it.isFinite() && it > 0.0 }.maxOrNull() ?: 1.0
    val ticks = scale.ticks(shown, halfSpan.toDouble())
    fun fade(offset: Double): Float = if (halfSpan <= 0f) 1f else
        ((halfSpan - abs(offset.toFloat())) / m.FADE).coerceIn(0f, 1f)
    val textMeasurer = rememberTextMeasurer()
    /** Shows [next] under the center line and sends it live, with a tick per new 0.1x step. */
    fun move(next: Double) {
        // Read the state now: the gesture keeps this function from an earlier composition.
        val current = scrub ?: value
        if (closing || !next.isFinite() || (next == current && scrub != null)) return
        if (MonitorZoomRulerScale.tick(next) != MonitorZoomRulerScale.tick(current)) step()
        scrub = next
        value = next
        send(next)
    }
    /** Accessibility steps 0.1x from the reported zoom. */
    fun stepTo(next: Double) {
        if (closing || !next.isFinite()) return
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
        // SurfaceView included); a tap anywhere off the panel closes it.
        Box(Modifier.size(screenWidth.dp, screenHeight.dp)
            .pointerInput(Unit) { detectTapGestures { closing = true } }) {
            Row(Modifier.offset(panelLeft.dp, top.dp).size(m.PANEL_WIDTH.dp, panelHeight.dp)
                .graphicsLayer {
                    alpha = motion
                    translationX = 24.dp.toPx() * (1f - motion)
                }
                .monitorMaterial(MonitorMaterial.Zoom, RoundedCornerShape(m.PANEL_CORNER.dp))
                // The panel's own background never closes it.
                .pointerInput(Unit) { detectTapGestures { } }
                .padding(start = m.PADDING.dp, end = (m.PADDING / 2).dp, top = m.PADDING.dp, bottom = m.PADDING.dp),
                horizontalArrangement = Arrangement.spacedBy(m.GAP.dp)) {
                Column(Modifier.width(m.COLUMN_WIDTH.dp).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    val readout = MonitorZoomRulerScale.readout(shown)
                    val words = caption(shown)
                    Column(Modifier.padding(top = 4.dp).clearAndSetSemantics { },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(readout, style = MonitorTypography.readout(fitted(readout, 17f, m.COLUMN_WIDTH, .62f),
                            FontWeight.Bold), maxLines = 1, softWrap = false)
                        if (words.isNotEmpty()) Text(words, color = ink, maxLines = 1, softWrap = false,
                            style = MonitorTypography.text(fitted(words, 9f, m.COLUMN_WIDTH, .72f), FontWeight.SemiBold)
                                .copy(letterSpacing = 1.sp))
                    }
                    Spacer(Modifier.weight(1f))
                    if (presets != null) MonitorZoomPresetStrip(presets, maxZoom, vertical = true, label = label,
                        onSaved = step, onRampTap = { rampOpen = true })
                    Spacer(Modifier.weight(1f))
                }
                Box(Modifier.width((m.LABEL_GUTTER + m.RULER_WIDTH).dp).height(rulerHeight.dp)
                    .testTag("monitor.zoom.dial")
                    .semantics {
                        contentDescription = "Zoom"
                        stateDescription = listOf(MonitorZoomRulerScale.readout(shown), caption(shown))
                            .filter { it.isNotEmpty() }.joinToString(", ")
                        val steps = ((scale.maximum - scale.minimum) / MonitorZoomRulerScale.STEP).let {
                            Math.round(it).toInt() - 1 }.coerceAtLeast(0)
                        progressBarRangeInfo = ProgressBarRangeInfo(shown.toFloat(),
                            scale.minimum.toFloat()..scale.maximum.toFloat(), steps)
                        setProgress { stepTo(it.toDouble()); true }
                        customActions = listOf(CustomAccessibilityAction("Close zoom") { closing = true; true })
                    }
                    .pointerInput(geometry, closing) {
                        if (closing) return@pointerInput
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            down.consume()
                            val start = down.position
                            val origin = value
                            var dragging = false
                            var pressed = true
                            try {
                                while (pressed) {
                                    val event = awaitPointerEvent()
                                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                    pressed = change.pressed
                                    change.consume()
                                    val dx = (change.position.x - start.x).toDp().value
                                    val dy = (change.position.y - start.y).toDp().value
                                    // Below the tap threshold the scale stays put, as on the other dials.
                                    if (!dragging && hypot(dx, dy) >= m.TAP_TRAVEL) dragging = true
                                    if (dragging) move(scale.dragged(origin, dy.toDouble()))
                                }
                                if (!pressed && !dragging) {
                                    // A tap: the step under the finger, measured from the center line.
                                    move(scale.tapped((start.y.toDp().value - center).toDouble(), scrub ?: value))
                                }
                            } finally {
                                scrub = null
                                // Disposal or a geometry change can interrupt a held finger. Close
                                // exactly this ruler so its adapter releases the zoom transaction.
                                if (pressed) dismiss()
                            }
                        }
                    }) {
                    Box(Modifier.align(Alignment.CenterEnd).width(m.RULER_WIDTH.dp).fillMaxHeight()
                        .background(Color.White.copy(alpha = .06f), RoundedCornerShape(m.RULER_CORNER.dp)))
                    Canvas(Modifier.fillMaxSize()) {
                        val strip = m.RULER_WIDTH.dp.toPx()
                        val left = size.width - strip
                        val middle = size.height / 2f
                        for (tick in ticks) {
                            val y = middle + tick.offset.toFloat().dp.toPx()
                            val (from, stroke, alpha) = when (tick.kind) {
                                MonitorZoomRulerTick.Kind.MAJOR -> Triple(.30f, 2f, .9f)
                                MonitorZoomRulerTick.Kind.MID -> Triple(.45f, 1.5f, .6f)
                                MonitorZoomRulerTick.Kind.MINOR -> Triple(.62f, 1f, .32f)
                            }
                            val optical = opticalStops.any { abs(it - tick.value) < .001 }
                            val digital = tick.value > opticalMax + .02
                            val color = if (optical) ink else if (digital) MonitorPalette.digitalCrop else Color.White
                            drawLine(color.copy(alpha = (if (optical) 1f else alpha) * fade(tick.offset)),
                                Offset(left + strip * from, y), Offset(left + strip * .88f, y), stroke.dp.toPx())
                            if (tick.kind == MonitorZoomRulerTick.Kind.MAJOR) {
                                val measured = textMeasurer.measure(label(tick.value),
                                    MonitorTypography.readout(12f, FontWeight.SemiBold))
                                drawText(measured, (if (digital) MonitorPalette.digitalCrop else MonitorPalette.secondary)
                                    .copy(alpha = fade(tick.offset)),
                                    topLeft = Offset(left - 6.dp.toPx() - measured.size.width, y - measured.size.height / 2f))
                            }
                        }
                        // The fixed center line the scale slides under.
                        drawLine(ink, Offset(left + 4.dp.toPx(), middle), Offset(left + strip - 4.dp.toPx(), middle),
                            3.dp.toPx(), StrokeCap.Round)
                    }
                }
            }
            if (rampOpen && presets != null) {
                val close = { rampOpen = false }
                Box(Modifier.fillMaxSize()) {
                    // A transparent backdrop over the viewport closes the ramp popup, not the ruler.
                    Box(Modifier.fillMaxSize().clearAndSetSemantics { }
                        .pointerInput(Unit) { detectTapGestures { close() } })
                    if (rampPanel != null) rampPanel(close)
                    else MonitorZoomRampFallback(presets, safeBottom, step, close)
                }
            }
        }
    }
}

/** Scales a one-line label down so it fits [width] dp, from [size] sp at most. */
private fun fitted(text: String, size: Float, width: Float, em: Float): Float =
    if (text.isEmpty()) size else minOf(size, width / (text.length * em)).coerceAtLeast(6f)

/**
 * The ramp choices on a drum, for a host that passes no camera popup ([MonitorZoomRuler]'s
 * `rampPanel`): the drum in a plain glass panel at the bottom.
 */
@Composable
private fun BoxScope.MonitorZoomRampFallback(presets: MonitorZoomPresetControls, safeBottom: Float,
    onDetent: () -> Unit, close: () -> Unit) {
    val options = MonitorZoomPresets.RAMP_CHOICES.map(MonitorZoomPresets::rampLabel)
    val current = MonitorZoomPresets.rampLabel(presets.presets.rampSeconds)
    Column(Modifier.align(Alignment.BottomCenter).padding(bottom = (safeBottom + 12f).dp, start = 12.dp, end = 12.dp)
        .widthIn(max = 420.dp).fillMaxWidth()
        .monitorMaterial(MonitorMaterial.Expanded, RoundedCornerShape(16.dp))
        .pointerInput(Unit) { detectTapGestures { } }
        .testTag("monitor.zoom.ramp.panel")
        .padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("PRESET RAMP  $current", style = MonitorTypography.text(9f, FontWeight.SemiBold), maxLines = 1)
        MonitorValueDrum(options, current, onDetent = onDetent) { label ->
            options.indexOf(label).takeIf { it >= 0 }?.let { presets.onRamp(MonitorZoomPresets.RAMP_CHOICES[it]) }
        }
    }
}
