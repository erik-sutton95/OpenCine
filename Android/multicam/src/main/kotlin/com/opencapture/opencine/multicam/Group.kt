package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.Freshness
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryError
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.StreamID
import kotlin.time.Duration

/**
 * What the engine evaluates against at one instant. The app gathers it from the sessions and
 * media runtime it owns; the engine never subscribes to a session or holds a runtime object.
 */
public class MulticamSnapshot(
    cameras: List<CameraSnapshot> = emptyList(),
    /** Health of each picture stream the app runs. */
    public val pictures: Map<StreamID, PictureHealth> = emptyMap(),
    /**
     * Entries with an app-side step still running (a connection step, an earlier record
     * operation). Group commands exclude them.
     */
    public val busy: Set<MonitorEntryID> = emptySet(),
    /** The shared host clock ([MonotonicInstant.now]), the reference every session stamps on. */
    public val now: MonotonicInstant = MonotonicInstant.now(),
) {
    /** Latest snapshot of each live camera session (the last one wins for a repeated session). */
    public val cameras: Map<CameraSessionID, CameraSnapshot> = cameras.associateBy { it.session }
}

public sealed interface MulticamGroupError {
    public data class InvalidEntry(public val error: MonitorEntryError) : MulticamGroupError
    public data class DuplicateEntry(public val entry: MonitorEntryID) : MulticamGroupError
    public data class UnknownEntry(public val entry: MonitorEntryID) : MulticamGroupError
}

public class MulticamGroupException(public val error: MulticamGroupError) : Exception(error.toString())

/**
 * Membership in slot order plus the staged (large) entry. Slots are [MonitorEntryID]s, so
 * reordering, staging, rotation and replacing an entry's picture or session keep them.
 *
 * Removing an entry only changes membership. The app owns the entry's session and picture;
 * closing them never stops a camera's recording (Core `CameraSession.close`).
 *
 * Mutable and unsynchronized, like a Swift `mutating` struct held by one owner: confine it to
 * that owner. [entries] is replaced on every change, so a list read earlier never changes.
 */
public class MulticamGroup {
    public var entries: List<MonitorEntryDescriptor> = emptyList()
        private set
    public var stage: MonitorEntryID? = null
        private set

    public operator fun get(id: MonitorEntryID): MonitorEntryDescriptor? = entries.firstOrNull { it.id == id }

    /**
     * Adds [entry] at [index] (default: last). Capacity is not checked here: the app's
     * qualification limit is a [ResourceBudget] value applied by [ResourceAdmission].
     *
     * @throws MulticamGroupException
     */
    public fun add(entry: MonitorEntryDescriptor, index: Int? = null) {
        validate(entry)
        if (get(entry.id) != null) throw MulticamGroupException(MulticamGroupError.DuplicateEntry(entry.id))
        entries = entries.toMutableList().apply { add((index ?: size).coerceIn(0, size), entry) }
    }

    /**
     * Replaces an entry's picture, session, authority or name in place, keeping its slot.
     *
     * @throws MulticamGroupException
     */
    public fun update(entry: MonitorEntryDescriptor) {
        validate(entry)
        val index = entries.indexOfFirst { it.id == entry.id }
        if (index < 0) throw MulticamGroupException(MulticamGroupError.UnknownEntry(entry.id))
        entries = entries.toMutableList().apply { set(index, entry) }
    }

    public fun remove(id: MonitorEntryID) {
        entries = entries.filter { it.id != id }
        if (stage == id) stage = null
    }

    /** @throws MulticamGroupException */
    public fun move(id: MonitorEntryID, index: Int) {
        val from = entries.indexOfFirst { it.id == id }
        if (from < 0) throw MulticamGroupException(MulticamGroupError.UnknownEntry(id))
        entries = entries.toMutableList().apply {
            val entry = removeAt(from)
            add(index.coerceIn(0, size), entry)
        }
    }

    /**
     * Stages an entry (or none). Staging never touches sessions or pictures.
     *
     * @throws MulticamGroupException
     */
    public fun setStage(id: MonitorEntryID?) {
        if (id != null && get(id) == null) throw MulticamGroupException(MulticamGroupError.UnknownEntry(id))
        stage = id
    }

    /**
     * Per-entry and aggregate state, with picture health, control-link health, telemetry
     * freshness and reported recording kept apart. [telemetryMaxAge] is the app's freshness
     * window.
     */
    public fun summary(state: MulticamSnapshot, telemetryMaxAge: Duration): GroupSummary =
        GroupSummary(entries.map { EntrySummary(it, state, telemetryMaxAge) })

    private fun validate(entry: MonitorEntryDescriptor) {
        entry.validationError()?.let { throw MulticamGroupException(MulticamGroupError.InvalidEntry(it)) }
    }
}

/** One role of an entry: not part of it, part of it with no report yet, or reported. */
public sealed interface RoleStatus<out T> {
    public data object Absent : RoleStatus<Nothing>
    public data object Unreported : RoleStatus<Nothing>
    public data class Reported<out T>(public val value: T) : RoleStatus<T>
}

public data class EntrySummary(
    public val entry: MonitorEntryID,
    public val session: CameraSessionID?,
    public val picture: RoleStatus<PictureHealth>,
    public val control: RoleStatus<ConnectionState>,
    /** Age of the newest camera report. [Freshness.UNKNOWN] without a session report. */
    public val telemetry: Freshness,
    /** Camera-reported only. A failed picture or a pending command never changes it. */
    public val recording: ObservedValue<RecordingState>,
) {
    public companion object {
        public operator fun invoke(
            entry: MonitorEntryDescriptor,
            state: MulticamSnapshot,
            telemetryMaxAge: Duration,
        ): EntrySummary {
            val snapshot = entry.cameraSession?.let { state.cameras[it] }
            // ponytail: newest of the common observations; a snapshot-level "last report" instant
            // in Core would be exact (proposed Core change).
            val newest = snapshot?.let {
                listOfNotNull(
                    it.mode.observedAt, it.recording.observedAt, it.power.battery.observedAt, it.storage.observedAt,
                ).maxOrNull()
            }
            return EntrySummary(
                entry = entry.id,
                session = entry.cameraSession,
                picture = entry.picture?.let { picture ->
                    state.pictures[picture.stream]?.let { RoleStatus.Reported(it) } ?: RoleStatus.Unreported
                } ?: RoleStatus.Absent,
                control = when {
                    entry.cameraSession == null -> RoleStatus.Absent
                    snapshot == null -> RoleStatus.Unreported
                    else -> RoleStatus.Reported(snapshot.connection)
                },
                telemetry = when {
                    newest == null -> Freshness.UNKNOWN
                    state.now - newest <= telemetryMaxAge -> Freshness.FRESH
                    else -> Freshness.STALE
                },
                recording = snapshot?.recording ?: ObservedValue.unknown,
            )
        }
    }
}

public data class GroupSummary(public val entries: List<EntrySummary>) {
    /** Distinct cameras reporting recording; two entries showing one camera count once. */
    public val camerasRecording: Int get() = cameras { it.recording.value == RecordingState.RECORDING }

    /** Distinct cameras whose recording state is unknown. Never counted as idle. */
    public val camerasRecordingUnknown: Int get() = cameras { !it.recording.isKnown }
    public val camerasReady: Int get() = cameras { it.control == RoleStatus.Reported(ConnectionState.Ready) }
    public val livePictures: Int get() = entries.count { it.picture == RoleStatus.Reported(PictureHealth.LIVE) }
    public val staleTelemetry: Int get() = cameras { it.telemetry == Freshness.STALE }

    private fun cameras(include: (EntrySummary) -> Boolean): Int =
        entries.filter(include).mapNotNull { it.session }.toSet().size
}
