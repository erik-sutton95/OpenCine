package com.opencapture.monitorui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs

private const val WHEEL_NOT_LAID_OUT = -1
/** Softer than iOS 0.22 / 0.78 so a taller fade well still reads as a list. */
private const val FADE_IN = 0.12f
private const val FADE_OUT = 0.88f
/** Centered / neighbour faces, 3 pt under iOS 30 / 23. */
private const val CENTER_PT = 27f
private const val NEIGHBOR_PT = 20f

/**
 * Vertical snap wheel of one-line labels between two hairlines, faded at both ends. Scrolling
 * selects the entry that settles in the center once the wheel has seated on the entry that
 * [matches] [selection]; a tap selects its row.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun <T> MonitorLabelWheel(
    entries: List<T>,
    selection: String,
    matches: (T, String) -> Boolean,
    key: (T) -> String,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    rowHeight: Dp,
    wheelHeight: Dp,
    onClickFeedback: () -> Unit = {},
    /** A long press on a removable entry (a stored look's delete); null keeps the wheel select-only. */
    onLongPress: ((T) -> Unit)? = null,
) {
    if (entries.isEmpty()) return
    val optionKey = entries.joinToString { key(it) }
    val selectedIndex = entries.indexOfFirst { matches(it, selection) }.coerceAtLeast(0)
    val listState = remember(optionKey) { LazyListState(firstVisibleItemIndex = selectedIndex) }
    var seated by remember { mutableStateOf(false) }
    val fling =
        rememberSnapFlingBehavior(
            lazyListState = listState,
            snapPosition = SnapPosition.Center,
        )
    val centeredIndex by remember {
        derivedStateOf {
            val layout = listState.layoutInfo
            val center = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
            layout.visibleItemsInfo
                .minByOrNull { abs(it.offset + it.size / 2 - center) }
                ?.index ?: WHEEL_NOT_LAID_OUT
        }
    }
    LaunchedEffect(entries, selection) {
        seated = false
        val index = entries.indexOfFirst { matches(it, selection) }
        if (index >= 0) {
            listState.scrollToItem(index)
        }
    }
    LaunchedEffect(listState, entries, selection) {
        snapshotFlow { listState.isScrollInProgress to centeredIndex }
            .collect { (scrolling, index) ->
                if (scrolling || index == WHEEL_NOT_LAID_OUT) return@collect
                val entry = entries.getOrNull(index) ?: return@collect
                if (matches(entry, selection)) {
                    seated = true
                    return@collect
                }
                if (!seated) return@collect
                onSelect(entry)
            }
    }
    val rowPx = with(LocalDensity.current) { rowHeight.toPx() }
    val hairlinePx = with(LocalDensity.current) { 1.dp.toPx() }
    val hairline = Color.White.copy(alpha = 0.10f)
    val edgePadding = ((wheelHeight - rowHeight) / 2).coerceAtLeast(0.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .height(wheelHeight)
            .clipToBounds()
            .drawWithContent {
                drawContent()
                val y0 = size.height / 2f - rowPx / 2f
                val y1 = size.height / 2f + rowPx / 2f
                drawLine(
                    hairline,
                    Offset(0f, y0),
                    Offset(size.width, y0),
                    hairlinePx,
                )
                drawLine(
                    hairline,
                    Offset(0f, y1),
                    Offset(size.width, y1),
                    hairlinePx,
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(wheelHeight)
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(
                        Brush.verticalGradient(
                            colorStops =
                                arrayOf(
                                    0f to Color.Transparent,
                                    FADE_IN to Color.Black,
                                    FADE_OUT to Color.Black,
                                    1f to Color.Transparent,
                                ),
                        ),
                        blendMode = BlendMode.DstIn,
                    )
                },
        ) {
            LazyColumn(
                state = listState,
                flingBehavior = fling,
                contentPadding = PaddingValues(vertical = edgePadding),
                modifier = Modifier.fillMaxWidth().height(wheelHeight),
            ) {
                items(entries.size, key = { key(entries[it]) }) { index ->
                    val entry = entries[index]
                    val centered = index == centeredIndex
                    Box(
                        Modifier.fillMaxWidth()
                            .requiredHeight(rowHeight)
                            .monitorChromeClickable(
                                onLongClick = onLongPress?.let { press -> { press(entry) } },
                                onClickFeedback = onClickFeedback, onClick = { onSelect(entry) },
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            label(entry),
                            style =
                                MonitorTypography.readout(
                                    if (centered) CENTER_PT else NEIGHBOR_PT,
                                    if (centered) FontWeight.SemiBold else FontWeight.Normal,
                                ),
                            color = if (centered) MonitorPalette.accent else MonitorPalette.muted.copy(alpha = 0.7f),
                            textAlign = TextAlign.Center,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        )
                    }
                }
            }
        }
    }
}
