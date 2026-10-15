import Foundation

/// The existing source owner supplies validity; no network state is inferred from a label.
public typealias CameraNetworkIsCurrent = @MainActor @Sendable () -> Bool

/// Values for an existing platform hotspot operation. Credentials are never diagnostics.
public struct CameraHotspotConfiguration: Sendable {
    public enum Selection: Sendable { case ssid(String), prefix(String) }
    public enum Security: Sendable { case open, personal(passphrase: String) }
    public var selection: Selection
    public var security: Security
    public var joinOnce: Bool
    /// A caller's existing apply budget, absent when the native completion has no deadline.
    public var timeout: Duration?
    public init(selection: Selection, security: Security, joinOnce: Bool, timeout: Duration? = nil) {
        self.selection = selection
        self.security = security
        self.joinOnce = joinOnce
        self.timeout = timeout
    }
}

public enum CameraHotspotError: Error, Sendable { case timedOut }

/// Mutations scoped to one source and the original caller's cancellation lifetime.
@MainActor public struct CameraHotspotOperations: Sendable {
    public var apply: @MainActor @Sendable (CameraHotspotConfiguration) async throws -> Void
    public var remove: @MainActor @Sendable (String) -> Void
    public init(
        apply: @escaping @MainActor @Sendable (CameraHotspotConfiguration) async throws -> Void,
        remove: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.apply = apply
        self.remove = remove
    }
}

public typealias CameraHotspotAttemptBody =
    @MainActor @Sendable (CameraHotspotOperations) async throws -> Void

/// A host retains this value across reconnects. The adapter owns native pending work.
@MainActor public struct CameraHotspotHost: Sendable {
    public var withAttempt: @MainActor @Sendable
        (@escaping CameraNetworkIsCurrent, @escaping CameraHotspotAttemptBody) async throws -> Void
    public var remove: @MainActor @Sendable (String, @escaping CameraNetworkIsCurrent) -> Void
    public var currentSSID: @MainActor @Sendable () async -> String?
    public var configuredSSIDs: @MainActor @Sendable () async -> [String]
    public init(
        withAttempt: @escaping @MainActor @Sendable
            (@escaping CameraNetworkIsCurrent, @escaping CameraHotspotAttemptBody) async throws -> Void,
        remove: @escaping @MainActor @Sendable (String, @escaping CameraNetworkIsCurrent) -> Void,
        currentSSID: @escaping @MainActor @Sendable () async -> String?,
        configuredSSIDs: @escaping @MainActor @Sendable () async -> [String]
    ) {
        self.withAttempt = withAttempt
        self.remove = remove
        self.currentSSID = currentSSID
        self.configuredSSIDs = configuredSSIDs
    }
}
