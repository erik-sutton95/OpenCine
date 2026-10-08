package com.opencapture.opencine.core

/** One queued operation's captured authority and integration-owned submission port.
 * This local lifetime evidence is never part of a camera command or wire encoding.
 */
public class CommandDispatchAdmission(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch,
    private val isCurrent: () -> Boolean,
    private val submit: suspend (CameraCommand) -> CommandReceipt,
) {
    /** The submission port propagates this authority into its actual native queues. */
    public fun rejection(command: CameraCommand, target: CameraSessionID): CommandRejection? = when {
        target != session || command.preconditions.session != session -> CommandRejection.WrongSession
        command.preconditions.epoch != epoch -> CommandRejection.StaleEpoch
        !runCatching(isCurrent).getOrDefault(false) -> CommandRejection.AuthorityExpired
        else -> null
    }

    /** Refusal is terminal and never submitted. Entered work keeps its original outcome. */
    public suspend fun dispatch(command: CameraCommand, target: CameraSessionID): CommandReceipt {
        val refusal = rejection(command, target)
        if (refusal != null) return CommandReceipt(
            command.operation, target, command.intent, CommandStage.Rejected(refusal),
        )
        return submit(command)
    }
}
