package com.opencapture.monitorui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.offset

/**
 * The minimum touch target of every chrome control, the Android twin of iOS `.monitorTapTarget`
 * (Apple's 44 pt). Material's own floor is 48 dp; 44 is the parity number.
 */
const val MONITOR_MIN_TAP_TARGET_DP = 44f

/**
 * Actual native press/tap/hold input; hosts supply their own optional feedback. A control drawn
 * smaller than [MONITOR_MIN_TAP_TARGET_DP] is still hit across that size, without moving anything drawn.
 * Disabled controls keep their accessibility state and return pointers to the surface underneath.
 */
@Composable
fun Modifier.monitorChromeClickable(
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    onClickFeedback: () -> Unit = {},
    onLongClickFeedback: () -> Unit = {},
    onClick: () -> Unit,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val alpha by animateFloatAsState(if (pressed && enabled) 0.6f else 1f, tween(120), label = "chrome-a")
    val scale by animateFloatAsState(if (pressed && enabled) 0.97f else 1f, tween(120), label = "chrome-s")
    val press =
        Modifier.graphicsLayer {
            this.alpha = alpha
            scaleX = scale
            scaleY = scale
        }
    val clicks =
        if (!enabled) {
            // A disabled clickable still wins Compose hit testing above a picker backdrop.
            Modifier.semantics(mergeDescendants = true) { disabled() }
        } else if (onLongClick != null) {
            Modifier.combinedClickable(
                enabled = enabled,
                interactionSource = interaction,
                indication = null,
                onClick = {
                    onClickFeedback()
                    onClick()
                },
                onLongClick = {
                    onLongClickFeedback()
                    onLongClick()
                },
            )
        } else {
            Modifier.clickable(
                enabled = enabled,
                interactionSource = interaction,
                indication = null,
                onClick = {
                    onClickFeedback()
                    onClick()
                },
            )
        }
    return this.then(press).tapTargetFloor(clicks)
}

/**
 * Grows the touch area to [MONITOR_MIN_TAP_TARGET_DP] without moving anything drawn: the Compose
 * form of the positive-then-negative padding iOS uses. Deliberately not
 * `minimumInteractiveComponentSize()`, which reports the floored size to the parent: a 27 dp readout
 * pill inside a 46 dp band would inflate the band. The drawn size is known only after measuring, so
 * the pad lands one pass later.
 */
@Composable
private fun Modifier.tapTargetFloor(clicks: Modifier): Modifier {
    val floorPx = with(LocalDensity.current) { MONITOR_MIN_TAP_TARGET_DP.dp.roundToPx() }
    var drawn by remember { mutableStateOf(IntSize.Zero) }
    val padX = if (drawn.width <= 0) 0 else ((floorPx - drawn.width) / 2).coerceAtLeast(0)
    val padY = if (drawn.height <= 0) 0 else ((floorPx - drawn.height) / 2).coerceAtLeast(0)
    val expands = padX > 0 || padY > 0
    return this.then(if (expands) Modifier.tapTargetInset(padX, padY) else Modifier)
        .then(clicks)
        .then(if (expands) Modifier.tapTargetExpand(padX, padY) else Modifier)
        .onSizeChanged { size ->
            // Only a control that could still be under the floor is recorded: rows, scrims and
            // cells clear it already and would pay a recomposition for a pad of zero.
            val next = if (size.width < floorPx || size.height < floorPx) size else IntSize.Zero
            if (next != drawn) drawn = next
        }
}

/** Pads the click node out around the drawn content: the half that is felt. */
private fun Modifier.tapTargetExpand(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(-2 * padX, -2 * padY))
        layout(placeable.width + 2 * padX, placeable.height + 2 * padY) { placeable.place(padX, padY) }
    }

/**
 * Hands the parent back the drawn size: the invisible half. It inflates the constraints by exactly
 * what [tapTargetExpand] subtracts, so a fixed-size caller is not squeezed by the pad.
 */
private fun Modifier.tapTargetInset(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(2 * padX, 2 * padY))
        layout((placeable.width - 2 * padX).coerceAtLeast(0), (placeable.height - 2 * padY).coerceAtLeast(0)) {
            placeable.place(-padX, -padY)
        }
    }
