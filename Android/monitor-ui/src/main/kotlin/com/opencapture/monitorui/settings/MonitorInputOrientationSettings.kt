package com.opencapture.monitorui.settings

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography

/** The remote shutter switch's test tag (A2-32), for the apps' settings UI tests. */
const val REMOTE_SHUTTER_TAG: String = "monitor.settings.controls.remoteShutter"

/** Known local input/display choices. The host retains persistence and input arming policy. */
@Composable
fun MonitorInputOrientationSettings(
    remoteShutter: Boolean? = null, onRemoteShutter: ((Boolean) -> Unit)? = null,
    remoteTitle: String = "Remote shutter", remoteHelp: String? = null, remoteCaption: String? = null,
    autoRotateFeed: Boolean? = null, onAutoRotateFeed: ((Boolean) -> Unit)? = null,
    rotationTitle: String = "Auto-Rotate Feed", rotationHelp: String, feedback: () -> Unit = {},
): Unit {
    val offersRemote = remoteShutter != null && onRemoteShutter != null
    val offersRotation = autoRotateFeed != null && onAutoRotateFeed != null
    if (!offersRemote && !offersRotation) return
    MonitorSettingsRowCard(title = "Input & orientation") {
        if (remoteShutter != null && onRemoteShutter != null) {
            MonitorSettingsSwitchInlineRow(title = remoteTitle, help = remoteHelp,
                isOn = remoteShutter, showTopDivider = false, testTag = REMOTE_SHUTTER_TAG) {
                feedback(); onRemoteShutter(!remoteShutter)
            }
            if (remoteCaption != null) Text(remoteCaption, style = MonitorTypography.text(10.5f),
                color = MonitorPalette.muted, modifier = Modifier.padding(bottom = 6.dp))
        }
        if (autoRotateFeed != null && onAutoRotateFeed != null) {
            MonitorSettingsSwitchInlineRow(title = rotationTitle, help = rotationHelp,
                isOn = autoRotateFeed, showTopDivider = offersRemote) {
                feedback(); onAutoRotateFeed(!autoRotateFeed)
            }
        }
    }
}
