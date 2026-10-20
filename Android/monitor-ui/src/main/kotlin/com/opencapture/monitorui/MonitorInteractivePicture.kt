package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import java.util.Locale

internal const val ZOOM_IN_ACTION = "Zoom in"
internal const val ZOOM_OUT_ACTION = "Zoom out"
internal const val RESET_ZOOM_ACTION = "Reset zoom"

/** The screen reader's zoom state for a page or playback picture: the same label on both pages. */
internal fun monitorZoomStateDescription(scale: Float): String =
    String.format(Locale.US, "Zoom %.1fx", scale)

/** One retained bounded picture, with source/size/cover cancellation and independent pinch/pan. */
@Composable
fun MonitorInteractivePicture(source: Any, width: Float, height: Float, modifier: Modifier = Modifier,
    maximumZoom: Float = MonitorPlaybackZoom.MAX_SCALE, enabled: Boolean = true,
    onTransform: (MonitorPlaybackZoom) -> Unit = {},
    /** Restores the still viewer's TalkBack label, zoom state and Zoom in/out/Reset actions. */
    contentDescription: String? = null,
    picture: @Composable BoxScope.() -> Unit,
) {
    var zoom by remember(source) { mutableStateOf(MonitorPlaybackZoom(maximumScale = maximumZoom)) }
    LaunchedEffect(source, width, height, enabled) { zoom = zoom.endGesture(width, height) }
    SideEffect { onTransform(zoom) }
    val accessibility = if (contentDescription != null) Modifier.semantics {
        this.contentDescription = contentDescription
        stateDescription = monitorZoomStateDescription(zoom.scale)
        customActions = listOf(
            CustomAccessibilityAction(ZOOM_IN_ACTION) {
                if (!enabled) false else {
                    zoom = zoom.transformed(1.5f, width / 2f, height / 2f, 0f, 0f, width, height); true
                }
            },
            CustomAccessibilityAction(ZOOM_OUT_ACTION) {
                if (!enabled) false else {
                    zoom = zoom.transformed(1f / 1.5f, width / 2f, height / 2f, 0f, 0f, width, height); true
                }
            },
            CustomAccessibilityAction(RESET_ZOOM_ACTION) {
                if (!enabled) false else { zoom = zoom.reset(); true }
            },
        )
    } else Modifier
    Box(modifier.clipToBounds().then(accessibility).pointerInput(source, width, height, enabled) {
        if (!enabled) return@pointerInput
        detectMonitorPlaybackVideoGestures(isReady = { enabled }, isZoomed = { zoom.isZoomed },
            config = MonitorPlaybackGestureConfig(enableTap = false, enableScrub = false, enableSwipe = false),
            onTap = {}, onChromeSwipe = {}, onScrubStart = {}, onScrubDelta = {}, onScrubEnd = {},
            onPinch = { magnification, centroid ->
                val anchor = monitorPlaybackUnitPoint(centroid, width, height)
                zoom = zoom.pinchChanged(magnification, anchor.first, anchor.second, width, height)
            }, onPinchEnd = { zoom = zoom.endPinch(width, height) },
            onPan = { zoom = zoom.panChanged(it.x, it.y) }, onPanEnd = { zoom = zoom.endPan(width, height) })
    }) {
        Box(Modifier.fillMaxSize().graphicsLayer {
            scaleX = zoom.scale; scaleY = zoom.scale; translationX = zoom.offsetX; translationY = zoom.offsetY
        }, content = picture)
    }
}
