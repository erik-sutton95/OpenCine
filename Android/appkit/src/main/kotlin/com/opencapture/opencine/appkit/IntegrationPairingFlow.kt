package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorPairingPresentation

/**
 * An integration's preparation steps inside the shared pair page's rail and pane.
 * Pass null to [PairScreen] when the connection model takes over progress.
 */
public class IntegrationPairingFlow(
    public val presentation: MonitorPairingPresentation,
    public val onPrimary: () -> Unit,
    public val onBack: () -> Unit,
    public val content: @Composable () -> Unit,
    public val onSelect: (String) -> Unit = {},
)
