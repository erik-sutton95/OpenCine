package com.opencapture.monitorui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics

/**
 * Fades chrome out while another control replaces it (the open zoom ruler) and back in after,
 * keeping it composed so nothing it holds is lost. Hidden chrome takes no touches and is left
 * out of accessibility.
 */
@Composable
fun Modifier.monitorChromeHidden(hidden: Boolean): Modifier {
    val alpha by animateFloatAsState(if (hidden) 0f else 1f, tween(MonitorMotion.OPACITY_MS), label = "chrome-hidden")
    val faded = graphicsLayer { this.alpha = alpha }
    if (!hidden) return faded
    return faded.clearAndSetSemantics { }.pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        }
    }
}
