package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.SessionDropStormGuard
import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode
import com.opencapture.opencine.vocabulary.SessionRecoveryTrigger
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Nikon's bound on one session-recovery attempt once [CameraSession.connect] returns: the
 * property bootstrap and the first live-view picture. The Swift twin is
 * `NikonSessionRecovery.attemptDeadline` in OpenCineNikon.
 */
val NIKON_RECOVERY_ATTEMPT_DEADLINE = SessionRecoveryEpisode.AttemptDeadline(attemptMs = 30_000)

/**
 * The monitor's picture clocks for session recovery, on one monotonic clock: when the last
 * live-view frame arrived from the camera and when the monitor last presented one. The app's
 * frame and present paths write it; [PictureAwareMonitorSessionRecoveryCoordinator] reads it. A returned PTP
 * control session moves neither, so it can never end recovery on its own.
 */
class MonitorPictureClock(val nowMs: () -> Long) {
    @Volatile var sourceFrameAtMs: Long? = null
        private set

    @Volatile var presentedAtMs: Long? = null
        private set

    fun noteSourceFrame() {
        sourceFrameAtMs = nowMs()
    }

    fun notePresented() {
        presentedAtMs = nowMs()
    }
}

/**
 * Owns the monitor's connection and its recovery only while [run] is active.
 *
 * A disconnected session connects at once. When an established session drops (or that first
 * connect fails) the shared [SessionRecoveryEpisode] recovers it: every attempt goes through
 * [CameraSession.connect], so identity, property, event and recording readback restart on the
 * full session path, and an attempt ends recovery only on a fresh frame and presented picture.
 * A spent budget or a storm pause waits for the operator ([retry]) across lifecycle restarts.
 */
class PictureAwareMonitorSessionRecoveryCoordinator(
    private val session: CameraSession,
    private val pictures: MonitorPictureClock,
    private val jitterSample: () -> Double = { Random.nextDouble() },
    /**
     * The device holding this session's camera now ([NikonDiscovery.currentHolder]); `null` when
     * the host has no presence lookup, so recovery asks nobody and waits for no answer.
     */
    private val currentHolder: (suspend () -> String?)? = null,
) {
    // One drop ledger per monitor session: lifecycle restarts keep it, the operator clears it.
    private val storm = SessionDropStormGuard()
    private var operatorRetry = false

    private val mutableRecoveryState =
        MutableStateFlow<SessionRecoveryUi>(SessionRecoveryUi.Idle)

    /** Drives the monitor's recovery affordance. */
    val recoveryState: StateFlow<SessionRecoveryUi> = mutableRecoveryState.asStateFlow()

    /** The operator's retry from the card: a fresh ledger, and the next [run] starts a fresh episode. */
    fun retry() {
        storm.reset()
        operatorRetry = true
    }

    /** Connects a disconnected session, then recovers drops until cancelled or handed to the operator. */
    suspend fun run(): Unit = coroutineScope {
        val held = mutableRecoveryState.value
        var trigger: SessionRecoveryTrigger? =
            when {
                operatorRetry -> SessionRecoveryTrigger.OPERATOR_RETRY
                // A lifecycle stop interrupted an automatic run: carry it on.
                held is SessionRecoveryUi.Retrying -> SessionRecoveryTrigger.DATALINK_LOST
                held.isRecovering -> return@coroutineScope // the operator decides
                else -> null
            }
        operatorRetry = false
        val port = Port(this)
        val episode =
            SessionRecoveryEpisode(
                scope = this,
                port = port,
                attemptDeadline = NIKON_RECOVERY_ATTEMPT_DEADLINE,
                timing = SessionRecoveryEpisode.Timing(pictures.nowMs, jitterSample),
                storm = storm,
            ) { snapshot ->
                // The admission snapshot (idle, picture held) is not a state to show.
                if (snapshot.state != SessionRecoveryUi.Idle || !snapshot.holdsPicture) {
                    mutableRecoveryState.value = snapshot.state
                }
            }
        while (true) {
            if (trigger == null) {
                if (session.state.value is CameraSessionState.Disconnected) session.connect()
                if (session.state.first { it !is CameraSessionState.Connecting } is CameraSessionState.Connected) {
                    mutableRecoveryState.value = SessionRecoveryUi.Idle
                    session.state.first { it !is CameraSessionState.Connected }
                }
            }
            if (!episode.begin(TARGET, trigger ?: SessionRecoveryTrigger.DATALINK_LOST, "monitor session lost")) {
                return@coroutineScope
            }
            trigger = null
            val ended = episode.snapshot.first { it.state !is SessionRecoveryUi.Retrying }
            if (ended.state != SessionRecoveryUi.Idle) return@coroutineScope // the operator decides
        }
    }

    /** The Nikon transport for the shared episode. */
    private inner class Port(private val scope: CoroutineScope) : SessionRecoveryEpisode.Port {
        private var teardown: Job? = null

        override fun observe() =
            SessionRecoveryEpisode.Observation(
                ownsConnection = true,
                progress =
                    if (session.state.value is CameraSessionState.Disconnected) {
                        SessionRecoveryEpisode.Progress.FAILED
                    } else {
                        SessionRecoveryEpisode.Progress.RUNNING
                    },
                sourceAtMs = pictures.sourceFrameAtMs,
                presentedAtMs = pictures.presentedAtMs,
            )

        override fun cleanup(kind: SessionRecoveryEpisode.Cleanup, attempt: SessionRecoveryEpisode.Attempt) {
            val retires =
                kind == SessionRecoveryEpisode.Cleanup.FAILED_ATTEMPT ||
                    kind == SessionRecoveryEpisode.Cleanup.BUDGET_EXHAUSTED
            // A control session that never produced a picture is not a monitor: close it
            // gracefully before the next attempt or the operator's decision.
            if (retires && session.state.value !is CameraSessionState.Disconnected) {
                teardown = scope.launch { session.disconnect() }
            }
        }

        override suspend fun holder(attempt: SessionRecoveryEpisode.Attempt, number: Int): String? =
            currentHolder?.let { NikonTakeOverRecovery.holder(number, it) }

        override suspend fun connect(attempt: SessionRecoveryEpisode.Attempt): Boolean {
            teardown?.join()
            teardown = null
            attempt.checkContinuation()
            // A session that came back on its own during the backoff is adopted, not duplicated.
            if (session.state.value is CameraSessionState.Disconnected) session.connect()
            return session.state.first { it !is CameraSessionState.Connecting } is CameraSessionState.Connected
        }
    }

    private companion object {
        const val TARGET = "monitor"
    }
}
