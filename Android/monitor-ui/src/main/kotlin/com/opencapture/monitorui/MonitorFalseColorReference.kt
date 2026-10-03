package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun MonitorFalseColorReference(values: MonitorFalseColorReferenceValues, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(MonitorScopePanelSize.falseColorReference.width.dp, MonitorScopePanelSize.falseColorReference.height.dp)
            .clip(RoundedCornerShape(12f.dp))
            .monitorMaterial(MonitorMaterial.Scope)
            .padding(7.dp),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val barH = 8.dp.toPx()
            val barY = 14.dp.toPx()
            val barW = size.width
            drawRect(Color.White.copy(alpha = 0.12f), Offset(0f, barY), Size(barW, barH))
            for (segment in values.segments) {
                val lo = segment.lowerFraction.toFloat()
                val hi = segment.upperFraction.toFloat()
                drawRect(
                    Color(
                        segment.red.toFloat(),
                        segment.green.toFloat(),
                        segment.blue.toFloat(),
                    ),
                    Offset(barW * lo, barY),
                    Size(maxOf(1f, barW * (hi - lo)), barH),
                )
            }
        }
        Text(
            "False Color",
            color = MonitorPalette.text,
            fontSize = 8.5.sp,
            lineHeight = 10.sp,
            fontFamily = MonitorTypography.fontFamily,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.TopStart),
        )
        Text(
            values.subtitle,
            color = MonitorPalette.muted,
            fontSize = 7.5.sp,
            lineHeight = 9.sp,
            fontFamily = MonitorTypography.fontFamily,
            modifier = Modifier.align(Alignment.TopEnd),
        )
        if (values.markers.isNotEmpty()) {
            Box(Modifier.align(Alignment.BottomStart).fillMaxSize().padding(top = 26.dp)) {
                values.markers.forEach { marker ->
                    Text(
                        marker.label,
                        color = MonitorPalette.muted,
                        fontSize = 5.5.sp,
                        lineHeight = 7.sp,
                        fontFamily = MonitorTypography.fontFamily,
                        modifier =
                            Modifier.offset(
                                x = (MonitorScopePanelSize.falseColorReference.width * marker.fraction.toFloat() - 10f).dp,
                                y = 0.dp,
                            ),
                    )
                }
            }
        } else if (values.axisLabels.isNotEmpty()) {
            Row(
                Modifier.align(Alignment.BottomStart).fillMaxSize().padding(top = 26.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                values.axisLabels.forEach { label ->
                    Text(
                        label,
                        color = MonitorPalette.muted,
                        fontSize = 5.5.sp,
                        lineHeight = 7.sp,
                        fontFamily = MonitorTypography.fontFamily,
                    )
                }
            }
        }
    }
}
