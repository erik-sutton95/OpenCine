package com.opencapture.monitorui

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo

/** The safe insets, in dp, a full-screen media page lays its chrome on. */
internal class MonitorPlaybackSafeInsets(val top: Float, val leading: Float, val trailing: Float,
    val bottom: Float, val navigationLeading: Float, val navigationTrailing: Float)

@Composable
internal fun monitorPlaybackSafeInsets(portrait: Boolean): MonitorPlaybackSafeInsets {
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    return with(density) {
        MonitorPlaybackSafeInsets(
            top = maxOf(WindowInsets.displayCutout.getTop(this), WindowInsets.statusBars.getTop(this)).toDp().value,
            leading = maxOf(WindowInsets.displayCutout.getLeft(this, direction),
                WindowInsets.systemBars.getLeft(this, direction)).toDp().value,
            trailing = maxOf(WindowInsets.displayCutout.getRight(this, direction),
                WindowInsets.systemBars.getRight(this, direction)).toDp().value,
            bottom = playbackBottomInsetDp(maxOf(WindowInsets.displayCutout.getBottom(this),
                WindowInsets.navigationBars.getBottom(this)).toDp().value, portrait),
            navigationLeading = WindowInsets.navigationBars.getLeft(this, direction).toDp().value,
            navigationTrailing = WindowInsets.navigationBars.getRight(this, direction).toDp().value,
        )
    }
}

/**
 * Where the playback page places its assist bar ([tools], dp in the page) and its option
 * inspector, for a full-screen media page of [viewportWidth] by [viewportHeight] dp. The still
 * viewer lays the same bar and inspector on it, so both pages show them in one place.
 */
public class MonitorPlaybackAssistChrome(public val portrait: Boolean, public val tools: MonitorRect,
    public val inspector: MonitorPlaybackInspectorContext)

@Composable
public fun monitorPlaybackAssistChrome(viewportWidth: Float, viewportHeight: Float): MonitorPlaybackAssistChrome {
    val window = LocalWindowInfo.current.containerSize
    val portrait = window.height > window.width
    val insets = monitorPlaybackSafeInsets(portrait)
    return monitorPlaybackAssistChrome(portrait, viewportWidth, viewportHeight, insets)
}

internal fun monitorPlaybackAssistChrome(portrait: Boolean, viewportWidth: Float, viewportHeight: Float,
    insets: MonitorPlaybackSafeInsets): MonitorPlaybackAssistChrome {
    val frame = MonitorLayoutPolicy.fieldMonitorAssists(
        viewportWidth - insets.navigationLeading - insets.navigationTrailing, viewportHeight, insets.top, insets.bottom)
    return MonitorPlaybackAssistChrome(portrait,
        MonitorRect(frame.x + insets.navigationLeading, frame.y, frame.width, frame.height),
        MonitorPlaybackInspectorContext(viewportWidth, viewportHeight, insets.leading, insets.top, insets.bottom,
            insets.trailing, viewportHeight - 120f))
}
