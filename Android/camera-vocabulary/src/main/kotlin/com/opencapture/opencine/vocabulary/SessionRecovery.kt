package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.RetryBackoff

/**
 * Whether an interrupted camera session is being recovered, and how the operator is told.
 *
 * The monitor stays up on the last frame, automatic retries run bounded, and when the
 * budget is spent the operator, not the app, decides what happens next.
 */
sealed class SessionRecoveryUi {
    data object Idle : SessionRecoveryUi()

    /** An automatic reconnect is running (or waiting out its backoff). [attempt] is 1-based. */
    data class Retrying(val attempt: Int, val maxAttempts: Int) : SessionRecoveryUi()

    /** The automatic budget is spent. The operator chooses: retry, or leave the monitor. */
    data class WaitingForOperator(val attemptsMade: Int) : SessionRecoveryUi()

    /** Reconnects kept succeeding but the session kept dying young. */
    data class PausedAfterDrops(val drops: Int) : SessionRecoveryUi()

    /**
     * Another device now holds the camera ([holder], when it names itself). Reconnecting would
     * take the camera back from it, so automatic recovery stops and the operator decides.
     */
    data class TakenOver(val holder: String?) : SessionRecoveryUi()

    val isRecovering: Boolean get() = this !is Idle

    /**
     * An automatic reconnect is actually running (Swift `isReconnecting`). A taken-over, paused
     * or spent recovery waits for the operator and must not say it is reconnecting.
     */
    val isReconnecting: Boolean get() = this is Retrying

    /**
     * Whether this device may still tell other devices it holds the camera (Swift
     * `claimsCamera`): a live session and a running reconnect keep the claim, a device that
     * stopped reconnecting has given the camera up (hardware pass 4.1).
     */
    val claimsCamera: Boolean get() = this is Idle || this is Retrying
}

/** Cross-run damping for sessions that reconnect cleanly but keep dying. */
class SessionDropStormGuard {
    private val dropTimesMs = ArrayList<Long>()

    fun noteDrop(nowMs: Long): Boolean {
        dropTimesMs.add(nowMs)
        dropTimesMs.removeAll { nowMs - it > WINDOW_MS }
        return dropTimesMs.size >= PAUSE_AFTER_DROPS
    }

    val dropsInWindow: Int get() = dropTimesMs.size

    fun reset() {
        dropTimesMs.clear()
    }

    companion object {
        const val WINDOW_MS = 120_000L
        const val PAUSE_AFTER_DROPS = 3
    }
}

sealed class SessionRecoveryDecision {
    data class Retry(val afterMs: Long) : SessionRecoveryDecision()

    data object Stop : SessionRecoveryDecision()
}

enum class SessionRecoveryTrigger {
    BLE_DROPPED,
    SOFTAP_LOST,
    /** Watchdog's last rung (new handshake) missed while SoftAP was still up. */
    DATALINK_LOST,
    OPERATOR_RETRY,
    FEED_WATCHDOG,
    COMMAND_TIMEOUT,
    FIRST_PICTURE,
}

/**
 * Jittered exponential backoff for reconnect retries.
 * Attempt 0 is [baseMs]; each step doubles up to [maxMs].
 */
class ReconnectBackoff(
    val baseMs: Long = 500,
    val maxMs: Long = 8_000,
    val multiplier: Double = 2.0,
    val jitterFraction: Double = 0.3,
) {
    fun delayMs(attempt: Int, jitter: Double): Long {
        val jittered = RetryBackoff(
            initialDelay = baseMs.toDouble(),
            maximumDelay = maxMs.toDouble(),
            multiplier = multiplier,
            jitterFraction = jitterFraction,
        ).delay(attempt, jitter)
        // Keep the legacy millisecond truncation and exact Long cap at this boundary.
        return minOf(maxMs, maxOf(0L, jittered.toLong()))
    }
}

/**
 * Shared reconnect rule: when to retry a dropped camera session, how long to back off,
 * and when to stop and ask the operator.
 */
class SessionRecoveryPolicy(
    val backoff: ReconnectBackoff = ReconnectBackoff(),
    val maxAutomaticAttempts: Int = 8,
) {
    /**
     * Retry at once, then 0.5s → 8s jittered, giving up after 8 attempts.
     * Long enough to ride out a camera power cycle; short enough that a
     * camera that is gone stops burning the radio.
     */
    fun decision(afterFailedAttempts: Int, jitter: Double): SessionRecoveryDecision {
        val failed = maxOf(0, afterFailedAttempts)
        if (failed >= maxAutomaticAttempts) return SessionRecoveryDecision.Stop
        if (failed == 0) return SessionRecoveryDecision.Retry(0)
        return SessionRecoveryDecision.Retry(backoff.delayMs(failed - 1, jitter))
    }

    fun state(afterFailedAttempts: Int): SessionRecoveryUi {
        val failed = maxOf(0, afterFailedAttempts)
        if (failed >= maxAutomaticAttempts) {
            return SessionRecoveryUi.WaitingForOperator(failed)
        }
        return SessionRecoveryUi.Retrying(attempt = failed + 1, maxAttempts = maxAutomaticAttempts)
    }

    companion object {
        const val AUTOMATIC_RECOVERY_BUDGET_MS = 180_000L
        const val ADVERTISEMENT_SCAN_BUDGET_MS = 30_000L
        val monitor = SessionRecoveryPolicy()

        fun shouldBegin(trigger: SessionRecoveryTrigger): Boolean =
            when (trigger) {
                SessionRecoveryTrigger.BLE_DROPPED,
                SessionRecoveryTrigger.SOFTAP_LOST,
                SessionRecoveryTrigger.DATALINK_LOST,
                SessionRecoveryTrigger.OPERATOR_RETRY,
                -> true
                SessionRecoveryTrigger.FEED_WATCHDOG,
                SessionRecoveryTrigger.COMMAND_TIMEOUT,
                SessionRecoveryTrigger.FIRST_PICTURE,
                -> false
            }
    }
}

/** A likely cause the host can name when a session keeps dropping. Any camera can report it. */
enum class SessionDropSuspect {
    /** Another phone or tablet may be scanning for or connecting to the same camera. */
    OTHER_DEVICE_SCANNING,
}

/** Operator-facing recovery copy. Never names a sister app or another brand. */
object SessionRecoveryCopy {
    const val RETRY_CONNECTION = "Retry connection"
    const val OPERATOR_MENU = "Operator menu"
    const val HELD_FRAME_BADGE = "NO LINK"

    fun title(state: SessionRecoveryUi): String =
        when (state) {
            SessionRecoveryUi.Idle -> ""
            is SessionRecoveryUi.Retrying -> "Reconnecting…"
            is SessionRecoveryUi.WaitingForOperator -> "Camera disconnected"
            is SessionRecoveryUi.PausedAfterDrops -> "Connection keeps dropping"
            is SessionRecoveryUi.TakenOver -> "Camera taken over"
        }

    /** [dropSuspect] names a likely cause for repeated drops; only the paused case reads it. */
    fun detail(state: SessionRecoveryUi, deviceName: String, dropSuspect: SessionDropSuspect? = null): String {
        val name = deviceName.trim()
        val camera = if (name.isEmpty()) "The camera" else name
        return when (state) {
            SessionRecoveryUi.Idle -> ""
            // The episode ends on its time budget, usually before maxAttempts: "attempt 1 of 8"
            // followed by "after 3 tries" read as two machines (hardware pass 5.1).
            is SessionRecoveryUi.Retrying ->
                "$camera dropped off. Holding the last frame, attempt ${state.attempt}. " +
                    "Reconnecting for up to ${SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS / 60_000} minutes."
            is SessionRecoveryUi.WaitingForOperator -> {
                val tries = if (state.attemptsMade == 1) "1 try" else "${state.attemptsMade} tries"
                "$camera didn't come back after $tries. Turn the camera off and on, then tap Retry. The frame below is held, not live."
            }
            is SessionRecoveryUi.PausedAfterDrops ->
                when (dropSuspect) {
                    null ->
                        "$camera reconnected but dropped ${state.drops} times in quick succession. Automatic retries are paused to protect the camera. The frame below is held, not live."
                    SessionDropSuspect.OTHER_DEVICE_SCANNING ->
                        "$camera reconnected but dropped ${state.drops} times in quick succession. Automatic retries are paused to protect the camera, since another device may be scanning for cameras. The frame below is held, not live."
                }
            is SessionRecoveryUi.TakenOver -> {
                val other = state.holder?.trim()?.takeIf(String::isNotEmpty) ?: "Another device"
                "$other connected to ${name.ifEmpty { "the camera" }}, so this device stopped reconnecting. Retry takes the camera back. The frame below is held, not live."
            }
        }
    }
}

/** A handshake/status packet cannot dismiss the held-frame warning. */
object RecoveryPictureProof {
    fun isFresh(startedAt: Long, now: Long, presentedAt: Long?, accessUnitAt: Long?): Boolean =
        presentedAt != null && accessUnitAt != null &&
            presentedAt >= startedAt && accessUnitAt >= startedAt &&
            now - presentedAt in 0 until 2_000 && now - accessUnitAt in 0 until 2_000
}

/** Total episode cap covers scan, BLE, Wi-Fi, handshake, picture and backoff. */
suspend fun withinAutomaticRecoveryBudget(work: suspend () -> Unit): Boolean =
    kotlinx.coroutines.withTimeoutOrNull(SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS) {
        work()
        true
    } ?: false

/** Scan has its own bound; later stages retain their camera-specific deadlines. */
suspend fun <Camera : Any> recoverAfterAdvertisement(
    scan: suspend () -> Camera?,
    reconnect: suspend (Camera) -> Boolean,
): Boolean {
    val camera = kotlinx.coroutines.withTimeoutOrNull(SessionRecoveryPolicy.ADVERTISEMENT_SCAN_BUDGET_MS) {
        scan()
    } ?: return false
    return reconnect(camera)
}
