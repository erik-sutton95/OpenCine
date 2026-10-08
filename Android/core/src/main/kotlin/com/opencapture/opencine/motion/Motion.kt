// Kotlin twin of the Swift OpenCineMotion seam: the declared capabilities, reachable targets,
// pose feedback validity, the service interface and its layout projection. A package of :core
// rather than its own module; nothing in com.opencapture.opencine.core imports it. Programs,
// curves and the waypoint overlay are in GimbalProgram.kt. The Kotlin move engine stays with the
// integration that runs it; head-look math has no Kotlin twin yet.
package com.opencapture.opencine.motion

import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.Freshness
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationValidity
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.SupportStatus
import kotlinx.coroutines.flow.StateFlow
import kotlin.time.Duration

/** An axis a motion service can drive. */
public enum class MotionAxis { PAN, TILT, ZOOM }

/** What the pan and tilt angles are measured against. */
public enum class MotionReferenceFrame {
    /** Relative to the handle or body the gimbal is mounted on. */
    HANDLE,

    /**
     * Relative to gravity and a fixed heading. Only a camera that reports and holds a world
     * reference itself declares this; an IMU sample on the phone alone does not establish it.
     */
    WORLD,
}

/**
 * Position bounds in degrees, in the service's reference frame. Pan is one arc narrower than a
 * full turn, unwrapped so it never crosses the unreachable gap.
 */
public data class MotionBounds(
    public val pan: ClosedFloatingPointRange<Double>,
    public val tilt: ClosedFloatingPointRange<Double>,
) {
    init {
        require(pan.endInclusive - pan.start < 360) { "pan must leave a gap" }
    }

    public operator fun contains(pose: GimbalWaypoint): Boolean =
        pose.yawDeg.isFinite() && pose.pitchDeg.isFinite() && pose.yawDeg in pan && pose.pitchDeg in tilt

    /** The middle of the unreachable pan gap: a raw angle below it belongs at `raw + 360`. */
    public val gapMidDeg: Double get() = (pan.endInclusive + pan.start - 360.0) / 2
}

/**
 * One gimbal pose in the service's reference frame: pan (yaw) and tilt (pitch) in degrees plus
 * the zoom factor, never below 1. [nativePitchDeg] is the camera's own absolute pitch when it
 * reports one apart from the operator-facing tilt.
 */
public class GimbalWaypoint(
    public val yawDeg: Double,
    public val pitchDeg: Double,
    zoom: Double,
    public val nativePitchDeg: Double? = null,
) {
    // Same as Swift `max(1, zoom)`, which also turns NaN into 1.
    public val zoom: Double = if (zoom >= 1.0) zoom else 1.0

    override fun equals(other: Any?): Boolean = other is GimbalWaypoint && yawDeg == other.yawDeg &&
        pitchDeg == other.pitchDeg && zoom == other.zoom && nativePitchDeg == other.nativePitchDeg

    override fun hashCode(): Int = listOf(yawDeg, pitchDeg, zoom, nativePitchDeg).hashCode()

    override fun toString(): String = "GimbalWaypoint(yaw=$yawDeg, pitch=$pitchDeg, zoom=$zoom, nativePitch=$nativePitchDeg)"

    public fun copy(
        yawDeg: Double = this.yawDeg,
        pitchDeg: Double = this.pitchDeg,
        zoom: Double = this.zoom,
        nativePitchDeg: Double? = this.nativePitchDeg,
    ): GimbalWaypoint = GimbalWaypoint(yawDeg, pitchDeg, zoom, nativePitchDeg)

    public fun clamped(bounds: MotionBounds): GimbalWaypoint = GimbalWaypoint(
        yawDeg.coerceIn(bounds.pan.start, bounds.pan.endInclusive),
        pitchDeg.coerceIn(bounds.tilt.start, bounds.tilt.endInclusive),
        zoom,
        nativePitchDeg,
    )

    public companion object {
        /**
         * Raw yaw (plus or minus 180) onto the reachable pan arc so A to B is plain subtraction
         * and a straight line cannot cross the gap. Measurements in the gap are preserved.
         */
        public fun unwrapYaw(rawDeg: Double, bounds: MotionBounds): Double =
            if (rawDeg < bounds.gapMidDeg) rawDeg + 360.0 else rawDeg
    }
}

/**
 * What a camera's motion service declares. Shared motion reads these instead of raw wire units;
 * the integration keeps its wire encoding, coordinate transforms and command pacing.
 */
public data class MotionCapabilities(
    public val axes: Set<MotionAxis>,
    public val frame: MotionReferenceFrame,
    public val bounds: MotionBounds,
    /** Fastest pan or tilt rate shared motion may plan; `null` when the camera paces moves itself. */
    public val maxRateDegPerSec: Double?,
    /** A pose reading older than this is not feedback. */
    public val feedbackMaxAge: Duration,
    /** A target is reached once the angular distance to it is at most this many degrees. */
    public val arrivalToleranceDeg: Double,
    /** Whether the camera reports its own pose ([MotionService.poses]), which head tracking needs. */
    public val pose: SupportStatus = SupportStatus.UNKNOWN,
) {
    /** The only way to make a [MotionTarget]: `null` outside the declared bounds. */
    public fun target(pose: GimbalWaypoint): MotionTarget? {
        if (!axes.containsAll(listOf(MotionAxis.PAN, MotionAxis.TILT)) || !pose.zoom.isFinite()) return null
        if (pose !in bounds || pose.nativePitchDeg?.isFinite() == false) return null
        return MotionTarget(pose)
    }

    /** Swift admits: every point is reachable, zoom needs its axis, and declared rates bound each leg. */
    public fun admits(program: GimbalProgram): Boolean {
        val a = program.a ?: return false
        val b = program.b ?: return false
        if (listOfNotNull(a, b, program.c).any { target(it) == null } ||
            (program.changesZoom && MotionAxis.ZOOM !in axes)) return false
        val rate = maxRateDegPerSec ?: return true
        if (!(GimbalPath.angularDistance(a, b) <= rate * program.durationAB)) return false
        return program.c?.let { GimbalPath.angularDistance(b, it) <= rate * program.durationBC } ?: true
    }

    /**
     * The pose when the reading is usable feedback: known, valid, reported by the camera (an
     * image estimate never stands in) and no older than [feedbackMaxAge].
     */
    public fun feedback(reading: ObservedValue<GimbalWaypoint>, now: MonotonicInstant): GimbalWaypoint? {
        val reported = reading.origin == ObservationOrigin.CAMERA_REPORTED ||
            reading.origin == ObservationOrigin.PROTOCOL_DERIVED
        val fresh = reading.freshness(now, feedbackMaxAge) == Freshness.FRESH
        return if (reading.validity == ObservationValidity.Valid && reported && fresh) reading.value else null
    }
}

/** A pose a motion service declared reachable. Made only by [MotionCapabilities.target]. */
public class MotionTarget internal constructor(public val pose: GimbalWaypoint) {
    override fun equals(other: Any?): Boolean = other is MotionTarget && pose == other.pose

    override fun hashCode(): Int = pose.hashCode()
}

/**
 * A camera's motion service: what today's gimbal monitors command and read. The integration
 * implements it only for a camera that moves, keeps wire units, pacing and coordinate transforms,
 * and answers each command with whether the camera accepted it. A programmed move has no command
 * of its own: the caller runs it as timed [move] targets.
 */
public interface MotionService {
    public val capabilities: MotionCapabilities

    /** Rate stick, each axis -1..1 of the camera's full stick speed. Zero on both axes releases. */
    public suspend fun stick(pan: Double, tilt: Double): Boolean

    /** The camera's own recenter. */
    public suspend fun recenter(): Boolean

    /**
     * Aims at a reachable pose, arriving after [duration] (`null`: as fast as the camera moves).
     * A newer request replaces an unfinished one.
     */
    public suspend fun move(target: MotionTarget, duration: Duration?): Boolean

    /** Ends a stick or timed move where the head is. */
    public suspend fun stop(): Boolean

    /**
     * The latest pose reading, [ObservedValue.unknown] until the camera reports;
     * [MotionCapabilities.feedback] says which may steer.
     */
    public val poses: StateFlow<ObservedValue<GimbalWaypoint>>
}

/**
 * The Core projection plus the motion sections: `gimbal` when the service drives pan and tilt,
 * `headTracking` when it also reports the camera's pose (unknown pose support keeps [base]).
 * [motion] `null` means the camera has no motion service; while that is not known yet, use the
 * Core constructor, which keeps both from [base]. Swift: the `motion:` initializer overload.
 */
public fun MonitorLayoutCapabilities(
    capabilities: CapabilitySnapshot,
    motion: MotionCapabilities?,
    base: MonitorLayoutCapabilities = MonitorLayoutCapabilities(),
): MonitorLayoutCapabilities {
    val gimbal = motion != null && motion.axes.containsAll(listOf(MotionAxis.PAN, MotionAxis.TILT))
    val headTracking = when (motion?.pose) {
        SupportStatus.SUPPORTED -> gimbal
        SupportStatus.UNKNOWN -> gimbal && base.headTracking
        SupportStatus.UNSUPPORTED, null -> false
    }
    return MonitorLayoutCapabilities(capabilities, base).copy(gimbal = gimbal, headTracking = headTracking)
}
