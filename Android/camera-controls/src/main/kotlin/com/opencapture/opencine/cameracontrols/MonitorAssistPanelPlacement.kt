package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.monitorui.MonitorRect

/** Borrow deployed panel storage without moving a live position into a playback namespace. */
public class MonitorAssistPanelPlacement(
    public val read: (MonitorAssistTool, Boolean) -> MonitorScopeStoredCenter?,
    public val write: (MonitorAssistTool, MonitorScopeStoredCenter, Boolean) -> Unit,
    public val falseColorDefaultHorizontalFraction: Float = 0.5f,
    public val portraitAudioTrailingGapDp: Float? = null,
    public val landscapeAudioTrailingGapDp: Float? = null,
    public val usesAnalysisViewport: Boolean = false,
    public val referenceBelowFeedGapDp: Float? = null,
    public val audioBottomGapDp: Float? = null,
    public val movementInsetDp: Float? = null,
    public val referenceDefaultFrame: MonitorRect? = null,
)
