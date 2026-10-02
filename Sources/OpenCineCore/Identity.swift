import Foundation

/// A UUID-backed identifier that cannot be confused with another kind of identifier.
public struct Identifier<Kind>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public var description: String { uuid.uuidString }
}

/// A monotonically increasing counter that cannot be confused with another kind of counter.
public struct Counter<Kind>: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64 = 0) { self.value = value }
    public func next() -> Self { Self(value + 1) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { String(value) }
}

/// Phantom kinds for `Identifier` and `Counter`. Never instantiated.
public enum IdentityKind {
    public enum ConnectionRoute {}
    public enum ConnectionAttempt {}
    public enum CameraSession {}
    public enum ControlEpoch {}
    public enum ControlLease {}
    public enum Stream {}
    public enum StreamGeneration {}
    public enum MonitorEntry {}
    public enum Operation {}
    public enum CapabilityRevision {}
    public enum SnapshotRevision {}
}

/// A saved setup path (USB, a station network, the camera's access point, a relay).
/// One camera can have several routes.
public typealias ConnectionRouteID = Identifier<IdentityKind.ConnectionRoute>
/// One attempt to connect or recover. Completions carrying an older attempt are ignored.
public typealias ConnectionAttemptID = Identifier<IdentityKind.ConnectionAttempt>
/// One owned live camera-control lifetime. Detail views borrow it; they never open a second link.
public typealias CameraSessionID = Identifier<IdentityKind.CameraSession>
/// Advances when the control link or control authority of a session is replaced.
/// A picture-format change alone does not advance it.
public typealias ControlEpoch = Counter<IdentityKind.ControlEpoch>
/// One granted remote control lease.
public typealias ControlLeaseID = Identifier<IdentityKind.ControlLease>
/// One picture stream.
public typealias StreamID = Identifier<IdentityKind.Stream>
/// Advances on reconnect or reconfiguration; frames from an older generation are stale.
public typealias StreamGeneration = Counter<IdentityKind.StreamGeneration>
/// Stable UI and multicam slot identity. Reordering, staging and rotation keep it.
public typealias MonitorEntryID = Identifier<IdentityKind.MonitorEntry>
/// One command or workflow intent and its results. Unrelated to telemetry revisions.
public typealias OperationID = Identifier<IdentityKind.Operation>
/// Advances whenever any setting descriptor (support, domain, access, availability) changes.
public typealias CapabilityRevision = Counter<IdentityKind.CapabilityRevision>
/// Advances with every published camera snapshot.
public typealias SnapshotRevision = Counter<IdentityKind.SnapshotRevision>

/// Stable namespaced integration identifier, for example `org.example.cameras`.
/// For registration and diagnostics only: shared code never chooses behavior from it.
public struct IntegrationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Persisted identity of a physical camera.
///
/// Durable identities come from a serial-like value the integration trusts. When none exists the
/// integration mints a provisional identity, which is a fresh UUID and therefore never derived
/// from a host address, display name or model. Reconciliation rule: a provisional identity equals
/// only itself; common code never merges two devices. When the integration later learns the
/// durable identity it replaces the provisional one explicitly and the app migrates its saved
/// references. Credentials are referenced elsewhere by opaque IDs, never embedded here.
public struct CameraDeviceID: Hashable, Codable, Sendable {
    public let integration: IntegrationID
    public let value: String
    public let isProvisional: Bool

    public static func durable(_ value: String, integration: IntegrationID) -> Self {
        Self(integration: integration, value: value, isProvisional: false)
    }

    public static func provisional(integration: IntegrationID) -> Self {
        Self(integration: integration, value: UUID().uuidString, isProvisional: true)
    }
}

/// A point on the host's monotonic clock. Production code takes every instant from `now()`, the
/// one process-wide reference, so deadlines, lease expiry and observation times from different
/// integrations compare (MULTI-03 F1). Tests inject instants directly, or a `() -> MonotonicInstant`
/// where a session takes one. Instants from different hosts or processes are not comparable.
public struct MonotonicInstant: Hashable, Comparable, Codable, Sendable {
    public var sinceReference: Duration
    public init(_ sinceReference: Duration) { self.sinceReference = sinceReference }
    public static let zero = Self(.zero)

    /// The process reference: `ContinuousClock` (keeps counting through device sleep), captured on
    /// first use. Never mix with `ProcessInfo.systemUptime`, which pauses in sleep.
    private static let reference = ContinuousClock.now
    /// Now on the shared host reference. Every integration and app uses this, never its own origin.
    public static func now() -> Self { Self(reference.duration(to: .now)) }

    public static func + (lhs: Self, rhs: Duration) -> Self { Self(lhs.sinceReference + rhs) }
    public static func - (lhs: Self, rhs: Self) -> Duration {
        lhs.sinceReference - rhs.sinceReference
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sinceReference < rhs.sinceReference }
}
