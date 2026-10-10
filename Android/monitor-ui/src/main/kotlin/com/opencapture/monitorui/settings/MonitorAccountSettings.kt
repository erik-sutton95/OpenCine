package com.opencapture.monitorui.settings

import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette

/** Known local state. The host owns authorization, credentials and request lifetime. */
public enum class MonitorAccountState { NOT_CONFIGURED, CONNECTING, SIGNED_OUT, SIGNED_IN, ATTENTION }

@Composable
public fun MonitorAccountSettings(
    title: String, help: String, state: MonitorAccountState,
    signIn: (() -> Unit)? = null, signOut: (() -> Unit)? = null,
    statusLabel: String? = null, signInTitle: String = "Sign in", signOutTitle: String = "Log out",
    busyLabel: String? = null, errorMessage: String? = null,
    pillActions: Boolean = false,
) {
    MonitorSettingsRowCard {
        MonitorSettingsInlineRow(title, help, showTopDivider = false) {
            if (busyLabel != null) MonitorSettingsValueText(busyLabel)
            else when (state) {
                MonitorAccountState.NOT_CONFIGURED -> MonitorSettingsValueText(statusLabel ?: "Not configured")
                MonitorAccountState.CONNECTING -> if (statusLabel != null) MonitorSettingsValueText(statusLabel)
                else CircularProgressIndicator(modifier = Modifier.size(18.dp), color = MonitorPalette.accent, strokeWidth = 2.dp)
                MonitorAccountState.SIGNED_OUT, MonitorAccountState.ATTENTION -> if (signIn != null) {
                    if (pillActions) MonitorSettingsActionPill(signInTitle, onClick = signIn)
                    else MonitorSettingsTextAction(signInTitle, onClick = signIn)
                } else MonitorSettingsValueText(statusLabel ?: "Signed out")
                MonitorAccountState.SIGNED_IN -> if (signOut != null) {
                    if (pillActions) MonitorSettingsActionPill(signOutTitle, onClick = signOut)
                    else MonitorSettingsTextAction(signOutTitle, onClick = signOut)
                } else MonitorSettingsValueText(statusLabel ?: "Connected")
            }
        }
        errorMessage?.let { Text(it, color = MonitorPalette.accent) }
    }
}
