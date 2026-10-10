package com.opencapture.monitorui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense

/** Finite common tool facts/actions. A section cannot swallow an arbitrary page Composable. */
sealed class MonitorAssistSettingsSection private constructor(
    val tool: MonitorAssistTool, internal val reset: (() -> Unit)?,
) {
    /** The card body alone, for an inspector that shows the same controls as Settings. */
    @Composable public abstract fun Menu(): Unit

    class FalseColor<Scale>(
        scales: List<Scale>, private val scale: Scale, private val onScale: (Scale) -> Unit,
        private val title: (Scale) -> String, private val readChoice: MonitorFalseColorReadChoice?,
        private val reference: MonitorFalseColorReferenceValues?, private val referenceEnabled: Boolean,
        private val onReferenceEnabled: (Boolean) -> Unit, private val scaleHelp: String,
        private val readHelp: String, private val referenceHelp: String, reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.FALSE, reset) {
        private val scales = scales.toList()
        @Composable override fun Menu(): Unit = MonitorFalseColorMenu(scales, scale, onScale, title,
            readChoice, reference, referenceEnabled, onReferenceEnabled, scaleHelp, readHelp, referenceHelp)
    }

    /** Direct number entry receives known calibration or a null editor on each supplied zone. */
    class ZebraNumbers<UnitValue>(
        units: List<UnitValue>, private val unit: UnitValue, private val title: (UnitValue) -> String,
        private val onUnit: (UnitValue) -> Unit, private val unitsHelp: String,
        private val highlightHelp: String, private val midtoneHelp: String,
        private val highlight: MonitorZebraNumberZone, private val midtone: MonitorZebraNumberZone,
        reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.ZEBRA, reset) {
        private val units = units.toList()
        @Composable override fun Menu(): Unit = MonitorZebraMenu(units, unit, title, onUnit, unitsHelp,
            highlightHelp, midtoneHelp, highlight, midtone)
    }

    /** The existing source-supplied slider policy remains available independently of direct entry. */
    class ZebraSliders<UnitValue>(
        units: List<UnitValue>, private val unit: UnitValue, private val title: (UnitValue) -> String,
        private val onUnit: (UnitValue) -> Unit, private val unitsHelp: String,
        private val highlightHelp: String, private val midtoneHelp: String,
        private val highlight: MonitorZebraZone, private val midtone: MonitorZebraZone,
        reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.ZEBRA, reset) {
        private val units = units.toList()
        @Composable override fun Menu(): Unit = MonitorZebraMenu(units, unit, title, onUnit, unitsHelp,
            highlightHelp, midtoneHelp, highlight, midtone)
    }

    class Trace<Mode> private constructor(
        tool: MonitorAssistTool, modes: List<Mode>, private val mode: Mode,
        private val onMode: (Mode) -> Unit, private val title: (Mode) -> String,
        private val brightness: Int, private val onBrightness: (Int) -> Unit,
        private val guides: MonitorScopeGuides, private val onGuides: (MonitorScopeGuides) -> Unit,
        reset: (() -> Unit)?,
    ) : MonitorAssistSettingsSection(tool, reset) {
        private val modes = modes.toList()
        @Composable override fun Menu(): Unit = MonitorScopeTraceMenu(modes, mode, onMode, title,
            brightness, onBrightness, guides, onGuides)

        companion object {
            fun <Mode> waveform(modes: List<Mode>, mode: Mode, onMode: (Mode) -> Unit,
                title: (Mode) -> String, brightness: Int, onBrightness: (Int) -> Unit,
                guides: MonitorScopeGuides, onGuides: (MonitorScopeGuides) -> Unit,
                reset: (() -> Unit)? = null): Trace<Mode> =
                Trace(MonitorAssistTool.WAVE, modes, mode, onMode, title, brightness, onBrightness, guides, onGuides, reset)

            fun <Mode> parade(modes: List<Mode>, mode: Mode, onMode: (Mode) -> Unit,
                title: (Mode) -> String, brightness: Int, onBrightness: (Int) -> Unit,
                guides: MonitorScopeGuides, onGuides: (MonitorScopeGuides) -> Unit,
                reset: (() -> Unit)? = null): Trace<Mode> =
                Trace(MonitorAssistTool.PARADE, modes, mode, onMode, title, brightness, onBrightness, guides, onGuides, reset)
        }
    }

    class Histogram(
        private val trafficLights: Boolean, private val onTrafficLights: () -> Unit,
        private val compensation: MonitorCrushClipCompensation,
        private val onCompensation: (MonitorCrushClipCompensation) -> Unit,
        private val trafficHelp: String, private val compensationHelp: String, reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.HISTO, reset) {
        @Composable override fun Menu(): Unit = MonitorHistogramMenu(trafficLights, onTrafficLights,
            compensation, onCompensation, trafficHelp, compensationHelp)
    }

    class Vectorscope(
        private val zoom: MonitorVectorscopeZoom, private val onZoom: (MonitorVectorscopeZoom) -> Unit,
        private val brightness: Int, private val onBrightness: (Int) -> Unit, reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.VECTOR, reset) {
        @Composable override fun Menu(): Unit = MonitorVectorscopeMenu(zoom, onZoom, brightness, onBrightness)
    }

    class Peaking(
        private val sensitivity: MonitorPeakingSense, private val color: MonitorPeakingColor,
        colors: List<MonitorSettingsColorDot>, private val sensitivityHelp: String,
        private val colorHelp: String, private val onSensitivity: (MonitorPeakingSense) -> Unit,
        private val onColor: (MonitorPeakingColor) -> Unit, reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.PEAK, reset) {
        private val colors = colors.toList()
        @Composable override fun Menu(): Unit = MonitorPeakingMenu(sensitivity, color, colors,
            sensitivityHelp, colorHelp, onSensitivity, onColor)
    }

    class TrafficLights(
        private val compensation: MonitorCrushClipCompensation,
        private val onCompensation: (MonitorCrushClipCompensation) -> Unit,
        private val help: String, reset: (() -> Unit)? = null,
    ) : MonitorAssistSettingsSection(MonitorAssistTool.LIGHTS, reset) {
        @Composable override fun Menu(): Unit = MonitorCrushClipMenu(compensation, onCompensation, help,
            showTopDivider = false)
    }

    /** An unavailable source explains absence without admitting writes or offering an inert reset. */
    class Unavailable(tool: MonitorAssistTool, private val message: String) : MonitorAssistSettingsSection(tool, null) {
        init { require(tool in assistSettingsToolOrder) }
        @Composable override fun Menu(): Unit = Text(message, style = MonitorTypography.text(12f),
            color = MonitorPalette.muted, modifier = Modifier.padding(vertical = 8.dp))
    }
}

private val assistSettingsToolOrder = listOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA,
    MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO, MonitorAssistTool.VECTOR,
    MonitorAssistTool.PEAK, MonitorAssistTool.LIGHTS)

/** Common settings owns card ordering, reset headers and responsive column placement. */
@Composable
fun MonitorViewAssistSettings(sections: List<MonitorAssistSettingsSection>): Unit {
    require(sections.map { it.tool }.distinct().size == sections.size)
    val ordered = assistSettingsToolOrder.mapNotNull { tool -> sections.firstOrNull { it.tool == tool } }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Keep full fraction targets and the card inset before admitting two columns.
        if (maxWidth < 584.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ordered.forEach { section -> key(section.tool) { AssistSettingsCard(section) } }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                for (column in 0..1) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        ordered.filterIndexed { index, _ -> index % 2 == column }.forEach { section ->
                            key(section.tool) { AssistSettingsCard(section) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AssistSettingsCard(section: MonitorAssistSettingsSection): Unit {
    val tag = when (section.tool) {
        MonitorAssistTool.FALSE -> "falseColor"
        MonitorAssistTool.ZEBRA -> "zebra"
        MonitorAssistTool.WAVE -> "waveform"
        MonitorAssistTool.PARADE -> "parade"
        MonitorAssistTool.HISTO -> "histogram"
        MonitorAssistTool.VECTOR -> "vectorscope"
        MonitorAssistTool.PEAK -> "peaking"
        MonitorAssistTool.LIGHTS -> "trafficLights"
        else -> error("No settings menu for ${section.tool}")
    }
    Column(Modifier.testTag("settings.assist.$tag")) {
        MonitorSettingsRowCard(title = if (section.tool == MonitorAssistTool.PARADE) "Parade" else section.tool.title,
            onReset = section.reset) { section.Menu() }
    }
}
