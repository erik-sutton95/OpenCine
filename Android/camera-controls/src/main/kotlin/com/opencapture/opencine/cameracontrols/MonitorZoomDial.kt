package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorZoomCaption
import com.opencapture.monitorui.MonitorZoomClearance
import com.opencapture.opencine.appkit.LocalOperatorHaptics

/** Existing session gestures adapt to the shared vertical zoom ruler (0.1x steps). */
@Composable
fun MonitorZoomDial(initial: Double, maximum: Double, onChange: (Double) -> Unit, onDismiss: () -> Unit,
    opticalStops: List<Double> = listOf(1.0), presets: com.opencapture.monitorui.MonitorZoomPresetControls? = null,
    driven: Double? = null, clearance: MonitorZoomClearance = MonitorZoomClearance()) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorZoomRuler(initial, maximum, onChange, onDismiss,
        opticalStops = opticalStops,
        caption = { factor -> MonitorZoomCaption.label(factor, opticalStops) },
        clearance = clearance,
        onStep = { haptics.selection() }, presets = presets, driven = driven, label = LiveZoom::label)
}
