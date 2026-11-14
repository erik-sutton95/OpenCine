package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MultiviewMemberLink
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.PictureSourceDescriptor
import com.opencapture.opencine.core.PowerStatus
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.multicam.MulticamGroup
import com.opencapture.opencine.multicam.MulticamSnapshot
import com.opencapture.opencine.multicam.RecordAll
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import kotlinx.coroutines.delay
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * What the app reads from its camera for one tile; the coordinator adds what the stage owns
 * (tally, notes, status, actions). Swift twin: `MultiviewTileReadings`.
 */
public data class MultiviewTileReadings(
    val name: String,
    val model: String = "",
    val format: String = "",
    val storage: String = MultiviewTally.UNAVAILABLE,
    val timecode: String? = null,
    val readouts: List<MultiviewReadout> = emptyList(),
    /** The camera's take length, null while it reports none. */
    val recordingSeconds: Int? = null,
    val power: PowerStatus? = null,
    /** A picture has arrived on the member's current link. */
    val hasPicture: Boolean,
    val accessibilityValue: String = "",
)

/**
 * A record command's confirmation window on one camera: a refusal ends it, the camera's own newer
 * report of the asked state confirms it, the window closing leaves it unconfirmed. Nothing is
 * resent. Swift twin: `MultiviewRecordConfirmation`.
 */
public object MultiviewRecordConfirmation {
    public enum class Outcome {
        CONFIRMED,
        REFUSED,

        /** The window closed, or the link was replaced, without a confirmation. */
        UNCONFIRMED,
    }

    /** The stage's window: a reply or a matching report within 8 s. */
    public val WINDOW: Duration = 8.seconds

    /**
     * Polls every 100 ms until the window closes on [clock] (milliseconds). Cancelling the caller
     * ends the wait with its cancellation (Swift returns `unconfirmed`).
     * @param current the command's link is still the member's.
     * @param reply the camera's reply to the command so far: true accepted, false refused.
     * @param report the camera's latest take report.
     * @param acknowledged called once when the camera accepted the command.
     */
    public suspend fun wait(
        start: Boolean,
        sentAtMillis: Long,
        clock: () -> Long,
        current: () -> Boolean,
        reply: () -> Boolean?,
        report: () -> MultiviewRecordReport?,
        acknowledged: () -> Unit,
        window: Duration = WINDOW,
    ): Outcome {
        val deadline = clock() + window.inWholeMilliseconds
        var accepted = false
        while (clock() < deadline) {
            delay(100.milliseconds)
            if (!current()) return Outcome.UNCONFIRMED
            reply()?.let { answer ->
                if (!answer) return Outcome.REFUSED
                if (!accepted) {
                    accepted = true
                    acknowledged()
                }
            }
            val latest = report()
            if (latest != null && latest.receivedAtMillis > sentAtMillis && latest.recording == start) {
                return Outcome.CONFIRMED
            }
        }
        return Outcome.UNCONFIRMED
    }
}

/** The camera's last reported take state on [slot], null until it reported one. */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.recordingActive(
    slot: Int,
): Boolean? = links[slot].recordReport?.recording

public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.anyRecording: Boolean
    get() = members.indices.any { members[it].camera != null && recordingActive(it) == true }

/** Slots with a camera, in order. */
public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.memberSlots: List<Int>
    get() = members.indices.filter { members[it].camera != null }

public val <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.canRecordTogether: Boolean
    get() = !busy && !groupRecordingBusy && recordPlan(null).isExecutable

private fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.entry(
    slot: Int,
): MonitorEntryDescriptor? {
    val camera = members[slot].camera ?: return null
    val name = describe(camera).name
    return MonitorEntryDescriptor(
        id = members[slot].entryID,
        name = name,
        picture = PictureSourceDescriptor(stream = members[slot].stream, label = name),
        cameraSession = links[slot].session.id,
        telemetry = TelemetrySource.CAMERA_SESSION,
        controlAuthority = ControlAuthority.Owner,
    )
}

/**
 * The engine's view of [slots] (default: every member), in slot order. A one-member view equals the
 * full view for that member's plans and leases.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.multicamGroup(
    slots: List<Int>? = null,
): MulticamGroup {
    val group = MulticamGroup()
    for (slot in slots ?: memberSlots) entry(slot)?.let { runCatching { group.add(it) } }
    return group
}

public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.multicamSnapshot(
    slots: List<Int>? = null,
): MulticamSnapshot {
    val chosen = (slots ?: memberSlots).filter { members[it].camera != null }
    return MulticamSnapshot(
        cameras = chosen.map { links[it].session.snapshots.value },
        pictures = chosen.associate { members[it].stream to links[it].pictureHealth },
        busy = chosen.filter { members[it].recordingBusy || members[it].connecting || members[it].recovering }
            .map { members[it].entryID }.toSet(),
        now = monotonic(),
    )
}

/**
 * The operator's record press as an explicit strict plan: stop when any requested camera reports
 * recording, else start. `slot == null` is every member.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.recordPlan(
    slot: Int?,
): RecordPlan {
    val requested = slot?.let { listOf(it) } ?: memberSlots
    return RecordAll.plan(
        requested.map { members[it].entryID },
        recording = { id -> requested.any { members[it].entryID == id && recordingActive(it) == true } },
        group = multicamGroup(requested),
        state = multicamSnapshot(requested),
    )
}

/** The record plan for every member (`null`) or one slot, with what blocks it now. */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.recordContext(
    slot: Int?,
): MultiviewRecordContext = MultiviewRecordContext(recordPlan(slot), busy = busy || groupRecordingBusy, closing = closing)

/**
 * Sends an approved plan: one explicit start or stop per camera, revalidated first, each outcome on
 * its own member. A partial result is never compensated.
 */
public suspend fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.record(
    plan: RecordPlan,
    together: Boolean,
) {
    if (busy || closing || groupRecordingBusy) return
    if (together) {
        groupRecordingBusy = true
        groupRecordingNote = RecordAll.progress(plan.direction)
    }
    try {
        val sessions = linkedMapOf<CameraSessionID, CameraSession>()
        for (slot in memberSlots) sessions.putIfAbsent(links[slot].session.id, links[slot].session)
        val result = RecordAll.run(plan, multicamGroup(), multicamSnapshot(), sessions)
        if (result == null) {
            // Stale: a camera, link or mode changed after the operator approved.
            if (together) groupRecordingNote = RecordAll.CHANGED
            return
        }
        val group = multicamGroup()
        for (member in members) {
            val outcome = result.outcome(member.entryID, group) ?: continue
            member.recordingNote = RecordAll.note(outcome, plan.direction) ?: continue
        }
        if (!together) return
        val start = plan.direction == RecordDirection.START
        val allMatch = memberSlots.all { members[it].recordingAvailable && recordingActive(it) == start }
        groupRecordingNote = RecordAll.summary(result, allMatch)
    } finally {
        if (together) groupRecordingBusy = false
    }
}

/**
 * The stage's values for [slot], null while it is empty: the app's readings with the tally, notes,
 * status and options the stage owns.
 */
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCoordinator<Camera, Link>.tile(
    slot: Int,
    readings: MultiviewTileReadings,
): MultiviewTile? {
    val member = members[slot]
    val camera = member.camera ?: return null
    val preview = policy.hasPreview(camera)
    val settled = !busy && !member.connecting && !member.recovering
    val recording = recordingActive(slot)
    val actions = mutableListOf(
        MultiviewCameraAction(
            MultiviewCameraAction.LIVE_VIEW, "Live View",
            enabled = member.controlHost != null && !member.recovering,
        ),
        MultiviewCameraAction(
            MultiviewCameraAction.RECORD, if (recording == true) "Stop recording" else "Start recording",
            MultiviewCameraAction.Kind.RECORD,
            enabled = member.recordingAvailable && !member.recordingBusy && !groupRecordingBusy && !closing,
        ),
        MultiviewCameraAction(
            MultiviewCameraAction.LUT, if (member.lutEnabled) "Disable Auto LUT" else "Enable Auto LUT",
            enabled = preview,
        ),
    )
    if (preview || member.failureMessage != null) {
        actions += MultiviewCameraAction(MultiviewCameraAction.RECONNECT, "Reconnect", enabled = settled, closes = true)
    }
    if (member.failureMessage != null && !member.experimental && member.identity == null) {
        actions += MultiviewCameraAction(
            MultiviewCameraAction.EXPERIMENTAL, "Try experimental shared Wi-Fi", enabled = settled, closes = true,
        )
    }
    actions += MultiviewCameraAction(
        MultiviewCameraAction.REMOVE, "Remove camera", MultiviewCameraAction.Kind.DESTRUCTIVE,
        enabled = !(busy || member.connecting || groupRecordingBusy || member.recordingBusy || closing),
    )
    val note = member.recordingNote
    val showsStatus = !readings.hasPicture || member.failureMessage != null || member.recovering
    return MultiviewTile(
        name = readings.name,
        model = readings.model,
        format = readings.format,
        storage = readings.storage,
        timecode = readings.timecode,
        tally = MultiviewTally.text(
            recording, readings.recordingSeconds, waiting = member.recordingBusy, holding = member.recovering,
            failed = member.failureMessage != null,
        ),
        recording = recording == true,
        lut = member.lutEnabled,
        note = note,
        tileNote = MultiviewTile.tileNote(note),
        readouts = readings.readouts,
        status = if (showsStatus) {
            MultiviewTileStatus(
                text = when {
                    member.recovering -> "Restoring picture…"
                    member.failureMessage == null -> member.status
                    else -> "Connection failed · Options"
                },
                detail = member.failureMessage ?: member.status,
                inProgress = member.recovering || (member.failureMessage == null && !member.networkVerified),
            )
        } else {
            null
        },
        detail = member.status,
        failure = member.failureMessage,
        footnote = if (member.networkVerified && !preview) {
            "Remove this camera to enable group recording for your other cameras."
        } else {
            null
        },
        actions = actions,
        accessibilityValue = readings.accessibilityValue,
    ).withPower(readings.power)
}
