package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight

/** Current monitor-assist identities. Sources provide availability and choose their tool ordering. */
enum class MonitorAssistTool {
    LUT,
    PEAK,
    FALSE,
    ZEBRA,
    WAVE,
    PARADE,
    HISTO,
    VECTOR,
    LIGHTS,
    ND,
    EV,
    AUDIO,
    GUIDES,
    GRID,
    CROSS,
    LEVEL,
    DESQ,
    MIRROR,
    ;

    val chipLabel: String
        get() = if (this == DESQ) "DE-SQ" else name

    val label: String
        get() = name

    val title: String
        get() =
            when (this) {
                LUT -> "LUT"
                PEAK -> "Peaking"
                FALSE -> "False Color"
                ZEBRA -> "Zebra"
                WAVE -> "Waveform"
                PARADE -> "RGB Parade"
                HISTO -> "Histogram"
                VECTOR -> "Vectorscope"
                LIGHTS -> "Traffic Lights"
                ND -> "ND Suggestion"
                EV -> "EV Meter"
                AUDIO -> "Audio Levels"
                GUIDES -> "Guides"
                GRID -> "Grid"
                CROSS -> "Crosshair"
                LEVEL -> "Level"
                DESQ -> "Anamorphic Desqueeze"
                MIRROR -> "Mirror"
            }

    /** The fixed camera EV meter and LEVEL are tap-only toggles. */
    val hasConfiguration: Boolean
        get() =
            when (this) {
                EV, LEVEL -> false
                else -> true
            }

    companion object {
        val toolbarGroups: List<List<MonitorAssistTool>> get() =
            listOf(
                listOf(LUT, PEAK, FALSE),
                listOf(ZEBRA, WAVE, PARADE),
                listOf(HISTO, VECTOR, LIGHTS, ND, EV),
                listOf(GUIDES, GRID, CROSS, LEVEL, DESQ),
                listOf(MIRROR),
            )

        /** AUDIO is appended as its own trailing section. */
        val toolbarCases: List<MonitorAssistTool> get() = toolbarGroups.flatten()

        /** Camera EV and LEVEL have no clip telemetry; AUDIO rides last like live. */
        val playbackToolbarCases: List<MonitorAssistTool> get() = toolbarCases.filter { it != EV && it != LEVEL } + AUDIO

        val settingsCases: List<MonitorAssistTool> get() = toolbarCases + AUDIO

        val cleanPinCases: List<MonitorAssistTool> get() = settingsCases.filter { it != EV }

        fun fromPersisted(raw: String): MonitorAssistTool? =
            entries.firstOrNull { it.name == raw || it.chipLabel == raw }
    }
}

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
