package com.opencapture.opencine.appkit

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorRecordLamp
import com.opencapture.monitorui.MonitorTypography
import kotlinx.coroutines.delay

/**
 * The still release for a camera that holds it: finger-down presses and finger-up (or a cancelled
 * pointer) releases, so a hold can latch a burst or end a bulb exposure. Accessibility activation is
 * one complete press and release. A press that loses [enabled] mid-hold still releases exactly once:
 * the camera never keeps a release the operator let go of.
 *
 * [timerRemaining] is the source's running self-timer countdown and [bodyPulse] a counter the source
 * bumps when the camera body fires on its own; each bump dips the button once.
 */
@Composable
public fun MonitorPhotoRelease(
    diameter: Float,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    capturing: Boolean = false,
    timerRemaining: Int? = null,
    bodyPulse: Int = 0,
    onPressed: () -> Unit,
    onReleased: () -> Unit,
): Unit {
    val press by rememberUpdatedState(onPressed)
    val release by rememberUpdatedState(onReleased)
    val admits by rememberUpdatedState(enabled)
    var dipped by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (dipped) .88f else 1f, tween(120), label = "photo-release-dip")
    LaunchedEffect(bodyPulse) {
        if (bodyPulse > 0) {
            dipped = true
            delay(130)
            dipped = false
        }
    }
    Box(
        modifier.size(diameter.dp).scale(scale).alpha(if (enabled) 1f else .4f)
            // Not keyed on [enabled]: restarting the detector would drop a held press without its release.
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown()
                    if (!admits) return@awaitEachGesture
                    press()
                    try {
                        waitForUpOrCancellation()
                    } finally {
                        release()
                    }
                }
            }
            .semantics {
                role = Role.Button
                contentDescription = when {
                    timerRemaining != null -> "Self-timer, $timerRemaining seconds"
                    capturing -> "Capturing"
                    else -> "Take photo"
                }
                if (enabled) {
                    onClick {
                        press()
                        release()
                        true
                    }
                } else {
                    disabled()
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        MonitorRecordLamp(recording = false, photo = true, modifier = Modifier.fillMaxSize().alpha(if (capturing) .5f else 1f))
        timerRemaining?.let { Text("$it", color = Color.Black, style = MonitorTypography.text(30f, FontWeight.Bold), maxLines = 1) }
    }
}
