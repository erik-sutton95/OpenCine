package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
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
    val bars = signalBars.coerceIn(0, 4)
    // Signal / fps stay in the accent; the bar count carries the health.
    val linkColor = MonitorPalette.accent
    // One link pill: tap swaps signal bars and feed fps.
    var showsFps by rememberSaveable { mutableStateOf(false) }
    val gauges: @Composable () -> Unit = {
        if (showsLink) TelemetryGauge(if (showsFps) MonitorIcon.GAUGE else MonitorIcon.SIGNAL, linkColor, bars / 4f,
            "Live link $signalBars of 4 delivery bars, feed $fps frames per second", horizontal,
            // Whole frames with a unit; RECOV / LINK / the dash pass through.
            if (showsFps) fps.toDoubleOrNull()?.let { "${Math.round(it)} fps" } ?: fps else null,
            onClick = { showsFps = !showsFps })
        if (showsPower) {
        TelemetryGauge(MonitorIcon.SMARTPHONE, phonePercent?.let(::batteryTint) ?: MonitorPalette.text,
            phonePercent?.div(100f) ?: 0f,
            if (phonePercent != null && phonePercent >= 0) "Phone battery $phonePercent percent" else "Phone battery unavailable",
            horizontal, phonePercent?.takeIf { it in 0..100 }?.let { "$it%" } ?: "\u2014")
        MonitorCameraBatteryGauge(cameraPercent, stacked = horizontal)
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
    stacked: Boolean, value: String? = null, onClick: (() -> Unit)? = null,
) {
    Row(
        Modifier
            // Without the glyph the pill still fits "100%" so values never jitter.
            .size(if (icon != null) 58.dp else 40.dp, 20.dp)
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
            Row(horizontalArrangement = Arrangement.spacedBy(1.5.dp)) {
                repeat(4) { index ->
                    Box(
                        Modifier.size(3.5.dp, 9.dp).background(
                            tint.copy(alpha = if (fraction >= (index + 1) / 4f) 1f else .2f),
                            RoundedCornerShape(.75.dp),
                        ),
                    )
                }
            }
        }
    }
}
