package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CapabilityRevision
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.rejection
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlin.time.Duration

public enum class RecordDirection {
    START,
    STOP,
    ;

    /** Always an explicit intent: a blind toggle is never sent (plan 5.4). */
    public val intent: CameraCommandIntent
        get() = if (this == START) CameraCommandIntent.StartRecording else CameraCommandIntent.StopRecording
}

public enum class TargetPolicy {
    /** Every requested entry must be eligible; otherwise nothing is commanded. */
    STRICT,

    /** Command the eligible cameras and show the exclusions. */
    ELIGIBLE_SUBSET,
}

public sealed interface ExclusionReason {
    public data object NotMember : ExclusionReason

    /** Picture-only entry (capture device, relay picture): nothing to command. */
    public data object NoCameraSession : ExclusionReason

    /** No requested entry of this camera holds owner or lease authority. */
    public data object NoCommandAuthority : ExclusionReason

    /** The camera session has not reported a snapshot. */
    public data object NotReported : ExclusionReason

    /** The app is still running a step for this entry. */
    public data object Busy : ExclusionReason

    /** The camera itself reports it is starting or stopping. */
    public data object CameraTransitioning : ExclusionReason

    /**
     * Core's shared admission rule ([CameraSnapshot.rejection]), or
     * [CommandRejection.RecordingStateUnknown] when the camera has not reported whether it records.
     */
    public data class Rejected(public val rejection: CommandRejection) : ExclusionReason
}

public data class Exclusion(public val entry: MonitorEntryID, public val reason: ExclusionReason)

/**
 * What one target's admission rested on. Routine telemetry (battery, storage, setting values,
 * snapshot revisions and timestamps) is deliberately absent, so it never invalidates a plan.
 * A replacement session, a new control epoch, changed capabilities (availability included),
 * changed authority, a mode change or a changed reported recording state do.
 */
@ConsistentCopyVisibility
public data class AdmissionFingerprint private constructor(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch,
    public val capabilityRevision: CapabilityRevision,
    public val authority: ControlAuthority,
    public val mode: CaptureMode?,
    public val recording: RecordingState?,
) {
    public constructor(snapshot: CameraSnapshot) : this(
        snapshot.session, snapshot.epoch, snapshot.capabilities.revision, snapshot.authority,
        snapshot.mode.value, snapshot.recording.value,
    )
}

/**
 * One camera control session and every requested entry showing it. They share one command and
 * its result.
 */
@ConsistentCopyVisibility
public data class RecordTarget internal constructor(
    public val session: CameraSessionID,
    public val entries: List<MonitorEntryID>,
    public val fingerprint: AdmissionFingerprint,
)

public enum class RecordSubmissionError {
    /** Strict policy with exclusions, or no camera to command. */
    NOT_EXECUTABLE,

    /**
     * The state changed since the plan was made (for example a replacement session). Nothing
     * was sent; make a new plan and show it again.
     */
    STALE,
}

public class RecordSubmissionException(public val error: RecordSubmissionError) : Exception(error.name)

/**
 * A group start or stop, resolved before anything is sent (plan 8.2). [make] is a pure function
 * of the operation-relevant state, so the plan is stable under routine telemetry and
 * revalidation is "rebuild and compare".
 */
@ConsistentCopyVisibility
public data class RecordPlan internal constructor(
    public val direction: RecordDirection,
    public val policy: TargetPolicy,
    public val requested: List<MonitorEntryID>,
    /** Cameras that will be commanded, one per control session, in slot order. */
    public val targets: List<RecordTarget>,
    /** Cameras already reporting the requested state: counted, never commanded. */
    public val satisfied: List<RecordTarget>,
    public val exclusions: List<Exclusion>,
) {
    /** Strict policy with any exclusion: nothing is commanded and the exclusions explain why. */
    public val isRefused: Boolean get() = policy == TargetPolicy.STRICT && exclusions.isNotEmpty()
    public val isExecutable: Boolean get() = !isRefused && targets.isNotEmpty()

    /**
     * Whether the plan the operator approved still describes the cameras now: same members,
     * sessions, epochs, capabilities, authority, modes, reported recording and exclusions.
     */
    public fun isCurrent(group: MulticamGroup, state: MulticamSnapshot): Boolean =
        make(direction, policy, requested, group, state) == this

    /**
     * Revalidates against fresh state, then submits each target's explicit start or stop, at
     * most [maxConcurrent] at a time. Sends nothing else.
     *
     * @param deadline how long a command stays valid, as [CommandPreconditions.deadline].
     * @throws RecordSubmissionException nothing was sent.
     */
    public suspend fun submit(
        group: MulticamGroup,
        state: MulticamSnapshot,
        sessions: Map<CameraSessionID, CameraSession>,
        deadline: Duration? = null,
        maxConcurrent: Int = 4,
    ): RecordSubmission {
        if (!isExecutable) throw RecordSubmissionException(RecordSubmissionError.NOT_EXECUTABLE)
        if (!isCurrent(group, state)) throw RecordSubmissionException(RecordSubmissionError.STALE)
        val commands = targets.map { target ->
            CameraCommand(
                direction.intent,
                CommandPreconditions(state.cameras.getValue(target.session), deadline?.let { state.now + it }),
            )
        }
        val permits = Semaphore(maxOf(maxConcurrent, 1))
        val receipts = coroutineScope {
            targets.zip(commands).map { (target, command) ->
                async {
                    val session = sessions[target.session]
                    // No runtime for this target: report it honestly, never skip silently.
                    target.session to (
                        session?.let { permits.withPermit { it.submit(command) } }
                            ?: CommandReceipt(
                                command.operation, target.session, command.intent,
                                CommandStage.Failed(CommandFailure.NOT_SENT),
                            )
                        )
                }
            }.awaitAll().toMap()
        }
        return RecordSubmission(
            this, targets.map { it.session }.zip(commands.map { it.operation }).toMap(), receipts,
        )
    }

    public companion object {
        public fun make(
            direction: RecordDirection,
            policy: TargetPolicy,
            entries: List<MonitorEntryID>,
            group: MulticamGroup,
            state: MulticamSnapshot,
        ): RecordPlan {
            val requested = entries
            val exclusions = mutableListOf<Exclusion>()
            val bySession = LinkedHashMap<CameraSessionID, MutableList<MonitorEntryDescriptor>>()
            for (id in requested.distinct()) {
                val entry = group[id]
                if (entry == null) {
                    exclusions += Exclusion(id, ExclusionReason.NotMember)
                    continue
                }
                val session = entry.cameraSession
                if (session == null) {
                    exclusions += Exclusion(id, ExclusionReason.NoCameraSession)
                    continue
                }
                bySession.getOrPut(session) { mutableListOf() } += entry
            }

            val targets = mutableListOf<RecordTarget>()
            val satisfied = mutableListOf<RecordTarget>()
            for ((session, members) in bySession) {
                val ids = members.map { it.id }
                fun exclude(reason: ExclusionReason) {
                    exclusions += ids.map { Exclusion(it, reason) }
                }
                if (members.none { it.controlAuthority.commands }) {
                    exclude(ExclusionReason.NoCommandAuthority)
                    continue
                }
                val snapshot = state.cameras[session]
                if (snapshot == null) {
                    exclude(ExclusionReason.NotReported)
                    continue
                }
                if (ids.any { it in state.busy }) {
                    exclude(ExclusionReason.Busy)
                    continue
                }
                val probe = CameraCommand(direction.intent, CommandPreconditions(snapshot))
                val rejection = snapshot.rejection(probe, state.now)
                if (rejection != null) {
                    exclude(ExclusionReason.Rejected(rejection))
                    continue
                }
                // A camera that has not reported its recording state cannot be sorted into target or
                // already-satisfied, and a later report could not be told from the approved state.
                if (!snapshot.recording.isKnown) {
                    exclude(ExclusionReason.Rejected(CommandRejection.RecordingStateUnknown))
                    continue
                }
                val target = RecordTarget(session, ids, AdmissionFingerprint(snapshot))
                val recording = snapshot.recording.value
                when {
                    recording == RecordingState.TRANSITIONING -> exclude(ExclusionReason.CameraTransitioning)
                    direction == RecordDirection.START && recording == RecordingState.RECORDING ||
                        direction == RecordDirection.STOP && recording == RecordingState.IDLE -> satisfied += target
                    else -> targets += target
                }
            }
            // Requested order for display, whichever pass excluded the entry.
            val position = HashMap<MonitorEntryID, Int>()
            requested.forEachIndexed { index, id -> position.putIfAbsent(id, index) }
            return RecordPlan(
                direction, policy, requested, targets, satisfied,
                exclusions.sortedBy { position.getValue(it.entry) },
            )
        }
    }
}

/** One command's progress as a group result reports it. */
public sealed interface TargetOutcome {
    /** Admitted or sent, no answer yet. */
    public data object Pending : TargetOutcome

    /** The protocol accepted it; the camera has not reported the new state yet. */
    public data object Accepted : TargetOutcome
    public data object Confirmed : TargetOutcome
    public data class Rejected(public val rejection: CommandRejection) : TargetOutcome
    public data class Failed(public val failure: CommandFailure) : TargetOutcome
    public data object TimedOut : TargetOutcome

    /** The camera may have acted but the link was lost. */
    public data object OutcomeUnknown : TargetOutcome

    /**
     * Replaced before its outcome was known: a newer operation, or the entry now shows a
     * replacement session that this result must not touch.
     */
    public data object Superseded : TargetOutcome

    public companion object {
        public operator fun invoke(stage: CommandStage): TargetOutcome = when (stage) {
            CommandStage.Created, CommandStage.Admitted, CommandStage.Sent -> Pending
            CommandStage.Accepted, CommandStage.AwaitingObservation -> Accepted
            CommandStage.Confirmed -> Confirmed
            is CommandStage.Rejected -> Rejected(stage.rejection)
            is CommandStage.Failed ->
                if (stage.failure == CommandFailure.SUPERSEDED) Superseded else Failed(stage.failure)
            CommandStage.TimedOut -> TimedOut
            CommandStage.OutcomeUnknown -> OutcomeUnknown
        }
    }
}

/**
 * Per-target outcomes of one submitted plan. Partial success is not a transaction: nothing here
 * (or anywhere in the engine) stops a camera because another failed. Compensation is a separate
 * explicit operator intent.
 */
public data class RecordResult(
    public val plan: RecordPlan,
    public val outcomes: Map<CameraSessionID, TargetOutcome>,
) {
    public val confirmed: Int get() = outcomes.values.count { it == TargetOutcome.Confirmed }

    /**
     * The outcome for one entry, mapped back through its target. An entry that now shows a
     * different session gets [TargetOutcome.Superseded], so a late result never lands on a
     * replacement.
     */
    public fun outcome(entry: MonitorEntryID, group: MulticamGroup): TargetOutcome? {
        val target = plan.targets.firstOrNull { entry in it.entries } ?: return null
        if (group[entry]?.cameraSession != target.session) return TargetOutcome.Superseded
        return outcomes[target.session]
    }
}

/** The commands a plan sent, by target session. */
public data class RecordSubmission(
    public val plan: RecordPlan,
    public val operations: Map<CameraSessionID, OperationID>,
    /** Each receipt as `submit` returned it. */
    public val receipts: Map<CameraSessionID, CommandReceipt>,
) {
    /** Outcomes now, without waiting. */
    public fun current(sessions: Map<CameraSessionID, CameraSession>): RecordResult {
        val outcomes = receipts.mapValuesTo(LinkedHashMap()) { TargetOutcome(it.value.stage) }
        for ((id, operation) in operations) {
            sessions[id]?.receipt(operation)?.let { outcomes[id] = TargetOutcome(it.stage) }
        }
        return RecordResult(plan, outcomes)
    }

    /**
     * Suspends until every target finishes. The integration enforces timeouts and the command
     * deadline; the engine runs no timer of its own.
     */
    public suspend fun finished(sessions: Map<CameraSessionID, CameraSession>): RecordResult {
        val outcomes = receipts.mapValuesTo(LinkedHashMap()) { TargetOutcome(it.value.stage) }
        coroutineScope {
            operations.mapNotNull { (id, operation) ->
                sessions[id]?.let { session -> async { id to session.outcome(operation) } }
            }.awaitAll()
        }.forEach { (id, receipt) -> receipt?.let { outcomes[id] = TargetOutcome(it.stage) } }
        return RecordResult(plan, outcomes)
    }
}

/** Owner or lease: this entry may command its session. */
internal val ControlAuthority.commands: Boolean
    get() = when (this) {
        ControlAuthority.Owner, is ControlAuthority.Lease -> true
        ControlAuthority.ReadOnly, is ControlAuthority.Unavailable -> false
    }
