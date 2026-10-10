package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.motion.GimbalProgram
import com.opencapture.opencine.motion.GimbalProgramPlayback
import com.opencapture.opencine.motion.MotionProgramTiming
import com.opencapture.opencine.motion.MotionService
import com.opencapture.opencine.motion.MotionTarget
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.time.Duration

/**
 * Swift OpenCineMotion MotionProgramSession. Call on the scope's single dispatcher (the app uses
 * Main.immediate). Core owns the pure timeline; AppKit owns coroutines and source retirement.
 * Cancellation sends no stop/recenter command, and closing a presentation never calls this owner.
 */
public class MotionProgramSession(
    private val scope: CoroutineScope,
    private val now: () -> MonotonicInstant = MonotonicInstant::now,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
) {
    public data class Source(public val motion: MotionService, public val isCurrent: () -> Boolean)
    public enum class Failure { INVALID_PROGRAM, COMMAND_REJECTED }
    public data class State(
        public val progress: GimbalProgramPlayback.State = GimbalProgramPlayback.State.IDLE,
        public val operation: OperationID? = null,
        public val failure: Failure? = null,
    )

    private val _state: MutableStateFlow<State> = MutableStateFlow(State())
    public val state: StateFlow<State> = _state.asStateFlow()
    public var onChange: ((State) -> Unit)? = null

    private class Run(val source: Source, val timing: MotionProgramTiming, val playback: GimbalProgramPlayback) {
        val operation = OperationID()
        var scheduler: Job? = null
        val commands = mutableMapOf<Long, Job>()
        var nextCommand = 0L
        var commandRevision = 0L
        var finalCommandPending = false
    }
    private var active: Run? = null
    private var lifecycleRevision = 0L

    /** An explicit start replaces the old take; old timers/replies cannot publish or dispatch to its successor. */
    public fun start(program: GimbalProgram, source: Source, timing: MotionProgramTiming): Boolean {
        val revision = lifecycleRevision
        if (!source.isCurrent() || lifecycleRevision != revision) return false
        val playback = if (timing.targetInterval > Duration.ZERO && timing.targetInterval.isFinite())
            GimbalProgramPlayback.create(program, source.motion.capabilities, timing.countdown, now()) else null
        if (lifecycleRevision != revision) return false
        if (playback == null) {
            if (active == null) publish(State(failure = Failure.INVALID_PROGRAM))
            return false
        }
        retireTasks()
        val run = Run(source, timing, playback)
        active = run
        publish(State(playback.state, run.operation))
        if (active !== run) return true
        val scheduler = scope.launch {
            try {
                while (isActive) {
                    val interval = pulse(run) ?: return@launch
                    sleep(interval)
                }
            } catch (cancelled: CancellationException) {
                if (active === run) cancel()
                throw cancelled
            }
        }
        if (active === run && scheduler.isActive) run.scheduler = scheduler else scheduler.cancel()
        return true
    }

    public fun pause(): Boolean {
        val run = currentRun() ?: return false
        if (run.finalCommandPending) return false
        val instant = now()
        if (active !== run || !run.playback.pause(instant)) return false
        retireCommands(run)
        publish(State(run.playback.state, run.operation))
        return true
    }

    public fun resume(): Boolean {
        val run = currentRun() ?: return false
        val instant = now()
        if (active !== run || !run.playback.resume(instant)) return false
        publish(State(run.playback.state, run.operation))
        return true
    }

    public fun cancel() {
        retireTasks()
        publish(State())
    }

    private fun currentRun(): Run? {
        val run = active ?: return null
        return run.takeIf { admits(it) }
    }

    /** A source callback can replace the take synchronously; its answer applies only to this run. */
    private fun admits(run: Run): Boolean {
        if (active !== run) return false
        val current = run.source.isCurrent()
        if (active !== run) return false
        if (!current) { cancel(); return false }
        return true
    }

    private fun pulse(run: Run): Duration? {
        if (!admits(run)) return null
        val instant = now()
        if (active !== run) return null
        val output = run.playback.step(instant)
        run.finalCommandPending = output.finished
        publish(State(run.playback.state, run.operation))
        if (!admits(run)) return null
        if (run.playback.state.paused) return run.playback.nextDelay(run.timing.targetInterval)
        output.target?.let { pose ->
            val target = run.source.motion.capabilities.target(pose)
            if (active !== run) return null
            if (target == null) { finish(run, Failure.INVALID_PROGRAM); return null }
            dispatch(target, output.finished, run)
        }
        return if (output.finished) null else run.playback.nextDelay(run.timing.targetInterval)
    }

    private fun dispatch(target: MotionTarget, final: Boolean, run: Run) {
        val command = ++run.nextCommand
        val revision = run.commandRevision
        // Start in order without blocking the target cadence on a reply's potentially long wait.
        val task = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            if (!isActive || active !== run || run.commandRevision != revision || run.playback.state.paused ||
                !admits(run) || !isActive || run.commandRevision != revision || run.playback.state.paused) return@launch
            val accepted = try { run.source.motion.move(target, null) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { false }
            if (!isActive || active !== run || run.commandRevision != revision) return@launch
            run.commands.remove(command)
            if (!admits(run) || !isActive || run.commandRevision != revision) return@launch
            if (!accepted) finish(run, Failure.COMMAND_REJECTED)
            else if (final) finish(run, null)
        }
        if (!task.isCompleted && active === run) run.commands[command] = task
    }

    private fun finish(run: Run, failure: Failure?) {
        if (active !== run) return
        val progress = if (failure == null) run.playback.state else GimbalProgramPlayback.State.IDLE
        retireTasks()
        publish(State(progress = progress, failure = failure))
    }

    private fun retireCommands(run: Run) {
        run.commandRevision += 1
        val commands = run.commands.values.toList()
        run.commands.clear()
        commands.forEach { it.cancel() }
    }

    private fun retireTasks() {
        lifecycleRevision += 1
        val run = active ?: return
        active = null
        run.scheduler?.cancel(); run.scheduler = null
        retireCommands(run)
        run.playback.cancel()
    }

    private fun publish(next: State) {
        if (_state.value == next) return
        _state.value = next
        onChange?.invoke(next)
    }
}
