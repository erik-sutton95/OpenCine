package com.opencapture.opencine.vocabulary

import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * One finite automatic recovery episode for a dropped camera session. Every app runs this one
 * (Swift twin: `SessionRecoveryEpisode` in OpenCineCameraVocabulary).
 *
 * The monitor keeps the last picture while bounded attempts reconnect through the host's own
 * connection path. An attempt ends recovery only on a source frame and a presented picture that
 * are both newer than its start ([RecoveryPictureProof]): a returned control session, a handshake
 * or a repaint of the held frame is not a recovered monitor. Retries follow
 * [SessionRecoveryPolicy.monitor], the episode stops at
 * [SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS] and hands the decision to the operator, and
 * drops that cluster across episodes pause automatic recovery ([SessionDropStormGuard]).
 *
 * While the host app is in the background the OS may block its camera network, so an attempt
 * there fails at once without reaching the camera. The host reports that with [pause] and
 * [resume]: while paused no attempt dials, an attempt that failed during a pause does not count,
 * and the total budget's clock stops. The held episode continues when the host resumes.
 *
 * Transport, decoders and presentation stay with the host behind [Port]. The episode and its port
 * are confined to [scope]'s dispatcher (the main thread in the apps); a port action that runs for
 * a retired attempt, or after the host lost the connection, cannot act for its successor.
 */
class SessionRecoveryEpisode(
    private val scope: CoroutineScope,
    private val port: Port,
    private val attemptDeadline: AttemptDeadline,
    private val timing: Timing,
    /**
     * The drop ledger. A host that rebuilds its episode per lifecycle run passes one it keeps, so
     * clustered drops still pause across runs.
     */
    private val storm: SessionDropStormGuard = SessionDropStormGuard(),
    private val changed: (Snapshot) -> Unit = {},
) {
    /** Where an attempt's transport is, for stage deadlines. Integrations map their own phases. */
    enum class Stage { CONNECTING, JOINING_NETWORK, OPENING_LINK, LIVE }

    /** How long one attempt may run, declared by the integration that owns the transport. */
    data class AttemptDeadline(
        /** Ceiling on the whole attempt, counted from the moment [Port.connect] admits it. */
        val attemptMs: Long,
        /** Ceiling per observed stage, restarted whenever the stage changes. */
        val stagesMs: Map<Stage, Long> = emptyMap(),
    ) {
        internal fun ceilingMs(stage: Stage?): Long? = stage?.let { stagesMs[it] }
    }

    /** The attempt's transport as the host sees it. */
    enum class Progress {
        RUNNING,

        /** The transport gave up without a picture. The episode counts a failure and backs off. */
        FAILED,

        /** Another connection replaced this attempt's source. The operator decides. */
        SUPERSEDED,
    }

    /** One reading of the host's transport and picture clocks, all on [Timing.nowMs]'s clock. */
    data class Observation(
        /** Explicit transport authority. Unknown (`null`) refuses like `false`. */
        val ownsConnection: Boolean? = null,
        val progress: Progress = Progress.RUNNING,
        val stage: Stage? = null,
        val sourceAtMs: Long? = null,
        val presentedAtMs: Long? = null,
    )

    /** Everything the host renders: the card, the held-picture badge, the reconnect spinner. */
    data class Snapshot(
        val state: SessionRecoveryUi = SessionRecoveryUi.Idle,
        val targetId: String? = null,
        val holdsPicture: Boolean = false,
        val cardGraceElapsed: Boolean = false,
        val reconnecting: Boolean = false,
    )

    /** When the host retires native work: the drop, a failed attempt, a storm pause, the budget. */
    enum class Cleanup { INITIAL_DROP, FAILED_ATTEMPT, STORM_PAUSE, BUDGET_EXHAUSTED }

    /** The one clock for deadlines, the storm ledger and picture stamps, plus the backoff jitter. */
    class Timing(val nowMs: () -> Long, val jitter: () -> Double = { Random.nextDouble() })

    /** The host's transport for this episode. */
    interface Port {
        fun observe(): Observation

        fun cleanup(kind: Cleanup, attempt: Attempt)

        /**
         * Starts one attempt through the host's own connection path and returns once it is
         * admitted. `false` means it could not start and counts as a failed attempt.
         */
        suspend fun connect(attempt: Attempt): Boolean

        /**
         * The device now holding the camera, asked before automatic attempt [number] (1-based)
         * dials. A body that takes one initiator drops the device holding it when another
         * connects, so reconnecting would take the camera straight back from it. `null` when
         * nobody says so. Never asked on an operator retry: that is the take-back.
         */
        suspend fun holder(attempt: Attempt, number: Int): String? = null
    }

    /** One admitted episode. Host actions check it before touching shared transport state. */
    inner class Attempt internal constructor(
        val targetId: String,
        val trigger: SessionRecoveryTrigger,
        val reason: String,
    ) {
        val id: String = UUID.randomUUID().toString()
        internal var job: Job? = null
        internal var graceJob: Job? = null
        internal var budgetJob: Job? = null
        internal var budgetLeftMs: Long = SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS
        internal var budgetSegmentStartMs: Long? = null

        val isCurrent: Boolean get() = current === this

        /** Throws a [CancellationException] once this attempt is retired or lost the connection. */
        fun checkCurrent() = ensureCurrent(this)

        /** [checkCurrent] plus the calling coroutine's cancellation, after a suspension. */
        suspend fun checkContinuation() = this@SessionRecoveryEpisode.checkContinuation(this)
    }

    private class Retired : CancellationException("session recovery attempt retired")

    private enum class Outcome { RECOVERED, FAILED, SUPERSEDED }

    private val mutableSnapshot = MutableStateFlow(Snapshot())
    val snapshot: StateFlow<Snapshot> = mutableSnapshot.asStateFlow()
    private var current: Attempt? = null
    private var generation = 0L
    private val hostActive = MutableStateFlow(true)
    private var pauseEpoch = 0L

    /** The host reported that it cannot reach the camera now ([pause]). */
    val isPaused: Boolean get() = !hostActive.value

    val currentEpisodeId: String? get() = current?.id
    val isRunning: Boolean get() = current?.job != null

    /**
     * Admits a drop. `false` when the trigger does not recover, there is no target, an episode is
     * in flight or waiting for the operator, the host does not own the connection, or a host
     * callback replaced or cancelled this episode before it was installed.
     */
    fun begin(targetId: String?, trigger: SessionRecoveryTrigger, reason: String): Boolean {
        if (!SessionRecoveryPolicy.shouldBegin(trigger) || targetId == null || current != null ||
            snapshot.value.state.isRecovering
        ) {
            return false
        }
        val observed = generation
        val context = port.observe()
        if (generation != observed || context.ownsConnection != true) return false
        val attempt = Attempt(targetId, trigger, reason)
        generation += 1
        current = attempt
        mutableSnapshot.value = Snapshot(targetId = targetId, holdsPicture = true)
        changed(mutableSnapshot.value)
        return try {
            cleanup(Cleanup.INITIAL_DROP, attempt)
            val droppedAt = timing.nowMs()
            ensureCurrent(attempt)
            if (storm.noteDrop(droppedAt)) {
                cleanup(Cleanup.STORM_PAUSE, attempt)
                publish(
                    mutableSnapshot.value.copy(
                        state = SessionRecoveryUi.PausedAfterDrops(storm.dropsInWindow),
                        cardGraceElapsed = true,
                    ),
                    attempt,
                )
                return attempt.isCurrent
            }
            attempt.graceJob = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    delay(CARD_GRACE_MS)
                    checkContinuation(attempt)
                    publish(mutableSnapshot.value.copy(cardGraceElapsed = true), attempt)
                } catch (_: Retired) {}
            }
            if (hostActive.value) {
                attempt.budgetJob = scope.launch(start = CoroutineStart.LAZY) {
                    waitForBudget(attempt)
                }
            }
            attempt.job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    run(attempt)
                } finally {
                    attempt.budgetJob?.cancel()
                    if (current === attempt) attempt.job = null
                }
            }
            // The identity and both jobs exist before the first publication, so a host callback
            // that cancels here cancels jobs that never started.
            publish(
                mutableSnapshot.value.copy(state = SessionRecoveryPolicy.monitor.state(0)),
                attempt,
            )
            attempt.graceJob?.start()
            attempt.budgetJob?.start()
            attempt.job?.start()
            attempt.isCurrent
        } catch (_: Retired) {
            false
        }
    }

    /** Local retirement only; the host's native disconnect and decoder teardown stay host actions. */
    fun cancel(clearHold: Boolean = true) {
        val retired = current
        generation += 1
        current = null
        retired?.job?.cancel()
        retired?.graceJob?.cancel()
        retired?.budgetJob?.cancel()
        val previous = mutableSnapshot.value
        mutableSnapshot.value =
            Snapshot(
                targetId = if (clearHold) null else previous.targetId,
                holdsPicture = if (clearHold) false else previous.holdsPicture,
            )
        changed(mutableSnapshot.value)
    }

    /**
     * The host went to the background or the OS blocks its camera network. Attempts wait, one
     * that fails while paused is not counted, and the budget's clock stops until [resume].
     * Lasts across episodes: an episode admitted while paused waits for [resume] to dial.
     */
    fun pause() {
        if (!hostActive.value) return
        hostActive.value = false
        pauseEpoch += 1
        val attempt = current ?: return
        val budget = attempt.budgetJob ?: return
        attempt.budgetJob = null
        budget.cancel()
        attempt.budgetSegmentStartMs?.let { started ->
            attempt.budgetLeftMs = maxOf(0L, attempt.budgetLeftMs - (timing.nowMs() - started))
        }
        attempt.budgetSegmentStartMs = null
    }

    /** The host can reach the camera again: a paused episode dials and its budget clock runs. */
    fun resume() {
        if (hostActive.value) return
        hostActive.value = true
        val attempt = current ?: return
        // A finished run (operator decision, storm pause) has no budget left to spend.
        if (attempt.job == null || attempt.budgetJob != null) return
        attempt.budgetJob = scope.launch { waitForBudget(attempt) }
    }

    /** Operator action: a fresh drop ledger. Never called on reconnect success. */
    fun resetStorm() {
        storm.reset()
    }

    /** Operator retry of the held target: a fresh ledger and a fresh episode. */
    fun retry(): Boolean {
        val target = snapshot.value.targetId ?: return false
        val before = generation
        val context = port.observe()
        if (generation != before || context.ownsConnection != true) return false
        storm.reset()
        cancel(clearHold = false)
        if (generation != before + 1 || current != null) return false
        return begin(target, SessionRecoveryTrigger.OPERATOR_RETRY, "operator retry")
    }

    private fun ensureCurrent(attempt: Attempt) {
        if (current !== attempt) throw Retired()
        val context = port.observe()
        if (current !== attempt || context.ownsConnection != true) throw Retired()
    }

    private suspend fun checkContinuation(attempt: Attempt) {
        currentCoroutineContext().ensureActive()
        ensureCurrent(attempt)
    }

    private fun observe(attempt: Attempt): Observation {
        ensureCurrent(attempt)
        val value = port.observe()
        ensureCurrent(attempt)
        return value
    }

    private fun now(attempt: Attempt): Long {
        ensureCurrent(attempt)
        return timing.nowMs()
    }

    private fun publish(value: Snapshot, attempt: Attempt) {
        ensureCurrent(attempt)
        mutableSnapshot.value = value
        changed(value)
        ensureCurrent(attempt)
    }

    private fun cleanup(kind: Cleanup, attempt: Attempt) {
        ensureCurrent(attempt)
        port.cleanup(kind, attempt)
        ensureCurrent(attempt)
    }

    private suspend fun run(attempt: Attempt) {
        // Like a Swift Task, the run starts after begin returns, even on an immediate dispatcher.
        yield()
        try {
            runAttempts(attempt)
        } catch (_: Retired) {}
    }

    private suspend fun waitForBudget(attempt: Attempt) {
        // Publish on the deadline before joining a native connect that may ignore cancellation.
        try {
            attempt.budgetSegmentStartMs = timing.nowMs()
            delay(attempt.budgetLeftMs)
            checkContinuation(attempt)
            val attempts = (mutableSnapshot.value.state as? SessionRecoveryUi.Retrying)?.attempt ?: 0
            cleanup(Cleanup.BUDGET_EXHAUSTED, attempt)
            publish(
                mutableSnapshot.value.copy(
                    state = SessionRecoveryUi.WaitingForOperator(attempts),
                    cardGraceElapsed = true,
                    reconnecting = false,
                ),
                attempt,
            )
            attempt.job?.cancel()
            attempt.graceJob?.cancel()
        } catch (_: Retired) {}
    }

    private suspend fun runAttempts(attempt: Attempt) {
        val policy = SessionRecoveryPolicy.monitor
        var failures = 0
        while (true) {
            checkContinuation(attempt)
            val state = policy.state(failures)
            publish(mutableSnapshot.value.copy(state = state), attempt)
            if (state !is SessionRecoveryUi.Retrying) return
            awaitHostActive(attempt)
            if (attempt.trigger != SessionRecoveryTrigger.OPERATOR_RETRY) {
                val holder = port.holder(attempt, failures + 1)
                checkContinuation(attempt)
                if (holder != null) {
                    publish(
                        mutableSnapshot.value.copy(
                            state = SessionRecoveryUi.TakenOver(holder.ifBlank { null }),
                            reconnecting = false,
                            cardGraceElapsed = true,
                        ),
                        attempt,
                    )
                    return
                }
            }
            // The host may have paused while the holder was asked.
            awaitHostActive(attempt)
            val epoch = pauseEpoch
            val outcome = runOneAttempt(attempt)
            checkContinuation(attempt)
            when (outcome) {
                Outcome.RECOVERED -> {
                    publish(
                        mutableSnapshot.value.copy(
                            state = SessionRecoveryUi.Idle,
                            holdsPicture = false,
                            reconnecting = false,
                            cardGraceElapsed = false,
                        ),
                        attempt,
                    )
                    attempt.graceJob?.cancel()
                    current = null
                    generation += 1
                    return
                }
                Outcome.SUPERSEDED -> {
                    publish(
                        mutableSnapshot.value.copy(
                            state = SessionRecoveryUi.WaitingForOperator(failures + 1),
                            reconnecting = false,
                            cardGraceElapsed = true,
                        ),
                        attempt,
                    )
                    return
                }
                Outcome.FAILED -> Unit
            }
            if (pauseEpoch != epoch || !hostActive.value) {
                // The OS, not the camera, refused this attempt: retire it without counting.
                cleanup(Cleanup.FAILED_ATTEMPT, attempt)
                publish(mutableSnapshot.value.copy(reconnecting = false), attempt)
                continue
            }
            failures += 1
            cleanup(Cleanup.FAILED_ATTEMPT, attempt)
            val jitter = timing.jitter()
            ensureCurrent(attempt)
            val decision = policy.decision(failures, jitter)
            if (decision !is SessionRecoveryDecision.Retry) {
                publish(mutableSnapshot.value.copy(state = policy.state(failures)), attempt)
                return
            }
            delay(decision.afterMs)
            checkContinuation(attempt)
        }
    }

    private suspend fun awaitHostActive(attempt: Attempt) {
        if (hostActive.value) return
        publish(mutableSnapshot.value.copy(reconnecting = false), attempt)
        hostActive.first { it }
        checkContinuation(attempt)
    }

    private suspend fun runOneAttempt(attempt: Attempt): Outcome {
        checkContinuation(attempt)
        publish(mutableSnapshot.value.copy(reconnecting = true), attempt)
        val admitted =
            try {
                port.connect(attempt)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                false
            }
        checkContinuation(attempt)
        if (!admitted) return Outcome.FAILED
        val started = now(attempt)
        val attemptEnds = started + attemptDeadline.attemptMs
        var stage = observe(attempt).stage
        var stageEnds = attemptDeadline.ceilingMs(stage)?.let { now(attempt) + it }
        while (true) {
            val seen = observe(attempt)
            // Any picture now belongs to the replacement, never to this attempt.
            if (seen.progress == Progress.SUPERSEDED) return Outcome.SUPERSEDED
            if (seen.stage != stage) {
                stage = seen.stage
                stageEnds = attemptDeadline.ceilingMs(stage)?.let { now(attempt) + it }
            }
            val time = now(attempt)
            if (time >= attemptEnds || stageEnds?.let { time >= it } == true) return Outcome.FAILED
            if (RecoveryPictureProof.isFresh(started, time, seen.presentedAtMs, seen.sourceAtMs)) {
                return Outcome.RECOVERED
            }
            if (seen.progress == Progress.FAILED) return Outcome.FAILED
            delay(POLL_MS)
            checkContinuation(attempt)
        }
    }

    companion object {
        /** How long the card waits behind attempt 1. The monitor holds the picture either way. */
        const val CARD_GRACE_MS: Long = 2_500
        private const val POLL_MS: Long = 100
    }
}
