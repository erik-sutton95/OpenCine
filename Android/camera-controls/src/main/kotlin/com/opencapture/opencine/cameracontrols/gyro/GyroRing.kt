package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** The grays and track colors the approved mockups use on the monitor background. */
internal object GyroPalette {
    /** Small uppercase overline above a title. */
    val overline = Color(0xFF8B8D90)

    /** The hint line under the ring. */
    val hint = Color(0xFF8B8D90)

    /** Supporting body copy. */
    val body = Color(0xFFA7A9AC)

    /** The unlit calibration ticks: dim white, like the mockup's near-black track. */
    val track = MonitorPalette.text.copy(alpha = 0.14f)

    /** An unfilled progress dot. */
    val dotOff = Color(0xFF3A3B3D)
}

/**
 * What the calibration ring draws for one state: the lit-tick fraction, the dim treatment and the
 * checkmark. Platform neutral and the Android twin of the Swift `GyroRingModel`.
 */
public data class GyroRingModel(
    /** Fraction of the 60 ticks lit in the accent, clockwise from twelve o'clock. */
    val litFraction: Double,
    /** Draw the whole ring at reduced opacity (a block or a discarded calibration). */
    val dimmed: Boolean,
    /** Replace the camera glyph with a checkmark. */
    val checkmark: Boolean,
    /** Static tilt of the camera glyph in degrees, a cue for the pose being asked for. */
    val tiltDegrees: Double = 0.0,
) {
    /** Number of lit ticks out of 60. */
    public val litTicks: Int
        get() = ceil(litFraction.coerceIn(0.0, 1.0) * 60).toInt()
}

/**
 * Maps a ring calibration state to what the ring draws: intro empty, looking at 0.15, a hold
 * filling from 0.15 to 1, a block or discarded calibration dimmed, a failed verification back to
 * empty, and completion full with the checkmark.
 */
public fun gyroRingModel(state: GyroRingState): GyroRingModel =
    when (state.phase) {
        GyroRingPhase.INTRO -> GyroRingModel(litFraction = 0.0, dimmed = false, checkmark = false)
        GyroRingPhase.POSING ->
            if (state.inZone == true) {
                GyroRingModel(
                    litFraction = 0.15 + 0.85 * (state.hold ?: 0.0).coerceIn(0.0, 1.0),
                    dimmed = false,
                    checkmark = false,
                    tiltDegrees = gyroRingTilt(state.step),
                )
            } else {
                GyroRingModel(
                    litFraction = 0.15,
                    dimmed = false,
                    checkmark = false,
                    tiltDegrees = gyroRingTilt(state.step),
                )
            }
        GyroRingPhase.BLOCKED ->
            GyroRingModel(
                litFraction = 0.15,
                dimmed = true,
                checkmark = false,
                tiltDegrees = gyroRingTilt(state.step),
            )
        GyroRingPhase.RETRYING -> GyroRingModel(litFraction = 0.0, dimmed = false, checkmark = false)
        GyroRingPhase.INVALIDATED ->
            GyroRingModel(litFraction = 0.0, dimmed = true, checkmark = false)
        GyroRingPhase.COMPLETE -> GyroRingModel(litFraction = 1.0, dimmed = false, checkmark = true)
    }

/** The camera glyph's tilt cue for a calibration step: level, tilted up, tilted and leaned. */
private fun gyroRingTilt(step: Int?): Double =
    when (step) {
        1 -> -14.0
        2 -> -24.0
        else -> 0.0
    }

/**
 * The spoken hold milestone (25, 50 or 75 percent) a new hold value reached, or null when it
 * crossed nothing new. The caller keeps the last announced threshold per step and resets it when
 * the step changes.
 */
internal fun gyroHoldAnnouncement(previousThreshold: Int, hold: Double): Int? {
    if (!hold.isFinite()) return null
    val reached = when {
        hold >= 0.75 -> 75
        hold >= 0.50 -> 50
        hold >= 0.25 -> 25
        else -> 0
    }
    return if (reached > previousThreshold) reached else null
}

/**
 * 60 dotted ticks around a camera glyph, the mockup's "fill the ring". Lit ticks use the theme
 * accent; the rest stay a dim track. A checkmark replaces the glyph and a full ring becomes the
 * large checked ring. The lit fraction animates over about 200 ms.
 */
@Composable
public fun GyroRing(model: GyroRingModel, modifier: Modifier = Modifier) {
    val litFraction by animateFloatAsState(
        targetValue = model.litFraction.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(durationMillis = 200),
        label = "gyroRingLit",
    )
    BoxWithConstraints(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val diameter = minOf(maxWidth, maxHeight).times(0.7f).coerceAtMost(260.dp)
        if (diameter.value.isFinite() && diameter > 0.dp) {
            Box(
                Modifier
                    .size(diameter)
                    .alpha(if (model.dimmed) 0.35f else 1f),
                contentAlignment = Alignment.Center,
            ) {
                if (model.checkmark && litFraction >= 0.99f) {
                    GyroCheckGlyph(diameter)
                } else {
                    GyroTicks(litTicks = ceil(litFraction * 60).toInt(), diameter = diameter)
                    if (model.checkmark) {
                        GyroCheckMark(diameter * 0.5f)
                    } else {
                        MonitorIcon(
                            icon = MonitorIcon.CAMERA,
                            contentDescription = null,
                            modifier = Modifier.size(diameter * 0.4f).rotate(model.tiltDegrees.toFloat()),
                            tint = MonitorPalette.secondary,
                        )
                    }
                }
            }
        }
    }
}

/** The 60 round-capped ticks from twelve o'clock, the first [litTicks] in the accent. */
@Composable
private fun GyroTicks(litTicks: Int, diameter: Dp) {
    val lit = MonitorPalette.accent
    val track = GyroPalette.track
    Canvas(Modifier.size(diameter)) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val outer = size.minDimension / 2f
        val inner = outer - size.minDimension * 0.10f
        val strokeWidth = size.minDimension * 0.026f
        for (index in 0 until 60) {
            val angle = -PI / 2.0 + index * 2.0 * PI / 60.0
            val start = Offset(
                center.x + inner * cos(angle).toFloat(),
                center.y + inner * sin(angle).toFloat(),
            )
            val end = Offset(
                center.x + outer * cos(angle).toFloat(),
                center.y + outer * sin(angle).toFloat(),
            )
            drawLine(
                color = if (index < litTicks) lit else track,
                start = start,
                end = end,
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}

/** The mockup's check tick, drawn on a 110 unit square so the shapes scale together. */
@Composable
private fun GyroCheckMark(size: Dp) {
    Canvas(Modifier.size(size)) {
        val scale = this.size.minDimension / 110f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        val path = Path().apply {
            moveTo(center.x - 17f * scale, center.y + 2f * scale)
            lineTo(center.x - 6f * scale, center.y + 13f * scale)
            lineTo(center.x + 18f * scale, center.y - 12f * scale)
        }
        drawPath(
            path = path,
            color = MonitorPalette.accent,
            style = Stroke(
                width = 7f * scale,
                cap = StrokeCap.Round,
                join = StrokeJoin.Round,
            ),
        )
    }
}

/** The mockup's complete glyph: an accent ring with an accent check inside it. */
@Composable
private fun GyroCheckGlyph(size: Dp) {
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val scale = this.size.minDimension / 110f
            drawCircle(
                color = MonitorPalette.accent,
                radius = 40f * scale,
                center = Offset(this.size.width / 2f, this.size.height / 2f),
                style = Stroke(width = 9f * scale),
            )
        }
        GyroCheckMark(size)
    }
}
