package com.opencapture.opencine.cameracontrols

import android.content.res.Configuration
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.settings.MonitorAssistSettingsSection
import com.opencapture.monitorui.settings.MonitorExposureMeterSettings
import com.opencapture.monitorui.settings.MonitorViewAssistSettings
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorTransfer

/** What a View Assist card's reset returns to (iOS `MonitorOperatorAssistResetPolicy`). */
public enum class MonitorOperatorAssistResetPolicy {
    /** Every option the card shows. */
    ALL_OPTIONS,

    /** The plot controls, and the traffic lights also return to their default size. */
    PLOT_CONTROLS;

    public fun reset(assist: MonitorAssistState, tool: MonitorAssistTool) {
        assist.resetSettings(tool)
        if (this == PLOT_CONTROLS && tool == MonitorAssistTool.LIGHTS) assist.setScale(tool, 1.0)
    }
}

/**
 * The View Assist tab's inputs (iOS `MonitorOperatorAssistSettings` plus the body's EV Meter row): the shared
 * state, the host's help copy and calibration, and the picture's transfer. A camera that owns its False Color
 * or Zebra conversion supplies that card as a typed [falseColor] or [zebra] section, reset included; every
 * other card is the common one. [changed] runs after each edit and reset (a haptic, or nothing).
 */
public class MonitorOperatorAssistSettingsSource(
    public val assist: MonitorAssistState,
    public val help: OperatorHelpCopy,
    public val host: AssistHost,
    public val transfer: MonitorTransfer,
    public val exposureHelp: String,
    available: Set<MonitorAssistTool> = MonitorOperatorAssistSettingsTools.toSet(),
    public val falseColor: MonitorAssistSettingsSection? = null,
    public val zebra: MonitorAssistSettingsSection? = null,
    public val resetPolicy: MonitorOperatorAssistResetPolicy = MonitorOperatorAssistResetPolicy.ALL_OPTIONS,
    public val changed: () -> Unit = {},
) {
    public val available: Set<MonitorAssistTool> = available.toSet()

    init {
        require(MonitorOperatorAssistSettingsTools.containsAll(this.available)) { "No View Assist card for $available" }
        require(falseColor == null || falseColor.tool == MonitorAssistTool.FALSE) { "falseColor must be a False Color section" }
        require(zebra == null || zebra.tool == MonitorAssistTool.ZEBRA) { "zebra must be a Zebra section" }
    }
}

/** The View Assist cards in settings order. */
public val MonitorOperatorAssistSettingsTools: List<MonitorAssistTool> = listOf(MonitorAssistTool.FALSE,
    MonitorAssistTool.ZEBRA, MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO,
    MonitorAssistTool.VECTOR, MonitorAssistTool.PEAK, MonitorAssistTool.LIGHTS)

/** The one View Assist recipe every app renders: main's cards, two columns in landscape, then EV Meter. */
@Composable
public fun MonitorOperatorAssistSettings(source: MonitorOperatorAssistSettingsSource) {
    val tools = MonitorOperatorAssistSettingsTools.filter { it in source.available }
    @Composable fun card(tool: MonitorAssistTool) = key(tool) {
        val signal = when (tool) {
            MonitorAssistTool.FALSE -> source.falseColor
            MonitorAssistTool.ZEBRA -> source.zebra
            else -> null
        }
        if (signal != null) MonitorViewAssistSettings(listOf(signal))
        else OperatorAssistCard(tool, source.assist, source.help, source.host, source.transfer, source.resetPolicy, source.changed)
    }
    if (LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) { tools.forEach { card(it) } }
    } else {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            for (column in 0..1) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    tools.filterIndexed { index, _ -> index % 2 == column }.forEach { card(it) }
                }
            }
        }
    }
    MonitorExposureMeterSettings(
        isOn = source.assist.evMeter,
        help = source.exposureHelp,
        onToggle = { source.assist.toggle(MonitorAssistTool.EV); source.changed() },
    )
}
