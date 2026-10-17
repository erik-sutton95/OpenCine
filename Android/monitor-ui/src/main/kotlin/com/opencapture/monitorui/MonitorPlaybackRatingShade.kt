package com.opencapture.monitorui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** A known rating is revealed only while the operator's shade is open. */
@Composable
public fun MonitorPlaybackRatingShade(stars: Int?, levels: List<Int>, enabled: Boolean, notice: String?,
    expanded: Boolean, expand: (Boolean) -> Unit, select: (Int) -> Unit, modifier: Modifier = Modifier): Unit {
    if (stars == null) return
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        MonitorPlaybackRatingAnchor(stars, expanded, expand)
        MonitorPlaybackRatingDetails(stars, levels, enabled, notice, expanded, select)
    }
}

/** Compact rating control with stable native touch bounds in the playback action row. */
@Composable
public fun MonitorPlaybackRatingAnchor(stars: Int?, expanded: Boolean, expand: (Boolean) -> Unit,
    modifier: Modifier = Modifier): Unit {
    if (stars == null) return
    Row(modifier.testTag("monitor.playback.rating")
        .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(percent = 50))
        .monitorChromeClickable { expand(!expanded) }.size(width = 52.dp, height = 44.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically) {
        MonitorIcon(MonitorIcon.STAR, MonitorPlaybackCopy.rating(expanded),
            Modifier.size(10.dp), MonitorPalette.muted, filled = true)
        MonitorIcon(if (expanded) MonitorIcon.CHEVRON_UP else MonitorIcon.CHEVRON_DOWN,
            null, Modifier.size(9.dp), MonitorPalette.muted)
    }
}

/** Expanded choices remain below the measured header, within its viewport and touch bounds. */
@Composable
public fun MonitorPlaybackRatingDetails(stars: Int?, levels: List<Int>, enabled: Boolean, notice: String?,
    expanded: Boolean, select: (Int) -> Unit, modifier: Modifier = Modifier): Unit {
    if (stars == null) return
    Column(modifier, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (expanded) MonitorStarRating(stars, select, levels, enabled,
            identifierPrefix = "monitor.playback.rating")
        if (notice != null) Text(notice, style = MonitorTypography.text(12f), color = MonitorPalette.text,
            modifier = Modifier.testTag("monitor.playback.rating.notice").padding(8.dp))
    }
}
