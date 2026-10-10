package com.opencapture.monitorui

import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/** Live highlights are cheap; only a settled scrub enters a new picture. */
@Composable
public fun <T> MonitorPhotoFilmstrip(items: List<T>, selectedKey: String, keyOf: (T) -> String,
    label: (T) -> String, enabled: Boolean = true, select: (String) -> Unit,
    thumbnail: @Composable (T, Modifier) -> Unit): Unit {
    val list = rememberLazyListState(initialFirstVisibleItemIndex = items.indexOfFirst { keyOf(it) == selectedKey }.coerceAtLeast(0))
    val currentSelected by rememberUpdatedState(selectedKey)
    val currentSelect by rememberUpdatedState(select)
    val currentEnabled by rememberUpdatedState(enabled)
    var centered by remember(items) { mutableStateOf(selectedKey) }
    fun centeredKey(): String? {
        val info = list.layoutInfo
        val center = (info.viewportStartOffset + info.viewportEndOffset) / 2
        val index = info.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - center) }?.index
        return index?.let { items.getOrNull(it) }?.let(keyOf)
    }
    LaunchedEffect(list, items) {
        snapshotFlow { centeredKey() }.collect { if (it != null) centered = it }
    }
    LaunchedEffect(list, items) {
        var wasScrolling = false
        snapshotFlow { list.isScrollInProgress }.collect { scrolling ->
            if (wasScrolling && !scrolling && currentEnabled) {
                centeredKey()?.takeIf { it != currentSelected }?.let(currentSelect)
            }
            wasScrolling = scrolling
        }
    }
    LaunchedEffect(selectedKey, items) {
        if (centered == selectedKey) return@LaunchedEffect
        centered = selectedKey
        val index = items.indexOfFirst { keyOf(it) == selectedKey }
        if (index >= 0 && !list.isScrollInProgress) list.animateScrollToItem(index)
    }
    BoxWithConstraints(Modifier.fillMaxWidth().height(56.dp)) {
        val sideInset = ((maxWidth - 46.dp) / 2f).coerceAtLeast(0.dp)
        LazyRow(state = list, horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically, contentPadding = PaddingValues(horizontal = sideInset),
            flingBehavior = rememberSnapFlingBehavior(list), modifier = Modifier.fillMaxWidth()) {
            items(items, key = keyOf) { item ->
                val highlighted = keyOf(item) == centered
                Box(Modifier.width(if (highlighted) 46.dp else 30.dp).height(44.dp).clip(RoundedCornerShape(4.dp))
                    .border(if (highlighted) 1.5.dp else 0.dp,
                        if (highlighted) MonitorPalette.accent else Color.Transparent, RoundedCornerShape(4.dp))
                    .semantics { contentDescription = label(item); role = Role.Button }
                    .monitorChromeClickable(enabled = enabled) { select(keyOf(item)) }) {
                    thumbnail(item, Modifier.fillMaxSize())
                }
            }
        }
    }
}
