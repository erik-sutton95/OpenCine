import Foundation

/// One native item lifetime. Clip changes and close retire callbacks carrying this token.
public struct MonitorPlaybackItemToken: Hashable, Sendable {
    public let owner: UUID
    public let revision: UInt64
    public init(owner: UUID, revision: UInt64) { self.owner = owner; self.revision = revision }
}

/// One pointer edit within a native item. Canceling and beginning again retires old input.
public struct MonitorPlaybackScrubToken: Hashable, Sendable {
    public let item: MonitorPlaybackItemToken
    public let edit: UUID
    public init(item: MonitorPlaybackItemToken, edit: UUID = UUID()) { self.item = item; self.edit = edit }
}

/// A resolved native file. Source addressing and transfer preparation happen before admission.
public struct MonitorPlaybackItem: Equatable, Sendable {
    public let url: URL
    public let mimeType: String
    public let sourceKey: String
    public let role: MediaRepresentationRole
    public let isRemote: Bool
    public init(url: URL, mimeType: String, sourceKey: String,
        role: MediaRepresentationRole = .original, isRemote: Bool = false) {
        self.url = url; self.mimeType = mimeType; self.sourceKey = sourceKey
        self.role = role; self.isRemote = isRemote
    }
}

public struct MonitorPlaybackMetadata: Equatable, Sendable {
    public var duration: Double?
    public var width: Double?
    public var height: Double?
    public var conform: MonitorConformPreview.Source
    public init(duration: Double? = nil, width: Double? = nil, height: Double? = nil,
        conform: MonitorConformPreview.Source = .init()) {
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.width = width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        self.height = height.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        self.conform = conform
    }
}

/// Observed native transport, separate from the operator's requested play state.
public enum MonitorPlaybackTransportState: Equatable, Sendable {
    case paused, waiting, playing
}

public enum MonitorPlaybackEvent: Equatable, Sendable {
    /// The native item is attached and preparation has been requested. It is not a ready frame.
    case itemInstalled
    case position(Double?)
    case playing(Bool?)
    /// Waiting retains play intent while the native clock is stalled. Nil is unobserved.
    case transport(MonitorPlaybackTransportState?)
    case metadata(MonitorPlaybackMetadata)
    case ended
    case failed(String)
}

public enum MonitorPlaybackError: Error, Equatable, Sendable {
    case retired, unavailable, nativeFailure(String)
}

/// The exercised player pipelines differ on when clip metadata must precede native decoding.
public enum MonitorPlaybackLookTiming: Sendable { case beforeNativePreparation, afterNativeReadiness }
public enum MonitorPlaybackStartTiming: Sendable { case afterNativeItemInstallation, afterNativeReadiness }

/// Whether returning from an inactive scene retains the operator's earlier play request.
/// The shared playback owner defaults to `clearRequest`: losing the scene pauses and forgets
/// the request, so returning never restarts sound by itself.
public enum MonitorPlaybackSceneLossPolicy: Sendable { case preserveRequest, clearRequest }

/// AVPlayer and the existing Android player SDK vary here. No camera or UI owner crosses it.
@MainActor public protocol MonitorPlaybackPort: AnyObject, Sendable {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)? { get set }
    /// Revision zero claims a newly composed owner. Later revisions may retire only that owner,
    /// before a new source/cache operation suspends; an outgoing owner cannot reclaim a successor.
    func retireItem(for token: MonitorPlaybackItemToken)
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata
    func play(rate: Double, token: MonitorPlaybackItemToken)
    func pause(token: MonitorPlaybackItemToken)
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken)
    func close(token: MonitorPlaybackItemToken)
}
