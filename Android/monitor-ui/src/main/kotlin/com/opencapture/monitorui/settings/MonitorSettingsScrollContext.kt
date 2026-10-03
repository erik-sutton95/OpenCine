package com.opencapture.monitorui.settings

import androidx.compose.foundation.ScrollState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Rect

/** The actual settings scroll owner and viewport for native reorder edge scrolling. */
public data class MonitorSettingsScrollContext(
    public val scrollState: ScrollState,
    public val viewportBounds: Rect?,
)

/** Available only within a settings page's rows; it owns no persistence or process-wide state. */
public val LocalMonitorSettingsScrollContext = staticCompositionLocalOf<MonitorSettingsScrollContext?> { null }
