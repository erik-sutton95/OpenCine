package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

@Composable
fun MonitorAspectGuideFrames(
    selected: Set<MonitorGuideAspect>, feed: MonitorScopeRect, maskEnabled: Boolean = false,
    maskPolicy: MonitorGuideMaskPolicy = MonitorGuideMaskPolicy.UNION,
) {
    val frames =
        selected.sortedBy { it.ratio }.map { it to MonitorGuideGeometry.rectForRatio(feed, it.ratio) }
    val maskPath = remember(frames, maskPolicy) {
        when (maskPolicy) {
            MonitorGuideMaskPolicy.UNION ->
                frames.map { (_, rect) -> Path().apply { addRect(Rect(rect.minX, rect.minY, rect.maxX, rect.maxY)) } }
                    .reduceOrNull { accumulated, next -> Path.combine(PathOperation.Union, accumulated, next) }
            MonitorGuideMaskPolicy.ENVELOPE -> if (frames.isEmpty()) null else {
                Path().apply {
                    addRect(Rect(frames.minOf { it.second.minX }, frames.minOf { it.second.minY },
                        frames.maxOf { it.second.maxX }, frames.maxOf { it.second.maxY }))
                }
            }
        }
    }
    Canvas(Modifier.fillMaxSize()) {
        if (maskEnabled && maskPath != null) {
            val mask = Color.Black.copy(alpha = 0.6f)
            clipPath(maskPath, clipOp = ClipOp.Difference) {
                drawRect(mask, Offset(feed.minX, feed.minY), Size(feed.width, feed.height))
            }
        }
        for ((aspect, frame) in frames) {
            drawRect(
                MonitorPalette.accent.copy(alpha = 0.85f),
                Offset(frame.minX, frame.minY),
                Size(frame.width, frame.height),
                style = Stroke(1.dp.toPx()),
            )
        }
    }
    frames.forEach { (aspect, frame) ->
        Text(
            aspect.label,
            color = MonitorPalette.accent,
            fontSize = 10.sp,
            fontFamily = MonitorTypography.fontFamily,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.2.sp,
            modifier =
                Modifier
                    .offset { IntOffset((frame.minX + 34f).roundToInt(), (frame.minY + 13f).roundToInt()) }
                    .clip(RoundedCornerShape(5.dp))
                    .background(Color.Black.copy(alpha = 0.42f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

@Composable
fun MonitorFeedGrid(feed: MonitorScopeRect, thirds: Boolean = true, phi: Boolean = false, diagonal: Boolean = false) {
    val lines = MonitorGridGeometry.segments(feed, thirds, phi, diagonal)
    Canvas(Modifier.fillMaxSize()) {
        val stroke = MonitorGridGeometry.STROKE_WIDTH_DP.dp.toPx()
        val color = Color.White.copy(alpha = MonitorGridGeometry.STROKE_OPACITY)
        for (segment in lines) {
            drawLine(color, Offset(segment.from.x, segment.from.y), Offset(segment.to.x, segment.to.y), stroke)
        }
    }
}

@Composable
fun MonitorFeedCrosshair(feed: MonitorScopeRect) {
    Canvas(Modifier.fillMaxSize()) {
        val color = Color.White.copy(alpha = MonitorCrosshairGeometry.OPACITY)
        val arm = MonitorCrosshairGeometry.ARM_LENGTH_DP.dp.toPx()
        val stroke = MonitorCrosshairGeometry.STROKE_WIDTH_DP.dp.toPx()
        val cx = feed.midX
        val cy = feed.midY
        drawRect(color, Offset(cx - stroke / 2f, cy - arm / 2f), Size(stroke, arm))
        drawRect(color, Offset(cx - arm / 2f, cy - stroke / 2f), Size(arm, stroke))
    }
}
