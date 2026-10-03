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

enum class MonitorGuideFamily(val label: String) {
    FILM("Film"),
    SOCIAL("Social"),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorGuideFamily =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: FILM
    }
}

enum class MonitorGuideAspect(val label: String) {
    CINEMA_276("2.76:1"),
    CINEMA("2.39:1"),
    CINEMA_235("2.35:1"),
    TWO_K("2.00:1"),
    WIDE("1.85:1"),
    HD("16:9"),
    EURO("1.66:1"),
    IMAX("1.43:1"),
    ACADEMY("4:3"),
    VERTICAL("9:16"),
    SOCIAL("4:5"),
    SQUARE("1:1"),
    PORTRAIT("2:3"),
    FEED("1.91:1"),
    ;

    val ratio: Float
        get() {
            val parts = label.split(':')
            val a = parts.getOrNull(0)?.toFloatOrNull() ?: return 1f
            val b = parts.getOrNull(1)?.toFloatOrNull() ?: return 1f
            return if (b > 0f) a / b else 1f
        }

    companion object {
        val film: List<MonitorGuideAspect> =
            listOf(CINEMA_276, CINEMA, CINEMA_235, TWO_K, WIDE, HD, EURO, IMAX, ACADEMY)
        val social: List<MonitorGuideAspect> = listOf(VERTICAL, SOCIAL, SQUARE, PORTRAIT, HD, FEED)

        fun ratios(family: MonitorGuideFamily): List<MonitorGuideAspect> =
            when (family) {
                MonitorGuideFamily.FILM -> film
                MonitorGuideFamily.SOCIAL -> social
            }

        fun fromPersisted(raw: String): MonitorGuideAspect =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: CINEMA
    }
}

data class MonitorGridSegment(val from: MonitorScopePoint, val to: MonitorScopePoint)

object MonitorGridGeometry {
    val thirdsFractions = listOf(1f / 3f, 2f / 3f)
    val phiFractions = listOf(0.382f, 0.618f)
    const val STROKE_OPACITY = 0.22f
    const val STROKE_WIDTH_DP = 1f
    val optionLabels = listOf("Thirds", "Phi Grid", "Diagonal")

    fun segments(
        feed: MonitorScopeRect,
        thirds: Boolean,
        phi: Boolean,
        diagonal: Boolean,
    ): List<MonitorGridSegment> {
        val lines = ArrayList<MonitorGridSegment>(12)
        if (thirds) appendFractions(feed, thirdsFractions, lines)
        if (phi) appendFractions(feed, phiFractions, lines)
        if (diagonal) {
            lines +=
                MonitorGridSegment(
                    MonitorScopePoint(feed.minX, feed.minY),
                    MonitorScopePoint(feed.maxX, feed.maxY),
                )
            lines +=
                MonitorGridSegment(
                    MonitorScopePoint(feed.maxX, feed.minY),
                    MonitorScopePoint(feed.minX, feed.maxY),
                )
        }
        return lines
    }

    private fun appendFractions(feed: MonitorScopeRect, fractions: List<Float>, lines: MutableList<MonitorGridSegment>) {
        for (fraction in fractions) {
            val x = feed.minX + feed.width * fraction
            val y = feed.minY + feed.height * fraction
            lines += MonitorGridSegment(MonitorScopePoint(x, feed.minY), MonitorScopePoint(x, feed.maxY))
            lines += MonitorGridSegment(MonitorScopePoint(feed.minX, y), MonitorScopePoint(feed.maxX, y))
        }
    }
}

object MonitorGuideGeometry {
    /** Letterbox when the guide is wider than the feed, pillarbox when narrower. */
    fun rectForRatio(feed: MonitorScopeRect, ratio: Float): MonitorScopeRect {
        val width: Float
        val height: Float
        if (feed.height <= 0f || ratio <= 0f) return feed
        if (feed.width / feed.height > ratio) {
            height = feed.height
            width = feed.height * ratio
        } else {
            width = feed.width
            height = feed.width / ratio
        }
        return MonitorScopeRect(
            feed.minX + (feed.width - width) / 2f,
            feed.minY + (feed.height - height) / 2f,
            width,
            height,
        )
    }
}

object MonitorCrosshairGeometry {
    const val ARM_LENGTH_DP = 40f
    const val STROKE_WIDTH_DP = 1.4f
    const val OPACITY = 0.65f
    const val HELP = "Tap the toolbar button to show or hide the centre crosshair."
}

@Composable
fun MonitorAspectGuideFrames(selected: Set<MonitorGuideAspect>, feed: MonitorScopeRect, maskEnabled: Boolean = false) {
    val frames =
        selected.sortedBy { it.ratio }.map { it to MonitorGuideGeometry.rectForRatio(feed, it.ratio) }
    val union = remember(frames) {
        frames.map { (_, rect) -> Path().apply { addRect(Rect(rect.minX, rect.minY, rect.maxX, rect.maxY)) } }
            .reduceOrNull { accumulated, next -> Path.combine(PathOperation.Union, accumulated, next) }
    }
    Canvas(Modifier.fillMaxSize()) {
        if (maskEnabled && union != null) {
            val mask = Color.Black.copy(alpha = 0.6f)
            clipPath(union, clipOp = ClipOp.Difference) {
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
