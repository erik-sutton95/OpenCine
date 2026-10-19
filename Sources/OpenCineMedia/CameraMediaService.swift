import Foundation
import OpenCineCore

/// Opaque, content-qualified identities supplied by the source. Consumers never parse them.
public struct MediaAssetID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { rawValue = value }
}

public struct MediaRepresentationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { rawValue = value }
}

public enum MediaAssetKind: String, Codable, Sendable { case video, photo }
public enum MediaRepresentationRole: String, Codable, Sendable { case original, proxy }

public struct MediaPixelSize: Equatable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct MediaRepresentation: Equatable, Codable, Sendable {
    public let id: MediaRepresentationID
    public let role: MediaRepresentationRole
    public let byteCount: UInt64?
    public init(id: MediaRepresentationID, role: MediaRepresentationRole, byteCount: UInt64? = nil) {
        self.id = id; self.role = role; self.byteCount = byteCount
    }
}

/// Source facts. Unknown metadata and permissions remain absent; local cache/favorites are not
/// camera observations. Routing and raw protocol handles stay behind the source service.
public struct MediaAsset: Equatable, Codable, Sendable {
    public let id: MediaAssetID
    public let volumeID: String?
    public let filename: String
    public let kind: MediaAssetKind?
    public let capturedAt: Date?
    public let durationSeconds: Double?
    public let pixelSize: MediaPixelSize?
    public let frameRate: Double?
    public let colorLabel: String?
    public let representations: [MediaRepresentation]
    public let deletable: Bool?

    public init(
        id: MediaAssetID, volumeID: String? = nil, filename: String, kind: MediaAssetKind? = nil,
        capturedAt: Date? = nil, durationSeconds: Double? = nil, pixelSize: MediaPixelSize? = nil,
        frameRate: Double? = nil, colorLabel: String? = nil,
        representations: [MediaRepresentation], deletable: Bool? = nil
    ) {
        self.id = id; self.volumeID = volumeID; self.filename = filename; self.kind = kind
        self.capturedAt = capturedAt; self.durationSeconds = durationSeconds
        self.pixelSize = pixelSize; self.frameRate = frameRate; self.colorLabel = colorLabel
        self.representations = representations; self.deletable = deletable
    }
}

/// A bounded catalog page. Nil volume facts are unknown, distinct from known empty storage.
/// Removal names a content identity, so recycled locations cannot erase a successor asset.
public struct MediaCatalogDelta: Equatable, Sendable {
    public let reset: Bool
    public let upserts: [MediaAsset]
    public let removed: [MediaAssetID]
    public let volumes: [StorageVolume]?
    public let complete: Bool
    public init(
        reset: Bool = false, upserts: [MediaAsset] = [], removed: [MediaAssetID] = [],
        volumes: [StorageVolume]? = nil, complete: Bool
    ) {
        self.reset = reset; self.upserts = upserts; self.removed = removed
        self.volumes = volumes; self.complete = complete
    }
}

public struct MediaBrowseBinding: Equatable, Sendable {
    public let session: CameraSessionID
    public let epoch: ControlEpoch
    public let lease: UUID
    public init(session: CameraSessionID, epoch: ControlEpoch, lease: UUID = UUID()) {
        self.session = session; self.epoch = epoch; self.lease = lease
    }
}

public enum MediaServiceError: Error, Equatable, Sendable {
    case unavailable, retired, unknownAsset, unsupported, refused
}

public struct MediaTransferReceipt: Equatable, Sendable {
    public let byteCount: UInt64
    public let expectedByteCount: UInt64?
    public init(byteCount: UInt64, expectedByteCount: UInt64? = nil) {
        self.byteCount = byteCount; self.expectedByteCount = expectedByteCount
    }
}

public enum MediaDeleteOutcome: Equatable, Sendable {
    /// The source acknowledged the request; a later catalog fact confirms removal.
    case accepted
    case refused, unsupported, unknown
}

public struct MediaDeleteResult: Equatable, Sendable {
    public let asset: MediaAssetID
    public let outcome: MediaDeleteOutcome
    public init(asset: MediaAssetID, outcome: MediaDeleteOutcome) {
        self.asset = asset; self.outcome = outcome
    }
}

/// An owned staging writer, never a whole movie in memory. Retirement makes further writes fail.
public protocol MediaByteSink: Sendable {
    func write(_ chunk: Data) async throws
}

/// Optional length observation for sinks that publish transfer progress. A response header may
/// replace the source hint; absent length stays unknown and never becomes a zero-byte fact.
public protocol MediaTransferProgressSink: MediaByteSink {
    func expectedByteCount(_ count: UInt64?) async throws
}

@MainActor public protocol CameraMediaThumbnailService: AnyObject, Sendable {
    func thumbnail(_ asset: MediaAssetID) async throws -> Data
}

@MainActor public protocol CameraMediaTransferService: AnyObject, Sendable {
    func transfer(_ representation: MediaRepresentationID, into sink: any MediaByteSink) async throws
        -> MediaTransferReceipt
}

@MainActor public protocol CameraMediaDeleteService: AnyObject, Sendable {
    func delete(_ assets: [MediaAssetID]) async throws -> [MediaDeleteResult]
}

/// Pulling a page supplies backpressure. Closing a cursor retires pending and future requests.
@MainActor public protocol MediaCatalogCursor: AnyObject, Sendable {
    func next() async throws -> MediaCatalogDelta?
    func close()
}

/// One media-mode lifetime; nested covers and rotation borrow this same lease. Optional services
/// are absent when the producer has no implementation, rather than throwing advertised defaults.
@MainActor public protocol CameraMediaBrowse: AnyObject, Sendable {
    var binding: MediaBrowseBinding { get }
    var thumbnails: (any CameraMediaThumbnailService)? { get }
    var transfers: (any CameraMediaTransferService)? { get }
    var deletion: (any CameraMediaDeleteService)? { get }
    /// True while the camera holds its own media (its own gallery is open), so this browse lists
    /// nothing; nil when the source does not say.
    var heldBySource: Bool? { get }
    func catalog() async throws -> any MediaCatalogCursor
    /// Retires before yielding. Idempotent; source owns safe return to the same live session.
    func close() async
}
extension CameraMediaBrowse {
    public var heldBySource: Bool? { nil }
}

/// Registered by protocol type in ConnectedCamera.services, never selected by manufacturer.
@MainActor public protocol CameraMediaService: AnyObject, Sendable {
    var sessionID: CameraSessionID { get }
    func openBrowse() async throws -> any CameraMediaBrowse
}
