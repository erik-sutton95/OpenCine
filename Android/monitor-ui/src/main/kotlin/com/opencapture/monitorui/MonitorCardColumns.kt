package com.opencapture.monitorui

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.ParentDataModifier
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Card placement on measured heights (iOS `MonitorCardColumns`): two columns once the width
 * holds two [minimumColumnWidth] columns, each card dropping into the shorter column so no
 * holes open below short cards. A [monitorFullWidthCard] spans both and starts below the
 * taller column.
 */
@Composable
fun MonitorCardColumns(
    modifier: Modifier = Modifier,
    minimumColumnWidth: Dp = 275.dp,
    spacing: Dp = 10.dp,
    content: @Composable () -> Unit,
) {
    Layout(content, modifier) { measurables, constraints ->
        val grid = MonitorCardGrid(constraints.maxWidth, minimumColumnWidth.roundToPx(), spacing.roundToPx())
        val full = measurables.map { it.parentData === FullWidthCard }
        val placeables = measurables.mapIndexed { index, card ->
            card.measure(Constraints.fixedWidth(if (full[index]) grid.width else grid.columnWidth))
        }
        val frames = grid.place(full, placeables.map { it.height })
        layout(grid.width, frames.height) {
            placeables.forEachIndexed { index, placeable -> placeable.place(frames.x[index], frames.y[index]) }
        }
    }
}

/** Marks a card that spans every column (iOS `monitorFullWidthCard`). */
fun Modifier.monitorFullWidthCard(): Modifier = this.then(FullWidthCard)

private object FullWidthCard : ParentDataModifier {
    override fun Density.modifyParentData(parentData: Any?): Any = FullWidthCard
}

/** The pure placement rule behind [MonitorCardColumns], in pixels. */
internal class MonitorCardGrid(val width: Int, minimumColumnWidth: Int, private val gap: Int) {
    val columns = if (width >= minimumColumnWidth * 2 + gap) 2 else 1
    val columnWidth = ((width - (columns - 1) * gap) / columns).coerceAtLeast(0)

    class Frames(val x: IntArray, val y: IntArray, val height: Int)

    fun place(fullWidth: List<Boolean>, heights: List<Int>): Frames {
        val bottoms = IntArray(columns)
        val x = IntArray(heights.size)
        val y = IntArray(heights.size)
        heights.forEachIndexed { index, height ->
            if (fullWidth[index]) {
                y[index] = bottoms.max()
                bottoms.fill(y[index] + height + gap)
            } else {
                val column = bottoms.indices.minBy { bottoms[it] }
                x[index] = column * (columnWidth + gap)
                y[index] = bottoms[column]
                bottoms[column] += height + gap
            }
        }
        return Frames(x, y, (bottoms.max() - gap).coerceAtLeast(0))
    }
}
