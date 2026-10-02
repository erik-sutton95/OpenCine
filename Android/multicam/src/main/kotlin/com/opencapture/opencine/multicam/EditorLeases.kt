package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ControlLeaseID
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MonotonicInstant
import java.util.UUID

/** One editor lease. */
@JvmInline public value class EditorLeaseID(public val uuid: UUID = UUID.randomUUID())

/**
 * A settings or detail view's borrowed right to command one entry's camera. It names the session,
 * control epoch and authority it was opened under; when any of them changes the lease retires,
 * so a queued edit can never reach a replacement camera or link. Opening a detail view never
 * opens a second camera link.
 */
@ConsistentCopyVisibility
public data class EditorLease internal constructor(
    public val id: EditorLeaseID,
    public val entry: MonitorEntryID,
    public val session: CameraSessionID,
    public val epoch: ControlEpoch,
    /** The remote control lease the session held, `null` when this device owns the link. */
    public val authority: ControlLeaseID?,
)

public enum class EditorLeaseRefusal {
    NOT_MEMBER,
    NO_CAMERA_SESSION,
    NO_COMMAND_AUTHORITY,
    NOT_REPORTED,

    /** Closed, replaced by a newer lease for the entry, or its session, epoch or authority changed. */
    RETIRED,
}

public class EditorLeaseException(public val refusal: EditorLeaseRefusal) : Exception(refusal.name)

/**
 * The open editor leases, at most one per entry. The app keeps this value with its other
 * presentation state and asks it before every submit. Mutable and unsynchronized: confine it to
 * that owner.
 */
public class EditorLeases {
    private val active = LinkedHashMap<MonitorEntryID, EditorLease>()

    public val leases: List<EditorLease> get() = active.values.toList()

    /**
     * Opens a lease on the entry's current session, retiring any earlier lease for the entry.
     *
     * @throws EditorLeaseException
     */
    public fun open(entry: MonitorEntryID, group: MulticamGroup, state: MulticamSnapshot): EditorLease {
        active.remove(entry)
        val descriptor = group[entry] ?: refuse(EditorLeaseRefusal.NOT_MEMBER)
        val session = descriptor.cameraSession ?: refuse(EditorLeaseRefusal.NO_CAMERA_SESSION)
        val snapshot = state.cameras[session] ?: refuse(EditorLeaseRefusal.NOT_REPORTED)
        if (!descriptor.controlAuthority.commands || !snapshot.authority.commands) {
            refuse(EditorLeaseRefusal.NO_COMMAND_AUTHORITY)
        }
        val lease = EditorLease(EditorLeaseID(), entry, session, snapshot.epoch, snapshot.authority.leaseID)
        active[entry] = lease
        return lease
    }

    /** Retires the entry's lease. Queued edits under it are refused from now on. Never sends a camera command. */
    public fun close(entry: MonitorEntryID) {
        active.remove(entry)
    }

    public fun closeAll() {
        active.clear()
    }

    /**
     * Retires every lease that no longer holds and returns them, so the app can drop their
     * queued edits and close their views.
     */
    public fun retireStale(group: MulticamGroup, state: MulticamSnapshot): List<EditorLease> {
        val stale = active.values.filter { refusal(it, group, state) != null }
        for (lease in stale) active.remove(lease.entry)
        return stale
    }

    /**
     * The command for [intent] under [lease], carrying the current snapshot's preconditions.
     * Call it when the edit is about to be submitted, not when it is queued. The session's own
     * admission still applies (read-only settings, stale capabilities, domains).
     *
     * @throws EditorLeaseException
     */
    public fun command(
        intent: CameraCommandIntent,
        lease: EditorLease,
        group: MulticamGroup,
        state: MulticamSnapshot,
        deadline: MonotonicInstant? = null,
    ): CameraCommand {
        refusal(lease, group, state)?.let(::refuse)
        return CameraCommand(intent, CommandPreconditions(state.cameras.getValue(lease.session), deadline))
    }

    /**
     * Why [lease] no longer holds, or `null` while it does. An app whose existing command path
     * asks "may this editor send now?" calls this at send time.
     */
    public fun refusal(lease: EditorLease, group: MulticamGroup, state: MulticamSnapshot): EditorLeaseRefusal? {
        val entry = group[lease.entry]
        val snapshot = state.cameras[lease.session]
        val holds = active[lease.entry] == lease && entry != null && entry.cameraSession == lease.session &&
            entry.controlAuthority.commands && snapshot != null && snapshot.epoch == lease.epoch &&
            snapshot.authority.commands && snapshot.authority.leaseID == lease.authority
        return if (holds) null else EditorLeaseRefusal.RETIRED
    }

    private fun refuse(refusal: EditorLeaseRefusal): Nothing = throw EditorLeaseException(refusal)
}
