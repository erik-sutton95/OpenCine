package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography

/** The radius shared with the Monitor theme and the mockups. */
private const val GYRO_BUTTON_RADIUS_DP = 12f

/**
 * Ink for text and icons drawn on an accent fill. Light accents (the brand yellow) need dark ink,
 * exactly like the Swift `MonitorTheme.onAccent`; the monitor-ui palette exposes no on-accent token
 * yet, so the shared rule is mirrored here rather than hard-coding the brand color.
 */
internal fun gyroOnAccent(): Color {
    val accent = MonitorPalette.accent
    val luminance = 0.2126f * accent.red + 0.7152f * accent.green + 0.0722f * accent.blue
    return if (luminance > 0.6f) MonitorPalette.background else MonitorPalette.text
}

/**
 * The one primary action of every gyro screen: full width, at least 50 dp tall, accent fill with
 * on-accent ink and a 12 dp radius. Carries the shared `gyro.primary` tag; [tag] puts a second
 * identifier on a wrapper so a screen-specific test id can sit beside it.
 */
@Composable
internal fun GyroPrimaryButton(
    text: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    tag: String? = null,
) {
    Box(Modifier.then(if (tag != null) Modifier.testTag(tag) else Modifier)) {
        Box(
            modifier
                .fillMaxWidth()
                .heightIn(min = 50.dp)
                .clip(RoundedCornerShape(GYRO_BUTTON_RADIUS_DP.dp))
                .background(
                    if (enabled) {
                        MonitorPalette.accent
                    } else {
                        MonitorPalette.accent.copy(alpha = 0.35f)
                    },
                )
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics(mergeDescendants = true) {}
                .testTag("gyro.primary")
                .padding(horizontal = 16.dp, vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = text,
                color = if (enabled) gyroOnAccent() else gyroOnAccent().copy(alpha = 0.7f),
                style = MonitorTypography.text(17f, FontWeight.SemiBold),
            )
        }
    }
}

/**
 * A secondary action: plain text on the monitor background, never filled. The default ink is white
 * for "keep it on" style choices; a caller can pass the accent instead.
 */
@Composable
internal fun GyroSecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = MonitorPalette.text,
    tag: String? = null,
) {
    Box(Modifier.then(if (tag != null) Modifier.testTag(tag) else Modifier)) {
        Box(
            modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onClick)
                .semantics(mergeDescendants = true) {}
                .padding(horizontal = 12.dp, vertical = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = text,
                color = color,
                style = MonitorTypography.text(16f, FontWeight.Medium),
            )
        }
    }
}

/**
 * A quiet text action in the accent: "Use last calibration" and the top-bar "Cancel". Full width
 * by default; [fillWidth] false keeps it as the small top-bar control.
 */
@Composable
internal fun GyroLinkButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fillWidth: Boolean = true,
    tag: String? = null,
) {
    Box(Modifier.then(if (tag != null) Modifier.testTag(tag) else Modifier)) {
        Box(
            (if (fillWidth) modifier.fillMaxWidth() else modifier)
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onClick)
                .semantics(mergeDescendants = true) {}
                .padding(horizontal = 12.dp, vertical = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = text,
                color = MonitorPalette.accent,
                style = MonitorTypography.text(16f, FontWeight.Medium),
            )
        }
    }
}
