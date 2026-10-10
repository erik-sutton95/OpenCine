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

/** One retained bounded picture, with source/size/cover cancellation and independent pinch/pan. */
@Composable
fun MonitorInteractivePicture(source: Any, width: Float, height: Float, modifier: Modifier = Modifier,
    maximumZoom: Float = MonitorPlaybackZoom.MAX_SCALE, enabled: Boolean = true,
    onTransform: (MonitorPlaybackZoom) -> Unit = {}, picture: @Composable BoxScope.() -> Unit,
) {
    var zoom by remember(source) { mutableStateOf(MonitorPlaybackZoom(maximumScale = maximumZoom)) }
    LaunchedEffect(source, width, height, enabled) { zoom = zoom.endGesture(width, height) }
    SideEffect { onTransform(zoom) }
    Box(modifier.clipToBounds().pointerInput(source, width, height, enabled) {
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
