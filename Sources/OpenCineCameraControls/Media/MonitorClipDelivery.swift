#if os(iOS)
import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraVocabulary
import OpenCineMedia

/// One camera session's clip library as the shared clip delivery reads it (A2-61). An app
/// adapts its session to these values; the delivery never names a camera or a service.
@MainActor public struct MonitorClipLibrary {
    /// The session, camera and cache generation are still the ones the selection came from.
    public let isCurrent: @MainActor () -> Bool
    public let connected: @MainActor () -> Bool
    public let cameraName: @MainActor () -> String?
    public let isDownloaded: @MainActor (MediaFile) -> Bool
    public let download: @MainActor (MediaFile) async -> Void
    public let downloadProgress: @MainActor (MediaFile) -> Double?
    public let localURL: @MainActor (MediaFile) -> URL?
    public let shotColor: @MainActor (MediaFile) -> ColorMode?
    public let rememberShotColor: @MainActor (ColorMode, MediaFile) -> Void
    public init(
        isCurrent: @escaping @MainActor () -> Bool, connected: @escaping @MainActor () -> Bool,
        cameraName: @escaping @MainActor () -> String?,
        isDownloaded: @escaping @MainActor (MediaFile) -> Bool,
        download: @escaping @MainActor (MediaFile) async -> Void,
        downloadProgress: @escaping @MainActor (MediaFile) -> Double?,
        localURL: @escaping @MainActor (MediaFile) -> URL?,
        shotColor: @escaping @MainActor (MediaFile) -> ColorMode?,
        rememberShotColor: @escaping @MainActor (ColorMode, MediaFile) -> Void
    ) {
        self.isCurrent = isCurrent
        self.connected = connected
        self.cameraName = cameraName
        self.isDownloaded = isDownloaded
        self.download = download
        self.downloadProgress = downloadProgress
        self.localURL = localURL
        self.shotColor = shotColor
        self.rememberShotColor = rememberShotColor
    }

    /// The cache owner every run and the pre-hop cache go through.
    public var originals: MonitorDeliveryOriginalService<MediaFile> {
        let isCurrent = isCurrent, download = download
        return .init(
            available: isDownloaded,
            acquire: { file in
                guard isCurrent() else { return }
                await download(file)
            }, progress: downloadProgress)
    }
}

/// The app's log-curve copy: the camera's own curve names stay in the app.
public struct MonitorClipDeliveryCopy: Sendable {
    public let convertHelp: String
    public let convertUnavailableHelp: String
    /// The outcome for a clip that is not in a convertible log curve.
    public let notLog: @Sendable (String) -> String
    public init(
        convertHelp: String, convertUnavailableHelp: String, notLog: @escaping @Sendable (String) -> String
    ) {
        self.convertHelp = convertHelp
        self.convertUnavailableHelp = convertUnavailableHelp
        self.notLog = notLog
    }
}

/// The best-effort JSON sidecar written next to an export.
public struct MonitorClipDeliveryMetadata: Codable, Sendable {
    public let filename: String
    public let captureDate: String
    public let sizeBytes: UInt64
    public let cameraName: String?
    public let lutName: String?
    public let lutExposureStops: Double?
    public let convertLog: String?
    public let exportedAt: Date
}

/// The operator's monitor look as an export reads it.
@MainActor struct MonitorClipLook {
    let label: String?
    let exposureStops: Double
    let cube: @MainActor (_ bakeExposure: Bool) -> CubeLUT?

    init(label: String?, exposureStops: Double, cube: @escaping @MainActor (Bool) -> CubeLUT?) {
        self.label = label
        self.exposureStops = exposureStops
        self.cube = cube
    }

    init(_ assist: MonitorClipDelivery.Assist) {
        self.init(
            label: assist.lutStatusLabel, exposureStops: assist.lutExposureStops,
            cube: { assist.exportLUTCube(bakeExposure: $0) })
    }
}

public enum MonitorClipDeliveryError: LocalizedError {
    case notCached(String)
    case noLook
    public var errorDescription: String? {
        switch self {
        case .notCached(let name): "\(name) isn't fully cached yet."
        case .noLook: "Turn on a LUT before baking one into the file."
        }
    }
}

/// The delivery of camera clips with a log curve and a monitor look (the shared host both log
/// camera apps compose): the popup's options, the export of each clip into the delivery store,
/// stills as their cached originals, and the run on the app's delivery coordinator.
@MainActor public enum MonitorClipDelivery {
    public typealias Format = MonitorMediaExporter.Format
    public typealias Configuration = MonitorDeliveryExportConfiguration<LogColorTransform, Format>
    public typealias Assist = MonitorAssistState<MonitorLUTLooks>
    public typealias Request<Project: Sendable, Context: Sendable, Lease: Sendable> =
        MonitorDeliveryPreparedRequest<LogColorTransform, Format, Project, Context, Lease>
    public typealias Preparation<Project: Sendable, Context: Sendable, Lease: Sendable> =
        MonitorDeliveryPreparationModel<LogColorTransform, Format, Project, Context, Lease>
    // The option, naming and metadata helpers are plain values: callable off the main actor,
    // as the apps' own helpers were.

    public nonisolated static func defaultConfiguration() -> Configuration {
        .init(logTransform: .dLogToDLog2, exportFormat: .mov)
    }

    /// A still travels as its original, so the popup offers it no clip export (ZIB-469).
    public nonisolated static func selectionFile(_ file: MediaFile) -> MonitorDeliveryFileFacts {
        .init(filename: file.filename, sizeBytes: file.sizeBytes > 0 ? file.sizeBytes : nil,
            isStill: file.kind == .photo)
    }
    /// Convert log is video-only. An unknown shot color stays available until export reads the
    /// original; a curve with no conversion disables the toggle.
    public nonisolated static func convertLogAvailable(files: [MediaFile], shotColors: [ColorMode?]) -> Bool {
        files.enumerated().contains { index, file in
            guard file.kind == .video else { return false }
            guard shotColors.indices.contains(index), let color = shotColors[index] else { return true }
            return LogColorTransform.converting(from: color) != nil
        }
    }

    public nonisolated static func filename(
        for file: MediaFile, configuration: Configuration, transform: LogColorTransform? = nil
    ) -> String {
        MonitorDeliveryFileNaming.filename(
            original: file.filename, configuration: configuration,
            formatExtension: configuration.exportFormat.rawValue, transformToken: transform?.filenameToken)
    }

    public nonisolated static func metadata(
        for file: MediaFile, configuration: Configuration, lutName: String?, cameraName: String?,
        lutExposureStops: Double = 0, convertLog: LogColorTransform? = nil
    ) -> MonitorClipDeliveryMetadata? {
        let selection = MonitorDeliveryMetadataSelection(configuration)
        guard selection.included else { return nil }
        return MonitorClipDeliveryMetadata(
            filename: file.filename, captureDate: file.filenameTimestamp ?? "", sizeBytes: file.sizeBytes,
            cameraName: cameraName, lutName: selection.bakedLook ? lutName : nil,
            lutExposureStops: selection.bakedExposure ? LUTExposureCompensation.snap(lutExposureStops) : nil,
            convertLog: selection.convertedCurve ? convertLog?.label : nil, exportedAt: Date())
    }

    public nonisolated static func metadataSummary(for files: [MediaFile]) -> String {
        MonitorDeliveryMetadataSummary.text(
            files: files.map {
                .init(filename: $0.filename, captureDate: $0.filenameTimestamp, sizeBytes: $0.sizeBytes > 0 ? $0.sizeBytes : nil)
            }, formatBytes: MediaClipFormatting.byteLabel)
    }

    /// The popup of one selection and the begin of its accepted request. The remote run binds
    /// the accepted request (its project) to the app's remote account.
    public static func popup<Project: Sendable, Context: Sendable, Lease: Sendable>(
        files: [MediaFile], library: MonitorClipLibrary, assist: @escaping @MainActor () -> Assist,
        copy: MonitorClipDeliveryCopy, coordinator: MonitorDeliveryCoordinator,
        remote: MonitorDeliveryRemoteService<Project, Context, Lease>?,
        remoteRun: @escaping @MainActor (Request<Project, Context, Lease>, MonitorDeliveryAdmission) ->
            MonitorDeliveryRemoteRun<MediaFile>?,
        preferredDestination: MonitorDeliveryDestination? = nil
    ) -> (model: Preparation<Project, Context, Lease>, begin: (Request<Project, Context, Lease>) -> Void) {
        let source = MonitorDeliveryAdmission { library.isCurrent() }
        var configuration = defaultConfiguration()
        if let first = files.filter({ $0.kind == .video }).compactMap(library.shotColor)
            .compactMap(LogColorTransform.converting(from:)).first
        {
            configuration.logTransform = first
        }
        let originals = library.originals
        let model = Preparation<Project, Context, Lease>(
            selection: {
                .init(
                    files: files.map(selectionFile),
                    cachedCount: files.filter(library.isDownloaded).count, connected: library.connected())
            }, configuration: configuration,
            exportOptions: .init(
                curves: LogColorTransform.allCases.map { .init(id: $0.rawValue, label: $0.destination.label, value: $0) },
                formats: Format.allCases.map { .init(id: $0.rawValue, label: $0.label, value: $0) },
                lutAvailable: {
                    assist().playbackEffects.lutDimension >= 2 || assist().effects.lutDimension >= 2
                },
                convertLogAvailable: {
                    convertLogAvailable(files: files, shotColors: files.map(library.shotColor))
                },
                lutLabel: { assist().lutStatusLabel }, convertHelp: copy.convertHelp,
                convertUnavailableHelp: copy.convertUnavailableHelp,
                filename: { configuration in
                    guard files.count == 1, let file = files.first else { return nil }
                    return filename(
                        for: file, configuration: configuration,
                        transform: configuration.convertLog ? configuration.logTransform : nil)
                }),
            remote: remote, preferredDestination: preferredDestination, sourceCurrent: { source.isCurrent() },
            beforeInternetHop: {
                try await coordinator.cacheBeforeInternetHop(
                    records: files, originals: originals, source: source, filename: \.filename,
                    uploadCaption: remote?.presentation.progressCaption)
            })
        let begin: (Request<Project, Context, Lease>) -> Void = { request in
            guard source.isCurrent() else {
                if let lease = request.internetLease { remote?.internet.restore(lease) }
                return
            }
            guard let configuration = request.configuration else {
                if let lease = request.internetLease { remote?.internet.restore(lease) }
                coordinator.fail("Export settings are unavailable.")
                return
            }
            coordinator.begin { admission, progress in
                let current = MonitorDeliveryAdmission { admission.isCurrent() && source.isCurrent() }
                return await coordinator.run(
                    records: files, destination: request.destination, action: request.action,
                    admission: current,
                    source: delivery(
                        configuration: configuration, library: library, look: { MonitorClipLook(assist()) },
                        copy: copy, admission: current),
                    includeMetadata: configuration.includeMetadata,
                    remote: request.destination == .remoteUpload ? remoteRun(request, current) : nil,
                    internet: remote?.internet, lease: request.internetLease, progress: progress)
            }
        }
        return (model, begin)
    }

    /// The clip source of one accepted configuration.
    static func delivery(
        configuration: Configuration, library: MonitorClipLibrary, look: @escaping @MainActor () -> MonitorClipLook,
        copy: MonitorClipDeliveryCopy, admission: MonitorDeliveryAdmission
    ) -> MonitorDeliverySource<MediaFile> {
        .init(
            originals: library.originals,
            still: { file in
                // A still is delivered as its cached original; only movies are exported.
                guard file.kind == .photo, admission.isCurrent(), library.isDownloaded(file) else { return nil }
                return library.localURL(file)
            },
            export: { file, store, progress in
                try await export(
                    file, configuration: configuration, library: library, look: look(), store: store,
                    admission: admission, progress: progress)
            },
            filename: \.filename, metadata: metadataSummary(for:),
            noPrepared: { files in configuration.convertLog ? files.first.map { copy.notLog($0.filename) } : nil })
    }

    /// Exports one clip into the store; nil skips a clip that is not in a convertible log curve.
    static func export(
        _ file: MediaFile, configuration: Configuration, library: MonitorClipLibrary, look: MonitorClipLook,
        store: MonitorDeliveryExportStore, admission: MonitorDeliveryAdmission,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL? {
        // The original camera file, never a proxy.
        guard admission.isCurrent(), let source = library.localURL(file), library.isDownloaded(file) else {
            throw MonitorClipDeliveryError.notCached(file.filename)
        }
        let transform: LogColorTransform?
        let exportLook: MonitorMediaExporter.Look?
        if configuration.convertLog {
            let color = ClipColorProfile.shotColor(at: source, path: file.path) ?? library.shotColor(file)
            guard admission.isCurrent() else { throw CancellationError() }
            if let color { library.rememberShotColor(color, file) }
            guard let color, LogColorTransform.converting(from: color) != nil else { return nil }
            let converting = LogColorTransform.converting(from: color, to: configuration.logTransform.destination)
            transform = converting
            exportLook = converting.map {
                .init(
                    cube: $0.cube(), preservingEncodedValues: true,
                    metadataReplacement: .init(key: ClipColorProfile.gammaKey, value: $0.destination.label))
            }
        } else if configuration.bakeLUT {
            guard let cube = look.cube(configuration.bakeLUTExposure) else {
                throw MonitorClipDeliveryError.noLook
            }
            transform = nil
            exportLook = .init(cube: cube)
        } else {
            transform = nil
            exportLook = nil
        }
        var name = filename(
            for: file, configuration: configuration,
            transform: configuration.convertLog ? configuration.logTransform : nil)
        if (name as NSString).pathExtension.isEmpty { name += "." + configuration.exportFormat.rawValue }
        let metadata = metadata(
            for: file, configuration: configuration, lutName: look.label,
            cameraName: library.cameraName(), lutExposureStops: look.exposureStops, convertLog: transform)
        let output = try store.outputURL(filename: name)
        guard admission.isCurrent() else {
            store.release(output)
            throw CancellationError()
        }
        do {
            let result = try await MonitorMediaExporter.export(
                sourceURL: source, outputURL: output, format: configuration.exportFormat, look: exportLook,
                metadata: metadata
            ) { fraction in
                Task { @MainActor in if admission.isCurrent() { progress(fraction) } }
            }
            guard admission.isCurrent() else { throw CancellationError() }
            return result.videoURL
        } catch {
            store.release(output)
            throw error
        }
    }
}
#endif
