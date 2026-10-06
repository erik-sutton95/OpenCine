package com.opencapture.opencine.appkit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorChromeClickable

/**
 * The card over the monitor while a camera connection recovers: a spinner while [retrying], else
 * the unplugged glyph, the host's [title] and [detail], and the retry and operator menu actions.
 * [actionMinHeight] lets a host hold the actions to a minimum touch target; unspecified keeps the pill height.
 */
@Composable
public fun MonitorRecoveryOverlay(
    retrying: Boolean,
    title: String,
    detail: String,
    retryTitle: String,
    operatorMenuTitle: String,
    onRetry: () -> Unit,
    onOperatorMenu: () -> Unit,
    modifier: Modifier = Modifier,
    actionMinHeight: Dp = Dp.Unspecified,
) {
    Box(
        modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.34f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 460.dp)
                .padding(horizontal = 24.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MonitorPalette.surface)
                .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (retrying) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        color = MonitorPalette.accent,
                        strokeWidth = 2.dp,
                    )
                } else {
                    MonitorIcon(MonitorIcon.UNPLUG, null, Modifier.size(22.dp), MonitorPalette.accent)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        title,
                        color = MonitorPalette.text,
                        style = MonitorTypography.text(16f, FontWeight.SemiBold),
                    )
                    Text(
                        detail,
                        color = MonitorPalette.muted,
                        style = MonitorTypography.text(12f, FontWeight.Medium),
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                val action = Modifier.defaultMinSize(minHeight = actionMinHeight)
                RecoveryAction(retryTitle, MonitorIcon.REFRESH_CW, accent = true, modifier = action.weight(1f), onClick = onRetry)
                RecoveryAction(operatorMenuTitle, MonitorIcon.CHEVRON_LEFT, accent = false, modifier = action.weight(1f), onClick = onOperatorMenu)
            }
        }
    }
}

@Composable
private fun RecoveryAction(
    title: String,
    icon: MonitorIcon,
    accent: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tint = if (accent) MonitorPalette.background else MonitorPalette.text
    val haptics = LocalOperatorHaptics.current
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(if (accent) MonitorPalette.accent else MonitorPalette.surface)
            .monitorChromeClickable(onClickFeedback = { haptics.selection() }, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MonitorIcon(icon, null, Modifier.size(13.dp), tint)
        Text(
            title,
            color = tint,
            style = MonitorTypography.text(13f, FontWeight.SemiBold),
            maxLines = 1,
        )
    }
}
