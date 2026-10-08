import Foundation

public enum MonitorDeliveryDestination: String, CaseIterable, Identifiable, Sendable {
    case nativeShare, remoteUpload
    public var id: String { rawValue }
    public func title(remoteDisplayName: String?) -> String {
        self == .nativeShare ? "Share" : remoteDisplayName ?? "Upload"
    }
    public var actionTitle: String { self == .nativeShare ? "Share" : "Upload" }
    public func subtitle(remoteDisplayName: String?) -> String {
        self == .nativeShare
            ? "Convert log, Bake LUT, AirDrop, Files"
            : "Upload to your \(remoteDisplayName ?? "remote") project"
    }
}
public enum MonitorDeliveryPostExportAction: String, Sendable { case systemShare, saveToPhotos }

/// Native curve and container choices remain typed source values.
public struct MonitorDeliveryExportConfiguration<Curve: Sendable, Format: Sendable>: Sendable {
    public var bakeLUT = true
    public var bakeLUTExposure = true
    public var convertLog = false
    public var logTransform: Curve
    public var exportFormat: Format
    public var includeMetadata = true
    public var forceReupload = false
    public init(logTransform: Curve, exportFormat: Format) {
        self.logTransform = logTransform
        self.exportFormat = exportFormat
    }
}

public struct MonitorDeliveryBatchProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case preparing, caching, exporting, uploading, saving, switchingNetworks,
            awaitingPhotosAccess
    }
    public let destination: MonitorDeliveryDestination
    public let totalClips: Int
    public var clipIndex: Int
    public var clipFraction: Double
    public var isCaching: Bool
    public var isSwitchingNetworks: Bool
    public var filename: String?
    public var uploadCaption: String?
    public var stage: Stage = .preparing
    public init(
        destination: MonitorDeliveryDestination, totalClips: Int, clipIndex: Int,
        clipFraction: Double, isCaching: Bool = false, isSwitchingNetworks: Bool = false,
        filename: String? = nil, uploadCaption: String? = nil
    ) {
        self.destination = destination
        self.totalClips = totalClips
        self.clipIndex = clipIndex
        self.clipFraction = clipFraction
        self.isCaching = isCaching
        self.isSwitchingNetworks = isSwitchingNetworks
        self.filename = filename
        self.uploadCaption = uploadCaption
    }
    public var overallFraction: Double {
        guard totalClips > 0 else { return 0 }
        return min(1, (Double(max(0, clipIndex - 1)) + clipFraction) / Double(totalClips))
    }
    public var isPreparingClip: Bool { clipFraction <= 0 }
    public var showsBusySpinner: Bool {
        isPreparingClip || isSwitchingNetworks || stage == .saving || stage == .awaitingPhotosAccess
    }
    public var percentText: String {
        isPreparingClip ? "" : "\(Int((overallFraction * 100).rounded()))%"
    }
    public func statusLine(uploadCaption: String? = nil) -> String {
        if isSwitchingNetworks { return "Switching networks…" }
        if stage == .awaitingPhotosAccess { return "Waiting for Photos access…" }
        if stage == .saving { return "Saving to Photos…" }
        let verb: String
        if isCaching {
            verb = isPreparingClip ? "Caching from camera…" : "Caching from camera"
        } else if destination == .nativeShare {
            verb =
                clipFraction > 0 && clipFraction < 0.95
                ? "Exporting" : isPreparingClip ? "Preparing…" : "Preparing to share"
        } else {
            verb =
                clipFraction > 0 && clipFraction < 0.45
                ? "Exporting"
                : isPreparingClip
                    ? "Preparing…" : uploadCaption ?? self.uploadCaption ?? "Uploading"
        }
        return isPreparingClip ? verb : "\(verb) \(percentText)"
    }
}

public enum MonitorDeliveryBatchOutcome<Artifact: Sendable>: Sendable {
    case share(urls: [Artifact], metadataText: String?, stagingCleanupURL: Artifact?)
    case savedToPhotos(count: Int)
    case uploaded(summary: String)
    case failed(message: String)
}

/// A captured run/source predicate. Every use checks its owner again after host callbacks.
@MainActor public struct MonitorDeliveryAdmission: Sendable {
    private let current: @MainActor @Sendable () -> Bool
    public init(_ current: @escaping @MainActor @Sendable () -> Bool) { self.current = current }
    public func isCurrent() -> Bool { !Task.isCancelled && current() && !Task.isCancelled }
}

/// Only the existing Library/SDK acquisition owner supplies an original receipt.
@MainActor public struct MonitorDeliveryOriginalService<Record: Sendable> {
    public let available: @MainActor (Record) -> Bool
    public let acquire: @MainActor (Record) async -> Void
    public let progress: @MainActor (Record) -> Double?
    public init(
        available: @escaping @MainActor (Record) -> Bool,
        acquire: @escaping @MainActor (Record) async -> Void,
        progress: @escaping @MainActor (Record) -> Double?
    ) {
        self.available = available
        self.acquire = acquire
        self.progress = progress
    }
}
@MainActor public struct MonitorDeliveryExportService<Record: Sendable, Artifact: Sendable> {
    public let prepare:
        @MainActor (Record, @escaping @MainActor @Sendable (Double) -> Void) async throws ->
            Artifact?
    /// Releases only the returned transient lease; borrowed originals use the default no-op.
    public let release: @MainActor (Artifact) async -> Void
    public init(
        prepare:
            @escaping @MainActor (Record, @escaping @MainActor @Sendable (Double) -> Void)
            async throws -> Artifact?
    ) {
        self.prepare = prepare
        self.release = { _ in }
    }
    public init(
        release: @escaping @MainActor (Artifact) async -> Void,
        prepare:
            @escaping @MainActor (Record, @escaping @MainActor @Sendable (Double) -> Void)
            async throws -> Artifact?
    ) {
        self.prepare = prepare
        self.release = release
    }
}
public struct MonitorDeliveryShareFiles<Artifact: Sendable>: Sendable {
    public let urls: [Artifact]
    public let cleanup: Artifact?
    public init(urls: [Artifact], cleanup: Artifact? = nil) {
        self.urls = urls
        self.cleanup = cleanup
    }
}
/// An OS batch transaction and per-item insert have different real permission/commit contracts.
@MainActor public enum MonitorDeliveryPhotosService<Artifact: Sendable> {
    case batch(@MainActor ([Artifact]) async throws -> Int)
    case perItem(@MainActor (Artifact) async throws -> Bool)
}
/// The existing OS authorization transaction, admitted before any cache or export work.
@MainActor public struct MonitorDeliveryPhotosAuthorizationService {
    public let isPending: @MainActor () -> Bool
    public let authorize: @MainActor () async throws -> Void
    public init(
        isPending: @escaping @MainActor () -> Bool,
        authorize: @escaping @MainActor () async throws -> Void
    ) {
        self.isPending = isPending
        self.authorize = authorize
    }
}
@MainActor public struct MonitorDeliveryUploadService<Artifact: Sendable> {
    public let progressCaption: String
    public let upload:
        @MainActor (Artifact, @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    public init(
        progressCaption: String = "Uploading",
        upload:
            @escaping @MainActor (Artifact, @escaping @MainActor @Sendable (Double) -> Void)
            async throws -> Void
    ) {
        self.progressCaption = progressCaption
        self.upload = upload
    }
}
/// Actual network lease operations, not a second route or reconnect owner.
@MainActor public struct MonitorDeliveryInternetService<Lease: Sendable> {
    public let needsHop: @MainActor () -> Bool
    public let begin: @MainActor () -> Lease
    public let owns: @MainActor (Lease) -> Bool
    public let wait: @MainActor (Lease) async -> Bool
    public let restore: @MainActor (Lease) -> Void
    public let restoreEntered: @MainActor (Lease) async -> Void
    public init(
        needsHop: @escaping @MainActor () -> Bool, begin: @escaping @MainActor () -> Lease,
        owns: @escaping @MainActor (Lease) -> Bool,
        wait: @escaping @MainActor (Lease) async -> Bool,
        restore: @escaping @MainActor (Lease) -> Void
    ) {
        self.needsHop = needsHop
        self.begin = begin
        self.owns = owns
        self.wait = wait
        self.restore = restore
        self.restoreEntered = { restore($0) }
    }
    public init(
        needsHop: @escaping @MainActor () -> Bool, begin: @escaping @MainActor () -> Lease,
        owns: @escaping @MainActor (Lease) -> Bool,
        wait: @escaping @MainActor (Lease) async -> Bool,
        restoreEntered: @escaping @MainActor (Lease) async -> Void,
        restore: @escaping @MainActor (Lease) -> Void
    ) {
        self.needsHop = needsHop
        self.begin = begin
        self.owns = owns
        self.wait = wait
        self.restore = restore
        self.restoreEntered = restoreEntered
    }
}

public enum MonitorDeliveryItemFailurePolicy: Equatable, Sendable { case stop, continueItems }

/// Immutable exercised differences in native transactions and empty upload summaries.
public struct MonitorDeliveryBatchBehavior: Sendable {
    public let nativeFailures: MonitorDeliveryItemFailurePolicy
    public let photosFailures: MonitorDeliveryItemFailurePolicy
    public let emptyUploadSucceeds: Bool
    public let singleUploadFailureUsesDetail: Bool
    public init(
        nativeFailures: MonitorDeliveryItemFailurePolicy = .stop,
        photosFailures: MonitorDeliveryItemFailurePolicy = .stop, emptyUploadSucceeds: Bool = false,
        singleUploadFailureUsesDetail: Bool = true
    ) {
        self.nativeFailures = nativeFailures
        self.photosFailures = photosFailures
        self.emptyUploadSucceeds = emptyUploadSucceeds
        self.singleUploadFailureUsesDetail = singleUploadFailureUsesDetail
    }
}

public struct MonitorDeliveryBatchCounts: Sendable {
    public let prepared: Int
    public let uploaded: Int
    public let skipped: Int
    public let failed: Int
    public let uncached: Int
    public init(prepared: Int, uploaded: Int, skipped: Int, failed: Int, uncached: Int) {
        self.prepared = prepared
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
        self.uncached = uncached
    }
}

/// Shared batch order/progress; platform messages preserve their existing native presentation.
public struct MonitorDeliveryBatchPolicy: Sendable {
    public var cacheFailure: @Sendable (Int) -> String
    public var emptySelection = "Select at least one clip."
    public var noPrepared: String?
    public var internetFailure =
        "Couldn't reach the internet after leaving the camera's Wi‑Fi. Check cellular or home Wi‑Fi and try again."
    public var behavior: MonitorDeliveryBatchBehavior
    public var nativeSummary: @Sendable (MonitorDeliveryBatchCounts) -> String?
    public var photosFailure: @Sendable (Int, Int) -> String?
    public init(
        cacheFailure: @escaping @Sendable (Int) -> String = {
            "Couldn't cache \($0) clip(s) from the camera. Check the connection and try again."
        }
    ) {
        self.cacheFailure = cacheFailure
        self.behavior = .init()
        self.nativeSummary = { _ in nil }
        self.photosFailure = { _, _ in nil }
    }
    public init(
        behavior: MonitorDeliveryBatchBehavior,
        nativeSummary: @escaping @Sendable (MonitorDeliveryBatchCounts) -> String? = { _ in nil },
        photosFailure: @escaping @Sendable (Int, Int) -> String? = { _, _ in nil },
        cacheFailure: @escaping @Sendable (Int) -> String = {
            "Couldn't cache \($0) clip(s) from the camera. Check the connection and try again."
        }
    ) {
        self.cacheFailure = cacheFailure
        self.behavior = behavior
        self.nativeSummary = nativeSummary
        self.photosFailure = photosFailure
    }
}

extension MonitorDeliveryBatchOutcome {
    public func completion() -> MonitorDeliveryCompletion<Self, MonitorDeliveryShareFiles<Artifact>>
    {
        switch self {
        case .share(let urls, _, let cleanup):
            return .init(self, share: .init(urls: urls, cleanup: cleanup))
        case .savedToPhotos(let count):
            return .init(self, toast: "Saved \(count) clip\(count == 1 ? "" : "s") to Photos")
        case .uploaded(let summary): return .init(self, toast: summary)
        case .failed(let message): return .init(self, toast: message)
        }
    }
}
