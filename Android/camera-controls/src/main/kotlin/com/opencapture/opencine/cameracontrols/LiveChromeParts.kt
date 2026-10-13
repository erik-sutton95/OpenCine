package com.opencapture.opencine.cameracontrols

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LiveChromeMetrics
import com.opencapture.monitorui.MonitorFocusResetButton
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.media.CameraLinkPhase
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Canvas origin in window pixels: capture / top-picker anchors are relative to this. */
val LocalLiveCanvasOrigin = compositionLocalOf { Offset.Zero }

fun Modifier.reportChromeFrame(onFrame: (MonitorRect) -> Unit): Modifier =
    composed {
        val density = LocalDensity.current
        val origin = LocalLiveCanvasOrigin.current
        onGloballyPositioned { coords ->
            val pos = coords.positionInRoot()
            val d = density.density
            onFrame(
                MonitorRect(
                    (pos.x - origin.x) / d,
                    (pos.y - origin.y) / d,
                    coords.size.width / d,
                    coords.size.height / d,
                ),
            )
        }
    }

/** Hold a numeric FPS string until it moves by [step] so hundredths do not tick the chip. */
object LiveChromeReadout {
    fun holdFPS(incoming: String, displayed: String, step: Double = 0.4): String {
        val next = incoming.toDoubleOrNull()
        val current = displayed.toDoubleOrNull()
        if (next == null || current == null) return incoming
        return if (abs(next - current) >= step) incoming else displayed
    }
}

/**
 * Live view link health onto the FPS chip labels. SoftAP live view is ~25 fps: that is
 * the delivery target for bars, not `CameraStatus.fps` (record format).
 */
object LiveViewLink {
    const val TARGET_FPS = 25.0

    fun cameraLinkPhase(
        connection: ConnectionPhase,
        recovering: Boolean,
        measuredFPS: Double,
    ): CameraLinkPhase {
        if (connection == ConnectionPhase.FAILED) return CameraLinkPhase.DISCONNECTED
        if (measuredFPS > 0) {
            return if (recovering) CameraLinkPhase.RECOVERING else CameraLinkPhase.STREAMING
        }
        return when (connection) {
            ConnectionPhase.IDLE -> CameraLinkPhase.DISCONNECTED
            ConnectionPhase.LIVE -> CameraLinkPhase.CONNECTED_IDLE
            else -> CameraLinkPhase.CONNECTING
        }
    }
    @Deprecated("Use MonitorLinkMeter.chipLabel")
    fun fpsChipLabel(connection: ConnectionPhase, recovering: Boolean, formattedFPS: String,
        measuredFPS: Double, sessionRecovering: Boolean = false): String =
        MonitorLinkMeter.chipLabel(connection, recovering, sessionRecovering, formattedFPS, measuredFPS)

}

/** The native Lock tile surface also hosts Multiview's Exit action. */
@Composable
fun MonitorChromeButton(
    icon: MonitorIcon, label: String, modifier: Modifier = Modifier,
    enabled: Boolean = true, selected: Boolean = false, buttonRole: Role = Role.Button, onClick: () -> Unit,
) {
    Box(
        modifier.size(LiveChromeMetrics.LOCK.dp).alpha(if (enabled) 1f else 0.4f)
            .monitorGlass(RoundedCornerShape(14.dp))
            .then(if (selected) Modifier.border(1.5.dp, LiveDesign.accent.copy(alpha = 0.75f), ChromeShape) else Modifier)
            .chromeClickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = label; role = buttonRole },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon, null, Modifier.fillMaxSize(26f / 54f),
            if (selected) LiveDesign.accent else LiveDesign.text.copy(alpha = 0.86f))
    }
}

@Composable
fun LockButton(locked: Boolean, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    LockButton(locked, if (locked) "Unlock monitor controls" else "Lock monitor controls",
        modifier, enabled, onClick)
}

@Composable
fun LockButton(locked: Boolean, label: String, modifier: Modifier = Modifier,
    enabled: Boolean = true, onClick: () -> Unit) {
    MonitorChromeButton(
        MonitorIcon.LOCK, label,
        modifier.semantics { toggleableState = ToggleableState(locked) },
        selected = locked, enabled = enabled, buttonRole = Role.Switch, onClick = onClick,
    )
}

@Composable
fun LiveFocusResetButton(modifier: Modifier = Modifier, onClick: () -> Unit) {
    val haptics = LocalOperatorHaptics.current
    MonitorFocusResetButton(
        modifier = modifier, foreground = LiveDesign.text, outline = LiveDesign.hairline,
        onClickFeedback = { haptics.selection() }, onClick = onClick,
    )
}

/** iOS `LiveAutoExposureUnlockButton`: releases the feed AE lock back to Auto. */
@Composable
fun LiveAutoExposureUnlockButton(modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .fillMaxSize()
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .border(1.dp, LiveDesign.hairline, CircleShape)
            .chromeClickable(onClick = onClick)
            .semantics { contentDescription = "Unlock exposure" },
        horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MonitorIcon(icon = MonitorIcon.SUN, contentDescription = null, tint = LiveDesign.aeLock, modifier = Modifier.size(15.dp))
        MonitorIcon(icon = MonitorIcon.LOCK_OPEN, contentDescription = null, tint = LiveDesign.aeLock, modifier = Modifier.size(13.dp))
    }
}

@Composable
fun SdCardGlyph(tint: Color, modifier: Modifier = Modifier) {
    MonitorIcon(MonitorIcon.CARD_SIM, null, modifier.size(14.dp), tint)
}

@Composable
fun LiveGimbalStick(
    enabled: Boolean,
    onMove: (Float, Float) -> Unit,
    onRelease: () -> Unit,
    onRecenter: () -> Unit,
    onFlip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val knobRatio = LiveChromeMetrics.GIMBAL_KNOB_DP / LiveChromeMetrics.GIMBAL_STICK_DP
    var knobOffset by remember { mutableStateOf(Offset.Zero) }
    var pressed by remember { mutableStateOf(false) }
    val renderedOffset by animateOffsetAsState(knobOffset,
        if (pressed) snap() else spring(dampingRatio = .8f, stiffness = 300f), label = "stick-return")
    // Resting ink is difference-blended, so its darkest result over white is
    // 1 - alpha. Keep it high enough to read dark on bright footage.
    val stickTint by animateColorAsState(
        if (pressed) LiveDesign.accent.copy(alpha = .8f) else Color.White.copy(alpha = .9f),
        tween(120), label = "stick-press")
    val scope = rememberCoroutineScope()
    var recenterJob by remember { mutableStateOf<Job?>(null) }
    Box(
        modifier
            .fillMaxSize()
            .semantics { contentDescription = "Gimbal stick" }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                var taps = 0
                var lastTap = 0L
                awaitEachGesture {
                    // Read per gesture: the operator Small / Medium / Large size resizes the frame.
                    val stickPx = min(this.size.width, this.size.height).toFloat()
                    val down = awaitFirstDown()
                    pressed = true
                    var dragged = false
                    var translation = Offset.Zero
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (change.pressed) {
                                translation += change.positionChange()
                                val mapped =
                                    CameraCommands.mapGimbalStickTouch(
                                        translation.x,
                                        translation.y,
                                        stickPx,
                                        stickPx * knobRatio,
                                        dragged,
                                    )
                                if (mapped.emit) {
                                    dragged = true
                                    taps = 0
                                    recenterJob?.cancel()
                                    knobOffset = Offset(mapped.visualX, mapped.visualY)
                                    onMove(mapped.commandX, mapped.commandY)
                                }
                                change.consume()
                            } else {
                                break
                            }
                        }
                        if (dragged) {
                            knobOffset = Offset.Zero
                            dragged = false
                            onRelease()
                        } else {
                            knobOffset = Offset.Zero
                            val now = System.currentTimeMillis()
                            if (now - lastTap > 420L) taps = 0
                            taps += 1
                            lastTap = now
                            when (taps) {
                                2 -> {
                                    recenterJob?.cancel()
                                    recenterJob =
                                        scope.launch {
                                            delay(280)
                                            onRecenter()
                                            taps = 0
                                        }
                                }
                                3 -> {
                                    recenterJob?.cancel()
                                    recenterJob = null
                                    taps = 0
                                    onFlip()
                                }
                            }
                        }
                    } finally {
                        pressed = false
                        knobOffset = Offset.Zero
                        // Cancellation/rotation must release the existing stick
                        // intent just as lifting the pointer does.
                        if (dragged) onRelease()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stickPx = size.minDimension
            val knobPx = stickPx * knobRatio
            val stroke = 2.dp.toPx()
            // Adapt only the two shapes during native composition: no pixel
            // samples, readback, blur or separate refresh cadence.
            val inkBlend = if (pressed) BlendMode.SrcOver else BlendMode.Difference
            drawCircle(
                color = stickTint,
                radius = stickPx / 2f - stroke / 2f,
                style = Stroke(width = stroke),
                blendMode = inkBlend,
            )
            drawCircle(
                color = stickTint,
                radius = knobPx / 2f,
                center = center + renderedOffset,
                blendMode = inkBlend,
            )
        }
    }
    LaunchedEffect(enabled) {
        if (!enabled) {
            recenterJob?.cancel()
            knobOffset = Offset.Zero
            onRelease()
        }
    }
}
