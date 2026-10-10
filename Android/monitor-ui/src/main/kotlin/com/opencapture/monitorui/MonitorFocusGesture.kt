package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

enum class MonitorFocusDisplayRequest { LIVE, CLEAN }

/** One point in the feed composable's local pixel coordinate space. */
data class MonitorFocusPixelPoint(
    val x: Float,
    val y: Float,
)

/** One direct AF point in the camera's authoritative live-view coordinate space. */
data class MonitorFocusCoordinate(
    val x: Int,
    val y: Int,
)

/** Geometry identity captured when a feed gesture begins. */
data class MonitorFocusGeometrySignature(
    val generation: Long,
    val presentedFeed: MonitorRect,
    val hitBounds: MonitorRect,
    val coordinateWidth: Int?,
    val coordinateHeight: Int?,
    val mirrored: Boolean = false,
    val mirroredVertical: Boolean = false,
)

/**
 * Exact feed geometry used to inverse-map pointer input into camera AF coordinates.
 *
 * [presentedFeed] is the full rendered and de-squeezed image, including any cropped overhang.
 * [hitBounds] is only the visible intersection used to accept or reject input. Mapping always uses
 * [presentedFeed], so a fill crop cannot incorrectly stretch the visible slice across the camera's
 * whole coordinate space.
 */
data class MonitorFocusGeometry(
    val presentedFeed: MonitorRect,
    val hitBounds: MonitorRect,
    val coordinateWidth: Int?,
    val coordinateHeight: Int?,
    val generation: Long,
    /** Mirror assist is on, so what the operator points at is the horizontally flipped picture. */
    val mirrored: Boolean = false,
    /** Presentation flips top-to-bottom; camera coordinates retain their source orientation. */
    val mirroredVertical: Boolean = false,
) {
    init {
        require(presentedFeed.hasFinitePositiveSize())
        require(hitBounds.hasFinitePositiveSize())
        require((coordinateWidth == null) == (coordinateHeight == null))
        require(coordinateWidth == null || coordinateWidth > 0)
        require(coordinateHeight == null || coordinateHeight > 0)
    }

    /** True only when real camera metadata supplied a usable AF coordinate space. */
    val hasAuthoritativeCoordinateSpace: Boolean
        get() = coordinateWidth != null && coordinateHeight != null

    val signature: MonitorFocusGeometrySignature
        get() =
            MonitorFocusGeometrySignature(
                generation = generation,
                presentedFeed = presentedFeed,
                hitBounds = hitBounds,
                coordinateWidth = coordinateWidth,
                coordinateHeight = coordinateHeight,
                mirrored = mirrored,
                mirroredVertical = mirroredVertical,
            )

    /** Whether [point] lands on the visible rendered feed, independent of AF metadata. */
    fun acceptsGestureAt(point: MonitorFocusPixelPoint): Boolean =
        point.x.isFinite() && point.y.isFinite() && hitBounds.containsInclusive(point)

    /**
     * Maps a visible feed-local pixel to a camera coordinate, or rejects the point.
     *
     * Source dimensions describe a zero-based coordinate space, so inclusive endpoints are
     * `0...(dimension - 1)`. The right and bottom feed edges must never emit the dimension itself.
     */
    fun cameraCoordinateAt(point: MonitorFocusPixelPoint): MonitorFocusCoordinate? {
        val width = coordinateWidth ?: return null
        val height = coordinateHeight ?: return null
        if (!acceptsGestureAt(point)) return null

        val tapped = ((point.x - presentedFeed.minX) / presentedFeed.width).coerceIn(0f, 1f)
        // The camera's coordinate space is the unflipped picture, so a tap on the mirrored image
        // has to be folded back before it becomes an AF point.
        val normalizedX = if (mirrored) 1f - tapped else tapped
        val tappedY = ((point.y - presentedFeed.minY) / presentedFeed.height).coerceIn(0f, 1f)
        val normalizedY = if (mirroredVertical) 1f - tappedY else tappedY
        return MonitorFocusCoordinate(
            x =
                (normalizedX * (width - 1))
                    .roundToInt()
                    .coerceIn(0, width - 1),
            y =
                (normalizedY * (height - 1))
                    .roundToInt()
                    .coerceIn(0, height - 1),
        )
    }
}

/** Feed and command conditions sampled for each pure gesture-reducer event. */
data class MonitorFocusGestureContext(
    val geometry: MonitorFocusGeometry?,
    val interfaceLocked: Boolean = false,
    val focusPointLocked: Boolean = false,
    val focusAvailable: Boolean? = null,
    val commandPending: Boolean = false,
    val mediaBusy: Boolean = false,
) {
    /** DISP gestures only need a visible feed and the app-wide interface lock to be open. */
    val canRecognizeDisplayGesture: Boolean
        get() =
            geometry != null &&
                !interfaceLocked

    /** AF placement and app-lock gestures require authoritative, non-busy camera focus state. */
    val canRecognizeFocusGesture: Boolean
        get() =
            canRecognizeDisplayGesture &&
                focusAvailable == true &&
                !commandPending &&
                !mediaBusy &&
                geometry?.hasAuthoritativeCoordinateSpace == true

    val canSetFocusPoint: Boolean
        get() = canRecognizeFocusGesture && !focusPointLocked
}

/** Motion and timing thresholds, expressed in the same local units as pointer positions. */
data class MonitorFocusGestureThresholds(
    val holdDurationMillis: Long = 300L,
    val holdSlop: Float = 10f,
    val dragStartDistance: Float = 28f,
    val completedSwipeDistance: Float = 44f,
    val swipeAxisMargin: Float = 8f,
) {
    init {
        require(holdDurationMillis > 0L)
        require(holdSlop >= 0f && holdSlop.isFinite())
        require(dragStartDistance > 0f && dragStartDistance.isFinite())
        require(completedSwipeDistance > 0f && completedSwipeDistance.isFinite())
        require(swipeAxisMargin >= 0f && swipeAxisMargin.isFinite())
    }

    companion object {
        /** iOS-parity thresholds when the reducer receives logical-point positions. */
        val Default: MonitorFocusGestureThresholds = MonitorFocusGestureThresholds()

        /** iOS-parity logical thresholds scaled for Compose pointer positions, which are pixels. */
        fun forDensity(density: Float): MonitorFocusGestureThresholds {
            require(density > 0f && density.isFinite())
            return MonitorFocusGestureThresholds(
                holdSlop = 10f * density,
                dragStartDistance = 28f * density,
                completedSwipeDistance = 44f * density,
                swipeAxisMargin = 8f * density,
            )
        }
    }
}

/** State retained by the pure feed-gesture reducer between pointer events. */
sealed interface MonitorFocusGestureState {
    data object Idle : MonitorFocusGestureState

    data class Tracking(
        val down: MonitorFocusPixelPoint,
        val current: MonitorFocusPixelPoint,
        val downUptimeMillis: Long,
        val holdEligible: Boolean,
        val geometrySignature: MonitorFocusGeometrySignature,
    ) : MonitorFocusGestureState

    data class Dragging(
        val down: MonitorFocusPixelPoint,
        val current: MonitorFocusPixelPoint,
        val geometrySignature: MonitorFocusGeometrySignature,
    ) : MonitorFocusGestureState

    data class Held(
        val geometrySignature: MonitorFocusGeometrySignature,
    ) : MonitorFocusGestureState
}

/** One input event accepted by [reduceMonitorFocusGesture]. */
sealed interface MonitorFocusGestureEvent {
    data class Down(
        val position: MonitorFocusPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : MonitorFocusGestureEvent

    data class Move(
        val position: MonitorFocusPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : MonitorFocusGestureEvent

    data class HoldTimeout(
        val uptimeMillis: Long,
    ) : MonitorFocusGestureEvent

    data class Up(
        val position: MonitorFocusPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : MonitorFocusGestureEvent

    /** Re-evaluates gates and geometry without manufacturing a pointer event. */
    data object ContextChanged : MonitorFocusGestureEvent

    data object Cancel : MonitorFocusGestureEvent
}

/** A side effect requested by the feed reducer for the Compose owner to execute. */
sealed interface MonitorFocusGestureAction {
    data class SetFocusPoint(
        val coordinate: MonitorFocusCoordinate,
    ) : MonitorFocusGestureAction

    data class RequestDisplayMode(
        val mode: MonitorFocusDisplayRequest,
    ) : MonitorFocusGestureAction

    data object ToggleFocusPointLock : MonitorFocusGestureAction
}

/** Next reducer state and its optional one-shot side effect. */
data class MonitorFocusGestureReduction(
    val state: MonitorFocusGestureState,
    val action: MonitorFocusGestureAction? = null,
)

/**
 * Reduces one feed-pointer event without retaining state or performing side effects.
 *
 * The caller must provide pointer counts including the lifted primary pointer on
 * [MonitorFocusGestureEvent.Up]. Any second pointer, consumed event, interface lock, or geometry
 * identity change cancels the entire touch sequence until a fresh
 * [MonitorFocusGestureEvent.Down].
 */
fun reduceMonitorFocusGesture(
    state: MonitorFocusGestureState,
    event: MonitorFocusGestureEvent,
    context: MonitorFocusGestureContext,
    thresholds: MonitorFocusGestureThresholds = MonitorFocusGestureThresholds.Default,
): MonitorFocusGestureReduction {
    if (event === MonitorFocusGestureEvent.Cancel) return idleReduction()
    if (event.invalidatesPointerSequence()) return idleReduction()
    if (!context.canRecognizeDisplayGesture) return idleReduction()

    val geometry = context.geometry ?: return idleReduction()
    val stateSignature = state.geometrySignatureOrNull()
    val currentState =
        if (stateSignature == null || stateSignature == geometry.signature) {
            state
        } else {
            MonitorFocusGestureState.Idle
        }
    return when (event) {
        is MonitorFocusGestureEvent.Down -> reduceDown(currentState, event, geometry, context)
        is MonitorFocusGestureEvent.Move -> reduceMove(currentState, event, context, thresholds)
        is MonitorFocusGestureEvent.HoldTimeout ->
            reduceHoldTimeout(currentState, event, context, thresholds)
        is MonitorFocusGestureEvent.Up -> reduceUp(currentState, event, context, thresholds)
        MonitorFocusGestureEvent.ContextChanged ->
            MonitorFocusGestureReduction(
                if (currentState is MonitorFocusGestureState.Tracking) {
                    currentState.copy(
                        holdEligible =
                            currentState.holdEligible && context.canRecognizeFocusGesture,
                    )
                } else {
                    currentState
                },
            )
        MonitorFocusGestureEvent.Cancel -> idleReduction()
    }
}

private fun reduceDown(
    state: MonitorFocusGestureState,
    event: MonitorFocusGestureEvent.Down,
    geometry: MonitorFocusGeometry,
    context: MonitorFocusGestureContext,
): MonitorFocusGestureReduction {
    if (state !== MonitorFocusGestureState.Idle) return idleReduction()
    if (!geometry.acceptsGestureAt(event.position)) return idleReduction()
    return MonitorFocusGestureReduction(
        MonitorFocusGestureState.Tracking(
            down = event.position,
            current = event.position,
            downUptimeMillis = event.uptimeMillis,
            holdEligible = context.canRecognizeFocusGesture,
            geometrySignature = geometry.signature,
        ),
    )
}

private fun reduceMove(
    state: MonitorFocusGestureState,
    event: MonitorFocusGestureEvent.Move,
    context: MonitorFocusGestureContext,
    thresholds: MonitorFocusGestureThresholds,
): MonitorFocusGestureReduction =
    when (state) {
        is MonitorFocusGestureState.Tracking -> {
            val distance = state.down.distanceTo(event.position)
            val updated =
                state.copy(
                    current = event.position,
                    holdEligible = state.holdEligible && distance <= thresholds.holdSlop,
                )
            when {
                distance >= thresholds.dragStartDistance ->
                    MonitorFocusGestureReduction(
                        MonitorFocusGestureState.Dragging(
                            down = state.down,
                            current = event.position,
                            geometrySignature = state.geometrySignature,
                        ),
                    )
                updated.holdEligible &&
                    context.canRecognizeFocusGesture &&
                    event.uptimeMillis - state.downUptimeMillis >= thresholds.holdDurationMillis ->
                    heldReduction(state.geometrySignature)
                else -> MonitorFocusGestureReduction(updated)
            }
        }
        is MonitorFocusGestureState.Dragging ->
            MonitorFocusGestureReduction(state.copy(current = event.position))
        is MonitorFocusGestureState.Held -> MonitorFocusGestureReduction(state)
        MonitorFocusGestureState.Idle -> idleReduction()
    }

private fun reduceHoldTimeout(
    state: MonitorFocusGestureState,
    event: MonitorFocusGestureEvent.HoldTimeout,
    context: MonitorFocusGestureContext,
    thresholds: MonitorFocusGestureThresholds,
): MonitorFocusGestureReduction {
    if (state !is MonitorFocusGestureState.Tracking || !state.holdEligible) {
        return MonitorFocusGestureReduction(state)
    }
    val elapsed = event.uptimeMillis - state.downUptimeMillis
    return if (elapsed >= thresholds.holdDurationMillis) {
        if (context.canRecognizeFocusGesture) {
            heldReduction(state.geometrySignature)
        } else {
            MonitorFocusGestureReduction(state.copy(holdEligible = false))
        }
    } else {
        MonitorFocusGestureReduction(state)
    }
}

private fun reduceUp(
    state: MonitorFocusGestureState,
    event: MonitorFocusGestureEvent.Up,
    context: MonitorFocusGestureContext,
    thresholds: MonitorFocusGestureThresholds,
): MonitorFocusGestureReduction =
    when (state) {
        is MonitorFocusGestureState.Tracking -> reduceTrackingUp(state, event, context, thresholds)
        is MonitorFocusGestureState.Dragging -> completeDrag(state.down, event.position, thresholds)
        is MonitorFocusGestureState.Held -> idleReduction()
        MonitorFocusGestureState.Idle -> idleReduction()
    }

private fun reduceTrackingUp(
    state: MonitorFocusGestureState.Tracking,
    event: MonitorFocusGestureEvent.Up,
    context: MonitorFocusGestureContext,
    thresholds: MonitorFocusGestureThresholds,
): MonitorFocusGestureReduction {
    val distance = state.down.distanceTo(event.position)
    if (distance >= thresholds.dragStartDistance) {
        return completeDrag(state.down, event.position, thresholds)
    }
    val elapsed = event.uptimeMillis - state.downUptimeMillis
    if (
        context.canRecognizeFocusGesture &&
        state.holdEligible &&
            distance <= thresholds.holdSlop &&
            elapsed >= thresholds.holdDurationMillis
    ) {
        return MonitorFocusGestureReduction(
            state = MonitorFocusGestureState.Idle,
            action = MonitorFocusGestureAction.ToggleFocusPointLock,
        )
    }
    if (!context.canSetFocusPoint) return idleReduction()
    val coordinate = context.geometry?.cameraCoordinateAt(event.position) ?: return idleReduction()
    return MonitorFocusGestureReduction(
        state = MonitorFocusGestureState.Idle,
        action = MonitorFocusGestureAction.SetFocusPoint(coordinate),
    )
}

private fun completeDrag(
    down: MonitorFocusPixelPoint,
    up: MonitorFocusPixelPoint,
    thresholds: MonitorFocusGestureThresholds,
): MonitorFocusGestureReduction {
    val deltaX = up.x - down.x
    val deltaY = up.y - down.y
    val completed =
        abs(deltaY) > thresholds.completedSwipeDistance &&
            abs(deltaY) > abs(deltaX) + thresholds.swipeAxisMargin
    if (!completed) return idleReduction()
    return MonitorFocusGestureReduction(
        state = MonitorFocusGestureState.Idle,
        action =
            MonitorFocusGestureAction.RequestDisplayMode(
                if (deltaY > 0f) MonitorFocusDisplayRequest.CLEAN else MonitorFocusDisplayRequest.LIVE,
            ),
    )
}

private fun heldReduction(
    signature: MonitorFocusGeometrySignature,
): MonitorFocusGestureReduction =
    MonitorFocusGestureReduction(
        state = MonitorFocusGestureState.Held(signature),
        action = MonitorFocusGestureAction.ToggleFocusPointLock,
    )

private fun idleReduction(): MonitorFocusGestureReduction =
    MonitorFocusGestureReduction(MonitorFocusGestureState.Idle)

private fun MonitorFocusGestureState.geometrySignatureOrNull(): MonitorFocusGeometrySignature? =
    when (this) {
        is MonitorFocusGestureState.Tracking -> geometrySignature
        is MonitorFocusGestureState.Dragging -> geometrySignature
        is MonitorFocusGestureState.Held -> geometrySignature
        MonitorFocusGestureState.Idle -> null
    }

private fun MonitorFocusGestureEvent.invalidatesPointerSequence(): Boolean =
    when (this) {
        is MonitorFocusGestureEvent.Down ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is MonitorFocusGestureEvent.Move ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is MonitorFocusGestureEvent.Up ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is MonitorFocusGestureEvent.HoldTimeout,
        MonitorFocusGestureEvent.ContextChanged,
        MonitorFocusGestureEvent.Cancel,
        -> false
    }

private fun MonitorFocusPixelPoint.hasFiniteCoordinates(): Boolean = x.isFinite() && y.isFinite()

private fun MonitorFocusPixelPoint.distanceTo(other: MonitorFocusPixelPoint): Float =
    hypot(other.x - x, other.y - y)

private fun MonitorRect.containsInclusive(point: MonitorFocusPixelPoint): Boolean =
    point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY

private fun MonitorRect.hasFinitePositiveSize(): Boolean =
    minX.isFinite() &&
        minY.isFinite() &&
        width.isFinite() &&
        height.isFinite() &&
        width > 0f &&
        height > 0f
