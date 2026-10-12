package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorReferenceValues

/** Only source-calibrated signal menus vary; the shared inspector owns navigation and lifetime. */
public data class MonitorOperatorSignalOptions(
    public val falseColor: (@Composable () -> Unit)? = null,
    public val zebra: (@Composable () -> Unit)? = null,
    public val reference: MonitorFalseColorReferenceValues? = null,
    public val referenceAvailable: Boolean? = null,
    public val level: (@Composable () -> Unit)? = null,
    public val instantReview: (@Composable () -> Unit)? = null,
) {
    /**
     * Whether the source supplies a menu for [tool]; such a tool has options whatever its stock flag says.
     * No tool is the source's own palette item, whose menu is [instantReview] (Swift `.instantReview`).
     */
    public fun offers(tool: MonitorAssistTool?): Boolean = when (tool) {
        null -> instantReview != null
        MonitorAssistTool.FALSE -> falseColor != null
        MonitorAssistTool.ZEBRA -> zebra != null
        MonitorAssistTool.LEVEL -> level != null
        else -> false
    }

    /** The toolless palette item that opens [instantReview] in the inspector, when the source supplies it. */
    public fun reviewItem(palette: List<MonitorOperatorPaletteItem>): MonitorOperatorPaletteItem? =
        if (offers(null)) palette.firstOrNull { it.tool == null } else null
}
