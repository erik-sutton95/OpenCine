package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import kotlin.math.max
import kotlin.math.min

/** Complete common screen over deployed chrome sections and observed camera descriptors. */
@Composable
public fun <K, S, M> MonitorOperatorDescriptorLiveSurface(
    control: MonitorControlModel, identity: MonitorOperatorLiveIdentity,
    current: (MonitorOperatorLiveIdentity) -> Boolean, layout: MonitorFieldLayout, viewport: MonitorRect,
    sections: MonitorOperatorLiveSections<S>, mounted: Set<S>, host: ChromeEditHost<S, M>, editing: M?,
    locked: Boolean, setLocked: (Boolean) -> Unit, covered: Boolean, clean: Boolean, command: Boolean,
    readOnly: Boolean, recovering: Boolean,
    status: MonitorOperatorLiveStatus<K, S>, power: List<MonitorOperatorPowerReading>,
    readouts: List<MonitorOperatorLiveReadout<K, S>>, panel: MonitorOperatorCameraPanel<K>?,
    open: (K) -> Unit, dismiss: () -> Unit, retireReadout: () -> Unit,
    settings: () -> Unit, media: () -> Unit, cycleDisplay: () -> Unit, displayIndex: Int?, displayCount: Int,
    photo: Boolean, confirmRecord: Boolean, recordEnabled: Boolean,
    onRecordConfirming: (Boolean) -> Unit = {},
    assist: MonitorAssistState, assists: MonitorOperatorAssistSource,
    palette: List<MonitorOperatorPaletteItem>, usage: MonitorToolUsageState,
    setUsage: (MonitorToolUsageState) -> Unit, usageSeed: Map<String, Int>,
    renderedTools: Set<MonitorAssistTool>, fittedScopes: List<MonitorAssistTool>, scopeZone: MonitorRect?,
    signalOptions: MonitorOperatorSignalOptions = MonitorOperatorSignalOptions(),
    audioChannels: Pair<AudioMeterReading, AudioMeterReading>? = null,
    reference: MonitorFalseColorReferenceValues? = null,
    aspect: MonitorOperatorAspectControl? = null, resetFocus: MonitorOperatorFocusReset? = null,
    comparison: MonitorOperatorLookComparison? = null, cameraViews: MonitorOperatorBodyViews = MonitorOperatorBodyViews(),
    captureColumns: Int? = null, modifier: Modifier = Modifier, onCaptureFrame: (MonitorRect) -> Unit = {},
    chromeBoxes: MutableMap<S, MonitorRect>? = null,
    resumed: Boolean = true, retainsPanel: Boolean = true,
    nativeFraming: Boolean = false, floatingBounds: MonitorRect? = null,
    floatingPlacement: MonitorRect? = null,
    audio: MonitorOperatorLiveAudio? = null,
    displayTitle: String? = null,
    onPanelFrameChanged: ((MonitorAssistTool, MonitorRect?) -> Unit)? = null,
    picture: @Composable BoxScope.() -> Unit,
    cameraPanel: @Composable (K, MonitorRect, Boolean) -> Unit,
    photoRelease: (@Composable (Boolean, Modifier) -> Unit)? = null,
): Unit {
    val inputs = MonitorOperatorCaptureInputs<K, S, Nothing>(readouts, panel,
        fields = (status.format + listOfNotNull(status.portraitFormat, status.color, status.mode))
            .mapNotNull { value -> value.field?.let { value.id to it } }.toMap(),
        columns = captureColumns, open = open, dismiss = dismiss, isTop = { key ->
            panel?.takeIf { it.key == key }?.top ?: (status.format + listOfNotNull(status.portraitFormat, status.color, status.mode)).any { it.id == key }
        })
    MonitorOperatorLiveBody(control, identity, current, layout, viewport, sections, mounted, host, editing,
        locked, setLocked, covered, clean, command, readOnly, recovering, status, power, inputs, retireReadout,
        settings, media, cycleDisplay, displayIndex, displayCount, photo, confirmRecord, recordEnabled,
        onRecordConfirming, assist, assists, palette, usage, setUsage, usageSeed, renderedTools, fittedScopes, scopeZone,
        signalOptions, audioChannels, reference, aspect, resetFocus, comparison, cameraViews,
        modifier, onCaptureFrame, chromeBoxes, resumed, retainsPanel, nativeFraming, floatingBounds, floatingPlacement,
        audio, displayTitle, onPanelFrameChanged, showsReference = reference != null,
        picture = picture, cameraPanel = { key, frame, top, _ -> cameraPanel(key, frame, top) }, photoRelease = photoRelease)
}

/** Deployed bottom-anchored placement, independent of camera catalogue or raw command IDs. */
public fun monitorOperatorPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout, isPortrait: Boolean,
    measuredCaptureBar: MonitorRect? = null): MonitorRect {
    val outerMargin = if (isPortrait) 12f else 8f
    val topLimit = if (isPortrait) max(viewport.y + outerMargin, layout.status.maxY + 8f) else viewport.y + outerMargin
    val zoneAnchor = layout.values
    val measuredBar = measuredCaptureBar?.takeIf { !isPortrait && it.width > 1f && it.height > 1f }
    val anchorFrame = measuredBar ?: zoneAnchor
    val landscapeStripTop = measuredBar?.y ?: min(layout.values.y, layout.assists.y)
    val bottomLimit = if (isPortrait) zoneAnchor.y - 10f else landscapeStripTop - 10f
    val height = min(if (isPortrait) 320f else 360f, max(0f, bottomLimit - topLimit))
    val width = if (isPortrait) max(0f, viewport.width - outerMargin * 2f) else min(420f, max(0f, anchorFrame.width))
    val rawX = if (isPortrait) viewport.x + outerMargin else anchorFrame.midX - width / 2f
    val minX = viewport.x + outerMargin
    val maxX = max(minX, viewport.maxX - width - outerMargin)
    return MonitorRect(rawX.coerceIn(minX, maxX), max(topLimit, bottomLimit - height), width, height)
}
public fun monitorOperatorTopPickerFrame(viewport: MonitorRect, layout: MonitorFieldLayout,
    command: Boolean = false, preferredWidth: Float = 340f, maximumHeight: Float = 300f,
    anchor: MonitorRect? = null): MonitorRect {
    val margin = 8f
    val width = min(preferredWidth, max(0f, viewport.width - margin * 2))
    if (command) {
        val height = min(300f, max(120f, viewport.height * .55f))
        return MonitorRect(viewport.x + (viewport.width - width) / 2, viewport.y + (viewport.height - height) / 2, width, height)
    }
    val x = ((anchor?.midX ?: layout.status.midX) - width / 2).coerceIn(viewport.x + margin,
        max(viewport.x + margin, viewport.maxX - width - margin))
    val y = (anchor?.maxY ?: layout.status.maxY) + 8f
    return MonitorRect(x, y, width, min(maximumHeight, max(120f, viewport.maxY - y - margin)))
}
