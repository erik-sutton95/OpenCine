package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import com.opencapture.monitorui.MonitorZoomTapStops
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue

/** A cycle tap's pending target, shown over the native report until the camera answers. */
public val MonitorControlModel.State.pendingZoom: Double?
    get() = (pending[SettingKey.ZOOM] as? SettingValue.Zoom)?.ratio

/**
 * A zoom cycle tap edits and commits [SettingKey.ZOOM] through the common control, so a revoked
 * authority, a stale epoch or an undescribed zoom sends nothing. `false` when refused.
 */
public fun MonitorControlModel.commitZoomCycle(ratio: Double): Boolean {
    val editor = edit(SettingKey.ZOOM) ?: return false
    return commit(SettingValue.Zoom(ratio), editor, "Zoom $ratio")
}

/**
 * Native zoom facts with the common cycle: taps go through [commitZoomCycle] from the pending
 * target or [nativeFrom]. The native pinch stays the continuous path; its first sample retires a
 * pending tap.
 */
@Composable
public fun MonitorControlModel.operatorZoom(factor: Double, dialFactor: Double, pinching: Boolean, dimmed: Boolean,
    maximum: Double, opticalStops: List<Double>, tapStops: MonitorZoomTapStops, nativeFrom: () -> Double,
    pinch: (Double) -> Unit, endPinch: () -> Unit): MonitorOperatorZoomPresentation =
    MonitorOperatorZoomPresentation(state.collectAsState().value.pendingZoom ?: factor, dialFactor, pinching, dimmed,
        maximum, opticalStops, tapStops, { state.value.pendingZoom ?: nativeFrom() }, { commitZoomCycle(it) },
        { if (state.value.pendingZoom != null) cancelEdit(SettingKey.ZOOM); pinch(it) }, endPinch)
