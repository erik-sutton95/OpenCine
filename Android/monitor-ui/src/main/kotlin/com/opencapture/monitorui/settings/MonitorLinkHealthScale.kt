package com.opencapture.monitorui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography

private fun linkHealthText(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    if (mono) MonitorTypography.readout(size, weight) else MonitorTypography.text(size, weight)
private fun Modifier.linkHealthSurface(): Modifier =
    background(MonitorPalette.surface, RoundedCornerShape(12.dp))
        .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))

/** Shows the host-resolved link score without measuring or making transport decisions. */
@Composable
fun MonitorLinkHealthScale(title: String, caption: String, score: Int) {
    val band = MonitorLinkHealth.band(score)
    val bandColor = MonitorLinkHealth.color(score)
    val litCount =
        when (band) {
            MonitorLinkHealth.Band.POOR -> 4
            MonitorLinkHealth.Band.WATCH -> 8
            MonitorLinkHealth.Band.STABLE -> 12
        }
    val bandSlot =
        when (band) {
            MonitorLinkHealth.Band.POOR -> 0
            MonitorLinkHealth.Band.WATCH -> 1
            MonitorLinkHealth.Band.STABLE -> 2
        }
    val bandLabel =
        when (band) {
            MonitorLinkHealth.Band.POOR -> "POOR"
            MonitorLinkHealth.Band.WATCH -> "WATCH"
            MonitorLinkHealth.Band.STABLE -> "STABLE"
        }
    Column(
        Modifier.fillMaxWidth()
            .linkHealthSurface()
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Text(title, style = linkHealthText(13f, FontWeight.SemiBold), color = MonitorPalette.text)
        Text(
            caption,
            style = linkHealthText(11.5f, FontWeight.Medium, mono = true),
            color = MonitorPalette.muted,
        )
        Row(Modifier.fillMaxWidth().height(19.dp)) {
            repeat(3) { slot ->
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (slot == bandSlot) {
                        Text(
                            bandLabel,
                            style = linkHealthText(9.5f, FontWeight.Bold, mono = true),
                            color = bandColor,
                            letterSpacing = 0.5.sp,
                            modifier =
                                Modifier
                                    .background(bandColor.copy(alpha = 0.12f), CircleShape)
                                    .border(1.dp, bandColor, CircleShape)
                                    .padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            repeat(12) { index ->
                val fill =
                    when {
                        index >= litCount -> Color.White.copy(alpha = 0.10f)
                        index < 4 -> MonitorLinkHealth.poor.copy(alpha = 0.8f)
                        index < 8 -> MonitorLinkHealth.watch.copy(alpha = 0.85f)
                        else -> MonitorLinkHealth.stable.copy(alpha = 0.9f)
                    }
                Box(
                    Modifier.weight(1f)
                        .height(6.dp)
                        .background(fill, CircleShape),
                )
            }
        }
        Row(Modifier.fillMaxWidth()) {
            DashLegend(MonitorLinkHealth.Band.POOR.label, "<50", Modifier.weight(1f), Alignment.Start)
            DashLegend(MonitorLinkHealth.Band.WATCH.label, "50-79", Modifier.weight(1f), Alignment.CenterHorizontally)
            DashLegend(MonitorLinkHealth.Band.STABLE.label, "80+", Modifier.weight(1f), Alignment.End)
        }
    }
}

@Composable
private fun DashLegend(
    name: String,
    sub: String,
    modifier: Modifier,
    alignment: Alignment.Horizontal,
) {
    Row(
        modifier,
        horizontalArrangement =
            when (alignment) {
                Alignment.Start -> Arrangement.Start
                Alignment.End -> Arrangement.End
                else -> Arrangement.Center
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(name, style = linkHealthText(10f, FontWeight.SemiBold), color = MonitorPalette.muted)
        Spacer(Modifier.size(4.dp))
        Text(sub, style = linkHealthText(9f, FontWeight.Normal, mono = true), color = MonitorPalette.faint)
    }
}
