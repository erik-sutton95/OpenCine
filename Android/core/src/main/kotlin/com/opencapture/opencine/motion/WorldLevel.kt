package com.opencapture.opencine.motion

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Camera attitude against gravity (Swift `WorldLevel.swift` in OpenCineMotion). The attitude is a
 * unit quaternion that maps world to camera (camera x forward, y up; gravity -y); the integration
 * decodes it from its own report. Heading is free and unused.
 */
public object WorldLevel {
    public data class Quat(public val w: Double, public val x: Double, public val y: Double, public val z: Double) {
        public operator fun times(r: Quat): Quat = Quat(
            w * r.w - x * r.x - y * r.y - z * r.z,
            w * r.x + x * r.w + y * r.z - z * r.y,
            w * r.y - x * r.z + y * r.w + z * r.x,
            w * r.z + x * r.y - y * r.x + z * r.w,
        )

        public fun rotate(vx: Double, vy: Double, vz: Double): Vec {
            val r = this * Quat(0.0, vx, vy, vz) * Quat(w, -x, -y, -z)
            return Vec(r.x, r.y, r.z)
        }
    }

    public data class Vec(public val x: Double, public val y: Double, public val z: Double)

    /** Unit gravity (down) in the camera frame. */
    public fun gravity(q: Quat): Vec = q.rotate(0.0, -1.0, 0.0)

    internal fun deg(r: Double): Double = r * 180 / PI
    internal fun asinDeg(v: Double): Double = deg(asin(v.coerceIn(-1.0, 1.0)))
}

public sealed interface LevelMode {
    public data object Unavailable : LevelMode
    /** Picture roll and look-up tilt from the horizon, degrees. */
    public data class Gauges(public val rollDeg: Double, public val tiltDeg: Double) : LevelMode
    /** Lens offset from plumb in picture axes (x right, y up), degrees. */
    public data class Bubble(public val xDeg: Double, public val yDeg: Double) : LevelMode
}

/**
 * Smoothed world level for the LEVEL assist and the Double-tap Level snap.
 * Written on the session thread, read by the overlay on main: synchronized.
 */
public class LevelReading {
    private var g: WorldLevel.Vec? = null
    private var acceptedAt = Double.NEGATIVE_INFINITY
    private var bubble = false

    @Synchronized
    public fun ingest(attitude: WorldLevel.Quat, now: Double) {
        val q = attitude
        if (!now.isFinite()) return
        val sample = WorldLevel.gravity(q)
        // After a gap, start over: pre-gap gravity must not bleed into a new pose.
        if (now - acceptedAt > STALE_AFTER) {
            g = null
            bubble = false
        }
        val prev = g
        g = if (prev == null) sample else {
            if (now - acceptedAt < MIN_INTERVAL) return
            val x = prev.x * (1 - SMOOTHING) + sample.x * SMOOTHING
            val y = prev.y * (1 - SMOOTHING) + sample.y * SMOOTHING
            val z = prev.z * (1 - SMOOTHING) + sample.z * SMOOTHING
            val n = sqrt(x * x + y * y + z * z)
            if (n > 0) WorldLevel.Vec(x / n, y / n, z / n) else sample
        }
        acceptedAt = now
        val tilt = abs(tilt(g!!))
        bubble = if (bubble) tilt >= BUBBLE_EXIT_DEG else tilt >= BUBBLE_ENTER_DEG
    }

    /** Smoothed look-up tilt, or null when stale. */
    @Synchronized
    public fun tiltDeg(now: Double): Double? {
        val g = g ?: return null
        return if (now - acceptedAt <= STALE_AFTER) tilt(g) else null
    }

    /**
     * Signed pitch-plane angle, look-up positive, unfolded past ±90° (lens past
     * nadir reads −92, not −88). The snap plans and judges on this; null when stale.
     */
    @Synchronized
    public fun pitchDeg(now: Double): Double? {
        val g = g ?: return null
        return if (now - acceptedAt <= STALE_AFTER) WorldLevel.deg(atan2(-g.x, -g.y)) else null
    }

    /** [viewFlip]: the camera's pan inversion XOR MIRROR (picture-relative, like the stick). */
    @Synchronized
    public fun mode(now: Double, viewFlip: Boolean): LevelMode {
        val g = g ?: return LevelMode.Unavailable
        if (now - acceptedAt > STALE_AFTER) return LevelMode.Unavailable
        val side = if (viewFlip) -1.0 else 1.0
        return if (bubble) {
            LevelMode.Bubble(side * -WorldLevel.asinDeg(g.z), -WorldLevel.asinDeg(g.y))
        } else {
            LevelMode.Gauges(side * WorldLevel.deg(atan2(g.z, -g.y)), tilt(g))
        }
    }

    private fun tilt(g: WorldLevel.Vec): Double = -WorldLevel.asinDeg(g.x)

    public companion object {
        public const val STALE_AFTER: Double = 1.0
        public const val MIN_INTERVAL: Double = 0.08
        public const val SMOOTHING: Double = 0.3
        public const val BUBBLE_ENTER_DEG: Double = 65.0
        public const val BUBBLE_EXIT_DEG: Double = 60.0
    }
}

public enum class WorldLevelTarget(public val tiltDeg: Double, public val successNote: String) {
    HORIZON(0.0, "Leveled to world"),
    PLUMB_DOWN(-90.0, "Leveled top-down"),
    PLUMB_UP(90.0, "Leveled straight up"),
    ;

    public companion object {
        public fun nearest(tiltDeg: Double): WorldLevelTarget = when {
            abs(tiltDeg) < 45 -> HORIZON
            tiltDeg < 0 -> PLUMB_DOWN
            else -> PLUMB_UP
        }
    }
}

public sealed interface SnapOutcome {
    public data object Pending : SnapOutcome
    public data object Arrived : SnapOutcome
    /** Judged more than a stale window past the deadline (attitude stopped): drop silently. */
    public data object Expired : SnapOutcome
    /** Remaining error to 0.1°, or null when the reading went stale. */
    public data class Failed(public val errorDeg: Double?) : SnapOutcome
}

/** One-shot timed move to the nearest world target. Roll is not commanded. */
public data class WorldLevelSnap(public val target: WorldLevelTarget, public val deadline: Double) {
    /** [tiltDeg] is the unfolded [LevelReading.pitchDeg]. */
    public fun evaluate(tiltDeg: Double?, now: Double): SnapOutcome {
        if (now - deadline > LevelReading.STALE_AFTER) return SnapOutcome.Expired
        tiltDeg ?: return SnapOutcome.Failed(null)
        val error = abs(tiltDeg - target.tiltDeg)
        if (error <= TOLERANCE_DEG) return SnapOutcome.Arrived
        return if (now >= deadline) SnapOutcome.Failed(roundAway(error * 10) / 10) else SnapOutcome.Pending
    }

    public companion object {
        public const val TOLERANCE_DEG: Double = 0.5
        public const val SETTLE_GRACE: Double = 1.5
        public const val NO_LEVEL_DATA: String = "No level data"
        public const val FPV_ROLL_NOTE: String = " · roll follows the handle in FPV"
        /** No live native pitch, or yaw in the unreachable pan gap. */
        public const val UNREACHABLE_NOTE: String = "Couldn't level from this pose"

        /** 0.1 s per 2°, clamped 0.5…3.0 s on the 0.1 s wire grid. */
        public fun duration(distanceDeg: Double): Double = (roundAway(abs(distanceDeg) * 0.5) / 10).coerceIn(0.5, 3.0)

        /**
         * The timed move from [pose] to the nearest world target: the native pitch goal and the
         * duration. Native pitch moves opposite to look-up tilt (`native = 180 - tilt`); null
         * without a native pitch.
         */
        public fun move(tiltDeg: Double, pose: GimbalWaypoint): WorldLevelMove? {
            val native = pose.nativePitchDeg ?: return null
            if (!tiltDeg.isFinite() || !native.isFinite()) return null
            val target = WorldLevelTarget.nearest(tiltDeg)
            val error = target.tiltDeg - tiltDeg
            var goal = native - error
            while (goal > 180) goal -= 360
            while (goal < -180) goal += 360
            return WorldLevelMove(target, goal, duration(error))
        }
    }
}

/** [WorldLevelSnap.move]: the world target, the native pitch goal and the move duration. */
public data class WorldLevelMove(
    public val target: WorldLevelTarget,
    public val nativePitchDeg: Double,
    public val duration: Double,
)

/** Swift `.rounded()`: half away from zero (Kotlin `round` is half-even). */
internal fun roundAway(value: Double): Double = Math.copySign(kotlin.math.floor(abs(value) + 0.5), value)
