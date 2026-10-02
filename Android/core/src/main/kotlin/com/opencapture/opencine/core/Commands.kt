package com.opencapture.opencine.core

/**
 * What the operator wants. Recording uses explicit start and stop: a blind toggle sent across a
 * delayed link can undo its own successful retry. A UI toggle resolves to start or stop from a
 * fresh snapshot before it becomes an intent.
 */
public sealed interface CameraCommandIntent {
    public data class Set(public val value: SettingValue) : CameraCommandIntent
    public data object StartRecording : CameraCommandIntent
    public data object StopRecording : CameraCommandIntent

    /** Normalized 0..1 coordinates in the displayed picture. */
    public data class FocusPoint(public val x: Double, public val y: Double) : CameraCommandIntent

    public val key: SettingKey
        get() = when (this) {
            is Set -> value.key
            StartRecording, StopRecording -> SettingKey.RECORDING
            is FocusPoint -> SettingKey.FOCUS_POINT
        }
}

/**
 * The assumptions a command was created under. Admission rejects the command when any of them
 * no longer holds, so a queued edit cannot reach a replacement link, a changed capability set or
 * a lapsed lease. Stream generation is deliberately absent: only operations that depend on one
 * picture stream need it, and none in this vocabulary do.
 */
public data class CommandPreconditions(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch,
    public val capabilityRevision: CapabilityRevision,
    /** Must equal the session's current lease (`null` for an owner). */
    public val lease: ControlLeaseID? = null,
    public val deadline: MonotonicInstant? = null,
) {
    /** The assumptions of an operator looking at [snapshot] right now. */
    public constructor(snapshot: CameraSnapshot, deadline: MonotonicInstant? = null) : this(
        snapshot.session, snapshot.epoch, snapshot.capabilities.revision, snapshot.authority.leaseID, deadline,
    )
}

public data class CameraCommand(
    public val intent: CameraCommandIntent,
    public val preconditions: CommandPreconditions,
    /** Resubmitting a known operation returns its receipt and never acts twice. */
    public val operation: OperationID = OperationID(),
)

public sealed interface CommandRejection {
    public data object SessionClosed : CommandRejection
    public data object WrongSession : CommandRejection
    public data object NotConnected : CommandRejection
    public data object StaleEpoch : CommandRejection
    public data object DeadlinePassed : CommandRejection
    public data object NoAuthority : CommandRejection
    public data object AuthorityExpired : CommandRejection
    public data object StaleCapabilities : CommandRejection
    public data object SupportUnknown : CommandRejection
    public data object Unsupported : CommandRejection
    public data object ReadOnly : CommandRejection
    public data class Unavailable(public val reason: UnavailableReason) : CommandRejection
    public data object OutOfDomain : CommandRejection

    /**
     * The adapter cannot express the intent safely without knowing the reported state, for
     * example when its wire command is a toggle.
     */
    public data object RecordingStateUnknown : CommandRejection

    /** The camera refused the command (protocol NACK). */
    public data object CameraRefused : CommandRejection
}

public enum class CommandFailure {
    /** The camera accepted, but its readback shows the value did not change. */
    NOT_APPLIED,

    /** The command never left the device. */
    NOT_SENT,

    /**
     * A newer write to the same setting replaced this one before its outcome was known. The
     * camera may or may not have acted on it; the newer operation's receipt carries the outcome.
     */
    SUPERSEDED,
}

/**
 * ```text
 * created -> admitted -> sent -> accepted -> awaitingObservation -> confirmed
 *               \-> rejected      \-> failed / timedOut / outcomeUnknown
 * ```
 * Not every protocol has every stage. [Accepted] means the protocol took the request, not that
 * the camera reports the new value. [OutcomeUnknown] means the camera may have acted but the
 * link was lost. A timeout never manufactures a reported state.
 */
public sealed interface CommandStage {
    public data object Created : CommandStage
    public data object Admitted : CommandStage
    public data object Sent : CommandStage
    public data object Accepted : CommandStage
    public data object AwaitingObservation : CommandStage
    public data object Confirmed : CommandStage
    public data class Rejected(public val rejection: CommandRejection) : CommandStage
    public data class Failed(public val failure: CommandFailure) : CommandStage
    public data object TimedOut : CommandStage
    public data object OutcomeUnknown : CommandStage

    public val isTerminal: Boolean
        get() = when (this) {
            Created, Admitted, Sent, Accepted, AwaitingObservation -> false
            Confirmed, is Rejected, is Failed, TimedOut, OutcomeUnknown -> true
        }
}

/** Progress of one operation, tracked by [OperationID] apart from the snapshot feed. */
public data class CommandReceipt(
    public val operation: OperationID,
    public val session: CameraSessionID,
    public val intent: CameraCommandIntent,
    public val stage: CommandStage = CommandStage.Created,
    /** From the setting's semantics at submission. */
    public val confirmation: SettingSemantics.Confirmation = SettingSemantics.Confirmation.READBACK,
) {
    /** Terminal, or accepted where the camera only acknowledges. */
    public val isFinished: Boolean
        get() = stage.isTerminal ||
            (stage == CommandStage.Accepted && confirmation == SettingSemantics.Confirmation.ACKNOWLEDGEMENT_ONLY)
}

/**
 * The shared admission rule: why [command] cannot run against this snapshot at [now], or `null`
 * when it may. Integrations apply it at submission (a control enabled a second ago is not
 * authorization now) and add their own protocol rules after it. Multicam can use it to evaluate
 * group eligibility without knowing the integration.
 */
public fun CameraSnapshot.rejection(command: CameraCommand, now: MonotonicInstant): CommandRejection? {
    val expected = command.preconditions
    if (connection is ConnectionState.Disconnected) return CommandRejection.SessionClosed
    if (expected.session != session) return CommandRejection.WrongSession
    if (connection != ConnectionState.Ready) return CommandRejection.NotConnected
    if (expected.epoch != epoch) return CommandRejection.StaleEpoch
    expected.deadline?.let { if (now >= it) return CommandRejection.DeadlinePassed }
    if (expected.lease != authority.leaseID) return CommandRejection.NoAuthority
    when (val authority = authority) {
        ControlAuthority.Owner -> Unit
        is ControlAuthority.Lease ->
            authority.lease.expiresAt?.let { if (now >= it) return CommandRejection.AuthorityExpired }
        ControlAuthority.ReadOnly, is ControlAuthority.Unavailable -> return CommandRejection.NoAuthority
    }
    if (expected.capabilityRevision != capabilities.revision) return CommandRejection.StaleCapabilities

    val key = command.intent.key
    val descriptor = capabilities[key]
        ?: return if (key in capabilities.unsupported) CommandRejection.Unsupported else CommandRejection.SupportUnknown
    if (descriptor.access == SettingAccess.READ_ONLY) return CommandRejection.ReadOnly
    (descriptor.availability as? Availability.Unavailable)?.let { return CommandRejection.Unavailable(it.reason) }
    when (val intent = command.intent) {
        is CameraCommandIntent.Set -> if (!descriptor.accepts(intent.value)) return CommandRejection.OutOfDomain
        is CameraCommandIntent.FocusPoint ->
            if (intent.x !in 0.0..1.0 || intent.y !in 0.0..1.0) return CommandRejection.OutOfDomain
        CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording -> Unit
    }
    return null
}
