package com.opencapture.monitorui

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** Compilation checks the public call forms from before legal actions were added. */
@Composable
internal fun originalPairPageCallForms(presentation: MonitorPairingPresentation) {
    MonitorPairCameraPage(presentation, {}, {}, {}, {}, {})
    MonitorPairCameraPage(presentation, {}, {}, {}, {}, {}, Modifier, null, { Text("Extra") })
    MonitorPairCameraPage(presentation, {}, {}, {}, {}, {}) { Text("Extra") }
    MonitorPairCameraPage(presentation, {}, {}, {}, {}, {}, onPrivacy = {}, onTerms = null) { Text("Extra") }
}
