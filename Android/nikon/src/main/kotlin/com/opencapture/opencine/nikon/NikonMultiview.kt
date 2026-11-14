package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MonitorTransfer
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// Shared Multiview prep (roadmap Plan 6): what a Pocket-standard Multiview needs from the Nikon
// integration, as plain values and lambdas. Plan 6 wraps them in the app shell's Multiview seams;
// nothing here names that shell. Swift twins: `NikonMultiview.swift`, same names.

/** Timing a Multiview member link keeps (Swift `NikonMemberTiming`). */
public object NikonMemberTiming {
    /**
     * After a link to a host closes (CloseSession, a dropped socket or a failed dial), the next Init
     * to that host waits this long: the ZR can hold the PTP slot briefly after a close, and an Init
     * inside that window tips a reconnect into a wedge (OpenZCine's reconnect settle, 1200 ms).
     */
    public val RECONNECT_SETTLE: Duration = 1_200.milliseconds

    /**
     * The least time between two automatic reopen attempts of one member after a failed reopen: the
     * saved-profile busy handoff's settle, the gentlest re-Init cadence the integration uses.
     */
    public val REOPEN_SPACING: Duration = 5.seconds
}

/** Why [NikonMemberOpener] did not hand back a link (Swift `NikonMemberOpenRefusal`). */
public enum class NikonMemberOpenRefusal {
    /**
     * A Multiview member or this app's Live View holds the host, or an open of it is in flight: it
     * was not dialled.
     */
    HOST_IN_USE,

    /**
     * Another device (the result's `heldBy`) holds the body now: it was not dialled, because a body
     * that takes one initiator hands its session to a new Init (a ZR drops the phone).
     */
    HELD_BY_ANOTHER_DEVICE,

    /**
     * The body (by serial) is already in the group, under whatever host: closed. This guards the
     * group's identity, not the member's session: the check runs after the Init, so only
     * `hostsInUse` keeps a live member's session from being dropped.
     */
    ALREADY_MEMBER,

    /** The host answered with another body than the one picked: closed. */
    DIFFERENT_BODY,

    /** The body reported no serial, so the group cannot tell it from a member: closed. */
    NO_IDENTITY,
}

/** Swift `NikonMemberOpenResult`. */
public sealed interface NikonMemberOpenResult<out L> {
    public val link: L?
    public val device: CameraDeviceID?
    public val refusal: NikonMemberOpenRefusal?

    /** The device that holds the body, for a [NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE] refusal. */
    public val heldBy: String?

    /** An open link to the picked body, and its member identity (the serial from GetDeviceInfo). */
    public data class Opened<out L>(override val link: L, override val device: CameraDeviceID) : NikonMemberOpenResult<L> {
        override val refusal: NikonMemberOpenRefusal? get() = null
        override val heldBy: String? get() = null
    }

    /** Refused; [heldBy] names the holding device for [NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE]. */
    public data class Refused(
        override val refusal: NikonMemberOpenRefusal,
        override val heldBy: String? = null,
    ) : NikonMemberOpenResult<Nothing> {
        override val link: Nothing? get() = null
        override val device: CameraDeviceID? get() = null
    }
}

/**
 * Opens the one body the operator picked from Multiview's Add camera, or the member a repair
 * reopens, and checks who it is (Swift `NikonMemberOpener`). It dials nothing else: never a host in
 * use, and never a host it was not asked to open. The link and its open, serial and close are the
 * app's (Android: a session over [NikonNative]).
 *
 * Every close or failed dial of a host starts that host's [NikonMemberTiming.RECONNECT_SETTLE]; an
 * open inside it waits out the rest before its Init. One open per host at a time: a second open of a
 * host whose open is in flight is refused [NikonMemberOpenRefusal.HOST_IN_USE] (one opener per group).
 *
 * @param currentHolder the device serving the host now, from a fresh presence sweep
 *   ([NikonDiscovery.currentHolder]), or null. Asked right before every Init.
 * @param connect opens a PTP session to the host (Init, OpenSession, GetDeviceInfo).
 * @param serialNumber the serial the link's GetDeviceInfo reported.
 * @param close a graceful CloseSession, then the sockets. Never a record command.
 */
public class NikonMemberOpener<L : Any>(
    private val settle: Duration = NikonMemberTiming.RECONNECT_SETTLE,
    private val now: () -> MonotonicInstant = MonotonicInstant::now,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
    private val currentHolder: suspend (String) -> String?,
    private val connect: suspend (String) -> L,
    private val serialNumber: (L) -> String?,
    close: suspend (L) -> Unit,
) {
    private val closeLink = close
    private val released = mutableMapOf<String, MonotonicInstant>()
    private val opening = mutableSetOf<String>()

    /**
     * Opens the picked [host] and checks the body: refused (and closed) when it is already in the
     * group ([members]), is not the [expectedSerial] body, or reports no serial. Refused without a
     * dial when [hostsInUse] has the host, an open of it is in flight, or another device holds it.
     * A failed dial throws.
     */
    public suspend fun open(
        host: String,
        expectedSerial: String? = null,
        members: Set<CameraDeviceID>,
        hostsInUse: Set<String>,
    ): NikonMemberOpenResult<L> = open(host, NikonMulticamPolicy.device(expectedSerial), members, hostsInUse)

    /**
     * A repair's reopen of [member] at its own [host], with the group's own sets: that host is not in
     * use against the member itself, and its serial is not "already in the group". Every other rule
     * of [open] holds, and the body must be [member].
     */
    public suspend fun reopen(
        member: CameraDeviceID,
        host: String,
        members: Set<CameraDeviceID>,
        hostsInUse: Set<String>,
    ): NikonMemberOpenResult<L> {
        val key = hostKey(host)
        return open(host, member, members - member, hostsInUse.filterTo(mutableSetOf()) { hostKey(it) != key })
    }

    private suspend fun open(
        host: String,
        expected: CameraDeviceID?,
        members: Set<CameraDeviceID>,
        hostsInUse: Set<String>,
    ): NikonMemberOpenResult<L> {
        val key = hostKey(host)
        if (hostsInUse.any { hostKey(it) == key } || !synchronized(released) { opening.add(key) }) {
            return NikonMemberOpenResult.Refused(NikonMemberOpenRefusal.HOST_IN_USE)
        }
        try {
            return openReserved(host, key, expected, members)
        } finally {
            synchronized(released) { opening.remove(key) }
        }
    }

    private suspend fun openReserved(
        host: String,
        key: String,
        expected: CameraDeviceID?,
        members: Set<CameraDeviceID>,
    ): NikonMemberOpenResult<L> {
        synchronized(released) { released[key] }?.let { releasedAt ->
            val wait = settle - (now() - releasedAt)
            if (wait.isPositive()) sleep(wait)
        }
        currentHolder(host)?.let { holder ->
            return NikonMemberOpenResult.Refused(NikonMemberOpenRefusal.HELD_BY_ANOTHER_DEVICE, heldBy = holder)
        }
        val link = try {
            connect(host)
        } catch (error: Throwable) {
            markReleased(key)
            throw error
        }
        val device = NikonMulticamPolicy.device(serialNumber(link))
        val refusal = when {
            device == null -> NikonMemberOpenRefusal.NO_IDENTITY
            device in members -> NikonMemberOpenRefusal.ALREADY_MEMBER
            expected != null && expected != device -> NikonMemberOpenRefusal.DIFFERENT_BODY
            else -> null
        }
        if (refusal != null || device == null) {
            close(link, host)
            return NikonMemberOpenResult.Refused(refusal ?: NikonMemberOpenRefusal.NO_IDENTITY)
        }
        return NikonMemberOpenResult.Opened(link, device)
    }

    /**
     * Closes a link this opener handed out (or any link to [host]) and starts the host's settle. The
     * close runs to the end even if the caller is cancelled: a half-closed session holds the PTP slot.
     */
    public suspend fun close(link: L, host: String) {
        try {
            withContext(NonCancellable) { closeLink(link) }
        } finally {
            markReleased(hostKey(host))
        }
    }

    private fun markReleased(key: String) {
        val time = now()
        synchronized(released) { released[key] = time }
    }

    private fun hostKey(host: String): String = NikonHosts.normalizedHost(host) ?: host
}

/** A movie tone a Nikon Z body records in (Swift `NikonMovieTone`), by its label. */
public enum class NikonMovieTone(public val label: String) {
    SDR("SDR"),
    HLG("HLG"),
    N_LOG("N-Log"),

    /** R3D NE records RED Log3G10 only. */
    LOG3G10("Log3G10"),
    ;

    /**
     * The neutral transfer this tone records in, the value an Auto LUT lookup keys on. It names the
     * recording, not the live-view pixels.
     */
    public val monitorTransfer: MonitorTransfer
        get() = when (this) {
            SDR -> MonitorTransfer.REC709
            HLG -> MonitorTransfer.HDR
            N_LOG -> MonitorTransfer.NLOG
            LOG3G10 -> MonitorTransfer.LOG3G10
        }

    public companion object {
        /** The tone a label names, or null for an unknown or missing label. */
        public fun fromLabel(label: String?): NikonMovieTone? = entries.firstOrNull { it.label == label }
    }
}

/**
 * The member's recording tone for Multiview's Auto LUT (Swift `NikonRecordingTone`): the tone the
 * active codec records, as the Swift session decided it from `MovFileType` and the per-codec tone
 * properties it polls in its live-monitor round robin. Read it from `reportedCameraProperties`.
 * Unknown is null, never SDR.
 */
public val CameraPropertySnapshot.recordingTone: NikonMovieTone?
    get() = NikonMovieTone.fromLabel(movieTone)

/**
 * One Multiview member's automatic repair ladder (Swift `NikonMemberRepair`): the coordinator ticks
 * it. Bounded automatic steps, each paid from the caller's budget (the coordinator's recovery
 * budget):
 *
 * 1. A stream that stops on a live link ([MISSED_FRAMES_FOR_STALL] frame deadlines missed, or a
 *    watchdog stall) restarts live view in place once per episode: no re-Init.
 * 2. A lost link, a failed restart, or a stall after the restart reopens the member: close the old
 *    link, then [NikonMemberOpener.reopen] of the member at its host. Not before the settle after
 *    the loss (the opener's own settle counts from the close, so a reopen after a stall can wait
 *    both), and not before the reopen spacing after a failed reopen.
 * 3. The budget refusing, or another device holding the body ([takenOver], from the opener's
 *    HELD_BY_ANOTHER_DEVICE or [NikonDiscovery.currentHolder]), waits for the operator. A take-over
 *    during an in-flight reopen leaves that reopen's link to the caller to close.
 *
 * A step that has not reported back ([attemptSucceeded] / [attemptFailed]) by [attemptDeadline]
 * failed: a dial into a vanished network can block past every cancellation, and the tile must still
 * reach the next rung or the operator's Reconnect. A late report is then ignored.
 *
 * A picture ([frameArrived]) ends the episode.
 */
public class NikonMemberRepair(
    private val settle: Duration = NikonMemberTiming.RECONNECT_SETTLE,
    private val reopenSpacing: Duration = NikonMemberTiming.REOPEN_SPACING,
    private val attemptDeadline: Duration = NIKON_RECOVERY_ATTEMPT_DEADLINE.attemptMs.milliseconds,
) {
    public sealed interface Step {
        /** Nothing to do now (healthy, or an attempt is in flight). */
        public data object None : Step

        /** Stop and start live view on the member's current link. */
        public data object RestartLiveView : Step

        /** Close the member's link and open its host again with the identity check. */
        public data object Reopen : Step

        /** Tick again at this instant; no attempt was spent. */
        public data class Wait(val until: MonotonicInstant) : Step

        /** No automatic step remains: the tile offers Reconnect. */
        public data class WaitForOperator(val reason: WaitReason) : Step
    }

    public enum class WaitReason { BUDGET_SPENT, TAKEN_OVER }

    public companion object {
        /** Frame deadlines missed in a row that make a stall (today's member pump threshold). */
        public const val MISSED_FRAMES_FOR_STALL: Int = 3
    }

    private sealed interface Phase {
        data object Streaming : Phase
        data object Stalled : Phase
        data class Lost(val since: MonotonicInstant, val reopenFailedAt: MonotonicInstant?) : Phase
        data class Attempting(val step: Step, val since: MonotonicInstant) : Phase
        data class WaitingForOperator(val reason: WaitReason) : Phase
    }

    private var phase: Phase = Phase.Streaming
    private var misses = 0
    private var restartedThisEpisode = false

    /** A picture arrived: the episode is over. */
    public fun frameArrived() {
        if (phase is Phase.WaitingForOperator) return
        phase = Phase.Streaming
        misses = 0
        restartedThisEpisode = false
    }

    /** A frame deadline passed without a picture. */
    public fun frameMissed(at: MonotonicInstant) {
        if (phase != Phase.Streaming) return
        misses += 1
        if (misses >= MISSED_FRAMES_FOR_STALL) streamStalled(at)
    }

    /** The stream is judged stalled (the miss count, or a watchdog verdict). */
    public fun streamStalled(at: MonotonicInstant) {
        if (phase == Phase.Streaming || (phase as? Phase.Attempting)?.step == Step.RestartLiveView) {
            misses = 0
            phase = if (restartedThisEpisode) Phase.Lost(at, null) else Phase.Stalled
        }
    }

    /** The link is gone: the camera closed it, the socket failed, or a command found it dead. */
    public fun linkLost(at: MonotonicInstant) {
        val current = phase
        when {
            current is Phase.WaitingForOperator || current is Phase.Lost -> return
            current is Phase.Attempting && current.step == Step.Reopen -> attemptFailed(at)
            else -> phase = Phase.Lost(at, null)
        }
    }

    /** Another device holds the body now: no automatic step may take it back. */
    public fun takenOver() {
        phase = Phase.WaitingForOperator(WaitReason.TAKEN_OVER)
    }

    /**
     * The step [next] returned has run and its link is up (live view restarted, or the member
     * reopened and attached); a picture still has to arrive to end the episode.
     */
    public fun attemptSucceeded() {
        val attempting = phase as? Phase.Attempting ?: return
        if (attempting.step == Step.Reopen) restartedThisEpisode = false
        phase = Phase.Streaming
        misses = 0
    }

    /** The step [next] returned failed. */
    public fun attemptFailed(at: MonotonicInstant) {
        val attempting = phase as? Phase.Attempting ?: return
        phase = Phase.Lost(at, if (attempting.step == Step.Reopen) at else null)
    }

    /** The operator's Reconnect (or Remove): a fresh ladder. */
    public fun reset() {
        phase = Phase.Streaming
        misses = 0
        restartedThisEpisode = false
    }

    /**
     * The step to take [at] this instant. [beginAttempt] is asked once before every restart or
     * reopen and never for a wait; refusing it ends the automatic ladder.
     */
    public fun next(at: MonotonicInstant, beginAttempt: () -> Boolean): Step {
        (phase as? Phase.Attempting)?.let { if (at >= it.since + attemptDeadline) attemptFailed(at) }
        return when (val current = phase) {
            Phase.Streaming, is Phase.Attempting -> Step.None
            is Phase.WaitingForOperator -> Step.WaitForOperator(current.reason)
            Phase.Stalled -> if (!beginAttempt()) {
                waitForOperator()
            } else {
                restartedThisEpisode = true
                phase = Phase.Attempting(Step.RestartLiveView, at)
                Step.RestartLiveView
            }
            is Phase.Lost -> {
                var earliest = current.since + settle
                current.reopenFailedAt?.let { earliest = maxOf(earliest, it + reopenSpacing) }
                when {
                    at < earliest -> Step.Wait(earliest)
                    !beginAttempt() -> waitForOperator()
                    else -> {
                        phase = Phase.Attempting(Step.Reopen, at)
                        Step.Reopen
                    }
                }
            }
        }
    }

    private fun waitForOperator(): Step {
        phase = Phase.WaitingForOperator(WaitReason.BUDGET_SPENT)
        return Step.WaitForOperator(WaitReason.BUDGET_SPENT)
    }
}
