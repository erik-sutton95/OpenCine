package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.random.Random
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive

/**
 * Injectable seam over the shared reconnect schedule, so Kotlin never owns a
 * second copy of when to retry or when to give up. Mirrors the
 * `LinkHealthBridge` pattern.
 */
fun interface SessionRetryScheduleBridge {
    /**
     * Milliseconds to wait before the next attempt after [failures]
     * consecutive failures, or `null` once the automatic budget is spent.
     */
    fun retryDelayMillis(failures: Int, jitter: Double): Long?

    /** The shared automatic-attempt budget, for a truthful "attempt N of M". */
    fun maxAutomaticAttempts(): Int = DEFAULT_MAX_AUTOMATIC_ATTEMPTS

    /**
     * Records one drop of an established session in the shared drop-storm
     * ledger; `true` = pause automatic recovery for the operator. Success is
     * exactly what a storm fakes well, so the per-run failure budget cannot
     * catch it — only this cross-run count can.
     */
    fun noteSessionDrop(): Boolean = false

    /** Drops inside the storm window, for the operator-facing count. */
    fun dropsInStormWindow(): Int = 0

    /** Operator action (retry, disconnect, fresh connect) starts a fresh ledger. */
    fun resetDropStormGuard() {}

    companion object {
        /**
         * Shown only when the core is unavailable, in which case no camera work
         * is possible anyway and [ProductionSessionRetryScheduleBridge] stops
         * immediately — this exists so the label never renders as "of 0".
         */
        const val DEFAULT_MAX_AUTOMATIC_ATTEMPTS: Int = 1
    }
}

/**
 * Production schedule: `SessionRecoveryPolicy.monitor` in the Swift core.
 *
 * Without the core there is no camera stack at all, so the honest answer is to
 * stop rather than invent a Kotlin-side fallback schedule that could drift from
 * the shared one.
 */
object ProductionSessionRetryScheduleBridge : SessionRetryScheduleBridge {
    override fun retryDelayMillis(failures: Int, jitter: Double): Long? {
        if (!NikonNative.isAvailable) return null
        val millis = NikonNative.sessionRetryDelayMillis(failures, jitter)
        return if (millis < 0) null else millis
    }

    override fun maxAutomaticAttempts(): Int =
        if (NikonNative.isAvailable) {
            NikonNative.sessionMaxAutomaticAttempts()
        } else {
            SessionRetryScheduleBridge.DEFAULT_MAX_AUTOMATIC_ATTEMPTS
        }

    override fun noteSessionDrop(): Boolean =
        NikonNative.isAvailable && NikonNative.sessionNoteSessionDrop()

    override fun dropsInStormWindow(): Int =
        if (NikonNative.isAvailable) NikonNative.sessionDropsInStormWindow() else 0

    override fun resetDropStormGuard() {
        if (NikonNative.isAvailable) NikonNative.sessionResetDropStormGuard()
    }
}

/**
 * Owns reconnection only while its monitor coroutine is active.
 *
 * Every attempt calls [CameraSession.connect], so identity, property, event,
 * and recording readback all restart through the existing full session path.
 * The retry cadence and the give-up point come from the shared core through
 * [SessionRetryScheduleBridge]; this class only sequences them and publishes
 * what the operator should be told.
 */
class MonitorSessionRecoveryCoordinator(
    private val session: CameraSession,
    private val schedule: SessionRetryScheduleBridge = ProductionSessionRetryScheduleBridge,
    private val jitterSample: () -> Double = { Random.nextDouble() },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    init {
        // A fresh monitor entry starts a fresh storm ledger (parity with iOS, which resets on
        // operator connect and disconnect): the ledger is process-static in the facade and must
        // not carry drops across a deliberate exit-and-return.
        schedule.resetDropStormGuard()
    }

    private val mutableRecoveryState =
        MutableStateFlow<SessionRecoveryUi>(SessionRecoveryUi.Idle)

    /** Drives the monitor's recovery affordance. */
    val recoveryState: StateFlow<SessionRecoveryUi> = mutableRecoveryState.asStateFlow()

    /** Connects immediately, then recovers unexpected disconnections until cancelled. */
    suspend fun run(): Unit {
        mutableRecoveryState.value = SessionRecoveryUi.Idle
        var firstConnection = true
        var consecutiveFailures = 0
        while (currentCoroutineContext().isActive) {
            when (session.state.value) {
                is CameraSessionState.Connected -> {
                    firstConnection = false
                    consecutiveFailures = 0
                    mutableRecoveryState.value = SessionRecoveryUi.Idle
                    session.state.first { it !is CameraSessionState.Connected }
                    // An established session just dropped. If drops keep clustering while every
                    // reconnect succeeds (the storm signature — `consecutiveFailures` above
                    // resets on success and can never catch it), pause instead of churning the
                    // body's PTP stack toward its battery-pull wedge.
                    if (schedule.noteSessionDrop()) {
                        mutableRecoveryState.value =
                            SessionRecoveryUi.PausedAfterDrops(
                                schedule.dropsInStormWindow()
                            )
                        return
                    }
                }

                CameraSessionState.Connecting -> {
                    firstConnection = false
                    session.state.first { it !is CameraSessionState.Connecting }
                }

                CameraSessionState.Disconnected -> {
                    if (firstConnection) {
                        firstConnection = false
                    } else {
                        val wait = schedule.retryDelayMillis(consecutiveFailures, jitterSample())
                        if (wait == null) {
                            // Budget spent. Stop burning the radio on a camera that is not coming
                            // back and hand the decision to the operator (retry, or leave the
                            // monitor) instead of retrying forever behind a static "No camera".
                            mutableRecoveryState.value =
                                SessionRecoveryUi.WaitingForOperator(consecutiveFailures)
                            return
                        }
                        mutableRecoveryState.value =
                            SessionRecoveryUi.Retrying(
                                attempt = consecutiveFailures + 1,
                                maxAttempts = schedule.maxAutomaticAttempts(),
                            )
                        sleep(wait)
                        consecutiveFailures += 1
                        currentCoroutineContext().ensureActive()
                        if (session.state.value !is CameraSessionState.Disconnected) continue
                    }
                    session.connect()
                }
            }
        }
    }
}
