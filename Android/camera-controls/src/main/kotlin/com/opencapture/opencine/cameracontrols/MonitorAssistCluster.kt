package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorToolUsageState
import com.opencapture.opencine.appkit.MonitorToolUsagePreferences

/**
 * The app supplies its supported tool inventory and existing live/playback actions.
 *
 * [prefs] keeps the palette's tool usage. [inspectorOpen] hides the cluster so the palette Popup cannot cover inspector
 * controls (iOS collapses the palette while `configureTool` is set). Landscape
 * and portrait chrome should pass `assist.configureTool != null`.
 */
@Composable
fun MonitorAssistCluster(prefs: OperatorPreferenceStore, portrait: Boolean, locked: Boolean, isOn: (MonitorAssistTool) -> Boolean,
    onToggle: (MonitorAssistTool) -> Unit, onLongPress: (MonitorAssistTool) -> Unit,
    modifier: Modifier = Modifier, requestExpand: Boolean = false, onExpansionHandled: () -> Unit = {},
    showsAudio: Boolean = true, inspectorOpen: Boolean = false, playback: Boolean = false,
    onBoundsChanged: (MonitorRect?) -> Unit = {}, collapseRevision: Long = 0L,
    availableTools: Set<MonitorAssistTool>? = null,
    hasOptions: (MonitorAssistTool) -> Boolean = { it.hasConfiguration }) {
    val context = LocalContext.current
    val usageStore = remember(prefs, context) { prefs.assistToolUsagePreferences(context) }
    MonitorAssistCluster(usageStore, portrait, locked, isOn, onToggle, onLongPress,
        modifier, requestExpand, onExpansionHandled, showsAudio, inspectorOpen, playback,
        onBoundsChanged, collapseRevision, availableTools, hasOptions)
}

/** Borrows an existing usage store without constructing a second namespace. */
@Composable
fun MonitorAssistCluster(usageStore: MonitorToolUsagePreferences?, portrait: Boolean, locked: Boolean, isOn: (MonitorAssistTool) -> Boolean,
    onToggle: (MonitorAssistTool) -> Unit, onLongPress: (MonitorAssistTool) -> Unit,
    modifier: Modifier = Modifier, requestExpand: Boolean = false, onExpansionHandled: () -> Unit = {},
    showsAudio: Boolean = true, inspectorOpen: Boolean = false, playback: Boolean = false,
    onBoundsChanged: (MonitorRect?) -> Unit = {}, collapseRevision: Long = 0L,
    availableTools: Set<MonitorAssistTool>? = null,
    hasOptions: (MonitorAssistTool) -> Boolean = { it.hasConfiguration }) {
    if (inspectorOpen) return
    val density = LocalDensity.current.density
    val origin = LocalLiveCanvasOrigin.current
    var usage by remember(usageStore) { mutableStateOf(usageStore?.value ?: MonitorToolUsageState()) }
    val catalog = if (playback) MonitorAssistTool.playbackToolbarCases else MonitorAssistTool.settingsCases
    val tools = catalog.filter { (showsAudio || it != MonitorAssistTool.AUDIO) && (availableTools?.contains(it) != false) }
    com.opencapture.monitorui.MonitorAssistPalette(
        tools = tools, usageSeed = ASSIST_USAGE_SEED,
        portrait = portrait, locked = locked, isOn = isOn, title = { it.title }, label = { it.chipLabel },
        hasOptions = hasOptions, onToggle = onToggle, onOptions = onLongPress,
        glyph = { tool, tint, iconModifier -> AssistToolGlyph(tool, tint, iconModifier, evFontSize = 17f) },
        chevron = { expanded, vertical ->
            val icon = if (vertical) { if (expanded) MonitorIcon.CHEVRON_DOWN else MonitorIcon.CHEVRON_UP }
                else { if (expanded) MonitorIcon.CHEVRON_LEFT else MonitorIcon.CHEVRON_RIGHT }
            MonitorIcon(icon, null, Modifier.size(14.dp), LiveDesign.muted)
        }, modifier = modifier, requestExpand = requestExpand, onExpansionHandled = onExpansionHandled,
        collapseRevision = collapseRevision,
        idOf = { it.name }, usage = usage,
        onUsageChange = { next: MonitorToolUsageState ->
            usage = next
            usageStore?.value = next
        },
        onBoundsInRootChanged = { bounds ->
            onBoundsChanged(bounds?.let {
                MonitorRect((it.left - origin.x) / density, (it.top - origin.y) / density,
                    it.width / density, it.height / density)
            })
        },
    )
}

/** Approved palette defaults; ties follow the supported catalog's stable order. */
private val ASSIST_USAGE_SEED = mapOf(
    "PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4,
    "LUT" to 4, "WAVE" to 3, "GUIDES" to 2,
    "GRID" to 2, "HISTO" to 2, "VECTOR" to 1,
    "PARADE" to 1, "LIGHTS" to 1, "CROSS" to 1,
    "MIRROR" to 1, "AUDIO" to 1,
)
