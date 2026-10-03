package com.opencapture.monitorui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputScope

/** Start on movement, retaining stationary holds for options. Root coordinates avoid drag feedback. */
internal suspend fun PointerInputScope.detectMonitorPanelDrag(
    holdMs: Long,
    enabled: Boolean,
    onDown: () -> Unit = {},
    onStart: () -> Unit,
    onLongPress: (() -> Unit)? = null,
    onDrag: (translation: Offset) -> Unit,
    onEnd: (translation: Offset) -> Unit,
    onCancel: () -> Unit = {},
    toRoot: (Offset) -> Offset = { it },
) {
    if (!enabled) return
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = true)
        down.consume()
        onDown()
        val pointerId = down.id
        val downRoot = toRoot(down.position)
        var total = Offset.Zero
        val moved = withTimeoutOrNull(holdMs) {
            var result = false
            while (true) {
                val change = awaitPointerEvent().changes.firstOrNull { it.id == pointerId } ?: break
                if (change.isConsumed || !change.pressed) break
                total = toRoot(change.position) - downRoot
                change.consume()
                if (total.getDistance() >= 4 * density) {
                    result = true
                    break
                }
            }
            result
        }
        if (moved == false) return@awaitEachGesture
        if (moved == null && onLongPress != null) {
            onLongPress()
            waitForUpOrCancellation()
            return@awaitEachGesture
        }
        onStart()
        var released = false
        try {
            onDrag(total)
            released = drag(pointerId) { change ->
                total = toRoot(change.position) - downRoot
                change.consume()
                onDrag(total)
            }
        } finally {
            if (released) onEnd(total) else onCancel()
        }
    }
}
