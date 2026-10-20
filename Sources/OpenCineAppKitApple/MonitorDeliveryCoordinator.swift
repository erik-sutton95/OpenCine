#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia

/// What a media source contributes to a delivery run. Everything else (ordering, progress,
/// staging, Photos, upload history, export lifetime) is the coordinator's.
@MainActor public struct MonitorDeliverySource<Record: Sendable> {
    public let originals: MonitorDeliveryOriginalService<Record>
    /// The cached original delivered unchanged (a still), or nil to export the record.
    public let still: @MainActor (Record) -> URL?
    /// Exports one record into the store; nil when the record is not eligible (skipped).
    public let export:
        @MainActor (Record, MonitorDeliveryExportStore, @escaping @MainActor @Sendable (Double) -> Void)
            async throws -> URL?
    public let filename: @MainActor (Record) -> String
    /// The "Include metadata" summary of the delivered records.
    public let metadata: @MainActor ([Record]) -> String?
    /// The outcome when no record could be prepared, or nil for the shared default.
    public let noPrepared: @MainActor ([Record]) -> String?
    public init(
        originals: MonitorDeliveryOriginalService<Record>,
        still: @escaping @MainActor (Record) -> URL?,
        export:
            @escaping @MainActor (
                Record, MonitorDeliveryExportStore, @escaping @MainActor @Sendable (Double) -> Void
            ) async throws -> URL?,
        filename: @escaping @MainActor (Record) -> String,
        metadata: @escaping @MainActor ([Record]) -> String?,
        noPrepared: @escaping @MainActor ([Record]) -> String? = { _ in nil }
    ) {
        self.originals = originals
        self.still = still
        self.export = export
        self.filename = filename
        self.metadata = metadata
        self.noPrepared = noPrepared
    }
}

/// A remote upload's services, bound to one accepted run (its captured project included).
@MainActor public struct MonitorDeliveryRemoteRun<Record: Sendable> {
    public let progressCaption: String
    public let upload:
        @MainActor (Record, URL, @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    public let history: MonitorDeliveryUploadHistory<Record>?
    public let reupload: Bool
    public init(
        progressCaption: String,
        upload:
            @escaping @MainActor (Record, URL, @escaping @MainActor @Sendable (Double) -> Void)
            async throws -> Void,
        history: MonitorDeliveryUploadHistory<Record>?, reupload: Bool
    ) {
        self.progressCaption = progressCaption
        self.upload = upload
        self.history = history
        self.reupload = reupload
    }
}

/// Which record each delivered file came from, for the upload of that record.
@MainActor private final class MonitorDeliveryOrigins<Record: Sendable> {
    var records: [URL: Record] = [:]
}

/// The app-scoped delivery owner every app composes: one run lifetime over the shared batch
/// progress, one export store, and the share leases the root presenter shows. A run survives
/// leaving the gallery or the player; only the app root closes it.
@available(iOS 17, *) @MainActor @Observable
public final class MonitorDeliveryCoordinator {
    public typealias Outcome = MonitorDeliveryBatchOutcome<URL>
    public typealias Lifetime = MonitorDeliveryModel<
        MonitorDeliveryBatchProgress, Outcome, MonitorDeliveryShareFiles<URL>
    >
    public let lifetime: Lifetime
    public let exports: MonitorDeliveryExportStore
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    /// The run that holds the camera or the route; a successor joins it before starting.
    @ObservationIgnored public private(set) var capturedRun: MonitorDeliveryRunHandle?

    public init(
        exports: MonitorDeliveryExportStore = .shared,
        sleep: (@MainActor (Duration) async throws -> Void)? = nil
    ) {
        // Resolved here, not as a closure-literal default: see `hostSleep(for:)` (swiftlang/swift#92017).
        let sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.exports = exports
        self.sleep = sleep
        // Exports a crash left behind go now; anything a live run or share holds stays.
        exports.prune()
        lifetime = .init(sleep: sleep, releaseShare: { exports.release($0.cleanup) })
    }

    public var isActive: Bool { lifetime.state.running }

    /// Whether delivery covers playback: a run is going, or its share sheet is still up. A
    /// finished run hands its files to the root share sheet, which hides the player until the
    /// sheet completes, so playback stays paused until then (A2-71).
    public var coversPlayback: Bool { isActive || lifetime.state.share != nil }

    /// Starts a run after the outgoing captured run has fully ended.
    @discardableResult public func begin(
        onCancel: (() -> Void)? = nil, onComplete: ((Outcome) -> Void)? = nil,
        run:
            @escaping @MainActor (
                MonitorDeliveryAdmission, @escaping @MainActor (MonitorDeliveryBatchProgress) -> Void
            ) async -> Outcome
    ) -> MonitorDeliveryRunHandle? {
        let outgoing = capturedRun
        let handle = lifetime.beginCaptured(
            onCancel: onCancel,
            onComplete: { outcome in
                onComplete?(outcome)
                return nil
            },
            cleanupWhenRetired: true,
            operation: { progress, admission in
                await outgoing?.cancelAndJoin()
                // A retired batch enters only its captured-resource cleanup; source work checks admission.
                return await run(admission, progress).completion()
            })
        capturedRun = handle
        return handle
    }

    /// Remote delivery from the camera network caches every original first, as a run of this
    /// owner, and throws unless all are cached (A2-05).
    public func cacheBeforeInternetHop<Record: Sendable>(
        records: [Record], originals: MonitorDeliveryOriginalService<Record>,
        source: MonitorDeliveryAdmission, filename: @escaping @MainActor (Record) -> String,
        uploadCaption: String?, onStarted: (MonitorDeliveryRunHandle) -> Void = { _ in }
    ) async throws {
        try await lifetime.cacheBeforeInternetHop(
            records: records, originals: originals, after: capturedRun, source: source,
            filename: filename, completion: .uploaded(summary: ""), uploadCaption: uploadCaption,
            progress: { $0 },
            onStarted: { run in
                capturedRun = run
                onStarted(run)
            })
    }

    /// Settings' cache with the exports nothing holds counted and cleared alongside it.
    public func cacheSource(_ base: MonitorSettingsCacheSource) -> MonitorSettingsCacheSource {
        let exports = self.exports
        return base.adding(count: { exports.byteCount() }, clear: { exports.prune() })
    }

    /// A run is caching originals from the camera, the transfer channel playback also needs
    /// (A2-54). Other stages (export, upload, share) never hold the camera.
    public var holdsCameraTransfer: Bool { lifetime.state.progress?.isCaching == true }

    /// A playback or camera barrier: waits only while a run is caching from the camera, and
    /// never cancels the run. Export, upload and share go on beside playback.
    public func cameraTransferReleased() async {
        // ponytail: polls the published stage every 50 ms; an observation continuation if this
        // ever shows in a trace.
        while holdsCameraTransfer, !Task.isCancelled {
            try? await sleep(.milliseconds(50))
        }
    }

    /// Announces a refusal through the same outcome toast.
    public func fail(_ message: String) { begin { _, _ in .failed(message: message) } }
    public func cancel() { lifetime.cancel() }
    public func close() { lifetime.close() }

    /// One delivery batch over a source: exports live in this store for the run, share files in
    /// their own lease, Photos saves item by item after access is granted, and a remote run
    /// skips what its history already has. An accepted route lease is restored when the run ends,
    /// whatever its destination.
    public func run<Record: Sendable, Lease: Sendable>(
        records: [Record], destination: MonitorDeliveryDestination,
        action: MonitorDeliveryPostExportAction, admission: MonitorDeliveryAdmission,
        source: MonitorDeliverySource<Record>, includeMetadata: Bool,
        remote: MonitorDeliveryRemoteRun<Record>?,
        internet: MonitorDeliveryInternetService<Lease>?, lease: Lease?,
        progress: @escaping @MainActor (MonitorDeliveryBatchProgress) -> Void
    ) async -> Outcome {
        let exports = self.exports
        let origin = MonitorDeliveryOrigins<Record>()
        let photos = MonitorDeliveryPhotosSaver.service
        return await Lifetime.runBatch(
            records: records, destination: destination, action: action, admission: admission,
            originals: source.originals,
            exporter: .init(
                original: { record in
                    guard let url = source.still(record) else { return nil }
                    origin.records[url] = record
                    return url
                },
                release: { exports.release($0) },
                prepare: { record, report in
                    guard let url = try await source.export(record, exports, report) else {
                        return nil
                    }
                    origin.records[url] = record
                    return url
                }),
            share: { urls in
                let staged = try exports.stage(urls) { try Task.checkCancellation() }
                return .init(urls: staged.urls, cleanup: staged.stagingCleanupURL)
            },
            photos: photos, photosAuthorization: MonitorDeliveryPhotosSaver.authorization,
            upload: remote.map { remote in
                .init(progressCaption: remote.progressCaption) { url, report in
                    guard let record = origin.records[url] else { throw CancellationError() }
                    try await remote.upload(record, url, report)
                }
            },
            uploadHistory: remote?.history, reupload: remote?.reupload ?? false,
            internet: internet, lease: lease, filename: source.filename,
            artifactFilename: { $0.lastPathComponent },
            metadata: { includeMetadata ? source.metadata($0) : nil },
            noPrepared: source.noPrepared, progress: progress)
    }
}
#endif
