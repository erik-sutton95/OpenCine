package com.opencapture.opencine.motion

import kotlin.math.abs

/**
 * Preparation, timed zoom targets and immediate cancellation share one transport owner.
 * The integration encodes each command for its camera. Twin of Swift `OpenCineMotion`
 * `NativeProgramZoomCommand`.
 */
public sealed interface NativeProgramZoomCommand {
    public data class Position(public val factor: Double) : NativeProgramZoomCommand
    public data class Track(public val factor: Double) : NativeProgramZoomCommand
    public data object Stop : NativeProgramZoomCommand
}

public data class NativeProgramZoomDemand(public val command: NativeProgramZoomCommand, public val destination: Double,
    public val failureReason: String? = null, public val nextChange: Double = Double.POSITIVE_INFINITY)

/** Linear zoom-factor targets throughout the full leg (Motion Control's programmed zoom). */
public object NativeProgramZoom {
    public const val INTERVAL: Double = 0.02

    public fun demand(from: Double, to: Double, duration: Double, elapsed: Double): NativeProgramZoomDemand {
        if (!from.isFinite() || !to.isFinite() || !duration.isFinite() || !elapsed.isFinite() ||
            from < 1.0 || to < 1.0 || duration <= 0 || elapsed < 0) {
            return NativeProgramZoomDemand(NativeProgramZoomCommand.Stop, to, failureReason = "Invalid zoom movement")
        }
        if (abs(from - to) <= 1e-6) return NativeProgramZoomDemand(NativeProgramZoomCommand.Stop, to)
        val fraction = minOf(1.0, elapsed / duration)
        return NativeProgramZoomDemand(NativeProgramZoomCommand.Track(from + (to - from) * fraction), to,
            nextChange = if (elapsed < duration) duration - elapsed else Double.POSITIVE_INFINITY)
    }
}
