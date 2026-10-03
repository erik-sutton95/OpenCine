package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight

@Composable
fun MonitorAssistToolGlyph(tool: MonitorAssistTool, tint: Color, modifier: Modifier = Modifier,
    evFontSize: Float = 13.3f) {
    val icon = when (tool) {
        MonitorAssistTool.LUT -> com.opencapture.monitorui.MonitorAssistIcon.LUT
        MonitorAssistTool.PEAK -> com.opencapture.monitorui.MonitorAssistIcon.PEAKING
        MonitorAssistTool.FALSE -> com.opencapture.monitorui.MonitorAssistIcon.FALSE_COLOR
        MonitorAssistTool.ZEBRA -> com.opencapture.monitorui.MonitorAssistIcon.ZEBRA
        MonitorAssistTool.WAVE -> com.opencapture.monitorui.MonitorAssistIcon.WAVEFORM
        MonitorAssistTool.PARADE -> com.opencapture.monitorui.MonitorAssistIcon.RGB_PARADE
        MonitorAssistTool.HISTO -> com.opencapture.monitorui.MonitorAssistIcon.HISTOGRAM
        MonitorAssistTool.VECTOR -> com.opencapture.monitorui.MonitorAssistIcon.VECTORSCOPE
        MonitorAssistTool.LIGHTS -> com.opencapture.monitorui.MonitorAssistIcon.TRAFFIC_LIGHTS
        MonitorAssistTool.GUIDES -> com.opencapture.monitorui.MonitorAssistIcon.FRAME_GUIDE
        MonitorAssistTool.GRID -> com.opencapture.monitorui.MonitorAssistIcon.GRID
        MonitorAssistTool.CROSS -> com.opencapture.monitorui.MonitorAssistIcon.CROSSHAIR
        MonitorAssistTool.LEVEL -> com.opencapture.monitorui.MonitorAssistIcon.LEVEL
        MonitorAssistTool.MIRROR -> com.opencapture.monitorui.MonitorAssistIcon.MIRROR
        MonitorAssistTool.AUDIO -> com.opencapture.monitorui.MonitorAssistIcon.AUDIO_METERS
        MonitorAssistTool.ND, MonitorAssistTool.EV, MonitorAssistTool.DESQ -> null
    }
    if (tool == MonitorAssistTool.EV) {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text("EV", style = MonitorTypography.text(evFontSize, FontWeight.SemiBold), color = tint, maxLines = 1)
        }
    } else if (tool == MonitorAssistTool.DESQ) MonitorIcon(MonitorIcon.CHEVRONS_UP_DOWN, null, modifier.rotate(90f), tint)
    else if (icon == null) MonitorIcon(MonitorIcon.APERTURE, null, modifier, tint)
    else com.opencapture.monitorui.MonitorAssistIcon(icon, tint, modifier)
}
