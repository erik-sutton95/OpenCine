package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.HorizontalAlignmentLine
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp

/** Native text sizing stays within the readable range, then ellipsizes at its lower bound.
 * The native Text semantics retain the full supplied value, independently of visual truncation. */
@Composable
public fun MonitorBoundedReadoutText(value: String, modifier: Modifier = Modifier,
    maximumSize: Float = 14f, minimumSize: Float = 11f, color: Color = MonitorPalette.text) {
    val maximum = maximumSize.takeIf { it.isFinite() }?.coerceAtLeast(1f) ?: 14f
    val minimum = minimumSize.takeIf { it.isFinite() }?.coerceIn(1f, maximum) ?: minOf(11f, maximum)
    BasicText(value, modifier = modifier, style = MonitorTypography.readout(maximum).copy(color = color),
        maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis,
        autoSize = if (minimum < maximum) TextAutoSize.StepBased(minimum.sp, maximum.sp, .25f.sp) else null)
}

/** Native layout propagates the unshifted first target edge to the status-row owner. */
internal val MonitorPortraitCaptureTargetTop = HorizontalAlignmentLine { old, new -> minOf(old, new) }

/** One line slot of the stacked portrait format group, in group coordinates (px). */
public data class MonitorPortraitFormatLineSlot(val x: Int, val y: Int, val width: Int, val height: Int)

/** Group size and the line slots of the stacked portrait format group. */
public data class MonitorPortraitFormatStackFrames(val width: Int, val height: Int,
    val slots: List<MonitorPortraitFormatLineSlot>)

/**
 * Stack frame math shared by the portrait format group (Swift twin:
 * `MonitorPortraitFormatStackLayout.frames(lines:)`): each line is as wide as its content; a
 * detail starts where the primary glyphs end; lines are end aligned. Every target keeps [target]
 * as its height floor. The primary target expands upward; later targets start at the previous
 * target's lower boundary. [lines] are (width, glyph height) pairs.
 */
public fun monitorPortraitFormatStackFrames(lines: List<Pair<Int, Int>>, target: Int): MonitorPortraitFormatStackFrames {
    val width = lines.maxOfOrNull { it.first } ?: 0
    var y = 0
    var bottom = 0
    val slots = lines.mapIndexed { index, (lineWidth, glyphHeight) ->
        val height = maxOf(target, glyphHeight)
        val top = if (index == 0 && lines.size > 1) minOf(0, glyphHeight - height) else y
        val slot = MonitorPortraitFormatLineSlot(width - lineWidth, top, lineWidth, height)
        bottom = maxOf(bottom, slot.y + slot.height)
        y = slot.y + slot.height
        slot
    }
    return MonitorPortraitFormatStackFrames(width, bottom, slots)
}

/**
 * Portrait capture readouts stack in one end-aligned column: resolution and frame rate on top,
 * codec and color directly below. The column's top is the primary's top, so the primary shares
 * the status row's top edge with the timecode and the STBY/REC chip. Each line is its own touch
 * target with the full height floor. The primary target expands upward while its label stays
 * at the original top, ending where the detail glyphs begin. The detail target stays below that
 * boundary, so the painted lines stay together and no tap lands on two readouts.
 */
@Composable
public fun MonitorPortraitFormatGroup(showsDetail: Boolean,
    primary: @Composable () -> Unit, detail: @Composable () -> Unit) {
    val target = LocalViewConfiguration.current.minimumTouchTargetSize.height
    Layout(content = {
        Box(propagateMinConstraints = true) { primary() }
        if (showsDetail) Box(propagateMinConstraints = true) { detail() }
    }) { measurables, constraints ->
        val lines = measurables.map { line ->
            val width = minOf(line.maxIntrinsicWidth(Constraints.Infinity), constraints.maxWidth)
            width to line.minIntrinsicHeight(width)
        }
        val frames = monitorPortraitFormatStackFrames(lines, target.roundToPx())
        val placeables = measurables.zip(frames.slots).map { (line, slot) ->
            line.measure(Constraints(minWidth = slot.width, maxWidth = maxOf(slot.width, constraints.maxWidth),
                minHeight = slot.height, maxHeight = slot.height))
        }
        val width = maxOf(frames.width, placeables.maxOfOrNull { it.width } ?: 0)
            .coerceIn(constraints.minWidth, maxOf(constraints.minWidth, constraints.maxWidth))
        val height = frames.height.coerceIn(constraints.minHeight,
            if (constraints.hasBoundedHeight) maxOf(constraints.minHeight, constraints.maxHeight) else Int.MAX_VALUE)
        layout(width, height, alignmentLines = mapOf(
            MonitorPortraitCaptureTargetTop to (frames.slots.minOfOrNull { it.y } ?: 0))) {
            placeables.zip(frames.slots).forEach { (placeable, slot) ->
                placeable.place(width - placeable.width, slot.y)
            }
        }
    }
}
