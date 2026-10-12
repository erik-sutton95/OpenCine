package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.MonitorEntryID

/**
 * Record all and a tile's own record press, the same in every app: one policy, one plan rule, one
 * submission and the operator's words for what came back. A group press is coordinated dispatch
 * with per-camera confirmation, never "sync" or "genlock".
 */
public object RecordAll {
    /**
     * Strict: when any requested camera cannot record (no live view, busy, lent to Live View, a
     * mode that cannot record), nothing is commanded, so one press never leaves some cameras
     * rolling and others not by surprise.
     */
    public val POLICY: TargetPolicy = TargetPolicy.STRICT

    /** Stop when any requested camera reports recording, else start. */
    public fun plan(
        requested: List<MonitorEntryID>,
        recording: (MonitorEntryID) -> Boolean,
        group: MulticamGroup,
        state: MulticamSnapshot,
    ): RecordPlan = RecordPlan.make(
        if (requested.any(recording)) RecordDirection.STOP else RecordDirection.START, POLICY, requested, group, state,
    )

    /**
     * Revalidates and sends an approved plan, then waits for every camera's outcome. `null`: the
     * plan is stale or refused and nothing was sent ([CHANGED]). A partial result is never
     * compensated; stopping a camera that started is a separate operator action.
     */
    public suspend fun run(
        plan: RecordPlan,
        group: MulticamGroup,
        state: MulticamSnapshot,
        sessions: Map<CameraSessionID, CameraSession>,
    ): RecordResult? = try {
        plan.submit(group, state, sessions).finished(sessions)
    } catch (_: RecordSubmissionException) {
        null
    }

    /** While a group press runs. */
    public fun progress(direction: RecordDirection): String =
        if (direction == RecordDirection.START) "Starting cameras…" else "Stopping cameras…"

    /** On each commanded camera until its outcome arrives. */
    public const val WAITING: String = "Waiting for camera confirmation"

    /** A camera, link or mode changed after the operator approved: nothing was sent. */
    public const val CHANGED: String = "Cameras changed · try again"

    /** One camera's note for its record outcome; `null` leaves the tile as it is (superseded). */
    public fun note(outcome: TargetOutcome, direction: RecordDirection): String? = when (outcome) {
        TargetOutcome.Confirmed -> if (direction == RecordDirection.START) "Recording" else "Recording stopped"
        is TargetOutcome.Rejected ->
            if (outcome.rejection == CommandRejection.CameraRefused) "Recording command rejected · check camera"
            else "Not sent · check camera"
        is TargetOutcome.Failed -> "Not sent · check camera"
        TargetOutcome.Superseded -> null
        else -> "No confirmation · check camera"
    }

    /** The group line: every target confirmed and every camera in the requested state, or how many did. */
    public fun summary(result: RecordResult, allMatch: Boolean): String {
        val start = result.plan.direction == RecordDirection.START
        val targets = result.plan.targets.size
        return if (result.confirmed == targets && allMatch) {
            if (start) "Recording on ${result.confirmed} cameras" else "Recording stopped"
        } else {
            "${result.confirmed} of $targets confirmed · check camera tiles"
        }
    }
}
