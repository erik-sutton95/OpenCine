package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.media.MonitorNDFilterNotation
import com.opencapture.opencine.media.MonitorNDFilterSuggestion

/** Resolved picture suggestion; settings/source observation stay outside the native chip. */
@Composable
fun MonitorNDFilterChip(
    reading: MonitorNDFilterSuggestion?,
    notation: MonitorNDFilterNotation = MonitorNDFilterNotation.FACTOR,
    modifier: Modifier = Modifier,
    emptyLabel: String = "?",
) {
    Box(modifier.fillMaxSize().padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
        Text(reading?.chipLabel(notation) ?: emptyLabel,
            color = if (reading?.needsGlass == true) MonitorPalette.accent else MonitorPalette.text,
            fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}
