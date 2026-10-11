package com.opencapture.monitorui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsPercentSlider
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow

@Composable
fun <Mode> MonitorScopeTraceMenu(
    modes: List<Mode>, mode: Mode, onMode: (Mode) -> Unit, title: (Mode) -> String,
    brightness: Int, onBrightness: (Int) -> Unit, guides: MonitorScopeGuides,
    onGuides: (MonitorScopeGuides) -> Unit, supportsCalibratedReferences: Boolean = true,
) {
    MonitorOptionGroup {
        MonitorSettingsInlineRow("Mode", showTopDivider = false) {
            MonitorSettingsChoices(modes, mode, compact = false, accentSelection = true,
                title = title, onSelect = onMode)
        }
        MonitorSettingsInlineRow("Brightness", help = "Raise trace intensity in bright light.", stacked = true) {
            MonitorSettingsPercentSlider(brightness, 0..200, onBrightness)
        }
    }
    Spacer(Modifier.height(11.dp))
    if (!supportsCalibratedReferences) {
        Text("Encoded code percentage. Source calibration unavailable.", color = MonitorPalette.faint)
        return
    }
    Text("GUIDE LINES", modifier = Modifier.padding(start = 12.dp, bottom = 5.dp),
        style = MonitorTypography.text(7.5f, FontWeight.Medium).copy(letterSpacing = 1.sp), color = MonitorPalette.faint)
    MonitorOptionGroup {
        MonitorSettingsSwitchInlineRow("Safe clip", isOn = guides.clip, showTopDivider = false) {
            onGuides(guides.copy(clip = !guides.clip))
        }
        MonitorSettingsSwitchInlineRow("Safe crush", isOn = guides.crush) {
            onGuides(guides.copy(crush = !guides.crush))
        }
        MonitorSettingsSwitchInlineRow("Middle gray", isOn = guides.middle) {
            onGuides(guides.copy(middle = !guides.middle))
        }
    }
}

@Composable
fun MonitorVectorscopeMenu(zoom: MonitorVectorscopeZoom, onZoom: (MonitorVectorscopeZoom) -> Unit,
    brightness: Int, onBrightness: (Int) -> Unit) {
    MonitorSettingsInlineRow("Trace Zoom", help = "Magnifies only the chroma trace; the graticule stays at unity.",
        showTopDivider = false, stacked = true) {
        MonitorSettingsChoices(MonitorVectorscopeZoom.entries, zoom, accentSelection = true,
            title = { it.label }, onSelect = onZoom)
    }
    MonitorSettingsInlineRow("Brightness", help = "Raise trace intensity when the chroma plot is hard to read.", stacked = true) {
        MonitorSettingsPercentSlider(brightness, 0..200, onBrightness)
    }
}
