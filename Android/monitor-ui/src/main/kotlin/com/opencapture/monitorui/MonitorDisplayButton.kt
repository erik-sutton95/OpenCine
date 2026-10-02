package com.opencapture.monitorui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The display-mode tile owns its visual state and accessibility on both platforms. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MonitorDisplayButton(clean: Boolean, width: Float, height: Float,
    modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null) {
    Column(modifier.width(width.dp).height(height.dp)
        .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(14.dp))
        .combinedClickable(enabled = enabled, onClick = onClick, onLongClick = onLongClick)
        .semantics { contentDescription = if (clean) "DISP 2 clean" else "DISP 1 live"; role = Role.Button },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
        Text("DISP", color = MonitorPalette.muted,
            style = MonitorTypography.text(MonitorLayoutPolicy.DISP_SIZE, FontWeight.Bold)
                .copy(letterSpacing = MonitorLayoutPolicy.DISP_TRACKING.sp))
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            for (active in listOf(!clean, clean)) Box(Modifier.size(14.dp, 3.dp).clip(CircleShape)
                .background(if (active) MonitorPalette.accent else Color.White.copy(alpha = .10f)))
        }
    }
}
