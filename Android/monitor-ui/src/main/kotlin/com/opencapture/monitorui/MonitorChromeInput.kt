package com.opencapture.monitorui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer

/** Actual native press/tap/hold input; hosts supply their own optional feedback. */
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
        if (onLongClick != null) {
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
    return this.then(press).then(clicks)
}
