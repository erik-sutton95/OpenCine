package com.opencapture.monitorui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** A reported rating; tapping the current level requests clearing it. */
@Composable
public fun MonitorStarRating(stars: Int, select: (Int) -> Unit, levels: List<Int> = listOf(1, 2, 3, 4, 5),
    enabled: Boolean = true, modifier: Modifier = Modifier, selectionFeedback: () -> Unit = {},
    identifierPrefix: String = "monitor.photo.rating"): Unit {
    Row(modifier.monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(percent = 50))
        .padding(horizontal = 4.dp, vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically) {
        levels.forEach { level ->
            Box(Modifier.size(44.dp).testTag("$identifierPrefix.$level")
                .monitorChromeClickable(enabled = enabled, onClickFeedback = selectionFeedback) {
                    select(if (level == stars) 0 else level)
                }, contentAlignment = Alignment.Center) {
                MonitorIcon(MonitorIcon.STAR, MonitorPlaybackCopy.rate(level), Modifier.size(22.dp),
                    if (level <= stars) MonitorPalette.accent else MonitorPalette.muted, filled = level <= stars)
            }
        }
    }
}
