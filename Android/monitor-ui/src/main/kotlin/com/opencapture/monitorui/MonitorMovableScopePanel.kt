package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Alignment
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp

import kotlin.math.roundToInt


private val PanelShape = RoundedCornerShape(12.dp)
private val ChipShape = RoundedCornerShape(percent = 50)

@Composable
fun MonitorMovableScopePanel(
    identity: String,
    base: MonitorScopeSize,
    scale: Double,
    stored: MonitorScopeStoredCenter?,
    canvas: MonitorScopeRect,
    placementBounds: MonitorScopeRect,
    defaultCenter: MonitorScopePoint,
    enabled: Boolean,
    onStore: (MonitorScopeStoredCenter) -> Unit,
    onScale: ((Double) -> Unit)? = null,
    onOpenOptions: ((MonitorScopeRect) -> Unit)? = null,
    anchorOrigin: Offset = Offset.Zero,
    onActivate: () -> Unit = {},
    onConfirm: () -> Unit = {},
    fillPlate: Boolean = true,
    chip: Boolean = false,
    content: @Composable (MonitorScopeSize) -> Unit,
) {
    val density = LocalDensity.current
    val preferred = MonitorScopePanelMath.panelSize(base, scale)
    val resizable = onScale != null
    val gripPx = if (resizable) with(density) { MonitorScopePanelMath.gripPadDp.dp.toPx() } else 0f
    val minimumHit = with(density) { MonitorScopePanelMath.MIN_GRIP_HIT_DP.dp.toPx() }
    val usable = placementBounds.width >= minimumHit && placementBounds.height >= minimumHit
    val sizePx = MonitorScopePanelMath.fittedSize(
        with(density) { MonitorScopeSize(preferred.width.dp.toPx(), preferred.height.dp.toPx()) },
        placementBounds, gripPx)
    val sizeDp = MonitorScopeSize(sizePx.width / density.density, sizePx.height / density.density)
    val gripPadDp = if (resizable) MonitorScopePanelMath.gripPadDp else 0f
    val gripHit = MonitorScopePanelMath.gripHitSize(sizeDp.width, sizeDp.height)
    val gripOrigin = MonitorScopePanelMath.gripHitOrigin(sizeDp.width, sizeDp.height)
    val gripOverhang = if (resizable) MonitorScopePanelMath.gripOverhang(sizeDp.width, sizeDp.height)
        else MonitorScopePoint(0f, 0f)
    val gripBottomDp = if (resizable) MonitorScopePanelMath.GRIP_BOTTOM_EXTERIOR_DP else 0f
    var session by remember(identity) { mutableStateOf<MonitorScopePoint?>(null) }
    var origin by remember { mutableStateOf<MonitorScopePoint?>(null) }
    var resizeOrigin by remember { mutableStateOf<Double?>(null) }
    var active by remember { mutableStateOf(false) }
    var panelCoords by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var gripCoords by remember { mutableStateOf<LayoutCoordinates?>(null) }
    LaunchedEffect(canvas.width, canvas.height) {
        if (!active) session = null
    }
    var panelFrame by remember { mutableStateOf(MonitorScopeRect(0f, 0f, 0f, 0f)) }
    val rawCenter =
        MonitorScopePanelMath.resolvedCenter(
            session = session,
            stored = stored,
            defaultCenter = defaultCenter,
            size = sizePx,
            bounds = canvas,
        )
    val center = MonitorScopePanelMath.clampWithGrip(rawCenter, sizePx, placementBounds, gripPx)
    val placementState = rememberUpdatedState(placementBounds)
    val centerState = rememberUpdatedState(center)
    val sizeState = rememberUpdatedState(sizePx)
    val scaleState = rememberUpdatedState(scale)
    val canvasState = rememberUpdatedState(canvas)
    if (!usable) return
    val snapGrid = with(density) { MonitorScopePanelMath.POSITION_GRID.dp.toPx() }
    val plateShape = if (chip) ChipShape else PanelShape
    Box(
        Modifier
            .offset {
                IntOffset(
                    (center.x - sizePx.width / 2f - gripOverhang.x * density.density).roundToInt(),
                    (center.y - sizePx.height / 2f - gripOverhang.y * density.density).roundToInt(),
                )
            }
            .size((sizeDp.width + gripPadDp + gripOverhang.x).dp,
                (sizeDp.height + gripBottomDp + gripOverhang.y).dp),
    ) {
        Box(
            Modifier
                .offset(gripOverhang.x.dp, gripOverhang.y.dp)
                .size(sizeDp.width.dp, sizeDp.height.dp)
                .align(Alignment.TopStart)
                .then(if (onOpenOptions != null) Modifier.onGloballyPositioned {
                    val position = it.positionInRoot()
                    val d = density.density
                    panelFrame = MonitorScopeRect((position.x - anchorOrigin.x) / d,
                        (position.y - anchorOrigin.y) / d, it.size.width / d, it.size.height / d)
                } else Modifier)
                // iOS ScopeMiniChrome: shadow outside, one clip, overlay hairline.
                // shadow(clip=true)+clip+Offscreen+border stacked a thick inner edge.
                .shadow(
                    elevation = 16.dp,
                    shape = plateShape,
                    clip = false,
                    ambientColor = Color.Black.copy(alpha = 0.34f),
                    spotColor = Color.Black.copy(alpha = 0.34f),
                )
                .clip(plateShape)
                .then(if (fillPlate) Modifier.monitorMaterial(MonitorMaterial.Scope, plateShape) else Modifier)
                .onGloballyPositioned { panelCoords = it }
                .pointerInput(identity, enabled, base, canvas, placementBounds, density.density) {
                    detectMonitorPanelDrag(
                        holdMs = 300L,
                        enabled = enabled,
                        onDown = onActivate,
                        onLongPress = onOpenOptions?.let { present -> {
                            onConfirm()
                            present(panelFrame)
                        } },
                        onStart = {
                            origin = centerState.value
                            active = true
                            onConfirm()
                        },
                        onDrag = { translation ->
                            val start = origin ?: centerState.value
                            val size = sizeState.value
                            val proposed = MonitorScopePoint(start.x + translation.x, start.y + translation.y)
                            val snapped =
                                MonitorScopePanelMath.clampWithGrip(
                                    MonitorScopePanelMath.snap(proposed, snapGrid),
                                    size,
                                    placementState.value,
                                    gripPx,
                                )
                            session = snapped
                        },
                        onEnd = { _ ->
                            if (canvas == canvasState.value && placementBounds == placementState.value) {
                                session?.let { onStore(MonitorScopeStoredCenter(it, canvas)) }
                            } else session = null
                            origin = null
                            active = false
                        },
                        onCancel = {
                            session = null
                            origin = null
                            active = false
                        },
                        toRoot = { local -> panelCoords?.localToRoot(local) ?: local },
                    )
                },
        ) {
            content(sizeDp)
            Canvas(Modifier.matchParentSize()) {
                val stroke = 1.dp.toPx()
                val inset = stroke / 2f
                val radius =
                    if (chip) {
                        (this.size.minDimension / 2f - inset).coerceAtLeast(0f)
                    } else {
                        (12.dp.toPx() - inset).coerceAtLeast(0f)
                    }
                drawRoundRect(
                    color = MonitorPalette.border,
                    topLeft = Offset(inset, inset),
                    size = Size(this.size.width - stroke, this.size.height - stroke),
                    cornerRadius = CornerRadius(radius, radius),
                    style = Stroke(stroke),
                )
            }
        }
        if (onScale != null) {
            val reachPx = with(density) { (base.width + base.height).dp.toPx() }.coerceAtLeast(1f)
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .offset((gripOrigin.x + gripOverhang.x).dp, (gripOrigin.y + gripOverhang.y).dp)
                    .size(gripHit.dp)
                    .background(Color.Transparent)
                    .onGloballyPositioned { gripCoords = it }
                    .pointerInput(identity, enabled, reachPx) {
                        detectMonitorPanelDrag(
                            holdMs = 300L,
                            enabled = enabled,
                            onDown = onActivate,
                            onStart = {
                                resizeOrigin = scaleState.value
                                active = true
                                onConfirm()
                            },
                            onDrag = { translation ->
                                val start = resizeOrigin ?: scaleState.value
                                val delta = (translation.x + translation.y) / reachPx
                                onScale(start + delta)
                            },
                            onEnd = {
                                resizeOrigin = null
                                active = false
                            },
                            onCancel = {
                                resizeOrigin = null
                                active = false
                            },
                            toRoot = { local -> gripCoords?.localToRoot(local) ?: local },
                        )
                    },
            ) {
                val visual = MonitorScopePanelMath.gripVisualOrigin(gripHit)
                Canvas(
                    Modifier
                        .offset(visual.x.dp, visual.y.dp)
                        .size(MonitorScopePanelMath.GRIP_VISUAL_DP.dp),
                ) {
                    val stroke = 1.5.dp.toPx()
                    val color = if (active) MonitorPalette.accent else MonitorPalette.muted
                    drawLine(
                        color,
                        Offset(0f, size.height),
                        Offset(size.width, size.height),
                        stroke,
                        cap = StrokeCap.Square,
                    )
                    drawLine(
                        color,
                        Offset(size.width, 0f),
                        Offset(size.width, size.height),
                        stroke,
                        cap = StrokeCap.Square,
                    )
                }
            }
        }
    }
}
