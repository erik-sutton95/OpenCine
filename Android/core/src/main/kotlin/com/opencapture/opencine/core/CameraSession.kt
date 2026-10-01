package com.opencapture.opencine.core

import kotlinx.coroutines.flow.StateFlow

/**
 * One owned live camera-control lifetime. Implementations serialize their own command state
 * (one confined owner, or a `Mutex`). The integration owns command serialization, ACK
 * interpretation, retries, readback, settle times and pacing; this seam reports results honestly.
 *
 * Snapshot feed ([snapshots]):
 * - A [StateFlow]: it always holds the current snapshot, and a new collector receives it first.
 * - Conflated to the latest value. A slow collector skips intermediate snapshots and never slows
 *   the session or other collectors.
 * - A collector's lifetime is its coroutine scope; cancelling it ends only that collection.
 * - `close` publishes a final snapshot whose connection is [ConnectionState.Disconnected]; the
 *   value never changes after that. A `StateFlow` never completes, so a collector that must end
 *   with the session stops on that snapshot (for example with `transformWhile`).
 *
 * Operations ([submit], [outcome]):
 * - [submit] applies [CameraSnapshot.rejection] plus integration rules and returns the receipt at
 *   its current stage, which may already be finished.
 * - Resubmitting an [OperationID] the session knows returns that receipt and never acts again.
 * - Receipts are tracked by [OperationID] independently of the snapshot feed and stay queryable
 *   for the life of the session, so a slow or absent snapshot collector never loses an outcome.
 * - [outcome] suspends until the receipt is finished and returns `null` for an operation this
 *   session never received. Cancelling the waiting coroutine cancels only the wait; it never
 *   cancels or alters the operation.
 * - [receipt] returns the receipt at its current stage without suspending or waiting for it to
 *   finish (`null` for an operation this session never received). Call it from the session's
 *   owner (a confined session); a `Mutex`-guarded session keeps receipts readable without the
 *   lock.
 * - A write may finish as `Failed(SUPERSEDED)` when a newer write to the same setting replaces it
 *   before its outcome is known (for example a coalesced drum step). Integrations that never
 *   coalesce never report it.
 *
 * Close ([close], [closeNow]):
 * - Idempotent; later calls do nothing. [closeNow] is the non-suspending form for callers that
 *   cannot suspend (Compose `onDispose`): it schedules the same close on the session's own scope
 *   and returns without waiting.
 * - Sent but unfinished operations become [CommandStage.OutcomeUnknown]; admitted but unsent ones
 *   become `Failed(NOT_SENT)`. Waiters resume.
 * - Closing never sends camera commands. In particular it never stops a recording.
 * - Later submissions are rejected with [CommandRejection.SessionClosed]. Other sessions are
 *   unaffected.
 */
public interface CameraSession {
    public val id: CameraSessionID
    public val snapshots: StateFlow<CameraSnapshot>

    public suspend fun submit(command: CameraCommand): CommandReceipt

    public suspend fun outcome(operation: OperationID): CommandReceipt?

    public fun receipt(operation: OperationID): CommandReceipt?

    public suspend fun close(reason: SessionCloseReason)

    public fun closeNow(reason: SessionCloseReason)
}
