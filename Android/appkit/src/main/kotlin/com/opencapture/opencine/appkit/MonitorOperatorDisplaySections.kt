package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.settings.MonitorDisplaySectionStyle
import com.opencapture.monitorui.settings.MonitorDisplaySections
import com.opencapture.monitorui.settings.MonitorDisplayToggle
import com.opencapture.monitorui.settings.MonitorDisplaySection as DisplaySection

/** Common display composition over existing, app-namespaced preference values, one section per
 * DISP mode the source offers. */
@Composable
public fun MonitorOperatorDisplaySections(
    modes: List<MonitorDisplayMode>,
    chrome: (MonitorDisplayMode) -> MonitorDisplayChrome,
    assist: MonitorAssistState,
    onChange: (MonitorDisplayMode, MonitorDisplayChrome) -> Unit,
    available: Set<MonitorDisplaySection> = MonitorDisplaySection.entries.toSet(),
    pinnable: Set<MonitorAssistTool> = MonitorAssistTool.cleanPinCases.toSet(),
    onPinsChanged: ((Set<MonitorAssistTool>) -> Unit)? = null,
    edit: ((MonitorDisplayMode) -> Unit)? = null,
    feedback: () -> Unit = {},
): Unit {
    val order = listOf(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.TOOL_BAR,
        MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.BATTERIES,
        MonitorDisplaySection.REC_READOUT, MonitorDisplaySection.TIMECODE, MonitorDisplaySection.FORMAT,
        MonitorDisplaySection.CODEC, MonitorDisplaySection.COLOR, MonitorDisplaySection.STORAGE, MonitorDisplaySection.FPS,
        MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_SETTINGS,
        MonitorDisplaySection.ZOOM_CHIP, MonitorDisplaySection.GIMBAL_STICK, MonitorDisplaySection.FOCUS_BOX)
    MonitorDisplaySections(modes.map { mode ->
        val value = chrome(mode)
        DisplaySection(id = mode.name, title = mode.settingsTitle, caption = mode.settingsCaption,
            reset = {
                feedback()
                onChange(mode, MonitorDisplayChrome.defaults(mode))
            }, editHint = "Arrange the bars, readouts and tools directly on the monitor.",
            edit = edit?.let { action -> { action(mode) } },
            unavailableEditHelp = "Connect to arrange this on the monitor.",
            visibility = order.filter { it in available && MonitorDisplayChrome.isConfigurable(it, mode) }.map { section ->
                MonitorDisplayToggle(id = mode.name + "." + section.name,
                    title = if (section == MonitorDisplaySection.FOCUS_BOX) "AF Box" else section.title,
                    isOn = value.isVisible(section), help = displayHelp(section)) {
                    feedback(); onChange(mode, value.toggling(section))
                }
            }, pinsTitle = "View assists that stay on in clean view",
            pins = if (mode != MonitorDisplayMode.CLEAN) emptyList() else MonitorAssistTool.cleanPinCases.filter { it in pinnable }.map { tool ->
                MonitorDisplayToggle(id = "clean.pin." + tool.name, title = tool.title,
                    isOn = tool in assist.pinned, accessibilityLabel = "Keep ${tool.title} in clean view") {
                    feedback()
                    if (onPinsChanged == null) assist.togglePin(tool)
                    else {
                        val next = if (tool in assist.pinned) assist.pinned - tool else assist.pinned + tool
                        assist.pinned = next; onPinsChanged(next)
                    }
                }
            }, style = MonitorDisplaySectionStyle.CONTROLS)
    })
}

private fun displayHelp(section: MonitorDisplaySection): String = when (section) {
    MonitorDisplaySection.STATUS_BAR -> "REC, timecode, format, and FPS along the top of the feed."
    MonitorDisplaySection.TOOL_BAR -> "The view-assist strip under the feed."
    MonitorDisplaySection.CAMERA_VALUES -> "ISO, shutter, white balance, and the rest of the capture strip."
    MonitorDisplaySection.LOCK_BUTTON -> "Side-rail lock. Remounts while the interface is locked."
    MonitorDisplaySection.BATTERIES -> "Phone and camera battery cluster."
    MonitorDisplaySection.REC_READOUT -> "Standby / recording chip on the status bar."
    MonitorDisplaySection.TIMECODE -> "Running timecode on the status bar."
    MonitorDisplaySection.FORMAT -> "Recording resolution and frame rate."
    MonitorDisplaySection.CODEC -> "Recording codec chip on the status bar."
    MonitorDisplaySection.COLOR -> "Color mode chip on the status bar."
    MonitorDisplaySection.STORAGE -> "Remaining media time on the status bar."
    MonitorDisplaySection.FPS -> "Live-view rate and link bars."
    MonitorDisplaySection.RAIL_RECORD -> "Rail record lamp. Stays available while rolling."
    MonitorDisplaySection.RAIL_MEDIA -> "Rail media button."
    MonitorDisplaySection.RAIL_SETTINGS -> "Rail settings button. Always an escape hatch."
    MonitorDisplaySection.ZOOM_CHIP -> "Live zoom readout on the feed."
    MonitorDisplaySection.GIMBAL_STICK -> "On-screen gimbal stick."
    MonitorDisplaySection.FOCUS_BOX -> "Focus and face-tracking brackets on the feed."
}
