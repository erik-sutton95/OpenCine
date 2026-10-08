package com.opencapture.opencine.motion

import com.opencapture.opencine.core.MonotonicInstant
import kotlin.math.ceil
import kotlin.math.min
import kotlin.time.Duration

/** Preparation and target pacing declared by a streamed motion adapter. */
public data class MotionProgramTiming(public val countdown: Duration, public val targetInterval: Duration)

/** Swift OpenCineMotion GimbalProgramPlayback: pure clock; path shape remains GimbalProgram.pose. */
public class GimbalProgramPlayback private constructor(
    public val program: GimbalProgram,
    private val preparationEnd: MonotonicInstant,
    private var last: MonotonicInstant,
    initial: State,
) {
    public data class State(
        public val running: Boolean = false,
        public val paused: Boolean = false,
        public val countdown: Int? = null,
        public val elapsed: Double = 0.0,
        public val reversing: Boolean = false,
    ) {
        public val canPause: Boolean get() = running && countdown == null
        public companion object { public val IDLE: State = State() }
    }

    public data class Output(public val target: GimbalWaypoint? = null, public val finished: Boolean = false)
    public var state: State = initial
        private set
    private var activeElapsed: Double = 0.0
    private var initialTargetPending: Boolean = true

    /** Absolute monotonic instants; late loops wrap completely and a finite take emits its exact end once. */
    public fun step(at: MonotonicInstant): Output {
        if (!state.running) return Output()
        val now = maxOf(at, last)
        val initial = initialTargetPending
        initialTargetPending = false
        if (now < preparationEnd) {
            last = now
            state = state.copy(countdown = remaining(preparationEnd - now))
            return Output(if (initial) program.a else null)
        }
        advance(now)
        state = state.copy(countdown = null)
        if (state.paused) return Output()
        updatePosition()
        if (!program.loop && activeElapsed >= program.duration) {
            state = state.copy(running = false)
            return Output(program.pose(program.duration), finished = true)
        }
        return Output(if (initial) program.a else program.pose(
            if (state.reversing) program.duration - state.elapsed else state.elapsed))
    }

    /** Tap-to-pause consumes its exact budget; settling on the last target does not resend a stale GET pose. */
    public fun pause(at: MonotonicInstant): Boolean {
        if (!state.canPause || state.paused) return false
        val now = maxOf(at, last)
        val next = activeElapsed + (now - maxOf(last, preparationEnd)).secondsValue()
        if (!program.loop && next >= program.duration) return false
        advance(now)
        updatePosition()
        state = state.copy(paused = true)
        return true
    }

    public fun resume(at: MonotonicInstant): Boolean {
        if (!state.running || !state.paused) return false
        last = maxOf(at, last)
        state = state.copy(paused = false)
        return true
    }

    public fun cancel() {
        state = State.IDLE
        initialTargetPending = false
    }

    /** Preparation ends on its exact deadline even when the target cadence does not divide it. */
    public fun nextDelay(upTo: Duration): Duration =
        if (state.countdown != null && last < preparationEnd) minOf(upTo, preparationEnd - last) else upTo

    private fun advance(now: MonotonicInstant) {
        if (!state.paused) activeElapsed += (now - maxOf(last, preparationEnd)).secondsValue()
        last = now
    }

    private fun updatePosition() {
        if (program.loop) {
            val position = activeElapsed % (2 * program.duration)
            val reverse = position >= program.duration
            state = state.copy(reversing = reverse, elapsed = if (reverse) position - program.duration else position)
        } else state = state.copy(elapsed = min(activeElapsed, program.duration), reversing = false)
    }

    public companion object {
        /** Missing, unreachable, unsupported-zoom and malformed plans never issue a target. */
        public fun create(program: GimbalProgram, capabilities: MotionCapabilities, countdown: Duration,
            at: MonotonicInstant): GimbalProgramPlayback? {
            if (countdown < Duration.ZERO || !countdown.isFinite() || !program.canRun ||
                !program.durationAB.isFinite() || program.durationAB !in GimbalProgram.MIN_DURATION..GimbalProgram.MAX_DURATION ||
                (program.c != null && (!program.durationBC.isFinite() ||
                    program.durationBC !in GimbalProgram.MIN_DURATION..GimbalProgram.MAX_DURATION)) ||
                !program.smoothness.isFinite() || program.smoothness !in 0.0..1.0 || !capabilities.admits(program)) return null
            return GimbalProgramPlayback(program, at + countdown, at,
                State(running = true, countdown = if (countdown > Duration.ZERO) remaining(countdown) else null))
        }

        private fun Duration.secondsValue(): Double = inWholeNanoseconds / 1e9
        private fun remaining(duration: Duration): Int = ceil(duration.secondsValue()).toInt()
    }
}
