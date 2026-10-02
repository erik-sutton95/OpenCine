import Foundation
import OpenCineCore

extension IdentityKind {
    public enum EditorLease {}
}

public typealias EditorLeaseID = Identifier<IdentityKind.EditorLease>

/// A settings or detail view's borrowed right to command one entry's camera. It names the session,
/// control epoch and authority it was opened under; when any of them changes the lease retires,
/// so a queued edit can never reach a replacement camera or link. Opening a detail view never
/// opens a second camera link.
public struct EditorLease: Hashable, Sendable {
    public let id: EditorLeaseID
    public let entry: MonitorEntryID
    public let session: CameraSessionID
    public let epoch: ControlEpoch
    /// The remote control lease the session held, `nil` when this device owns the link.
    public let authority: ControlLeaseID?
}

public enum EditorLeaseRefusal: Error, Hashable, Sendable {
    case notMember
    case noCameraSession
    case noCommandAuthority
    case notReported
    /// Closed, replaced by a newer lease for the entry, or its session, epoch or authority changed.
    case retired
}

/// The open editor leases, at most one per entry. The app keeps this value with its other
/// presentation state and asks it before every submit.
public struct EditorLeases: Hashable, Sendable {
    private var active: [MonitorEntryID: EditorLease] = [:]

    public init() {}

    public var leases: [EditorLease] { Array(active.values) }

    /// Opens a lease on the entry's current session, retiring any earlier lease for the entry.
    public mutating func open(_ entry: MonitorEntryID, in group: MulticamGroup, at state: MulticamSnapshot)
        throws(EditorLeaseRefusal) -> EditorLease
    {
        active[entry] = nil
        guard let descriptor = group[entry] else { throw .notMember }
        guard let session = descriptor.cameraSession else { throw .noCameraSession }
        guard let snapshot = state.cameras[session] else { throw .notReported }
        guard descriptor.controlAuthority.commands, snapshot.authority.commands else {
            throw .noCommandAuthority
        }
        let lease = EditorLease(
            id: EditorLeaseID(), entry: entry, session: session, epoch: snapshot.epoch,
            authority: snapshot.authority.leaseID)
        active[entry] = lease
        return lease
    }

    /// Retires the entry's lease. Queued edits under it are refused from now on. Never sends a
    /// camera command.
    public mutating func close(_ entry: MonitorEntryID) { active[entry] = nil }

    public mutating func closeAll() { active.removeAll() }

    /// Retires every lease that no longer holds and returns them, so the app can drop their
    /// queued edits and close their views.
    @discardableResult
    public mutating func retireStale(in group: MulticamGroup, at state: MulticamSnapshot) -> [EditorLease] {
        let stale = active.values.filter { refusal(for: $0, in: group, at: state) != nil }
        for lease in stale { active[lease.entry] = nil }
        return stale
    }

    /// The command for `intent` under `lease`, carrying the current snapshot's preconditions.
    /// Call it when the edit is about to be submitted, not when it is queued. The session's own
    /// admission still applies (read-only settings, stale capabilities, domains).
    public func command(
        _ intent: CameraCommandIntent, under lease: EditorLease, in group: MulticamGroup,
        at state: MulticamSnapshot, deadline: MonotonicInstant? = nil
    ) throws(EditorLeaseRefusal) -> CameraCommand {
        if let refusal = refusal(for: lease, in: group, at: state) { throw refusal }
        return CameraCommand(
            intent, preconditions: CommandPreconditions(state.cameras[lease.session]!, deadline: deadline))
    }

    /// Why `lease` no longer holds, or `nil` while it does. An app whose existing command path
    /// asks "may this editor send now?" calls this at send time.
    public func refusal(for lease: EditorLease, in group: MulticamGroup, at state: MulticamSnapshot)
        -> EditorLeaseRefusal?
    {
        guard active[lease.entry] == lease, let entry = group[lease.entry],
            entry.cameraSession == lease.session, entry.controlAuthority.commands,
            let snapshot = state.cameras[lease.session], snapshot.epoch == lease.epoch,
            snapshot.authority.commands, snapshot.authority.leaseID == lease.authority
        else { return .retired }
        return nil
    }
}
