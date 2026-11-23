package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.roundToInt

enum class MonitorReferenceMode { BLEND, SPLIT }

internal fun MonitorReferenceMode.rasterOpacity(blend: Float, split: Float): Float =
    (if (this == MonitorReferenceMode.SPLIT) split else blend).coerceIn(0f, 1f)

enum class MonitorReferenceSide { LEFT, RIGHT }

internal fun MonitorReferenceSide.clip(visible: Rect, divider: Float): Rect =
    if (this == MonitorReferenceSide.LEFT) Rect(visible.left, visible.top, divider, visible.bottom)
    else Rect(divider, visible.top, visible.right, visible.bottom)

/** Only matching display apertures may share the comparison rectangle, within rounding error. */
fun monitorReferenceMatches(savedAspect: Float, liveAspect: Float): Boolean =
    savedAspect.isFinite() && liveAspect.isFinite() && savedAspect > 0f && liveAspect > 0f &&
        abs(savedAspect / liveAspect - 1f) <= 0.015f

/** The actual image placement before clipping to the feed well. */
fun monitorReferenceRect(well: Size, aspect: Float, fill: Boolean): Rect? {
    if (!aspect.isFinite() || aspect <= 0f || well.width <= 0f || well.height <= 0f) return null
    val width = if ((well.width / well.height > aspect) == fill) well.width else well.height * aspect
    val height = width / aspect
    val left = (well.width - width) / 2f
    val top = (well.height - height) / 2f
    return Rect(left, top, left + width, top + height)
}

/** A passive image plus a separate, accessible split handle inside the visible picture. */
@Composable
fun MonitorReferenceOverlay(
    image: ImageBitmap,
    mode: MonitorReferenceMode,
    opacity: Float,
    split: Float,
    onSplit: (Float) -> Unit,
    imageRect: (Size) -> Rect?,
    mirrorX: Boolean = false,
    mirrorY: Boolean = false,
    modifier: Modifier = Modifier,
    interactive: Boolean = true,
    splitSide: MonitorReferenceSide = MonitorReferenceSide.LEFT,
    splitOpacity: Float = 1f,
) {
    BoxWithConstraints(modifier) {
        val well = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val imagePlacement = imageRect(well) ?: return@BoxWithConstraints
        val visible = imagePlacement.intersect(Rect(Offset.Zero, well))
        if (visible.width <= 0f || visible.height <= 0f) return@BoxWithConstraints
        val divider = visible.left + visible.width * split.coerceIn(0f, 1f)
        val referenceBounds = if (mode == MonitorReferenceMode.SPLIT) splitSide.clip(visible, divider) else visible
        Canvas(Modifier.fillMaxSize()) {
            clipRect(referenceBounds.left, referenceBounds.top, referenceBounds.right, referenceBounds.bottom) {
                scale(if (mirrorX) -1f else 1f, if (mirrorY) -1f else 1f, imagePlacement.center) {
                    drawImage(image,
                        dstOffset = IntOffset(imagePlacement.left.roundToInt(), imagePlacement.top.roundToInt()),
                        dstSize = IntSize(imagePlacement.width.roundToInt(), imagePlacement.height.roundToInt()),
                        alpha = mode.rasterOpacity(opacity, splitOpacity))
                }
            }
            if (mode == MonitorReferenceMode.SPLIT) {
                val centre = Offset(divider, visible.center.y)
                drawLine(Color.Black.copy(alpha = 0.75f), Offset(divider, visible.top),
                    Offset(divider, visible.bottom), 3.dp.toPx())
                drawLine(Color.White, Offset(divider, visible.top), Offset(divider, visible.bottom), 1.dp.toPx())
                drawCircle(Color.White, 6.dp.toPx(), centre)
            }
        }
        if (mode == MonitorReferenceMode.SPLIT && interactive) {
            ReferenceSplitTarget(visible, well.width, split, onSplit)
        }
    }
}

/** Positions just the split touch target so the monitor can layer it above the focus gestures. */
@Composable
fun MonitorReferenceSplitHandle(
    split: Float,
    onSplit: (Float) -> Unit,
    imageRect: (Size) -> Rect?,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier) {
        val well = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val visible = imageRect(well)?.intersect(Rect(Offset.Zero, well)) ?: return@BoxWithConstraints
        if (visible.width > 0f && visible.height > 0f) {
            ReferenceSplitTarget(visible, well.width, split, onSplit)
        }
    }
}

@Composable
private fun ReferenceSplitTarget(visible: Rect, wellWidth: Float, split: Float, onSplit: (Float) -> Unit) {
    val nowSplit by rememberUpdatedState(split)
    val updateSplit by rememberUpdatedState(onSplit)
    val density = LocalDensity.current
    val handleWidth = 44.dp
    val handlePx = with(density) { handleWidth.toPx() }
    val divider = visible.left + visible.width * split.coerceIn(0f, 1f)
    Box(
        Modifier.offset {
            IntOffset((divider - handlePx / 2f).coerceIn(0f, maxOf(wellWidth - handlePx, 0f)).roundToInt(),
                visible.top.roundToInt())
        }.size(handleWidth, with(density) { visible.height.toDp() })
            .semantics {
                contentDescription = "Reference split"
                progressBarRangeInfo = ProgressBarRangeInfo(split, 0f..1f)
                setProgress { updateSplit(it.coerceIn(0f, 1f)); true }
            }.pointerInput(visible) {
                var value = 0.5f
                detectHorizontalDragGestures(onDragStart = { value = nowSplit }) { change, amount ->
                    change.consume()
                    value = (value + amount / visible.width).coerceIn(0f, 1f)
                    updateSplit(value)
                }
            }
    )
}
