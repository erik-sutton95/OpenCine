package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.appkit.MonitorMediaDeletionProgress

/** Shared progress card for an admitted deletion; source detail names any companion files. */
@Composable
public fun MonitorMediaDeletionOverlay(progress: MonitorMediaDeletionProgress, detail: String? = null): Unit {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f))
        .chromeClickable(onClick = {}), contentAlignment = Alignment.Center) {
        Column(Modifier.mediaGlass(RoundedCornerShape(16.dp))
            .padding(horizontal = 24.dp, vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Deleting ${progress.selectedCount} ${if (progress.selectedCount == 1) "item" else "items"}…", color = LiveDesign.text)
            Text(detail ?: "${progress.completed} of ${progress.total}", color = LiveDesign.muted)
            LinearProgressIndicator(progress = {
                if (progress.total > 0) progress.completed.toFloat() / progress.total else 0f
            })
        }
    }
}
