package com.opencapture.opencine.dji

import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.motion.GimbalPath
import com.opencapture.opencine.motion.GimbalProgram
import com.opencapture.opencine.motion.GimbalProgramCurve
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.GimbalWaypointOverlay
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.MotionBounds
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionReferenceFrame
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.GimbalMode
import com.opencapture.opencine.vocabulary.GimbalRamp
import com.opencapture.opencine.vocabulary.GimbalSpeed
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan
import kotlin.time.Duration.Companion.milliseconds

// The Pocket reach on the shared waypoint (Swift `HeadTrack.Reach`): pan one arc from -48
// through front to 225, tilt -44 to 70.
val GimbalWaypoint.Companion.PAN_MIN_DEG: Double get() = -48.0
val GimbalWaypoint.Companion.PAN_MAX_DEG: Double get() = 225.0
val GimbalWaypoint.Companion.TILT_MIN_DEG: Double get() = -44.0
val GimbalWaypoint.Companion.TILT_MAX_DEG: Double get() = 70.0

fun GimbalWaypoint.Companion.unwrapYaw(rawDeg: Double): Double = unwrapYaw(rawDeg, pocketGimbal.bounds)

fun GimbalWaypoint.Companion.from(yawTenth: Int?, pitchTenth: Int?, zoom: Double, nativePitchTenth: Int? = null): GimbalWaypoint? {
    if (yawTenth == null || pitchTenth == null) return null
    return GimbalWaypoint(
        unwrapYaw(yawTenth / 10.0),
        pitchTenth / 10.0,
        max(1.0, zoom),
        nativePitchTenth?.div(10.0),
    )
}

fun GimbalWaypoint.clamped(): GimbalWaypoint = clamped(pocketGimbal.bounds)

/** Waypoint marks on the live frame use the Pocket lens's widest horizontal field of view. */
fun GimbalWaypointOverlay.project(waypoint: GimbalWaypoint, live: GimbalWaypoint, aspect: Double): Triple<Double, Double, Boolean> =
    project(waypoint, live, aspect, GimbalMoveEngine.WIDE_HFOV)

/**
 * What the Pocket gimbal declares to shared motion (Swift `MotionCapabilities.pocketGimbal`):
 * handle-frame pan and tilt inside the operator-confirmed reach, zoom through native program
 * zoom, firmware-paced timed targets (no client rate cap), the `0x04/0x05` attitude it reports is
 * the pose (older than 0.3 s is not feedback), arrival within 0.15 degrees.
 */
val pocketGimbal = MotionCapabilities(
    axes = setOf(MotionAxis.PAN, MotionAxis.TILT, MotionAxis.ZOOM),
    frame = MotionReferenceFrame.HANDLE,
    bounds = MotionBounds(
        GimbalWaypoint.PAN_MIN_DEG..GimbalWaypoint.PAN_MAX_DEG,
        GimbalWaypoint.TILT_MIN_DEG..GimbalWaypoint.TILT_MAX_DEG,
    ),
    maxRateDegPerSec = null,
    feedbackMaxAge = 300.milliseconds,
    arrivalToleranceDeg = 0.15,
    pose = SupportStatus.SUPPORTED,
)

/** The body's motion service: the Pocket gimbal, or `null` for a body without one. */
val CameraModel.motion: MotionCapabilities? get() = if (hasGimbal) pocketGimbal else null

/** Refresh tilt/speed from attitude receipts, capped at one GET per second. */
class GimbalParamPoll {
    private var lastRequestAt: Long? = null

    fun shouldRequest(nowMs: Long): Boolean {
        if (lastRequestAt?.let { nowMs - it < 1_000L } == true) return false
        lastRequestAt = nowMs
        return true
    }
}

/**
 * Mirrors core `GimbalPrepRestore`. Motion Control drives on Fast with tilt unlocked;
 * the operator's speed and mode from before the first prep come back once nothing
 * has driven the gimbal for [IDLE_DELAY] seconds, so the stick does not stay Fast.
 */
class GimbalPrepRestore {
    /** Operator values to put back; cleared when the operator picks a new one mid-hold. */
    var speed: GimbalSpeed? = null
    var mode: GimbalMode? = null
    private var idleSince: Double? = null

    val isHolding: Boolean get() = speed != null || mode != null

    data class Restore(val speed: GimbalSpeed?, val mode: GimbalMode?) {
        /** `0x04/0x50` SET payloads. Fast and Follow need no write. */
        val payloads: List<ByteArray>
            get() = buildList {
                if (speed != null && speed != GimbalSpeed.FAST) add(CameraCommands.setGimbalSpeed(speed.wire))
                if (mode == GimbalMode.TILT_LOCKED) add(CameraCommands.setGimbalTiltLock(true))
            }
    }

    /** Fast + tilt unlocked. Held values are kept: later readbacks report our Fast. */
    fun prep(speed: GimbalSpeed, mode: GimbalMode): List<ByteArray> {
        if (this.speed == null) this.speed = speed
        if (this.mode == null) this.mode = mode
        idleSince = null
        return listOf(CameraCommands.setGimbalTiltLock(false), CameraCommands.setGimbalSpeed(GimbalSpeed.FAST.wire))
    }

    /** Call on each attitude report; [busy] is a Motion Control run. */
    fun restore(busy: Boolean, now: Double): Restore? {
        if (!isHolding || busy || !now.isFinite()) {
            idleSince = null
            return null
        }
        val since = idleSince ?: now
        idleSince = since
        return if (now - since >= IDLE_DELAY) restoreNow() else null
    }

    /** Immediate restore, for a disconnect while the link can still send. */
    fun restoreNow(): Restore? {
        if (!isHolding) return null
        val restore = Restore(speed, mode)
        speed = null
        mode = null
        idleSince = null
        return restore
    }

    companion object {
        const val IDLE_DELAY = 1.0
    }
}

object GimbalControl {
    fun modeFromGet(tiltLocked: Boolean, commanded: GimbalMode): GimbalMode =
        when (commanded) {
            GimbalMode.FPV, GimbalMode.DIRECTION_LOCK -> commanded
            GimbalMode.FOLLOW, GimbalMode.TILT_LOCKED ->
                if (tiltLocked) GimbalMode.TILT_LOCKED else GimbalMode.FOLLOW
        }

    fun modeFromFamily(family: Int, current: GimbalMode): GimbalMode =
        when (family) {
            0 -> GimbalMode.DIRECTION_LOCK
            1 -> GimbalMode.FPV
            2 -> if (current == GimbalMode.TILT_LOCKED) current else GimbalMode.FOLLOW
            else -> current
        }
}

class GimbalRampFilter {
    var x = 0.0
    var y = 0.0

    fun reset() {
        x = 0.0
        y = 0.0
    }

    fun tick(targetX: Double, targetY: Double, ramp: GimbalRamp, dt: Double): Pair<Double, Double> {
        val tau = ramp.tau
        if (tau <= 0.0 || dt <= 0.0) {
            x = targetX
            y = targetY
            return x to y
        }
        val alpha = 1 - exp(-dt / tau)
        x += (targetX - x) * alpha
        y += (targetY - y) * alpha
        return x to y
    }
}

/** Camera-executed timed targets, lockstep with Swift GimbalMoveEngine. */
class GimbalMoveEngine {
    data class Output(val target: GimbalWaypoint? = null, val duration: Double = 0.0,
        val stop: Boolean = false, val finished: Boolean = false)
    data class Readout(val label: String, val phase: String, val setDuration: Double,
        val elapsed: Double, val liveYaw: Double, val livePitch: Double,
        val targetYaw: Double, val targetPitch: Double, val remainingDeg: Double)
    private data class Leg(val label: String, val from: GimbalWaypoint, val to: GimbalWaypoint, val duration: Double)
    private data class Observation(val time: Double, val pose: GimbalWaypoint)
    private data class Checkpoint(val time: Double, val incoming: Leg, val outgoing: Leg?, val outgoingAt: Double,
        val usesCommandHistory: Boolean = false, val isTurnaround: Boolean = false)
    // The overlapping timed targets are affine between dispatches, even on a smoothed path.
    private data class CommandReference(val time: Double, val from: GimbalWaypoint, val to: GimbalWaypoint,
        val duration: Double) {
        fun position(at: Double) = lerp(from, to, (at - time) / duration)
    }

    var running = false
        private set
    var isPaused = false
        private set
    var verificationInterruptedByPause = false
        private set
    private var resumeNeedsCommand = false
    var failure: String? = null
        private set
    private var program = GimbalProgram()
    private var reversed = false
    private var zoomPath = GimbalZoomPath(GimbalProgram())
    private var zoomElapsedOffset = 0.0
    private var pendingZoomEndpoint: Double? = null
    private var legs: List<Leg> = emptyList()
    private var index = 0
    private var phase = "HOLD"
    private var clock = 0.0
    private var elapsed = 0.0
    private var approachDuration = 0.0
    private val approachTargets = mutableListOf<GimbalWaypoint>()
    private var needsCommand = false
    private val observations = mutableListOf<Observation>()
    private val checkpoints = mutableListOf<Checkpoint>()
    private val commandHistory = mutableListOf<CommandReference>()
    private var lastReadout: Readout? = null
    private var curve: GimbalProgramCurve? = null
    private var nextCurveCommand = 0.0

    val programmedZoomTarget: Double?
        get() {
            if (!running || isPaused || !program.changesZoom) return null
            pendingZoomEndpoint?.let { return it }
            if (phase == "APPROACH" || phase == "HOLD") return program.a?.zoom
            return if (phase == "RUN") zoomPath.position(zoomElapsedOffset + elapsed) else zoomPath.end
        }

    fun consumeProgrammedZoomTarget(): Double? = programmedZoomTarget.also {
        if (it != null) pendingZoomEndpoint = null
    }

    /** Native zoom shares the pass/resume clock, including B on a rounded angular path. */
    internal val nativeZoomDemand: NativeProgramZoomDemand?
        get() {
            if (!program.changesZoom || !running || isPaused || index >= legs.size) return null
            pendingZoomEndpoint?.let { return NativeProgramZoomDemand(NativeProgramZoomCommand.Track(it), it) }
            if (phase == "APPROACH" || phase == "HOLD") {
                val zoom = program.a?.zoom ?: return null
                return NativeProgramZoomDemand(NativeProgramZoomCommand.Position(zoom), zoom)
            }
            return if (phase == "RUN") zoomPath.nativeDemand(zoomElapsedOffset + elapsed)
                else NativeProgramZoomDemand(NativeProgramZoomCommand.Track(zoomPath.end), zoomPath.end)
        }

    internal fun consumeNativeZoomDemand(): NativeProgramZoomDemand? = nativeZoomDemand.also {
        if (it?.command is NativeProgramZoomCommand.Track) pendingZoomEndpoint = null
    }

    fun start(program: GimbalProgram, live: GimbalWaypoint): Boolean {
        cancel()
        this.program = program
        zoomPath = GimbalZoomPath(program)
        zoomElapsedOffset = 0.0
        verificationInterruptedByPause = false
        failure = null
        lastReadout = null
        if (program.a == null || program.b == null) {
            failure = "Set A and B before running"
            return false
        }
        if (!program.smoothness.isFinite() || program.smoothness !in 0.0..1.0) return false
        val points = listOfNotNull(program.a, program.b, live, program.c)
        if (!points.all {
                it.yawDeg.isFinite() && it.pitchDeg.isFinite() && it.zoom.isFinite() && it == it.clamped() &&
                    it.nativePitchDeg.let { native -> native == null || (native.isFinite() && native in -180.0..180.0) } }) {
            failure = "Set reachable gimbal points again"
            return false
        }
        if (points.any { it.nativePitchDeg != null } && !points.all { it.nativePitchDeg != null }) {
            failure = "Set gimbal points from fresh camera feedback"
            return false
        }
        val planned = planFromLive(program, live)
        this.program = planned
        zoomPath = GimbalZoomPath(planned)
        val a = planned.a ?: return false
        val b = planned.b ?: return false
        val next = mutableListOf(Leg("A→B", a, b, planned.durationAB))
        planned.c?.let { next += Leg("B→C", b, it, planned.durationBC) }
        if (!next.all { it.duration.isFinite() && it.duration in GimbalProgram.MIN_DURATION..GimbalProgram.MAX_DURATION &&
                abs(it.duration * 10 - kotlin.math.round(it.duration * 10)) < 1e-6 }) {
            failure = "Increase the move duration"
            return false
        }
        legs = next
        reversed = false
        curve = GimbalProgramCurve.create(planned)
        nextCurveCommand = 0.0
        index = 0
        clock = 0.0
        elapsed = 0.0
        observations.clear()
        checkpoints.clear()
        val approachSteps = max(1, kotlin.math.ceil(abs(a.yawDeg - live.yawDeg) / 120).toInt())
        approachTargets.clear()
        approachTargets += (1..approachSteps).map { lerp(live, a, it.toDouble() / approachSteps) }
        approachDuration = max(GimbalProgram.MIN_DURATION,
            kotlin.math.ceil(angularDistance(live, a) / approachSteps / 120 * 10) / 10)
        needsCommand = angularDistance(live, a) > ARRIVE_DEG
        phase = if (needsCommand) "APPROACH" else "HOLD"
        running = true
        return true
    }

    fun pause(live: GimbalWaypoint): Boolean {
        if (!running || isPaused) return false
        verificationInterruptedByPause = verificationInterruptedByPause || checkpoints.isNotEmpty()
        checkpoints.clear()
        observations.clear()
        isPaused = true
        pendingZoomEndpoint = null
        lastReadout = snapshot(live)
        return true
    }

    fun resume(live: GimbalWaypoint): Boolean {
        if (!running || !isPaused || !live.yawDeg.isFinite() || !live.pitchDeg.isFinite() ||
            !live.zoom.isFinite() || live != live.clamped() ||
            (legs[0].from.nativePitchDeg != null && live.nativePitchDeg == null) ||
            live.nativePitchDeg.let { native -> native != null && (!native.isFinite() || native !in -180.0..180.0) }) return false
        if (phase == "APPROACH" || phase == "HOLD") {
            val interrupted = verificationInterruptedByPause
            if (!start(program, live)) return false
            verificationInterruptedByPause = interrupted
            resumeNeedsCommand = true
            return true
        }
        zoomPath = zoomPath.remaining(if (phase == "VERIFY") zoomPath.duration else zoomElapsedOffset + elapsed,
            live.zoom, quantized = curve == null || phase == "VERIFY")
        zoomElapsedOffset = 0.0
        val activeCurve = curve
        if (activeCurve != null && phase == "RUN") {
            curve = activeCurve.remaining(elapsed, live)
            index = if (curve!!.durationAB > 0) 0 else 1
        } else {
            curve = null
            val remaining = if (phase == "VERIFY") 0.1 else max(0.0, legs[index].duration - elapsed)
            legs = legs.toMutableList().also { it[index] = it[index].copy(from = live,
                duration = max(0.1, kotlin.math.ceil((remaining - 1e-9) * 10) / 10)) }
        }
        phase = "RUN"
        clock = 0.0
        elapsed = 0.0
        nextCurveCommand = 0.0
        checkpoints.clear()
        observations.clear()
        commandHistory.clear()
        isPaused = false
        resumeNeedsCommand = true
        return true
    }

    fun cancel() {
        if (running) lastReadout = lastReadout?.copy(phase = "STOP")
        running = false
        isPaused = false
        resumeNeedsCommand = false
        pendingZoomEndpoint = null
        needsCommand = false
        checkpoints.clear()
        observations.clear()
        commandHistory.clear()
    }

    val nextWakeInterval: Double
        get() {
            if (!running) return 0.04
            val activeCurve = curve
            if (activeCurve != null && phase == "RUN") {
                val boundary = min(nextCurveCommand, activeCurve.duration)
                return if (boundary > elapsed + 1e-9) min(0.04, boundary - elapsed) else 0.04
            }
            if (phase == "RUN" && (abs(legs[index].to.yawDeg - legs[index].from.yawDeg) >= 180 || legs[index].duration > 25.5)) {
                val boundary = min(nextCurveCommand, legs[index].duration)
                return if (boundary > elapsed + 1e-9) min(0.04, boundary - elapsed) else 0.04
            }
            val end = if (phase == "RUN") legs[index].duration else if (phase == "HOLD") HOLD_SECONDS else 0.0
            return if (end > elapsed) min(0.04, end - elapsed) else 0.04
        }

    fun tick(dt: Double, live: GimbalWaypoint, telemetryAge: Double = 0.0): Output? {
        if (!running || isPaused) return null
        if (!dt.isFinite() || dt <= 0 || dt > 0.12 || !telemetryAge.isFinite() || telemetryAge !in 0.0..0.3 ||
            !live.yawDeg.isFinite() || !live.pitchDeg.isFinite() ||
            (legs[0].from.nativePitchDeg != null && live.nativePitchDeg == null) ||
            live.nativePitchDeg.let { native -> native != null && (!native.isFinite() || native !in -180.0..180.0) }) {
            return stop(live, "Move interrupted: timing or camera feedback lost")
        }
        if (resumeNeedsCommand) {
            resumeNeedsCommand = false
            if (phase == "RUN") {
                val activeCurve = curve
                if (activeCurve != null) {
                    nextCurveCommand = if (activeCurve.duration <= 0.1) activeCurve.duration else min(0.05, activeCurve.duration - 0.1)
                    return output(live, activeCurve.position(0.1), 0.1)
                }
                return startExactLeg(live)
            }
            if (phase == "APPROACH") {
                needsCommand = false
                return output(live, approachTargets.firstOrNull(), approachDuration)
            }
            return output(live)
        }
        clock += dt
        elapsed += dt
        val sampleTime = clock - telemetryAge
        if (sampleTime > (observations.lastOrNull()?.time ?: Double.NEGATIVE_INFINITY) + 1e-9) {
            observations += Observation(sampleTime, live)
        }
        observations.removeAll { it.time < clock - 0.8 }
        checkpoints.removeAll { checkpointIsConsistent(it) }
        if (checkpoints.any { clock - it.time > 0.4 }) return stop(live, "Camera waypoint could not be verified")
        val a = legs[0].from
        if (phase == "APPROACH") {
            val approachTarget = approachTargets.firstOrNull() ?: a
            if (needsCommand) {
                needsCommand = false
                elapsed = 0.0
                return output(live, approachTarget, approachDuration)
            }
            if (elapsed >= approachDuration && angularDistance(live, approachTarget) <= ARRIVE_DEG) {
                approachTargets.removeAt(0)
                elapsed = 0.0
                approachTargets.firstOrNull()?.let { return output(live, it, approachDuration) }
                phase = "HOLD"
            } else if (elapsed > approachDuration + 0.5) return stop(live, "Camera did not reach A")
            return output(live)
        }
        if (phase == "HOLD") {
            if (angularDistance(live, a) > ARRIVE_DEG) return stop(live, "Camera moved before the take")
            if (elapsed + 1e-9 < HOLD_SECONDS) return output(live)
            return beginPassMotion(live)
        }
        if (phase == "RUN") curve?.let { return tickCurve(it, live) }
        if (phase == "RUN") {
            val leg = legs[index]
            val streamed = abs(leg.to.yawDeg - leg.from.yawDeg) >= 180 || leg.duration > 25.5
            if (elapsed + 1e-9 < leg.duration) return if (streamed) tickLinearLeg(live) else output(live)
            if (streamed && nextCurveCommand < leg.duration) return stop(live, "Move interrupted: waypoint dispatch was late")
            if (elapsed - leg.duration > 0.02 + 1e-9) return stop(live, "Move interrupted: waypoint dispatch was late")
            if (program.changesZoom) pendingZoomEndpoint = leg.to.zoom
            if (index + 1 == legs.size && program.loop) {
                return turnAround(live, clock - (elapsed - leg.duration))
            }
            checkpoints += Checkpoint(clock - (elapsed - leg.duration), leg, legs.getOrNull(index + 1), clock)
            if (index + 1 < legs.size) {
                zoomElapsedOffset += leg.duration
                index += 1
                elapsed = 0.0
                return startExactLeg(live)
            }
            phase = "VERIFY"
            elapsed = 0.0
            return output(live)
        }
        if (phase == "VERIFY" && elapsed >= 0.3 && checkpoints.isEmpty()) {
            if (angularDistance(live, legs[index].to) > ARRIVE_DEG) return stop(live, "Camera missed its final position")
            phase = "DONE"
            running = false
            return output(live, finished = true)
        }
        return output(live)
    }

    /** Reverse on the deadline and qualify arrival/departure together while moving. */
    private fun turnAround(live: GimbalWaypoint, boundary: Double): Output {
        val incoming = legs[index]
        val streamed = curve != null
        reversed = !reversed
        val a = program.a!!
        val b = program.b!!
        val c = program.c
        val pass = when {
            !reversed -> program
            c != null -> program.copy(a = c, c = a, durationAB = program.durationBC, durationBC = program.durationAB)
            else -> program.copy(a = b, b = a)
        }
        legs = when {
            !reversed -> listOfNotNull(Leg("A→B", a, b, program.durationAB),
                c?.let { Leg("B→C", b, it, program.durationBC) })
            c != null -> listOf(Leg("C→B", c, b, program.durationBC), Leg("B→A", b, a, program.durationAB))
            else -> listOf(Leg("B→A", b, a, program.durationAB))
        }
        curve = GimbalProgramCurve.create(pass)
        zoomPath = GimbalZoomPath(pass)
        zoomElapsedOffset = 0.0
        index = 0
        nextCurveCommand = 0.0
        checkpoints += Checkpoint(boundary, incoming, legs[0], clock, streamed, isTurnaround = true)
        return beginPassMotion(live)
    }

    private fun beginPassMotion(live: GimbalWaypoint): Output {
        phase = "RUN"
        elapsed = 0.0
        curve?.let {
            nextCurveCommand = 0.05
            return output(live, it.position(0.1), 0.1)
        }
        return startExactLeg(live)
    }

    private fun startExactLeg(live: GimbalWaypoint): Output {
        val leg = legs[index]
        if (abs(leg.to.yawDeg - leg.from.yawDeg) >= 180 || leg.duration > 25.5) {
            nextCurveCommand = 0.0
            return sendRoutedLegPart(live)
        }
        return output(live, leg.to, leg.duration)
    }

    private fun tickLinearLeg(live: GimbalWaypoint): Output {
        if (elapsed + 1e-9 < nextCurveCommand) return output(live)
        if (elapsed - nextCurveCommand > 0.02 + 1e-9) return stop(live, "Move interrupted: waypoint dispatch was late")
        return sendRoutedLegPart(live)
    }

    private fun sendRoutedLegPart(live: GimbalWaypoint): Output {
        val leg = legs[index]
        val parts = max(1, max(kotlin.math.ceil(abs(leg.to.yawDeg - leg.from.yawDeg) / 120).toInt(),
            kotlin.math.ceil(leg.duration / 25.5).toInt()))
        val ticks = kotlin.math.round(leg.duration * 10).toInt()
        var endTicks = 0
        val start = nextCurveCommand
        for (part in 0 until parts) {
            val partTicks = ticks / parts + if (part < ticks % parts) 1 else 0
            endTicks += partTicks
            val end = endTicks / 10.0
            if (end <= start + 1e-9) continue
            nextCurveCommand = end
            val target = if (part == parts - 1) leg.to else lerp(leg.from, leg.to, end / leg.duration)
            return output(live, target, partTicks / 10.0)
        }
        return stop(live, "Move interrupted: waypoint dispatch was late")
    }

    private fun tickCurve(curve: GimbalProgramCurve, live: GimbalWaypoint): Output {
        if (program.changesZoom && index == 0 && elapsed + 1e-9 >= curve.durationAB) pendingZoomEndpoint = curve.b.zoom
        index = if (elapsed + 1e-9 >= curve.durationAB) 1 else 0
        if (elapsed + 1e-9 >= curve.duration) {
            if (nextCurveCommand < curve.duration) return stop(live, "Move interrupted: waypoint dispatch was late")
            if (elapsed - curve.duration > 0.02 + 1e-9) return stop(live, "Move interrupted: waypoint dispatch was late")
            if (program.changesZoom) pendingZoomEndpoint = curve.c.zoom
            if (program.loop) return turnAround(live, clock - (elapsed - curve.duration))
            checkpoints += Checkpoint(clock - (elapsed - curve.duration), legs[1], null, clock)
            phase = "VERIFY"
            elapsed = 0.0
            return output(live)
        }
        if (elapsed + 1e-9 < nextCurveCommand) return output(live)
        if (elapsed - nextCurveCommand > 0.02 + 1e-9) return stop(live, "Move interrupted: waypoint dispatch was late")
        val lastCommandAt = curve.duration - 0.1
        val target = if (nextCurveCommand >= lastCommandAt - 1e-9) curve.c
            else curve.position(min(curve.duration, nextCurveCommand + 0.1))
        nextCurveCommand = if (nextCurveCommand >= lastCommandAt - 1e-9) curve.duration
            else min(lastCommandAt, nextCurveCommand + 0.05)
        return output(live, target, 0.1)
    }

    /** Fit one bounded feedback delay across all nearby reports without relaxing angular error. */
    private fun checkpointIsConsistent(check: Checkpoint): Boolean {
        if (check.outgoing == null) {
            val settled = observations.filter { it.time >= check.time && it.time <= check.time + 0.4 }
                .asReversed().takeWhile { angularDistance(it.pose, check.incoming.to) <= ARRIVE_DEG }
            return settled.size >= 2 && settled.first().time - settled.last().time >= 0.08 - 1e-9
        }
        val outgoing = check.outgoing ?: return false
        if (clock + 1e-9 < check.time + 0.3) return false
        val nearby = observations.filter { it.time >= check.time - 0.3 && it.time <= check.time + 0.3 }
        if (nearby.size < 3) return false
        // References are affine between delay breakpoints. Intersect the error
        // circles with each interval so submillisecond delays remain representable.
        val low = max(0.0, nearby.first().time - check.time)
        val high = min(0.2, nearby.last().time - check.time)
        if (low > high) return false
        fun reference(sample: Observation, delay: Double): GimbalWaypoint {
            val time = sample.time - delay
            if (check.usesCommandHistory && commandHistory.isNotEmpty()) {
                return (commandHistory.lastOrNull { it.time <= time } ?: commandHistory.first()).position(time)
            }
            return if (time < check.time) {
                lerp(check.incoming.from, check.incoming.to,
                    1 + (time - check.time) / check.incoming.duration)
            } else {
                lerp(outgoing.from, outgoing.to, (time - check.outgoingAt) / outgoing.duration)
            }
        }
        val knots = mutableListOf(low, high)
        val boundaries = if (check.usesCommandHistory) commandHistory.flatMap { listOf(it.time, it.time + it.duration) }
            else listOf(check.time - check.incoming.duration, check.time, check.outgoingAt, check.outgoingAt + outgoing.duration)
        for (sample in nearby) {
            for (time in boundaries) {
                val delay = sample.time - time
                if (delay > low && delay < high) knots += delay
            }
        }
        knots.sort()
        if (low == high) return nearby.all {
            angularDistance(it.pose, reference(it, low)) <= ARRIVE_DEG
        }
        for ((lower, upper) in knots.zipWithNext()) {
            if (upper - lower <= 1e-12) continue
            val span = upper - lower
            var feasibleLow = 0.0
            var feasibleHigh = span
            for (sample in nearby) {
                val first = reference(sample, lower)
                val last = reference(sample, upper)
                val ey = sample.pose.yawDeg - first.yawDeg
                val ep = pitchDelta(first, sample.pose)
                val vy = -(last.yawDeg - first.yawDeg) / span
                val vp = -pitchDelta(first, last) / span
                val aa = vy * vy + vp * vp
                val bb = 2 * (ey * vy + ep * vp)
                val cc = ey * ey + ep * ep - ARRIVE_DEG * ARRIVE_DEG
                if (aa < 1e-12) {
                    if (cc > 1e-10) { feasibleHigh = -1.0; break }
                    continue
                }
                val discriminant = bb * bb - 4 * aa * cc
                if (discriminant < -1e-9) { feasibleHigh = -1.0; break }
                val root = kotlin.math.sqrt(max(0.0, discriminant))
                feasibleLow = max(feasibleLow, (-bb - root) / (2 * aa))
                feasibleHigh = min(feasibleHigh, (-bb + root) / (2 * aa))
                if (feasibleLow > feasibleHigh) break
            }
            if (feasibleLow <= feasibleHigh) {
                val delay = lower + (feasibleLow + feasibleHigh) / 2
                if (nearby.all { angularDistance(it.pose, reference(it, delay)) <= ARRIVE_DEG + 1e-9 }) {
                    return true
                }
            }
        }
        return turnaroundIsObserved(check, nearby)
    }

    /** Native endpoint easing need not have constant velocity when contact and reversal are observed. */
    private fun turnaroundIsObserved(check: Checkpoint, nearby: List<Observation>): Boolean {
        if (!check.isTurnaround || check.usesCommandHistory) return false
        val outgoing = check.outgoing ?: return false
        val endpoint = check.incoming.to
        fun along(pose: GimbalWaypoint, other: GimbalWaypoint): Double? {
            val yaw = other.yawDeg - endpoint.yawDeg
            val pitch = pitchDelta(endpoint, other)
            val length = hypot(yaw, pitch)
            if (length <= ARRIVE_DEG) return null
            val distance = ((pose.yawDeg - endpoint.yawDeg) * yaw + pitchDelta(endpoint, pose) * pitch) / length
            val nearest = lerp(endpoint, other, distance / length)
            return if (angularDistance(pose, nearest) <= ARRIVE_DEG + 1e-9) distance else null
        }
        return nearby.any { arrival ->
            if (arrival.time < check.time || arrival.time > check.time + 0.2 + 1e-9 ||
                angularDistance(arrival.pose, endpoint) > ARRIVE_DEG) return@any false
            val approach = nearby.filter { it.time <= arrival.time }
            val departure = nearby.filter { it.time >= arrival.time }
            if (approach.none { arrival.time - it.time >= 0.08 - 1e-9 && angularDistance(it.pose, endpoint) > ARRIVE_DEG } ||
                departure.none { it.time - arrival.time >= 0.08 - 1e-9 && angularDistance(it.pose, endpoint) > ARRIVE_DEG }) {
                return@any false
            }
            var nearest = Double.POSITIVE_INFINITY
            for (sample in approach) {
                val distance = along(sample.pose, check.incoming.from) ?: return@any false
                if (distance > nearest + ARRIVE_DEG + 1e-9) return@any false
                nearest = min(nearest, distance)
            }
            var farthest = Double.NEGATIVE_INFINITY
            for (sample in departure) {
                val distance = along(sample.pose, outgoing.to) ?: return@any false
                if (distance < farthest - ARRIVE_DEG - 1e-9) return@any false
                farthest = max(farthest, distance)
            }
            true
        }
    }

    private fun stop(live: GimbalWaypoint, reason: String): Output {
        failure = reason
        lastReadout = snapshot(live)?.copy(phase = "STOP")
        phase = "STOP"
        isPaused = false
        running = false
        return Output(stop = true, finished = true)
    }

    private fun output(live: GimbalWaypoint, target: GimbalWaypoint? = null,
        duration: Double = 0.0, finished: Boolean = false): Output {
        if (target != null && !canSendNativeTarget(live, target)) {
            return stop(live, "Camera moved outside the safe rotation path")
        }
        if (program.loop && target != null) {
            val from = commandHistory.lastOrNull()?.position(clock) ?: live
            commandHistory += CommandReference(clock, from, target, duration)
            while (commandHistory.size > 1 && commandHistory[1].time < clock - 1) commandHistory.removeAt(0)
        }
        lastReadout = snapshot(live)
        return Output(target, duration, finished = finished)
    }

    private fun snapshot(live: GimbalWaypoint): Readout? {
        if (index >= legs.size) return lastReadout
        val leg = legs[index]
        val atA = phase == "APPROACH" || phase == "HOLD"
        val target = if (atA) legs[0].from else leg.to
        return Readout(if (atA) "A" else leg.label, if (isPaused) "PAUSED" else phase,
            if (phase == "APPROACH") approachDuration else if (phase == "HOLD") HOLD_SECONDS else leg.duration,
            if (phase == "VERIFY" || phase == "DONE") leg.duration
            else if (curve != null && phase == "RUN" && index == 1) elapsed - curve!!.durationAB else elapsed,
            live.yawDeg, live.pitchDeg, target.yawDeg, target.pitchDeg, angularDistance(live, target))
    }

    fun readout(live: GimbalWaypoint): Readout? = if (running) snapshot(live) else lastReadout
    fun hudText(live: GimbalWaypoint?): String = hudText(program, live)
    fun hudText(program: GimbalProgram, live: GimbalWaypoint?): String =
        formatDebug(program, live, live?.let { readout(it) } ?: lastReadout)

    companion object {
        const val ARRIVE_DEG = 0.15
        const val HOLD_SECONDS = 2.0
        fun canSendNativeTarget(live: GimbalWaypoint, target: GimbalWaypoint): Boolean =
            live.yawDeg.isFinite() && live.pitchDeg.isFinite() && target.yawDeg.isFinite() && target.pitchDeg.isFinite() &&
                live == live.clamped() && target == target.clamped() &&
                abs(java.lang.Math.copySign(kotlin.math.floor(abs(target.yawDeg * 10) + 0.5), target.yawDeg) / 10 - live.yawDeg) < 180

        const val DEBUG_HUD = true
        const val WIDE_HFOV = 84.0
        const val PITCH_UP_SIGN = GimbalWaypointOverlay.PITCH_UP_SIGN

        fun formatHud(row: Readout): String = formatDebug(GimbalProgram(), null, row)
        fun formatDebug(program: GimbalProgram, live: GimbalWaypoint?, row: Readout?): String {
            fun xy(name: String, point: GimbalWaypoint?): String = if (point == null) "$name  --"
                else String.format(java.util.Locale.US, "%s  X%+7.1f  Y%+7.1f", name, point.yawDeg, point.pitchDeg)
            val lines = mutableListOf(xy("A", program.a), xy("B", program.b), xy("C", program.c), xy("now", live))
            if (row != null) {
                lines += "${row.label}  ${row.phase}"
                lines += String.format(java.util.Locale.US, "set %4.1fs  t %5.2fs", row.setDuration, row.elapsed)
                lines += String.format(java.util.Locale.US, "tgt  X%+7.1f  Y%+7.1f", row.targetYaw, row.targetPitch)
                lines += String.format(java.util.Locale.US, "rem %5.1f°", row.remainingDeg)
            }
            return lines.joinToString("\n")
        }

        fun wrapAngle(value: Double): Double = GimbalPath.wrapAngle(value)

        /**
         * Saved native pitch goes stale once the handle tilts after the point was set:
         * a 38° display change once planned as ~110° native. Re-derive every point's
         * native pitch from the live pose at Start, like Double-tap Level (native falls
         * 1° per 1° of look-up tilt).
         */
        fun planFromLive(program: GimbalProgram, live: GimbalWaypoint): GimbalProgram {
            val liveNative = live.nativePitchDeg ?: return program
            fun rebase(point: GimbalWaypoint?): GimbalWaypoint? {
                val saved = point?.nativePitchDeg ?: return point
                val planned = wrapAngle(liveNative - (point.pitchDeg - live.pitchDeg))
                return if (abs(wrapAngle(planned - saved)) < 1e-9) point else point.copy(nativePitchDeg = planned)
            }
            return program.copy(a = rebase(program.a), b = rebase(program.b), c = rebase(program.c))
        }
        fun pitchDelta(from: GimbalWaypoint, to: GimbalWaypoint): Double = GimbalPath.pitchDelta(from, to)
        fun angularDistance(a: GimbalWaypoint, b: GimbalWaypoint): Double = GimbalPath.angularDistance(a, b)
        fun lerp(a: GimbalWaypoint, b: GimbalWaypoint, u: Double): GimbalWaypoint = GimbalPath.lerp(a, b, u)
        fun tanHalfHFov(zoom: Double): Double = GimbalWaypointOverlay.tanHalfHFov(zoom, WIDE_HFOV)

        fun project(waypoint: GimbalWaypoint, live: GimbalWaypoint, aspect: Double): Triple<Double, Double, Boolean> =
            GimbalWaypointOverlay.project(waypoint, live, aspect)
    }
}

/** Display-only measured-velocity interpolation; never a motor or capture input. */
class GimbalOverlayMotion {
    private data class Sample(val pose: GimbalWaypoint, val time: Double)
    private var previous: Sample? = null
    private var latest: Sample? = null

    fun reset() {
        previous = null
        latest = null
    }

    fun observe(pose: GimbalWaypoint, time: Double) {
        if (!time.isFinite() || !pose.yawDeg.isFinite() || !pose.pitchDeg.isFinite() || !pose.zoom.isFinite() ||
            time <= (latest?.time ?: Double.NEGATIVE_INFINITY)) return
        previous = latest
        latest = Sample(pose, time)
    }

    fun pose(time: Double): GimbalWaypoint? {
        val last = latest ?: return null
        if (!time.isFinite() || time < last.time || time - last.time > STALE_AFTER) return null
        val result = last.pose.copy(nativePitchDeg = null)
        val before = previous ?: return result
        val interval = last.time - before.time
        if (interval < 0.02 || interval > STALE_AFTER) return result
        val ahead = min(time - last.time, PREDICTION_HORIZON)
        val yawDelta = GimbalMoveEngine.wrapAngle(last.pose.yawDeg - before.pose.yawDeg)
        return result.copy(yawDeg = result.yawDeg + yawDelta * ahead / interval,
            pitchDeg = result.pitchDeg + (last.pose.pitchDeg - before.pose.pitchDeg) * ahead / interval)
    }

    companion object {
        const val PREDICTION_HORIZON = 0.1
        const val STALE_AFTER = 0.3
    }
}
