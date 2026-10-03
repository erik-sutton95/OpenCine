package com.opencapture.monitorui.settings

import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette

/** Known local state. The host owns authorization, credentials and request lifetime. */
public enum class MonitorAccountState { NOT_CONFIGURED, CONNECTING, SIGNED_OUT, SIGNED_IN }

@Composable
public fun MonitorAccountSettings(
    title: String, help: String, state: MonitorAccountState,
    signIn: (() -> Unit)? = null, signOut: (() -> Unit)? = null,
) {
    MonitorSettingsRowCard {
        MonitorSettingsInlineRow(title, help, showTopDivider = false) {
            when (state) {
                MonitorAccountState.NOT_CONFIGURED -> MonitorSettingsValueText("Not configured")
                MonitorAccountState.CONNECTING -> CircularProgressIndicator(
                    modifier = Modifier.size(18.dp), color = MonitorPalette.accent, strokeWidth = 2.dp)
                MonitorAccountState.SIGNED_OUT -> if (signIn != null) {
                    MonitorSettingsTextAction("Sign in", onClick = signIn)
                } else MonitorSettingsValueText("Signed out")
                MonitorAccountState.SIGNED_IN -> if (signOut != null) {
                    MonitorSettingsTextAction("Log out", onClick = signOut)
                } else MonitorSettingsValueText("Connected")
            }
        }
    }
}
