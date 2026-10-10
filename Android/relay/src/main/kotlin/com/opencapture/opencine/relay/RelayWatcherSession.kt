package com.opencapture.opencine.relay

import kotlin.math.roundToInt

/** Existing watcher cadence and presentation deadlines, independent of transport or decoder. */
public data class RelayWatcherTimingPolicy(public val pollInterval: Double = 0.25,
    public val fpsWindow: Double = 1.0, public val pictureWait: Double = 3.0,
    public val controlRequestTimeout: Double = 15.0) {
    init { require(listOf(pollInterval, fpsWindow, pictureWait, controlRequestTimeout).all { it.isFinite() && it > 0.0 }) }
}
public sealed interface RelayWatcherPhase {
    public data object Idle : RelayWatcherPhase
    public data object Connecting : RelayWatcherPhase
    public data class Reconnecting(public val attempt: Int) : RelayWatcherPhase
    public data object NeedsPasscode : RelayWatcherPhase
    public data object Live : RelayWatcherPhase
    public data class Failed(public val message: String) : RelayWatcherPhase
}
public data class RelayWatcherStatus(public val phase: RelayWatcherPhase = RelayWatcherPhase.Idle,
    public val receivedFPS: Int = 0, public val waitingForPicture: Boolean = false,
    public val controlRequested: Boolean = false)
public data class RelayWatcherRefusal(public val reason: String, public val passcodeRequired: Boolean)

/** Exact existing bounded retry policy, mirrored from Swift WatcherRelayRecovery. */
public class WatcherRelayRecovery(now: Double) {
    public enum class Action { NONE, RECONNECT, EXHAUSTED }
    public var retryCount: Int = 0
        private set
    public var retryAt: Double? = null
        private set
    private var deadline: Double? = now + JOIN_TIMEOUT
    private var pictureDeadline: Double? = null
    private var lastPicture: Double? = null
    private var stableSince: Double? = null
    private var accepted: Boolean = false
    private var stopped: Boolean = false
    public fun connected(now: Double): Unit {
        accepted = true; stableSince = null; lastPicture = null
        pictureDeadline = now + 10.0; deadline = now + SILENCE_TIMEOUT; retryAt = null
    }
    public fun received(now: Double, picture: Boolean = false): Unit {
        if (!accepted || stopped || retryAt != null) return
        deadline = now + SILENCE_TIMEOUT
        if (picture) {
            if (lastPicture == null || now - (lastPicture ?: now) > 2.0) stableSince = now
            lastPicture = now; pictureDeadline = now + SILENCE_TIMEOUT
            if (stableSince?.let { now - it >= 10.0 } == true) retryCount = 0
        }
    }
    public fun disconnected(now: Double): Action {
        if (stopped || retryAt != null) return Action.NONE
        accepted = false; stableSince = null; lastPicture = null; pictureDeadline = null; deadline = null
        if (retryCount >= MAXIMUM_RETRIES) { stopped = true; return Action.EXHAUSTED }
        retryAt = now + listOf(1.0, 2.0, 4.0)[retryCount]; retryCount += 1
        return Action.NONE
    }
    public fun tick(now: Double): Action {
        if (stopped) return Action.NONE
        if (retryAt?.let { now >= it } == true) { retryAt = null; deadline = now + JOIN_TIMEOUT; return Action.RECONNECT }
        if (pictureDeadline?.let { now >= it } == true || deadline?.let { now >= it } == true) return disconnected(now)
        return Action.NONE
    }
    public fun stop(): Unit { stopped = true; pictureDeadline = null; deadline = null; retryAt = null }
    public companion object {
        public const val MAXIMUM_RETRIES: Int = 3
        public const val JOIN_TIMEOUT: Double = 15.0
        public const val SILENCE_TIMEOUT: Double = 5.0
    }
}
public class WatcherRelayFrameFreshness {
    private var minimumOffset: Double? = null
    public fun isFallingBehind(encodedAt: Double?, receivedAt: Double): Boolean {
        if (encodedAt == null || !encodedAt.isFinite() || !receivedAt.isFinite()) return false
        val offset = receivedAt - encodedAt
        minimumOffset = minOf(minimumOffset ?: offset, offset)
        return offset - (minimumOffset ?: offset) > MAXIMUM_ADDED_DELAY
    }
    public companion object { public const val MAXIMUM_ADDED_DELAY: Double = 0.75 }
}

/** Received access units cannot refresh a deadline that requires an actual native presentation. */
public class RelayWatcherSession(public val policy: RelayWatcherTimingPolicy = RelayWatcherTimingPolicy()) {
    public var status: RelayWatcherStatus = RelayWatcherStatus()
        private set
    private var recovery: WatcherRelayRecovery? = null
    private var freshness: WatcherRelayFrameFreshness = WatcherRelayFrameFreshness()
    private var lastPictureAt: Double? = null
    private var lastPresentation: Double? = null
    private var acceptedAt: Double? = null
    private var frameCount: Int = 0
    private var fpsSince: Double = 0.0
    private var controlRequestedAt: Double? = null
    public val active: Boolean get() = recovery != null
    public fun begin(now: Double): Unit {
        status = RelayWatcherStatus(phase = RelayWatcherPhase.Connecting)
        recovery = WatcherRelayRecovery(now); freshness = WatcherRelayFrameFreshness()
        lastPictureAt = null; lastPresentation = null; acceptedAt = null
        frameCount = 0; fpsSince = now; controlRequestedAt = null
    }
    public fun beginConnection(): Unit { freshness = WatcherRelayFrameFreshness() }
    public fun connected(now: Double): Unit {
        if (!active) return
        acceptedAt = now; status = status.copy(phase = RelayWatcherPhase.Live); recovery?.connected(now)
    }
    public fun receivedState(now: Double): Unit { recovery?.received(now) }
    public fun receivedControl(now: Double): Unit {
        status = status.copy(controlRequested = false); controlRequestedAt = null; recovery?.received(now)
    }
    public fun presentedPicture(presentation: Double, now: Double): Unit {
        if (status.phase != RelayWatcherPhase.Live || !presentation.isFinite() || lastPresentation == presentation) return
        lastPresentation = presentation; lastPictureAt = now; frameCount += 1; recovery?.received(now, picture = true)
    }
    public fun admitsFrame(encodedAt: Double?, receivedAt: Double): Boolean = status.phase == RelayWatcherPhase.Live &&
        !freshness.isFallingBehind(encodedAt, receivedAt)
    public fun disconnected(now: Double): WatcherRelayRecovery.Action {
        if (!active) return WatcherRelayRecovery.Action.NONE
        val action = recovery?.disconnected(now) ?: WatcherRelayRecovery.Action.NONE
        if (action != WatcherRelayRecovery.Action.EXHAUSTED) beginReconnect()
        return action
    }
    private fun beginReconnect(): Unit {
        status = status.copy(phase = RelayWatcherPhase.Reconnecting(recovery?.retryCount ?: 1), controlRequested = false)
        acceptedAt = null
    }
    public fun tick(now: Double): WatcherRelayRecovery.Action {
        val recovery = recovery ?: return WatcherRelayRecovery.Action.NONE
        val action = recovery.tick(now)
        if (recovery.retryAt != null && status.phase !is RelayWatcherPhase.Reconnecting) beginReconnect()
        if (now - fpsSince >= policy.fpsWindow) {
            status = status.copy(receivedFPS = (frameCount / (now - fpsSince)).roundToInt())
            frameCount = 0; fpsSince = now
        }
        status = status.copy(waitingForPicture = status.phase == RelayWatcherPhase.Live &&
            now - (lastPictureAt ?: acceptedAt ?: now) >= policy.pictureWait)
        if (controlRequestedAt?.let { now - it >= policy.controlRequestTimeout } == true) {
            status = status.copy(controlRequested = false); controlRequestedAt = null
        }
        return action
    }
    public fun requestControl(now: Double): Boolean {
        if (status.phase != RelayWatcherPhase.Live || status.controlRequested) return false
        status = status.copy(controlRequested = true); controlRequestedAt = now; return true
    }
    public fun denied(passcodeRequired: Boolean, reason: String): Unit {
        stopRecovery(); status = status.copy(phase = if (passcodeRequired) RelayWatcherPhase.NeedsPasscode else RelayWatcherPhase.Failed(reason))
    }
    public fun fail(message: String): Unit { stopRecovery(); status = status.copy(phase = RelayWatcherPhase.Failed(message)) }
    public fun leave(): Unit { stopRecovery(); status = status.copy(phase = RelayWatcherPhase.Idle) }
    private fun stopRecovery(): Unit {
        recovery?.stop(); recovery = null; status = status.copy(controlRequested = false, waitingForPicture = false)
        controlRequestedAt = null
    }
}
