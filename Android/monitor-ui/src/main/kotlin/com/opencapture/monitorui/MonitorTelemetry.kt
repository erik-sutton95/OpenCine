package com.opencapture.monitorui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Draw-only readouts. The adapter supplies its existing delivery-health mapping. */
@Composable
fun MonitorTelemetry(
    signalBars: Int,
    fps: String,
    phonePercent: Int?,
    cameraPercent: Int,
    horizontal: Boolean,
    modifier: Modifier = Modifier,
    showsLink: Boolean = true,
    showsPower: Boolean = true,
) {
    MonitorTelemetry(signalBars, fps, listOf(
        MonitorTelemetryPower(false, phonePercent), MonitorTelemetryPower(true, cameraPercent.takeIf { it in 0..100 })),
        horizontal, modifier, showsLink, showsPower)
}

/** Battery facts may be percentages or an actual coarse gauge. Missing measurements remain absent. */
public class MonitorTelemetryPower(public val camera: Boolean, public val percent: Int?,
    public val charging: Boolean? = null, public val bars: Int? = null, public val barCount: Int = 5,
    public val warning: Boolean = false, public val exhausted: Boolean = false)

/** All operator entry points use the same link toggle and power rendering. */
@Composable
public fun MonitorTelemetry(signalBars: Int?, fps: String?, power: List<MonitorTelemetryPower>,
    horizontal: Boolean, modifier: Modifier = Modifier, showsLink: Boolean = true, showsPower: Boolean = true) {
    var showsFps by rememberSaveable { mutableStateOf(false) }
    val gauges: @Composable () -> Unit = {
        if (showsLink && (signalBars != null || fps != null)) {
            val value = if (showsFps) fps?.toDoubleOrNull()?.let { "${Math.round(it)} fps" } ?: fps ?: "\u2014"
                else if (signalBars == null) "\u2014" else null
            TelemetryGauge(if (showsFps) MonitorIcon.GAUGE else MonitorIcon.SIGNAL, MonitorPalette.accent,
                signalBars?.coerceIn(0, 4)?.div(4f) ?: 0f,
                "Live link ${signalBars?.let { "$it of 4 delivery bars" } ?: "unavailable"}, feed ${fps ?: "unavailable"} frames per second",
                horizontal, value, onClick = { showsFps = !showsFps })
        }
        if (showsPower) power.forEach { reading ->
            val percent = reading.percent?.takeIf { it in 0..100 }
            val tint = if (reading.warning || reading.exhausted) MonitorPalette.recording
                else percent?.let(::batteryTint) ?: MonitorPalette.text
            val label = "${if (reading.camera) "Camera" else "Phone"} battery " +
                (reading.bars?.let { "$it of ${reading.barCount} bars" } ?: percent?.let { "$it percent" } ?: "unavailable")
            val opacity = if (reading.exhausted && (reading.bars != null || percent != null)) {
                val transition = rememberInfiniteTransition(label = "reportedLiveBatteryExhaustion")
                val alpha by transition.animateFloat(initialValue = 1f, targetValue = 0.35f,
                    animationSpec = infiniteRepeatable(tween(600, easing = FastOutSlowInEasing), RepeatMode.Reverse),
                    label = "reportedLiveBatteryExhaustionAlpha")
                alpha
            } else 1f
            TelemetryGauge(if (reading.charging == true) MonitorIcon.ZAP else if (reading.camera) MonitorIcon.CAMERA else MonitorIcon.SMARTPHONE,
                tint, reading.bars?.let { it.toFloat() / reading.barCount.coerceAtLeast(1) } ?: percent?.div(100f) ?: 0f,
                label, horizontal, if (reading.bars != null) null else percent?.let { "$it%" } ?: "\u2014",
                barCount = if (reading.bars != null) reading.barCount else 4, filled = reading.bars, opacity = opacity)
        }
    }
    if (horizontal) Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) { gauges() }
    else Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) { gauges() }
}

/** Phone and camera batteries share one scale (matches iOS). */
private fun batteryTint(percent: Int): Color = when {
    percent !in 0..100 -> MonitorPalette.text
    percent <= 20 -> MonitorPalette.recording
    percent <= 40 -> Color(0.914f, 0.674f, 0.208f)
    else -> Color(0.18f, 0.78f, 0.42f)
}

/** The camera battery pill; without the glyph it keeps the width that fits "100%". */
@Composable
private fun MonitorCameraBatteryGauge(percent: Int, stacked: Boolean = false, showsIcon: Boolean = true) {
    TelemetryGauge(MonitorIcon.CAMERA.takeIf { showsIcon }, batteryTint(percent), if (percent in 0..100) percent / 100f else 0f,
        if (percent in 0..100) "Camera battery $percent percent" else "Camera battery unavailable",
        stacked, percent.takeIf { it in 0..100 }?.let { "$it%" } ?: "\u2014")
}

/**
 * One glass pill per gauge, styled like the Live View buttons: white icon beside
 * the value, status color on the value only. One width fits the widest value.
 */
@Composable
private fun TelemetryGauge(
    icon: MonitorIcon?, tint: Color, fraction: Float, label: String,
    stacked: Boolean, value: String? = null, onClick: (() -> Unit)? = null, barCount: Int = 4,
    filled: Int? = null, opacity: Float = 1f,
) {
    Row(
        Modifier
            // Without the glyph the pill still fits "100%" so values never jitter.
            .size((if (filled != null && value == null) monitorGaugeReadoutWidth(filled, barCount,
                if (icon != null) 58f else 40f, if (icon != null) 28f else 12f)
                else if (icon != null) 58f else 40f).dp, 20.dp)
            .alpha(opacity)
            .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(7.dp))
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(horizontal = 6.dp)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (icon != null) MonitorIcon(icon, contentDescription = null, tint = MonitorPalette.text, modifier = Modifier.size(11.dp))
        if (value != null) {
            Text(value, color = tint, style = MonitorTypography.readout(10f, FontWeight.Bold), maxLines = 1)
        } else {
            if (filled != null) MonitorGaugeBars(filled, barCount, tint)
            else MonitorGaugeBars(fraction, barCount, tint)
        }
    }
}

/** Keep the original fraction entry point for link delivery and existing callers. */
@Composable
fun MonitorGaugeBars(fraction: Float, count: Int, tint: Color) {
    if (count > 10) {
        val filled = if (!fraction.isFinite() || fraction <= 0f) 0 else if (fraction >= 1f) count
            else Math.round(fraction.toDouble() * count).toInt()
        MonitorGaugeStepText(filled, count, tint)
    } else MonitorGaugeBarCells(count, tint) { index -> fraction >= (index + 1).toFloat() / count.coerceAtLeast(1) }
}

/** Batteries retain exact integer steps; large counts never allocate a cell per step. */
@Composable
fun MonitorGaugeBars(filled: Int, count: Int, tint: Color) {
    if (count > 10) MonitorGaugeStepText(filled, count, tint)
    else MonitorGaugeBarCells(count, tint) { index -> index < filled }
}

internal fun monitorGaugeReadoutWidth(filled: Int, count: Int, minimum: Float, inset: Float): Float =
    if (count > 10) ("$filled/$count".length * 6f + inset).coerceAtMost(156f).coerceAtLeast(minimum) else minimum

@Composable
private fun MonitorGaugeStepText(filled: Int, count: Int, tint: Color) {
    MonitorScaleToFit(minScale = 0.5f) {
        Text("$filled/$count", color = tint, style = MonitorTypography.readout(10f, FontWeight.Bold),
            maxLines = 1, softWrap = false, modifier = Modifier.semantics { contentDescription = "$filled of $count bars" })
    }
}

@Composable
private fun MonitorGaugeBarCells(count: Int, tint: Color, lit: (Int) -> Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(1.5.dp)) {
        repeat(count.coerceIn(1, 10)) { index ->
            Box(Modifier.size(3.5.dp, 9.dp).background(tint.copy(alpha = if (lit(index)) 1f else .2f),
                RoundedCornerShape(.75.dp)))
        }
    }
}
