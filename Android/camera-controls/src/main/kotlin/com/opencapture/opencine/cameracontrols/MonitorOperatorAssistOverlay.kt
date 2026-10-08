package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.MonitorAssistState

/** Native adapters forward portable bundles; only this plot scope reads high-rate publication. */
@Composable
internal fun MonitorOperatorAssistOverlay(state: MonitorAssistState, host: AssistHost,
    feed: MonitorRect, locked: Boolean, onOptions: (MonitorAssistTool, MonitorRect) -> Unit): Unit {
    val bundle = state.scopeBundle
    AssistOverlayLayer(state, bundle, host, locked = locked, feedFrame = feed, framingFrame = feed,
        transfer = bundle.transfer, onOpenOptions = onOptions)
}
