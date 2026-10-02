package com.opencapture.monitorui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

/** Legal destinations stay with the app, including in-app documents and external URLs. */
@Composable
fun MonitorLegalLinks(onPrivacy: (() -> Unit)?, onTerms: (() -> Unit)?, modifier: Modifier = Modifier.fillMaxWidth()) {
    if (onPrivacy == null && onTerms == null) return
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterHorizontally)) {
        if (onPrivacy != null) LegalLink("Privacy", "legal.privacy", onPrivacy)
        if (onTerms != null) LegalLink("Terms", "legal.terms", onTerms)
    }
}

/** Keep the camera viewport's landscape height while preserving full legal tap targets. */
@Composable
fun MonitorCameraFooter(onPrivacy: (() -> Unit)?, onTerms: (() -> Unit)?, action: @Composable () -> Unit) {
    val config = LocalConfiguration.current
    if (config.screenWidthDp > config.screenHeightDp && (onPrivacy != null || onTerms != null)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) { action() }
            MonitorLegalLinks(onPrivacy, onTerms, Modifier)
        }
    } else {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            action()
            MonitorLegalLinks(onPrivacy, onTerms)
        }
    }
}

@Composable
private fun LegalLink(title: String, id: String, action: () -> Unit) {
    Box(
        Modifier.sizeIn(minWidth = 44.dp, minHeight = 44.dp).clickable(role = Role.Button, onClick = action).testTag(id),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, color = MonitorPalette.secondary, style = MonitorTypography.text(11f))
    }
}
