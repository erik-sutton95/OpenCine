package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex

/** Operator customization, before safety and borrowed-session policies are applied. */
data class MonitorSystemControlsVisibility(val lock: Boolean = true, val settings: Boolean = true,
    val media: Boolean = true, val record: Boolean = true, val display: Boolean = true) {
    fun resolved(locked: Boolean, recording: Boolean?, borrowed: Boolean): MonitorSystemControlsVisibility = copy(
        lock = lock || locked, settings = settings || recording == true,
        record = record || recording == true, media = media && !borrowed)
}

/** Fixed system positions survive rotation and coverage; only native return and edit decoration are slots. */
@Composable
fun MonitorSystemControls(layout: MonitorFieldLayout, visibility: MonitorSystemControlsVisibility,
    capturePresented: Boolean = false, visible: Boolean = true, interactive: Boolean = true,
    navigationHidden: Boolean = capturePresented,
    lock: @Composable (Boolean) -> Unit, settings: @Composable (Boolean) -> Unit, media: @Composable (Boolean) -> Unit,
    record: @Composable (Boolean) -> Unit, display: @Composable (Boolean) -> Unit) {
    @Composable fun place(rect: MonitorRect, hidden: Boolean = false, raised: Boolean = false,
        content: @Composable (Boolean) -> Unit) {
        val accepts = visible && !hidden
        Box(Modifier.offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)
            .alpha(if (accepts) 1f else 0f)
            .then(if (!accepts) Modifier.clearAndSetSemantics { } else Modifier)
            .zIndex(if (raised && capturePresented) 11f else 0f)) { content(interactive && accepts) }
    }
    if (visibility.lock) place(layout.lock, content = lock)
    if (visibility.settings) place(layout.settings, navigationHidden, content = settings)
    if (visibility.media) place(layout.media, navigationHidden, content = media)
    if (visibility.record) place(layout.record, raised = true, content = record)
    if (visibility.display) place(layout.display, raised = true, content = display)
}
