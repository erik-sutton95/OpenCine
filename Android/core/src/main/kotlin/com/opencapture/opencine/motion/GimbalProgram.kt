// Kotlin twin of the Swift OpenCineMotion programs: A·B·C waypoints, durations, the rounded-corner
// curve, straight-line pose math and the waypoint overlay projection.
package com.opencapture.opencine.motion

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

public enum class GimbalWaypointSlot(public val letter: String) {
    A("A"),
    B("B"),
    C("C"),
}

public data class GimbalProgram(
    public val a: GimbalWaypoint? = null,
    public val b: GimbalWaypoint? = null,
    public val c: GimbalWaypoint? = null,
    public val durationAB: Double = DEFAULT_DURATION,
    public val durationBC: Double = DEFAULT_DURATION,
    public val smoothness: Double = 0.0,
    public val loop: Boolean = false,
) {
    public val canRun: Boolean get() = a != null && b != null
    public val changesZoom: Boolean
        get() = listOfNotNull(a, b, c).map { it.zoom }.zipWithNext().any { (from, to) -> abs(to - from) > 1e-6 }

    public val summary: String
        get() =
            when {
                a != null && b != null && c != null -> "A·B·C"
                a != null && b != null -> "A·B"
                a != null || b != null || c != null -> "Partial"
                else -> "Not set"
            }

    /** One pass: A to B, then B to C when C is set. */
    public val duration: Double get() = durationAB + if (c == null) 0.0 else durationBC

    /**
     * Target pose [time] seconds into a pass streamed as plain targets: the rounded-corner curve
     * for A·B·C with smoothness, straight legs otherwise. `null` until A and B are set.
     */
    public fun pose(time: Double): GimbalWaypoint? {
        val a = a ?: return null
        val b = b ?: return null
        GimbalProgramCurve.create(this)?.let { return it.position(time) }
        val c = c
        if (time < durationAB || c == null) return GimbalPath.lerp(a, b, time / durationAB)
        return GimbalPath.lerp(b, c, (time - durationAB) / durationBC)
    }

    public fun point(slot: GimbalWaypointSlot): GimbalWaypoint? =
        when (slot) {
            GimbalWaypointSlot.A -> a
            GimbalWaypointSlot.B -> b
            GimbalWaypointSlot.C -> c
        }

    public fun withPoint(
        slot: GimbalWaypointSlot,
        point: GimbalWaypoint?,
    ): GimbalProgram {
        val next =
            when (slot) {
                GimbalWaypointSlot.A -> copy(a = point)
                GimbalWaypointSlot.B -> copy(b = point)
                GimbalWaypointSlot.C -> copy(c = point)
            }
        return if (point != null) next.seedTravelDurations() else next
    }

    public fun seedTravelDurations(): GimbalProgram {
        var next = this
        if (a != null && b != null) next = next.copy(durationAB = max(durationAB, minTravelDuration(a, b)))
        if (b != null && c != null) next = next.copy(durationBC = max(durationBC, minTravelDuration(b, c)))
        return next
    }

    public companion object {
        public const val DURATION_STEP: Double = 0.5
        public const val MIN_DURATION: Double = 0.5
        public const val MAX_DURATION: Double = 120.0
        public const val DEFAULT_DURATION: Double = 5.0
        public val durationStops: List<Double> = listOf(2.0, 5.0, 10.0)

        public fun snapDuration(value: Double): Double {
            val clamped = value.coerceIn(MIN_DURATION, MAX_DURATION)
            return (kotlin.math.round(clamped / DURATION_STEP) * DURATION_STEP)
        }

        public fun minTravelDuration(
            from: GimbalWaypoint?,
            to: GimbalWaypoint?,
        ): Double {
            if (from == null || to == null) return DEFAULT_DURATION
            return MIN_DURATION
        }

        public fun steppedDuration(value: Double, delta: Double, floor: Double): Double =
            snapDuration(max(floor, value + delta))

        /** Whole seconds as `5s`, half seconds as `2.5s` (no locale). */
        public fun durationLabel(value: Double): String {
            val snap = snapDuration(value)
            if (abs(snap - kotlin.math.round(snap)) < 0.05) return "${snap.toInt()}s"
            val tenths = kotlin.math.round(snap * 10).toLong()
            return "${tenths / 10}.${tenths % 10}s"
        }
    }
}

/** Time-preserving quadratic fillet at B; A/C exact, B rounded when smoothness > 0. */
public class GimbalProgramCurve private constructor(program: GimbalProgram) {
    public val a: GimbalWaypoint = program.a!!
    public val b: GimbalWaypoint = program.b!!
    public val c: GimbalWaypoint = program.c!!
    public var durationAB: Double = program.durationAB
        private set
    public var durationBC: Double = program.durationBC
        private set
    public val halfCornerDuration: Double = min(durationAB, durationBC) * 0.5 * min(program.smoothness, 1.0)
    public val duration: Double get() = durationAB + durationBC

    private data class Piece(val from: GimbalWaypoint, val control: GimbalWaypoint?, val to: GimbalWaypoint, val duration: Double)
    private var pieces: List<Piece> = run {
        val p = GimbalPath.lerp(a, b, 1 - halfCornerDuration / durationAB)
        val q = GimbalPath.lerp(b, c, halfCornerDuration / durationBC)
        listOf(Piece(a, null, p, durationAB - halfCornerDuration),
            Piece(p, b, q, 2 * halfCornerDuration), Piece(q, null, c, durationBC - halfCornerDuration))
    }
    private val originalProgram = program

    public fun position(time: Double): GimbalWaypoint {
        if (time <= 0) return pieces.first().from
        if (time >= duration) return c
        var remaining = time
        for (piece in pieces) {
            if (remaining <= piece.duration) {
                val u = remaining / piece.duration
                val control = piece.control
                return if (control == null) GimbalPath.lerp(piece.from, piece.to, u)
                else GimbalPath.lerp(GimbalPath.lerp(piece.from, control, u),
                    GimbalPath.lerp(control, piece.to, u), u)
            }
            remaining -= piece.duration
        }
        return c
    }

    public fun remaining(time: Double, pose: GimbalWaypoint): GimbalProgramCurve {
        val result = GimbalProgramCurve(originalProgram)
        var consumed = max(0.0, time)
        var rest = emptyList<Piece>()
        for ((index, piece) in pieces.withIndex()) {
            if (consumed >= piece.duration) { consumed -= piece.duration; continue }
            val u = consumed / piece.duration
            val cut = piece.copy(from = pose,
                control = piece.control?.let { GimbalPath.lerp(it, piece.to, u) },
                duration = piece.duration - consumed)
            rest = listOf(cut) + pieces.drop(index + 1)
            break
        }
        if (rest.isEmpty()) rest = listOf(Piece(pose, null, c, 0.1))
        val total = rest.sumOf { it.duration }
        if (total < 0.1) rest = listOf(rest[0].copy(duration = rest[0].duration + 0.1 - total)) + rest.drop(1)
        result.pieces = rest
        result.durationAB = max(0.0, durationAB - max(0.0, time))
        result.durationBC = rest.sumOf { it.duration } - result.durationAB
        return result
    }

    public fun samples(count: Int = 80): List<GimbalWaypoint> {
        val size = max(2, count)
        return (0 until size).map { position(duration * it / (size - 1)) }
    }

    public companion object {
        public fun create(program: GimbalProgram): GimbalProgramCurve? {
            if (program.a == null || program.b == null || program.c == null ||
                !program.smoothness.isFinite() || program.smoothness <= 0 ||
                !program.durationAB.isFinite() || !program.durationBC.isFinite() ||
                program.durationAB <= 0 || program.durationBC <= 0) return null
            return GimbalProgramCurve(program)
        }
    }
}

/** Straight-line pose math shared by programmed moves and head tracking. */
public object GimbalPath {
    public fun wrapAngle(value: Double): Double = ((value + 180) % 360 + 360) % 360 - 180

    public fun pitchDelta(from: GimbalWaypoint, to: GimbalWaypoint): Double {
        val start = from.nativePitchDeg
        val end = to.nativePitchDeg
        return if (start != null && end != null) wrapAngle(end - start) else to.pitchDeg - from.pitchDeg
    }

    public fun angularDistance(a: GimbalWaypoint, b: GimbalWaypoint): Double = hypot(b.yawDeg - a.yawDeg, pitchDelta(a, b))

    public fun lerp(a: GimbalWaypoint, b: GimbalWaypoint, u: Double): GimbalWaypoint {
        val t = u.coerceIn(0.0, 1.0)
        val start = a.nativePitchDeg
        return GimbalWaypoint(a.yawDeg + (b.yawDeg - a.yawDeg) * t,
            a.pitchDeg + (b.pitchDeg - a.pitchDeg) * t, a.zoom + (b.zoom - a.zoom) * t,
            if (start != null && b.nativePitchDeg != null) wrapAngle(start + pitchDelta(a, b) * t) else null)
    }
}

/** Where a waypoint draws on the live frame, from the camera's widest horizontal field of view. */
public object GimbalWaypointOverlay {
    public const val PITCH_UP_SIGN: Double = 1.0

    public fun tanHalfHFov(zoom: Double, wideHFovDeg: Double): Double = tan(wideHFovDeg / 2 * PI / 180) / max(zoom, 1.0)

    /** Normalized x, y on the frame and whether the point is in front of the camera and on screen. */
    public fun project(waypoint: GimbalWaypoint, live: GimbalWaypoint, aspect: Double, wideHFovDeg: Double): Triple<Double, Double, Boolean> {
        val tanH = tanHalfHFov(live.zoom, wideHFovDeg)
        val tanV = tanH / max(aspect, 0.1)
        val dYaw = (waypoint.yawDeg - live.yawDeg) * PI / 180
        val tp = PITCH_UP_SIGN * waypoint.pitchDeg * PI / 180
        val cp = PITCH_UP_SIGN * live.pitchDeg * PI / 180
        val x = sin(dYaw) * cos(tp)
        val y = sin(tp)
        val z = cos(dYaw) * cos(tp)
        val yc = y * cos(cp) - z * sin(cp)
        val zc = y * sin(cp) + z * cos(cp)
        if (zc <= 1e-6) return Triple(if (x >= 0) 1.0 else 0.0, 0.5, false)
        val nx = 0.5 + (x / zc) / (2 * tanH)
        val ny = 0.5 - (yc / zc) / (2 * tanV)
        val onScreen = nx in 0.0..1.0 && ny in 0.0..1.0
        return Triple(nx.coerceIn(0.0, 1.0), ny.coerceIn(0.0, 1.0), onScreen)
    }
}
