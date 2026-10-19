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
    MonitorDisplayButton(activeIndex = if (clean) 1 else 0, modeCount = 2,
        description = if (clean) "DISP 2 clean" else "DISP 1 live", width = width, height = height,
        modifier = modifier, enabled = enabled, onClick = onClick, onLongClick = onLongClick)
}

/** Admitted mode order is a source value; an absent selection lights no dash. */
@Composable
fun MonitorDisplayButton(activeIndex: Int?, modeCount: Int, description: String,
    width: Float, height: Float, modifier: Modifier = Modifier, enabled: Boolean = true,
    onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    MonitorDisplayButton(activeIndex, modeCount, description, width, height, modifier, enabled,
        onClick, onLongClick, onClickFeedback = {})
}

/**
 * The tile with the host's tick on a tap (the Swift tile ticks on the mode change). A separate
 * overload, so positional callers of the plain one keep their callback order.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MonitorDisplayButton(activeIndex: Int?, modeCount: Int, description: String,
    width: Float, height: Float, modifier: Modifier, enabled: Boolean,
    onClick: () -> Unit, onLongClick: (() -> Unit)?, onClickFeedback: () -> Unit) {
    Column(modifier.width(width.dp).height(height.dp)
        .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(14.dp))
        .combinedClickable(enabled = enabled, onClick = monitorDisplayClick(enabled, onClickFeedback, onClick),
            onLongClick = onLongClick)
        .semantics { contentDescription = description; role = Role.Button },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
        Text("DISP", color = MonitorPalette.muted,
            style = MonitorTypography.text(MonitorLayoutPolicy.DISP_SIZE, FontWeight.Bold)
                .copy(letterSpacing = MonitorLayoutPolicy.DISP_TRACKING.sp))
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            repeat(modeCount.coerceAtLeast(0)) { index ->
                Box(Modifier.size(14.dp, 3.dp).clip(CircleShape)
                    .background(if (activeIndex == index) MonitorPalette.accent else Color.White.copy(alpha = .10f)))
            }
        }
    }
}

/** One DISP tap: the host's feedback, then the mode change, only while admitted. */
internal fun monitorDisplayClick(enabled: Boolean, feedback: () -> Unit, onClick: () -> Unit): () -> Unit = {
    if (enabled) {
        feedback()
        onClick()
    }
}
