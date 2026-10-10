package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.MonitorLevelDisplay
import com.opencapture.monitorui.MonitorLevelOverlay
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.opencine.motion.LevelMode
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.motion.WorldLevelSnap
import kotlinx.coroutines.delay

/** Camera-attitude freshness belongs to this small observation scope, separate from native picture geometry. */
@Composable
public fun MonitorOperatorLevelOverlay(reading: LevelReading, viewFlip: Boolean, feed: MonitorRect,
    viewport: MonitorRect, portrait: Boolean, modifier: Modifier = Modifier): Unit {
    var display by remember { mutableStateOf<MonitorLevelDisplay>(MonitorLevelDisplay.Unavailable) }
    LaunchedEffect(reading, viewFlip) {
        while (true) {
            display = when (val mode = reading.mode(android.os.SystemClock.elapsedRealtimeNanos() / 1e9, viewFlip)) {
                LevelMode.Unavailable -> MonitorLevelDisplay.Unavailable
                is LevelMode.Gauges -> MonitorLevelDisplay.Gauges(mode.rollDeg, mode.tiltDeg)
                is LevelMode.Bubble -> MonitorLevelDisplay.Bubble(mode.xDeg, mode.yDeg)
            }
            delay(100L)
        }
    }
    MonitorLevelOverlay(display, MonitorScopeRect(feed.x, feed.y, feed.width, feed.height),
        MonitorScopeRect(viewport.x, viewport.y, viewport.width, viewport.height), portrait, modifier,
        noDataLabel = WorldLevelSnap.NO_LEVEL_DATA, unknownLabel = "\u2014")
}
