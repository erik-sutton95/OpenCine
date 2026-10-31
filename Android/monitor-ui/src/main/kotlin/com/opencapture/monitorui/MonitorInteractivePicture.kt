package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.IntOffset
import java.util.Locale
import kotlin.math.roundToInt

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

/**
 * The same picture on a page canvas, zoomed the way playback zooms (#299). At 1x the picture fills
 * [feed], its letterboxed frame in the [canvasWidth] by [canvasHeight] canvas (pixels), and only a
 * gesture that lands on it is taken. Zoomed, the picture is shown past that frame up to the canvas
 * edge, a pinch or pan anywhere on the canvas moves it, and its edge stops at the canvas edge. The
 * picture keeps its frame-sized node: zoom is a transform of the one view, never a redraw.
 * [onTransform] reports the zoom; [visiblePictureRect][MonitorPlaybackZoom.visiblePictureRect] of it
 * is where the picture is seen.
 */
@Composable
fun MonitorInteractivePicture(source: Any, canvasWidth: Float, canvasHeight: Float, feed: MonitorRect,
    modifier: Modifier = Modifier, maximumZoom: Float = MonitorPlaybackZoom.MAX_SCALE, enabled: Boolean = true,
    onTransform: (MonitorPlaybackZoom) -> Unit = {},
    contentDescription: String? = null,
    picture: @Composable BoxScope.() -> Unit,
) {
    var zoom by remember(source) { mutableStateOf(MonitorPlaybackZoom(maximumScale = maximumZoom)) }
    LaunchedEffect(source, feed.width, feed.height, canvasWidth, canvasHeight, enabled) {
        zoom = zoom.endGesture(canvasWidth, canvasHeight, pictureWidth = feed.width, pictureHeight = feed.height)
    }
    SideEffect { onTransform(zoom) }
    val density = LocalDensity.current
    val latestFeed by rememberUpdatedState(feed)
    val latestZoomed by rememberUpdatedState(zoom.isZoomed)
    fun answers(position: Offset): Boolean = latestZoomed || latestFeed.let {
        position.x >= it.x && position.x <= it.x + it.width && position.y >= it.y && position.y <= it.y + it.height
    }
    fun step(zoomChange: Float): MonitorPlaybackZoom = zoom.transformed(zoomChange, canvasWidth / 2f,
        canvasHeight / 2f, 0f, 0f, canvasWidth, canvasHeight, feed.width, feed.height)
    val accessibility = if (contentDescription != null) Modifier.semantics {
        this.contentDescription = contentDescription
        stateDescription = monitorZoomStateDescription(zoom.scale)
        customActions = listOf(
            CustomAccessibilityAction(ZOOM_IN_ACTION) { if (!enabled) false else { zoom = step(1.5f); true } },
            CustomAccessibilityAction(ZOOM_OUT_ACTION) { if (!enabled) false else { zoom = step(1f / 1.5f); true } },
            CustomAccessibilityAction(RESET_ZOOM_ACTION) { if (!enabled) false else { zoom = zoom.reset(); true } },
        )
    } else Modifier
    val visible = zoom.visiblePictureRect(feed, canvasWidth, canvasHeight)
    Box(modifier) {
        Box(Modifier.offset { IntOffset(visible.x.roundToInt(), visible.y.roundToInt()) }
            .size(with(density) { visible.width.toDp() }, with(density) { visible.height.toDp() }).clipToBounds()) {
            Box(Modifier.wrapContentSize(Alignment.TopStart, unbounded = true)
                .offset { IntOffset((feed.x - visible.x).roundToInt(), (feed.y - visible.y).roundToInt()) }
                .size(with(density) { feed.width.toDp() }, with(density) { feed.height.toDp() })
                .graphicsLayer {
                    scaleX = zoom.scale; scaleY = zoom.scale; translationX = zoom.offsetX; translationY = zoom.offsetY
                }, content = picture)
        }
        // The gesture well spans the canvas; at 1x it answers only on the picture's frame.
        Box(Modifier.fillMaxSize().then(accessibility)
            .pointerInput(source, feed, canvasWidth, canvasHeight, enabled) {
                if (!enabled) return@pointerInput
                detectMonitorPlaybackVideoGestures(isReady = { enabled }, isZoomed = { zoom.isZoomed },
                    config = MonitorPlaybackGestureConfig(enableTap = false, enableScrub = false, enableSwipe = false),
                    answers = ::answers,
                    onTap = {}, onChromeSwipe = {}, onScrubStart = {}, onScrubDelta = {}, onScrubEnd = {},
                    onPinch = { magnification, centroid ->
                        val anchor = monitorPlaybackUnitPoint(centroid, canvasWidth, canvasHeight)
                        zoom = zoom.pinchChangedBounded(magnification, anchor.first, anchor.second,
                            canvasWidth, canvasHeight, canvasWidth, canvasHeight,
                            pictureWidth = feed.width, pictureHeight = feed.height)
                    },
                    onPinchEnd = { zoom = zoom.endPinch(canvasWidth, canvasHeight, pictureWidth = feed.width, pictureHeight = feed.height) },
                    onPan = { zoom = zoom.panChangedBounded(it.x, it.y, canvasWidth, canvasHeight,
                        pictureWidth = feed.width, pictureHeight = feed.height) },
                    onPanEnd = { zoom = zoom.endPan(canvasWidth, canvasHeight, pictureWidth = feed.width, pictureHeight = feed.height) })
            })
    }
}
