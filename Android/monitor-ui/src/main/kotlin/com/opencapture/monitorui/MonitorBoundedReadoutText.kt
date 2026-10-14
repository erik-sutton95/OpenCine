package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
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

/** Primary and detail keep independent touch targets within one portrait group. */
@Composable
public fun MonitorPortraitFormatGroup(showsDetail: Boolean,
    primary: @Composable () -> Unit, detail: @Composable () -> Unit) {
    val minimum = LocalViewConfiguration.current.minimumTouchTargetSize.height
    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Box(Modifier.heightIn(min = minimum), contentAlignment = Alignment.TopEnd) { primary() }
        if (showsDetail) Box(Modifier.heightIn(min = minimum), contentAlignment = Alignment.TopEnd) { detail() }
    }
}
