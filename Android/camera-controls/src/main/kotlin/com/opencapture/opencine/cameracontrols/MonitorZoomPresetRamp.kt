package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.motion.NativeProgramZoom
import com.opencapture.opencine.motion.NativeProgramZoomCommand
import com.opencapture.opencine.vocabulary.CamFov

/**
 * One preset tap: the zoom to ask for over time, sampled from Motion Control's linear zoom ramp
 * ([NativeProgramZoom]). The session's continuous zoom path sends each sample, at the gamepad
 * zoom pump's cadence. Twin of Swift `MonitorZoomPresetRamp`.
 */
data class MonitorZoomPresetRamp(val from: Double, val to: Double, val duration: Double) {
    fun factor(elapsed: Double): Double {
        if (!(duration > 0.0)) return to
        val command = NativeProgramZoom.demand(from, to, duration, maxOf(0.0, elapsed)).command
        return (command as? NativeProgramZoomCommand.Track)?.factor ?: to
    }

    fun isFinished(elapsed: Double): Boolean = !(duration > 0.0) || !(elapsed < duration)

    companion object {
        const val INTERVAL_MS: Long = CamFov.ZOOM_STEP_INTERVAL_MS
    }
}
