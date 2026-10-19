package com.opencapture.opencine.vocabulary

/**
 * Decisions for one automatic session-recovery loop over [SessionRecoveryPolicy.monitor].
 *
 * The host keeps transport, jobs, logging and the recovery card. This value records when a
 * drop may start, the storm pause, the generation, the card-grace latch, the attempt counter
 * and the budget's operator handoff. A host whose transport stages differ keeps its own episode.
 *
 * [nowMs] is the same clock as [SessionDropStormGuard.noteDrop].
 */
class SessionRecoveryDrive {
    var generation: Int = 0
        private set
    var state: SessionRecoveryUi = SessionRecoveryUi.Idle
    var holdsPicture: Boolean = false
        private set
    var cardGraceElapsed: Boolean = false
        private set
    var failures: Int = 0
        private set
    /** True from a started run until that run's job ends or the host cancels. */
    var automaticTaskRunning: Boolean = false
        private set
    private val storm = SessionDropStormGuard()

    /**
     * Adopts [current] first so a host edit of the published state is the phase this call sees.
     */
    fun begin(
        trigger: SessionRecoveryTrigger,
        hasTarget: Boolean,
        nowMs: Long,
        current: SessionRecoveryUi,
    ): Begin {
        state = current
        if (!SessionRecoveryPolicy.shouldBegin(trigger) || !hasTarget || automaticTaskRunning) {
            return Begin.Ignored
        }
        if (
            state is SessionRecoveryUi.PausedAfterDrops || state is SessionRecoveryUi.WaitingForOperator ||
            state is SessionRecoveryUi.TakenOver
        ) {
            return Begin.Ignored
        }
        holdsPicture = true
        generation += 1
        if (storm.noteDrop(nowMs)) {
            val drops = storm.dropsInWindow
            state = SessionRecoveryUi.PausedAfterDrops(drops)
            cardGraceElapsed = true
            return Begin.Paused(drops)
        }
        failures = 0
        state = SessionRecoveryPolicy.monitor.state(0)
        cardGraceElapsed = false
        automaticTaskRunning = true
        return Begin.Started
    }

    fun resetStorm() {
        storm.reset()
    }

    /** Local retirement. The host cancels its jobs and clears a held target when [clearHold] is set. */
    fun cancel(clearHold: Boolean) {
        generation += 1
        automaticTaskRunning = false
        state = SessionRecoveryUi.Idle
        cardGraceElapsed = false
        failures = 0
        if (clearHold) holdsPicture = false
    }

    /** The grace wait finished. A stale generation leaves the latch alone. */
    fun noteCardGrace(seenGeneration: Int): Boolean {
        if (seenGeneration != generation) return false
        cardGraceElapsed = true
        return true
    }

    fun beginAttempts() {
        failures = 0
    }

    /** State for the current failure count. The host stops the loop when it is not retrying. */
    fun prepareAttempt(): SessionRecoveryUi {
        state = SessionRecoveryPolicy.monitor.state(failures)
        return state
    }

    /** Failures so far, then idle with the hold cleared. */
    fun noteRecovered(): Int {
        val failed = failures
        state = SessionRecoveryUi.Idle
        holdsPicture = false
        cardGraceElapsed = false
        failures = 0
        return failed
    }

    fun noteAttemptFailed(jitter: Double): FailedAttempt {
        failures += 1
        val decision = SessionRecoveryPolicy.monitor.decision(failures, jitter)
        if (decision is SessionRecoveryDecision.Retry) {
            return FailedAttempt.Backoff(decision.afterMs)
        }
        state = SessionRecoveryPolicy.monitor.state(failures)
        return FailedAttempt.Exhausted
    }

    /** Budget spent while [current] is the published phase. Attempt number comes from a retrying phase. */
    fun noteBudgetExhausted(current: SessionRecoveryUi) {
        state = current
        val attempts = (state as? SessionRecoveryUi.Retrying)?.attempt ?: 0
        state = SessionRecoveryUi.WaitingForOperator(attempts)
        cardGraceElapsed = true
    }

    fun noteAutomaticTaskEnded(seenGeneration: Int) {
        if (seenGeneration != generation) return
        automaticTaskRunning = false
    }

    sealed class Begin {
        data object Ignored : Begin()
        data class Paused(val drops: Int) : Begin()
        data object Started : Begin()
    }

    sealed class FailedAttempt {
        data class Backoff(val afterMs: Long) : FailedAttempt()
        data object Exhausted : FailedAttempt()
    }

    companion object {
        const val CARD_GRACE_MS: Long = 2_500
    }
}
