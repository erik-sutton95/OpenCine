package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.max
import kotlin.math.min


/** Resolved marks use normalized picture coordinates after source-axis projection. */
data class MonitorTrackingRect(val x: Double, val y: Double, val width: Double, val height: Double)
data class MonitorTrackingBracketValue(val normalizedRect: MonitorTrackingRect, val color: Color, val lineWidth: Float = 2f)
data class MonitorFocusMark(val point: Offset, val color: Color, val aeLocked: Boolean = false,
    val focusLocked: Boolean = false,
    /** The camera-reported AF area, normalized like [point] (its centre); null draws the standard tap box. */
    val area: MonitorTrackingRect? = null,
    /** Hold-to-lock feedback in 0..1: the box outline fills in the accent until the lock engages. */
    val lockProgress: Float = 0f)

object MonitorTrackingGeometry {
    const val FOCUS_BOX_SIDE_FRACTION = 0.14f
    const val CANCEL_SIZE = 28f
    const val CANCEL_HIT_SIZE = 44f
    fun bracketArm(along: Float): Float {
        val proposed = along * 0.26f
        val minGap = max(8f, along * 0.28f)
        return min(max(10f, proposed), max(10f, (along - minGap) / 2f))
    }

    /**
     * The focus box in feed pixels (twin of the SwiftUI `focusBoxFrame`): the camera-reported area at
     * its own size and centre, else the standard square of the short side around the mark's point.
     */
    fun focusBoxFrame(mark: MonitorFocusMark, width: Float, height: Float): Rect {
        val area = mark.area
        if (area != null && area.width > 0 && area.height > 0) {
            return Rect((area.x * width).toFloat(), (area.y * height).toFloat(),
                ((area.x + area.width) * width).toFloat(), ((area.y + area.height) * height).toFloat())
        }
        val side = min(width, height) * FOCUS_BOX_SIDE_FRACTION
        val cx = mark.point.x * width
        val cy = mark.point.y * height
        return Rect(cx - side / 2f, cy - side / 2f, cx + side / 2f, cy + side / 2f)
    }

    /** A camera-reported area keeps its own corner (at most [areaCornerCap]); the standard tap box keeps 6 px. */
    fun focusCornerRadius(frame: Rect, reportedArea: Boolean, areaCornerCap: Float): Float {
        val side = min(frame.width, frame.height)
        return if (reportedArea) min(side * 0.12f, areaCornerCap) else max(6f, side * 0.12f)
    }
}

/** Drawing owns no camera report selection, tap policy or coordinate flip. */
@Composable
fun MonitorTrackingLayer(brackets: List<MonitorTrackingBracketValue>, focus: MonitorFocusMark?,
    modifier: Modifier = Modifier,
    /** Further camera-reported AF areas (a body that reports several), drawn as boxes without tags. */
    areas: List<MonitorFocusMark> = emptyList()) {
    val visibleMarks = brackets.toList()
    val measurer = rememberTextMeasurer()
    val lockIcon = if (focus?.focusLocked == true) painterResource(MonitorIcon.LOCK.drawableRes) else null
    Canvas(modifier.fillMaxSize()) {
        visibleMarks.forEach { mark ->
            val rect = mark.normalizedRect
            drawBracket(Rect((rect.x * size.width).toFloat(), (rect.y * size.height).toFloat(),
                ((rect.x + rect.width) * size.width).toFloat(), ((rect.y + rect.height) * size.height).toFloat()),
                mark.color, mark.lineWidth.dp.toPx())
        }
        areas.forEach { drawFocusBox(it, null, null) }
        if (focus != null) {
            val aeTag = if (focus.aeLocked) measurer.measure("AE-L",
                MonitorTypography.text(9f, FontWeight.SemiBold).copy(color = focus.color,
                    letterSpacing = 0.5.sp,
                    shadow = Shadow(Color.Black.copy(alpha = 0.8f), Offset(0f, 0.5.dp.toPx()), 1.5.dp.toPx()))) else null
            drawFocusBox(focus, aeTag, lockIcon)
        }
    }
}

@Composable
fun MonitorTrackingCancelButton(rect: MonitorRect, color: Color, ink: Color,
    onClick: () -> Unit, feedback: () -> Unit = {}) {
    Box(Modifier.offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)
        .clip(CircleShape).monitorChromeClickable(onClickFeedback = feedback, onClick = onClick)
        .semantics { contentDescription = "Stop subject tracking" }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(MonitorTrackingGeometry.CANCEL_SIZE.dp).clip(CircleShape).background(color),
            contentAlignment = Alignment.Center) {
            MonitorIcon(MonitorIcon.X, null, Modifier.size(11.dp), ink)
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFocusBox(
    focus: MonitorFocusMark,
    aeTag: TextLayoutResult?,
    lockIcon: Painter?,
) {
    val frame = MonitorTrackingGeometry.focusBoxFrame(focus, size.width, size.height)
    val boxWidth = frame.width
    val boxHeight = frame.height
    val cx = frame.center.x
    val cy = frame.center.y
    val halfWidth = boxWidth / 2f
    val halfHeight = boxHeight / 2f
    val tint = focus.color
    // Tags sit right of the box, or left near the right edge.
    val tagGap = 3.dp.toPx()
    val tagWidth = aeTag?.size?.width?.toFloat() ?: (23.dp.toPx() - tagGap)
    val leading = cx + halfWidth + tagGap + tagWidth > size.width
    if (aeTag != null) {
        val x = if (leading) cx - halfWidth - tagGap - tagWidth else cx + halfWidth + tagGap
        drawText(aeTag, topLeft = Offset(x, cy - halfHeight + 6.dp.toPx() - aeTag.size.height / 2f))
    }
    if (lockIcon != null) {
        val icon = 10.dp.toPx()
        val gap = 5.dp.toPx()
        val x = if (leading) cx - halfWidth - gap - icon else cx + halfWidth + gap
        translate(x, cy + halfHeight - 6.dp.toPx() - icon / 2f) {
            with(lockIcon) { draw(Size(icon, icon), colorFilter = ColorFilter.tint(tint)) }
        }
    }
    val radius = MonitorTrackingGeometry.focusCornerRadius(frame, focus.area != null, 7.dp.toPx())
    drawRoundRect(
        tint,
        topLeft = Offset(cx - halfWidth, cy - halfHeight),
        size = Size(boxWidth, boxHeight),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
        style = Stroke(1.5.dp.toPx()),
    )
    val progress = focus.lockProgress.coerceIn(0f, 1f)
    if (!focus.focusLocked && progress > 0.001f) {
        val outline = Path().apply {
            addRoundRect(androidx.compose.ui.geometry.RoundRect(cx - halfWidth, cy - halfHeight, cx + halfWidth,
                cy + halfHeight, androidx.compose.ui.geometry.CornerRadius(radius)))
        }
        val measure = androidx.compose.ui.graphics.PathMeasure().apply { setPath(outline, false) }
        val segment = Path()
        measure.getSegment(0f, measure.length * progress, segment, true)
        // The hold to lock traces the outline in the accent until the lock engages, as on iOS.
        drawPath(segment, MonitorPalette.accent,
            style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawBracket(
    rect: Rect,
    color: Color,
    stroke: Float,
) {
    if (rect.width < 2f || rect.height < 2f) return
    val path = bracketPath(rect.width, rect.height)
    path.translate(Offset(rect.left, rect.top))
    drawPath(
        path,
        color,
        style = Stroke(stroke, cap = StrokeCap.Round, join = StrokeJoin.Round),
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.bracketPath(
    w: Float,
    h: Float,
): Path {
    val ax = MonitorTrackingGeometry.bracketArm(w)
    val ay = MonitorTrackingGeometry.bracketArm(h)
    val r = min(max(6f, min(w, h) * 0.12f), min(ax - 1f, ay - 1f)).coerceAtLeast(0f)
    val path = Path()
    path.moveTo(0f, ay)
    path.lineTo(0f, r)
    if (r >= 3f) path.quadraticTo(0f, 0f, r, 0f) else {
        path.lineTo(0f, 0f)
        path.lineTo(r, 0f)
    }
    path.lineTo(ax, 0f)
    path.moveTo(w - ax, 0f)
    path.lineTo(w - r, 0f)
    if (r >= 3f) path.quadraticTo(w, 0f, w, r) else {
        path.lineTo(w, 0f)
        path.lineTo(w, r)
    }
    path.lineTo(w, ay)
    path.moveTo(w, h - ay)
    path.lineTo(w, h - r)
    if (r >= 3f) path.quadraticTo(w, h, w - r, h) else {
        path.lineTo(w, h)
        path.lineTo(w - r, h)
    }
    path.lineTo(w - ax, h)
    path.moveTo(ax, h)
    path.lineTo(r, h)
    if (r >= 3f) path.quadraticTo(0f, h, 0f, h - r) else {
        path.lineTo(0f, h)
        path.lineTo(0f, h - r)
    }
    path.lineTo(0f, h - ay)
    return path
}
