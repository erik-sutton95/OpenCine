package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Focus recenter appearance; native admission, command ownership and feedback stay with callers. */
@Composable
fun MonitorFocusResetButton(
    modifier: Modifier = Modifier,
    title: String = "Recenter focus",
    enabled: Boolean = true,
    pending: Boolean = false,
    size: Dp = LiveChromeMetrics.FOCUS_RESET_DP.dp,
    foreground: Color = MonitorPalette.text,
    outline: Color = MonitorPalette.border,
    accessibilityIdentifier: String = "monitor.system.focusReset",
    onClickFeedback: () -> Unit = {},
    onClick: () -> Unit,
) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .border(1.dp, outline, CircleShape)
            .monitorChromeClickable(enabled = enabled, onClickFeedback = onClickFeedback, onClick = onClick)
            .testTag(accessibilityIdentifier)
            .semantics { contentDescription = title },
        contentAlignment = Alignment.Center,
    ) {
        if (pending) Text("…", color = foreground, style = MonitorTypography.text(18f, FontWeight.SemiBold))
        else MonitorIcon(MonitorIcon.ROTATE_CW, null, Modifier.size(18.dp), foreground)
    }
}
