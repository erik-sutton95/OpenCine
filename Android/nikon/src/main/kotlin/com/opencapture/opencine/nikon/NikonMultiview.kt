package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MonitorTransfer
import kotlinx.coroutines.delay
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
    /** A Multiview member or this app's Live View holds the host: it was not dialled. */
    HOST_IN_USE,

    /** The body (by serial) is already in the group, under whatever host: closed. */
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

    /** An open link to the picked body, and its member identity (the serial from GetDeviceInfo). */
    public data class Opened<out L>(override val link: L, override val device: CameraDeviceID) : NikonMemberOpenResult<L> {
        override val refusal: NikonMemberOpenRefusal? get() = null
    }

    public data class Refused(override val refusal: NikonMemberOpenRefusal) : NikonMemberOpenResult<Nothing> {
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
 * open inside it waits out the rest before its Init.
 *
 * @param connect opens a PTP session to the host (Init, OpenSession, GetDeviceInfo).
 * @param serialNumber the serial the link's GetDeviceInfo reported.
 * @param close a graceful CloseSession, then the sockets. Never a record command.
 */
public class NikonMemberOpener<L : Any>(
    private val settle: Duration = NikonMemberTiming.RECONNECT_SETTLE,
    private val now: () -> MonotonicInstant = MonotonicInstant::now,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
    private val connect: suspend (String) -> L,
    private val serialNumber: (L) -> String?,
    close: suspend (L) -> Unit,
) {
    private val closeLink = close
    private val released = mutableMapOf<String, MonotonicInstant>()

    /**
     * Opens [host] and checks the body: refused (and closed) when it is already in the group
     * ([members]), is not the [expectedSerial] body, or reports no serial. A host in [hostsInUse] is
     * refused without a dial. A failed dial throws.
     */
    public suspend fun open(
        host: String,
        expectedSerial: String? = null,
        members: Set<CameraDeviceID>,
        hostsInUse: Set<String>,
    ): NikonMemberOpenResult<L> {
        val key = hostKey(host)
        if (hostsInUse.any { hostKey(it) == key }) return NikonMemberOpenResult.Refused(NikonMemberOpenRefusal.HOST_IN_USE)
        synchronized(released) { released[key] }?.let { releasedAt ->
            val wait = settle - (now() - releasedAt)
            if (wait.isPositive()) sleep(wait)
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
            NikonMulticamPolicy.device(expectedSerial)?.let { it != device } == true -> NikonMemberOpenRefusal.DIFFERENT_BODY
            else -> null
        }
        if (refusal != null || device == null) {
            close(link, host)
            return NikonMemberOpenResult.Refused(refusal ?: NikonMemberOpenRefusal.NO_IDENTITY)
        }
        return NikonMemberOpenResult.Opened(link, device)
    }

    /** Closes a link this opener handed out (or any link to [host]) and starts the host's settle. */
    public suspend fun close(link: L, host: String) {
        closeLink(link)
        markReleased(hostKey(host))
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
