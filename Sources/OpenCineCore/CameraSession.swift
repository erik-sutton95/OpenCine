import Foundation

/// One owned live camera-control lifetime. Implementations serialize their own command state;
/// an actor is the expected shape. The integration owns command serialization, ACK
/// interpretation, retries, readback, settle times and pacing; this seam reports results honestly.
///
/// Snapshot feed (`snapshots()`):
/// - Each call returns a new stream that first yields the current snapshot.
/// - Each stream buffers at most one newer snapshot (`.bufferingNewest(1)`). A slow consumer skips
///   intermediate snapshots and never slows the session or other consumers.
/// - Cancelling the consuming task, or dropping the stream, ends only that stream.
/// - `close` yields a final snapshot whose connection is `.disconnected`, then finishes every
///   stream. A stream requested after close yields that final snapshot and finishes.
///
/// Operations (`submit`, `outcome(of:)`, `receipt(of:)`):
/// - `submit` applies `CameraSnapshot.rejection(of:at:)` plus integration rules and returns the
///   receipt at its current stage, which may already be finished.
/// - Resubmitting an `OperationID` the session knows returns that receipt and never acts again.
/// - Receipts are tracked by `OperationID` independently of the snapshot feed and stay queryable
///   for the life of the session, so a slow or absent snapshot consumer never loses an outcome.
/// - `outcome(of:)` suspends until the receipt is finished and returns `nil` for an operation this
///   session never received. Cancelling the waiting task returns the current, possibly unfinished,
///   receipt at once; it never cancels or alters the operation.
/// - `receipt(of:)` returns the receipt at its current stage without waiting for it to finish
///   (`nil` for an operation this session never received). It has no default: a default `async`
///   overload would shadow a main-actor adapter's synchronous accessor in async callers.
/// - A write may finish as `.failed(.superseded)` when a newer write to the same setting replaces
///   it before its outcome is known (for example a coalesced drum step). Integrations that never
///   coalesce never report it.
///
/// Close (`close(_:)`):
/// - Idempotent; later calls do nothing.
/// - Sent but unfinished operations become `.outcomeUnknown`; admitted but unsent ones become
///   `.failed(.notSent)`. Waiters resume.
/// - Closing never sends camera commands. In particular it never stops a recording.
/// - Later submissions are rejected with `.sessionClosed`. Other sessions are unaffected.
public protocol CameraSession: Sendable {
    var id: CameraSessionID { get }
    func snapshots() async -> AsyncStream<CameraSnapshot>
    func submit(_ command: CameraCommand) async -> CommandReceipt
    func outcome(of operation: OperationID) async -> CommandReceipt?
    func receipt(of operation: OperationID) async -> CommandReceipt?
    func close(_ reason: SessionCloseReason) async
}

extension CameraSession {
    /// The current snapshot, read from a short-lived subscription.
    public func currentSnapshot() async -> CameraSnapshot? {
        for await snapshot in await snapshots() { return snapshot }
        return nil
    }
}
