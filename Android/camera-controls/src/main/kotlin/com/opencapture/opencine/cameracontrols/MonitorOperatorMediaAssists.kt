package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorPlaybackInspectorContext
import com.opencapture.monitorui.MonitorPlaybackToolsContext
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorToolUsagePreferences
import com.opencapture.opencine.media.MonitorTransfer

/**
 * The view assist bar, option inspector and tool rules the media pages share: clip playback and the
 * still viewer show the one bar, open the one inspector, and read the playback-visible tools.
 */
internal class MonitorOperatorMediaAssists(
    val assist: MonitorAssistState,
    val assists: MonitorOperatorAssistSource?,
    val usageStore: MonitorToolUsagePreferences?,
    /** The tools this page offers; null offers the playback set. */
    val supportedTools: Set<MonitorAssistTool>?,
    val transfer: MonitorTransfer?,
    val signalOptions: MonitorOperatorSignalOptions,
) {
    fun hasOptions(tool: MonitorAssistTool): Boolean = tool.hasConfiguration && when (tool) {
        MonitorAssistTool.FALSE -> transfer != null || signalOptions.falseColor != null
        MonitorAssistTool.ZEBRA -> transfer != null || signalOptions.zebra != null
        else -> true
    }

    fun options(tool: MonitorAssistTool, frame: MonitorRect? = null) {
        if (supportedTools?.contains(tool) == false || !hasOptions(tool)) return
        if (frame != null) assist.longPressAnchor = frame
        assist.configureTool = tool
    }

    /** The playback page's assist bar, placed in the page's tools frame. */
    @Composable
    fun Bar(chrome: MonitorPlaybackToolsContext, showsAudio: Boolean, inspectorOpen: Boolean = false) {
        MonitorAssistCluster(usageStore, chrome.portrait, false, assist::isPlaybackVisible,
            { assist.togglePlayback(it) }, { options(it) },
            Modifier.offset(chrome.frame.x.dp, chrome.frame.y.dp).size(chrome.frame.width.dp, chrome.frame.height.dp),
            requestExpand = chrome.expanded, onExpansionHandled = chrome.onExpansionHandled,
            showsAudio = showsAudio, inspectorOpen = inspectorOpen, playback = true, availableTools = supportedTools, hasOptions = ::hasOptions)
    }

    /** The open tool's options in the playback page's inspector; [preview] overrides the source preview. */
    @Composable
    fun Inspector(chrome: MonitorPlaybackInspectorContext,
        preview: (@Composable (MonitorAssistTool) -> Unit)? = assists?.preview) {
        val tool = assist.configureTool?.takeIf { supportedTools?.contains(it) != false && hasOptions(it) } ?: return
        val image: (@Composable () -> Unit)? = preview?.let { renderer -> { renderer(tool) } }
        AssistInspectorFrame(tool, assist, chrome.width, chrome.height, chrome.leading, chrome.top, chrome.bottom,
            onDismiss = { assist.configureTool = null }, playback = true, safeTrailing = chrome.trailing,
            tabs = MonitorAssistTool.settingsCases.filter { supportedTools?.contains(it) != false && hasOptions(it) }) { maximum ->
            AssistOptionsPanel(tool, assist, { assist.configureTool = null }, assists?.host ?: MonitorDefaultAssistHost, assists?.lookPicker,
                maxHeightDp = maximum, transfer = transfer, embedded = true,
                playback = true, imagePreview = image, signalOptions = signalOptions,
                lookMenu = assists?.lookMenu)
        }
    }
}
