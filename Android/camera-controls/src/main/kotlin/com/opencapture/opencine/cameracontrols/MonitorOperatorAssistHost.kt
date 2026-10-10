package com.opencapture.opencine.cameracontrols

import androidx.compose.ui.graphics.Color
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorZebraPaint

/** Source-independent tool menus use the detector's typed paint values and shared labels. */
public val MonitorDefaultAssistHost: AssistHost = AssistHost(
    peakingColors = MonitorPeakingColor.entries.map { MonitorSettingsColorDot(it.label, it.rgb.monitorColor()) },
    highlightColors = listOf(MonitorZebraPaint.WHITE, MonitorZebraPaint.RED, MonitorZebraPaint.CYAN).map {
        MonitorSettingsColorDot(it.label, it.rgb.monitorColor())
    },
    midtoneColors = listOf(MonitorZebraPaint.AMBER, MonitorZebraPaint.GREEN, MonitorZebraPaint.CYAN).map {
        MonitorSettingsColorDot(it.label, it.rgb.monitorColor())
    },
)

private fun Triple<Double, Double, Double>.monitorColor(): Color = Color(first.toFloat(), second.toFloat(), third.toFloat())
