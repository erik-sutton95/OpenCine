package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.opencine.gyro.GyroPillKind
import com.opencapture.opencine.gyro.GyroPillState

/**
 * The compact gyro pill on the monitor, the Android twin of the Swift `GyroPillView`, in the
 * uppercase style of the other monitor chips. Renders nothing when hidden; mount moved, error and
 * gaps read amber with the warning glyph on the first two; a small amber dot marks "IBIS is still
 * on". Tapping opens the gyro logs (the host's action).
 */
@Composable
public fun GyroPillChip(state: GyroPillState, onClick: () -> Unit, modifier: Modifier = Modifier) {
    if (state.kind == GyroPillKind.HIDDEN) return
    val alert = state.kind == GyroPillKind.MOUNT_MOVED || state.kind == GyroPillKind.ERROR
    val ink = if (alert || state.kind == GyroPillKind.GAPS) {
        MonitorLinkHealth.watch
    } else {
        MonitorPalette.text
    }
    Row(
        modifier
            .testTag("gyro.pill")
            .monitorChromeClickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = GyroCopy.pillA11y(state.kind, state.stabilizationWarning)
                role = Role.Button
            }
            .background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        MonitorIcon(
            icon = if (alert) MonitorIcon.TRIANGLE_ALERT else MonitorIcon.AUDIO_WAVEFORM,
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = ink,
        )
        Text(
            GyroCopy.pill(state.kind),
            color = ink,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            modifier = Modifier.clearAndSetSemantics {},
        )
        if (state.stabilizationWarning) {
            Box(Modifier.size(6.dp).background(MonitorLinkHealth.watch, CircleShape))
        }
    }
}
