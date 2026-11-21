package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorValueDrum
import com.opencapture.monitorui.MonitorZoomCaption
import com.opencapture.monitorui.MonitorZoomClearance
import com.opencapture.monitorui.MonitorZoomPresetControls
import com.opencapture.monitorui.MonitorZoomPresets
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.appkit.MonitorOperatorCaptureDrawer
import com.opencapture.opencine.appkit.monitorOperatorCapturePlacement

/**
 * Existing session gestures adapt to the shared zoom panel (presets, ramp key and a smooth ruler
 * with 0.1x ticks). With [layout] the ramp key opens the camera value popup at its own place.
 */
@Composable
fun MonitorZoomDial(initial: Double, maximum: Double, onChange: (Double) -> Unit, onDismiss: () -> Unit,
    opticalStops: List<Double> = listOf(1.0), presets: MonitorZoomPresetControls? = null,
    driven: Double? = null, clearance: MonitorZoomClearance = MonitorZoomClearance(),
    layout: LiveMonitorLayout? = null) {
    val haptics = LocalOperatorHaptics.current
    val field = layout?.field
    com.opencapture.monitorui.MonitorZoomRuler(initial, maximum, onChange, onDismiss,
        opticalStops = opticalStops,
        caption = { factor -> MonitorZoomCaption.label(factor, opticalStops) },
        clearance = clearance,
        onStep = { haptics.selection() }, presets = presets, driven = driven, label = LiveZoom::label,
        rampPanel = if (presets != null && layout != null && field != null) {
            { close -> MonitorZoomRampPanel(presets, layout, field, close) }
        } else null)
}

/** The ramp choices on a drum in the camera value popup, placed as `MonitorOperatorCapturePopup` places it. */
@Composable
private fun MonitorZoomRampPanel(presets: MonitorZoomPresetControls, layout: LiveMonitorLayout,
    field: MonitorFieldLayout, close: () -> Unit) {
    val haptics = LocalOperatorHaptics.current
    val density = LocalDensity.current
    var height by remember { mutableFloatStateOf(86f) }
    val place = monitorOperatorCapturePlacement(field, top = false, panelHeight = height,
        safeLeading = layout.safeLeading, safeTrailing = layout.safeTrailing,
        safeTop = layout.safeTop, safeBottom = layout.safeBottom)
    val options = MonitorZoomPresets.RAMP_CHOICES.map(MonitorZoomPresets::rampLabel)
    val current = MonitorZoomPresets.rampLabel(presets.presets.rampSeconds)
    Box(Modifier.offset(place.x.dp, place.y.dp).width(place.width.dp)
        .onGloballyPositioned { height = with(density) { it.size.height.toDp().value } }
        .testTag("monitor.zoom.ramp.panel")) {
        MonitorOperatorCaptureDrawer("Preset ramp", current, place.maxHeight, top = false,
            portrait = field.portrait, close = close) {
            MonitorValueDrum(options, current, onDetent = { haptics.selection() }) { label ->
                options.indexOf(label).takeIf { it >= 0 }?.let { presets.onRamp(MonitorZoomPresets.RAMP_CHOICES[it]) }
            }
        }
    }
}
