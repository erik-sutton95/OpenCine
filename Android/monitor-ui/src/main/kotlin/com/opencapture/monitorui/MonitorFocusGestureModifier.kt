package com.opencapture.monitorui

import android.os.SystemClock
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One feed-local pointer arbiter for tap-to-focus, DISP swipe, focus lock, and feed zoom.
 *
 * One recognizer serves the drag's two roles: pan while zoomed, the display swipe when not. Two
 * drag recognizers on one surface arbitrate unpredictably: on iOS the earlier-recognizing pan
 * starved the swipe even while inert (`7020cf9`), which is why the roles share this arbiter here
 * rather than stacking a second `pointerInput`.
 *
 * A second pointer permanently cancels focus/lock/swipe recognition for that touch sequence and
 * leaves the events for the native transform recognizer. Focus input cannot consume that pinch.
 *
 * Full geometry, the interface lock, and [isZoomed] are pointer-input keys, so a rotation, crop,
 * de-squeeze, coordinate-space change, lock, or a change in the drag's role cancels the active
 * coroutine before a stale coordinate can be emitted. Updated-state callbacks and focus gates keep
 * later DISP swipes and focus decisions current without restarting solely for camera command
 * availability.
 */
@Composable
fun Modifier.monitorFocusGestures(
    geometry: MonitorFocusGeometry?,
    sourceIdentity: Any? = null,
    context: MonitorFocusGestureContext,
    isPortrait: Boolean,
    isZoomed: Boolean,
    onHoldingChanged: (Boolean) -> Unit,
    onAction: (MonitorFocusGestureAction) -> Unit,
): Modifier {
    val currentContext by rememberUpdatedState(context)
    val currentOnHoldingChanged by rememberUpdatedState(onHoldingChanged)
    val currentOnAction by rememberUpdatedState(onAction)
    return pointerInput(
        sourceIdentity,
        geometry,
        context.interfaceLocked,
        isPortrait,
        isZoomed,
    ) {
        val thresholds = MonitorFocusGestureThresholds.forDensity(density)
        awaitEachGesture {
            var gestureState: MonitorFocusGestureState = MonitorFocusGestureState.Idle
            var sawMultiplePointers = false

            fun reduce(event: MonitorFocusGestureEvent) {
                val reduction =
                    reduceMonitorFocusGesture(
                        state = gestureState,
                        event = event,
                        context = currentContext,
                        thresholds = thresholds,
                    )
                gestureState = reduction.state
                currentOnHoldingChanged(
                    (gestureState as? MonitorFocusGestureState.Tracking)?.holdEligible == true,
                )
                reduction.action?.let { action ->
                    // While zoomed the drag is a pan, so its DISP swipe stands down. Taps still
                    // reach focus; only the swipe's lane is taken.
                    if (isZoomed && action is MonitorFocusGestureAction.RequestDisplayMode) return@let
                    currentOnAction(action)
                }
            }

            try {
                val down =
                    awaitFirstDown(
                        requireUnconsumed = true,
                        pass = PointerEventPass.Main,
                    )
                reduce(
                    MonitorFocusGestureEvent.Down(
                        position = MonitorFocusPixelPoint(down.position.x, down.position.y),
                        uptimeMillis = down.uptimeMillis,
                        consumed = down.isConsumed,
                    ),
                )
                val holdDeadlineUptimeMillis =
                    SystemClock.uptimeMillis() + thresholds.holdDurationMillis
                while (true) {
                    val event =
                        awaitNextFocusPointerEvent(
                            state = gestureState,
                            holdDeadlineUptimeMillis = holdDeadlineUptimeMillis,
                        )
                    if (event == null) {
                        reduce(
                            MonitorFocusGestureEvent.HoldTimeout(
                                down.uptimeMillis + thresholds.holdDurationMillis,
                            ),
                        )
                        continue
                    }
                    if (event.changes.any { it.isConsumed }) {
                        reduce(MonitorFocusGestureEvent.Cancel)
                        return@awaitEachGesture
                    }

                    val pressedCount = event.changes.count { it.pressed }
                    if (pressedCount >= 2 || sawMultiplePointers) {
                        // A second pointer means a pinch, which `Modifier.transformable` owns.
                        // Stand down for the rest of the sequence and leave the events unconsumed
                        // so the transform sees them.
                        if (!sawMultiplePointers) {
                            sawMultiplePointers = true
                            reduce(MonitorFocusGestureEvent.Cancel)
                        }
                        if (pressedCount == 0) return@awaitEachGesture
                        continue
                    }

                    val primary = event.changes.firstOrNull { it.id == down.id }
                        ?: event.changes.firstOrNull()
                        ?: run {
                            reduce(MonitorFocusGestureEvent.Cancel)
                            return@awaitEachGesture
                        }
                    val point = MonitorFocusPixelPoint(primary.position.x, primary.position.y)
                    if (pressedCount == 0) {
                        reduce(
                            MonitorFocusGestureEvent.Up(
                                position = point,
                                uptimeMillis = primary.uptimeMillis,
                                pointerCount = event.changes.size,
                                consumed = primary.isConsumed,
                            ),
                        )
                        primary.consume()
                        return@awaitEachGesture
                    }
                    reduce(
                        MonitorFocusGestureEvent.Move(
                            position = point,
                            uptimeMillis = primary.uptimeMillis,
                            pointerCount = pressedCount,
                            consumed = primary.isConsumed,
                        ),
                    )
                    // While zoomed a one-finger drag is the pan, which `transformable` owns; leave
                    // the move unconsumed so it gets it.
                    if (!isZoomed) primary.consume()
                }
            } finally {
                currentOnHoldingChanged(false)
            }
        }
    }
}

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.awaitNextFocusPointerEvent(
    state: MonitorFocusGestureState,
    holdDeadlineUptimeMillis: Long,
): PointerEvent? {
    val tracking = state as? MonitorFocusGestureState.Tracking
    if (tracking == null || !tracking.holdEligible) {
        return awaitPointerEvent(PointerEventPass.Main)
    }
    // Compose's test injector owns a virtual pointer-event clock. A real monotonic deadline keeps
    // coroutine scheduling in one clock domain, while the reducer still receives an event-relative
    // timestamp and therefore behaves identically for physical and injected input.
    val remaining = holdDeadlineUptimeMillis - SystemClock.uptimeMillis()
    if (remaining <= 0L) return null
    return withTimeoutOrNull(remaining) {
        awaitPointerEvent(PointerEventPass.Main)
    }
}
