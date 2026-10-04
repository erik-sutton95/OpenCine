import Foundation
import OpenCineCore
import OpenCineMedia

/// One native connection, distinguished from the stable common session during recovery.
public struct NikonMediaSourceIdentity: Equatable, Sendable {
    public let native: ObjectIdentifier
    public let session: CameraSessionID
    public let epoch: ControlEpoch
    public init(native: ObjectIdentifier, session: CameraSessionID, epoch: ControlEpoch) {
        self.native = native
        self.session = session
        self.epoch = epoch
    }
}

/// A successful empty card is authoritative. Failure never means that its objects disappeared.
public struct NikonMediaHandleSnapshot: Equatable, Sendable {
    public let handles: [MediaObjectHandle]
    public let authoritativeStorages: Set<UInt32>
    public let failedStorages: Set<UInt32>
    public let storageListAuthoritative: Bool
    public var complete: Bool { storageListAuthoritative && failedStorages.isEmpty }
    public init(
        handles: [MediaObjectHandle], authoritativeStorages: Set<UInt32>,
        failedStorages: Set<UInt32> = [], storageListAuthoritative: Bool
    ) {
        self.handles = handles
        self.authoritativeStorages = authoritativeStorages
        self.failedStorages = failedStorages
        self.storageListAuthoritative = storageListAuthoritative
    }
}

public struct NikonMediaStorageRecord: Equatable, Sendable {
    public let id: UInt32
    public let info: PTPStorageInfo
    public init(id: UInt32, info: PTPStorageInfo) {
        self.id = id
        self.info = info
    }
}

/// Camera facts only. The legacy cache codec retains favorite/rating/export/local-file policy.
public struct NikonMediaObjectRecord: Equatable, Sendable {
    public let location: MediaObjectHandle
    public let filename: String
    public let captureDate: String
    public let sizeBytes: UInt64
    public var pixelWidth: UInt32?
    public var pixelHeight: UInt32?
    public var sourcePixelWidth: UInt32?
    public var sourcePixelHeight: UInt32?
    public var linkedR3DFilename: String?
    public init(
        location: MediaObjectHandle, filename: String, captureDate: String, sizeBytes: UInt64,
        pixelWidth: UInt32? = nil, pixelHeight: UInt32? = nil,
        sourcePixelWidth: UInt32? = nil, sourcePixelHeight: UInt32? = nil,
        linkedR3DFilename: String? = nil
    ) {
        self.location = location
        self.filename = filename
        self.captureDate = captureDate
        self.sizeBytes = sizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.linkedR3DFilename = linkedR3DFilename
    }
    public var identity: MediaClipObjectIdentity {
        .init(
            location: location, filename: filename, captureDate: captureDate, sizeBytes: sizeBytes)
    }
    public var isPhoto: Bool { MediaClipFilename.isPhoto(filename) }
    public var knownSize: UInt64? { sizeBytes > 0 && sizeBytes != 0xFFFF_FFFF ? sizeBytes : nil }
    public func asset(namespace: String) -> MediaAsset {
        // Length-delimited encoding preserves arbitrary Unicode without filename/path parsing.
        let fields = [
            namespace, String(location.storageID), String(location.handle), filename,
            captureDate, knownSize.map(String.init) ?? "unknown",
        ]
        let fingerprint = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let id = MediaAssetID(Data(fingerprint.utf8).base64EncodedString())
        let pixelSize: MediaPixelSize?
        if let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 {
            pixelSize = .init(width: Int(width), height: Int(height))
        } else {
            pixelSize = nil
        }
        return .init(
            id: id, volumeID: String(location.storageID), filename: filename,
            kind: isPhoto ? .photo : .video, pixelSize: pixelSize,
            representations: [
                .init(
                    id: MediaRepresentationID(id.rawValue),
                    role: MediaClipFilename.isPlayableProxy(filename) ? .proxy : .original,
                    byteCount: knownSize)
            ])
    }
}

/// Cached pairing facts also exist for downloaded rows with no current camera location.
/// This is metadata context, never a camera object, storage claim or fabricated asset.
public struct NikonMediaPairingRecord: Equatable, Sendable {
    public let filename: String
    public let captureDate: String
    public let sizeBytes: UInt64
    public let pixelWidth: UInt32?
    public let pixelHeight: UInt32?
    public let sourcePixelWidth: UInt32?
    public let sourcePixelHeight: UInt32?
    public let linkedR3DFilename: String?
    public init(
        filename: String, captureDate: String, sizeBytes: UInt64,
        pixelWidth: UInt32? = nil, pixelHeight: UInt32? = nil,
        sourcePixelWidth: UInt32? = nil, sourcePixelHeight: UInt32? = nil,
        linkedR3DFilename: String? = nil
    ) {
        self.filename = filename
        self.captureDate = captureDate
        self.sizeBytes = sizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.linkedR3DFilename = linkedR3DFilename
    }
}
/// An accepted source-derived metadata change for one exact cached row, including local-only rows.
public struct NikonMediaPairingUpdate: Equatable, Sendable {
    public let previous: NikonMediaPairingRecord
    public let width: UInt32
    public let height: UInt32
    public let masterFilename: String
    public init(
        previous: NikonMediaPairingRecord, width: UInt32, height: UInt32,
        masterFilename: String
    ) {
        self.previous = previous
        self.width = width
        self.height = height
        self.masterFilename = masterFilename
    }
}

public enum NikonMediaCategory: Equatable, Sendable { case all, videos, photos, favorites }
public struct NikonMediaCatalogRequest: Sendable {
    public let cached: [NikonMediaObjectRecord]
    public let pairing: [NikonMediaPairingRecord]
    public let retainedLocalFilenames: Set<String>
    public let category: NikonMediaCategory
    public let identityProbeBudget: Int
    public init(
        cached: [NikonMediaObjectRecord], pairing: [NikonMediaPairingRecord]? = nil,
        category: NikonMediaCategory,
        identityProbeBudget: Int = 8, retainedLocalFilenames: Set<String> = []
    ) {
        self.cached = cached
        self.pairing =
            pairing
            ?? cached.map { object in
                .init(
                    filename: object.filename, captureDate: object.captureDate,
                    sizeBytes: object.sizeBytes, pixelWidth: object.pixelWidth,
                    pixelHeight: object.pixelHeight, sourcePixelWidth: object.sourcePixelWidth,
                    sourcePixelHeight: object.sourcePixelHeight,
                    linkedR3DFilename: object.linkedR3DFilename)
            }
        self.category = category
        self.identityProbeBudget = identityProbeBudget
        self.retainedLocalFilenames = retainedLocalFilenames
    }
}

public struct NikonMediaCatalogRecord: Sendable {
    public let asset: MediaAssetID
    public let object: NikonMediaObjectRecord
    public init(asset: MediaAssetID, object: NikonMediaObjectRecord) {
        self.asset = asset
        self.object = object
    }
}

@MainActor public protocol NikonMediaCatalogRecordSource: AnyObject, Sendable {
    func mediaCatalogRecord(_ asset: MediaAssetID, binding: MediaBrowseBinding)
        -> NikonMediaCatalogRecord?
    func mediaPairingUpdates(binding: MediaBrowseBinding) -> [NikonMediaPairingUpdate]?
}

/// Primitive IO only. Enumeration, reconciliation and R3D/catalog policy belong to the producer.
@MainActor public protocol NikonMediaIO: AnyObject, Sendable {
    var sourceIdentity: NikonMediaSourceIdentity? { get }
    var cameraNamespace: String { get }
    func storage(source: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord]
    func handles(source: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot
    func handles(formats: [UInt32], source: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    func object(_ location: MediaObjectHandle, source: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    func header(_ location: MediaObjectHandle, source: NikonMediaSourceIdentity) async throws
        -> Data?
}

/// A local library row is distinct from a camera observation and needs no invented PTP location.
/// The host supplies its existing immutable cache identity. Metadata size changes keep that row.
public enum NikonMediaLibraryAssets {
    public static func asset(
        namespace: String, identity: String, filename: String,
        captureDate: String, sizeBytes: UInt64, pixelWidth: UInt32?, pixelHeight: UInt32?
    ) -> MediaAsset {
        let fields = ["library", namespace, identity, captureDate]
        let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let id = MediaAssetID(Data(encoded.utf8).base64EncodedString())
        let dimensions: MediaPixelSize?
        if let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 {
            dimensions = .init(width: Int(width), height: Int(height))
        } else {
            dimensions = nil
        }
        return .init(
            id: id, filename: filename,
            kind: MediaClipFilename.isPhoto(filename) ? .photo : .video,
            pixelSize: dimensions,
            representations: [
                .init(
                    id: .init(id.rawValue),
                    role: MediaClipFilename.isPlayableProxy(filename) ? .proxy : .original,
                    byteCount: sizeBytes > 0 && sizeBytes != 0xFFFF_FFFF ? sizeBytes : nil)
            ])
    }
}
