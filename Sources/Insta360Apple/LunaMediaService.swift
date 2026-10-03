import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineMedia

/// Native host operations. The source chooses addressing; the host supplies the existing
/// streaming transport and exact thumbnail codec without an integration-to-runtime dependency.
@MainActor public protocol LunaMediaIO: AnyObject, Sendable {
    func jpeg(_ thumbnail: LunaThumbnail) async throws -> Data
    func transfer(from url: URL, into sink: any MediaByteSink) async throws -> MediaTransferReceipt
}

struct LunaMediaSourceState: Equatable, Sendable {
    let session: CameraSessionID
    let epoch: ControlEpoch
    let connection: Int
}

@MainActor protocol LunaMediaSourcePort: AnyObject {
    var mediaSourceState: LunaMediaSourceState? { get }
    var mediaIO: (any LunaMediaIO)? { get }
    func mediaRequest(_ request: LunaRequest, source: LunaMediaSourceState) async throws -> Data
    func prepareMediaReturn(_ binding: MediaBrowseBinding) async
}

/// The real producer: one media owner, source-fenced protocol ordering and bounded catalog work.
@MainActor final class LunaMediaService: CameraMediaService {
    let sessionID: CameraSessionID
    private weak var port: (any LunaMediaSourcePort)?
    private var current: LunaMediaBrowse?
    private var returnTask: Task<Void, Never>?

    init(session: CameraSessionID, port: any LunaMediaSourcePort) {
        sessionID = session; self.port = port
    }

    func openBrowse() async throws -> any CameraMediaBrowse {
        guard let port, let source = port.mediaSourceState, source.session == sessionID else {
            throw MediaServiceError.unavailable
        }
        returnTask?.cancel(); returnTask = nil
        current?.retire()
        let browse = LunaMediaBrowse(owner: self, source: source, io: port.mediaIO)
        current = browse
        do {
            // Preserve the donor's best-effort stop, but never swallow retirement/cancellation.
            _ = try await request(LunaProtocol.stopLiveRequest, browse: browse, optional: true)
            return browse
        } catch {
            browse.retire()
            throw error
        }
    }

    func retire() {
        current?.retire(); current = nil
        returnTask?.cancel(); returnTask = nil
    }

    func check(_ browse: LunaMediaBrowse, returning: Bool = false) throws {
        try Task.checkCancellation()
        guard current === browse, port?.mediaSourceState == browse.source,
            returning || !browse.closed else { throw MediaServiceError.retired }
    }

    func request(
        _ request: LunaRequest, browse: LunaMediaBrowse, optional: Bool = false,
        returning: Bool = false
    ) async throws -> Data? {
        try check(browse, returning: returning)
        guard let port else { throw MediaServiceError.retired }
        let result: Data?
        do { result = try await port.mediaRequest(request, source: browse.source) }
        catch {
            try check(browse, returning: returning)
            if error is CancellationError || !optional { throw error }
            result = nil
        }
        try check(browse, returning: returning)
        return result
    }

    func returnToLive(_ browse: LunaMediaBrowse) async {
        guard current === browse else { return }
        // A source-owned task survives caller cancellation, but never replacement/retirement.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.check(browse, returning: true)
                await self.port?.prepareMediaReturn(browse.binding)
                try self.check(browse, returning: true)
                _ = try await self.request(LunaProtocol.stopLiveRequest, browse: browse,
                    optional: true, returning: true)
                _ = try await self.request(
                    LunaProtocol.setAccessCameraFileState(LunaProtocol.shootingViewAccessState),
                    browse: browse, optional: true, returning: true)
                _ = try await self.request(LunaProtocol.startLiveRequest, browse: browse,
                    returning: true)
            } catch { /* Retirement or transport failure cannot authorize another live enable. */ }
        }
        returnTask = task
        await task.value
        if current === browse { returnTask = nil }
    }
}

@MainActor final class LunaMediaBrowse: CameraMediaBrowse, CameraMediaThumbnailService,
    CameraMediaTransferService, CameraMediaDeleteService
{
    let binding: MediaBrowseBinding
    let source: LunaMediaSourceState
    private weak var owner: LunaMediaService?
    private let io: (any LunaMediaIO)?
    private(set) var closed = false
    private var cursor: LunaMediaCursor?
    private var files: [MediaAssetID: LunaMediaFile] = [:]
    private var representations: [MediaRepresentationID: URL] = [:]
    private var jobs: [UUID: () -> Void] = [:]
    var thumbnails: (any CameraMediaThumbnailService)? { io == nil ? nil : self }
    var transfers: (any CameraMediaTransferService)? { io == nil ? nil : self }
    var deletion: (any CameraMediaDeleteService)? { self }

    init(owner: LunaMediaService, source: LunaMediaSourceState, io: (any LunaMediaIO)?) {
        self.owner = owner; self.source = source; self.io = io
        binding = MediaBrowseBinding(session: source.session, epoch: source.epoch)
    }

    func retire() {
        closed = true; cursor?.close()
        let cancelling = jobs.values; jobs.removeAll()
        for cancel in cancelling { cancel() }
    }

    func close() async {
        guard !closed else { return }
        retire()
        await owner?.returnToLive(self)
    }

    func check() throws {
        guard let owner else { throw MediaServiceError.retired }
        try owner.check(self)
    }

    func catalog() async throws -> any MediaCatalogCursor {
        try check(); cursor?.close()
        let next = LunaMediaCursor(browse: self)
        cursor = next
        return next
    }

    func perform<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try check()
        let id = UUID()
        let task = Task {
            try self.check()
            return try await operation()
        }
        jobs[id] = { task.cancel() }
        defer { jobs[id] = nil }
        let value = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try check()
        return value
    }

    func list() async throws -> [MediaAsset] {
        guard let owner else { throw MediaServiceError.retired }
        _ = try await owner.request(
            LunaProtocol.setAccessCameraFileState(LunaProtocol.albumAccessState),
            browse: self, optional: true)
        guard let response = try await owner.request(LunaProtocol.fileListRequest(), browse: self)
        else { throw MediaServiceError.unavailable }
        let listing = try LunaProtocol.fileList(response: response)
        var listed = listing.uris.map { LunaMediaFile(uri: $0) }
        if let info = try await owner.request(LunaProtocol.fileInfoListRequest(), browse: self,
            optional: true), let metadata = try? LunaProtocol.fileInfoList(response: info)
        {
            let byURI = Dictionary(metadata.map { ($0.uri, $0) }, uniquingKeysWith: { a, _ in a })
            listed = listed.map { byURI[$0.uri] ?? $0 }
        }
        try check()
        var nextFiles: [MediaAssetID: LunaMediaFile] = [:]
        var nextRepresentations: [MediaRepresentationID: URL] = [:]
        let assets = listed.filter { !$0.isProxy }.map { file in
            let asset = Self.asset(file)
            nextFiles[asset.id] = file
            if let url = file.httpURL(), let original = asset.representations.first {
                nextRepresentations[original.id] = url
            }
            if let proxy = file.proxyURI, let url = LunaMediaFile(uri: proxy).httpURL(),
                let representation = asset.representations.first(where: { $0.role == .proxy })
            { nextRepresentations[representation.id] = url }
            return asset
        }
        files = nextFiles; representations = nextRepresentations
        return assets
    }

    func thumbnail(_ asset: MediaAssetID) async throws -> Data {
        try await perform { [self] in
            guard let io, let owner else { throw MediaServiceError.unsupported }
            guard let file = files[asset] else { throw MediaServiceError.unknownAsset }
            guard let response = try await owner.request(
                LunaProtocol.fileExtraRequest(file.uri, extraType: .thumbnail), browse: self)
            else { throw MediaServiceError.unavailable }
            let result = try await io.jpeg(LunaThumbnail(response: response))
            try check()
            return result
        }
    }

    func transfer(_ representation: MediaRepresentationID, into sink: any MediaByteSink) async throws
        -> MediaTransferReceipt
    {
        try await perform { [self] in
            guard let io else { throw MediaServiceError.unsupported }
            guard let url = representations[representation] else { throw MediaServiceError.unknownAsset }
            let ownedSink = LunaMediaOwnedSink(sink: sink, check: { [weak self] in
                guard let self else { throw MediaServiceError.retired }
                try self.check()
            })
            return try await io.transfer(from: url, into: ownedSink)
        }
    }

    func delete(_ assets: [MediaAssetID]) async throws -> [MediaDeleteResult] {
        try await perform { [self] in
            guard let owner else { throw MediaServiceError.retired }
            var outcomes: [MediaDeleteResult] = []
            for asset in assets {
                try check()
                guard let file = files[asset] else {
                    outcomes.append(.init(asset: asset, outcome: .unsupported)); continue
                }
                let outcome: MediaDeleteOutcome
                do {
                    _ = try await owner.request(LunaProtocol.deleteFiles(file.uri), browse: self)
                    outcome = .accepted
                } catch LunaProtocolError.cameraRejectedRequest { outcome = .refused }
                catch {
                    try check()
                    if error is CancellationError { throw error }
                    outcome = .unknown
                }
                outcomes.append(.init(asset: asset, outcome: outcome))
            }
            return outcomes
        }
    }

    static func asset(_ file: LunaMediaFile) -> MediaAsset {
        let metadata = file.metadata
        let stamp = (metadata?.creationStamp).map { String($0) } ?? ""
        let size = (metadata?.fileSize).map { String($0) } ?? ""
        let identity = [file.uri, stamp, size].joined(separator: "|")
        let id = MediaAssetID(Data(identity.utf8).base64EncodedString())
        let original = MediaRepresentation(id: .init(id.rawValue + ":original"), role: .original,
            byteCount: (metadata?.fileSize).flatMap { $0 > 0 ? $0 : nil })
        var representations: [MediaRepresentation] = [original]
        if file.proxyURI != nil {
            representations.append(.init(id: .init(id.rawValue + ":proxy"), role: .proxy))
        }
        let pixelSize = metadata.flatMap { data -> MediaPixelSize? in
            guard let width = data.width, let height = data.height, width > 0, height > 0 else { return nil }
            return .init(width: width, height: height)
        }
        let duration = (metadata?.durationMilliseconds).map { Double($0) / 1000 }
            ?? (metadata?.durationSeconds).map { Double($0) }
        let kind: MediaAssetKind? = file.isVideo ? .video
            : (metadata?.subMediaType == 3 || ["jpg", "jpeg", "dng"].contains(
                (file.uri as NSString).pathExtension.lowercased()) ? .photo : nil)
        return MediaAsset(id: id, filename: (file.uri as NSString).lastPathComponent, kind: kind,
            capturedAt: (metadata?.creationDate).flatMap { Calendar.current.date(from: $0) },
            durationSeconds: duration, pixelSize: pixelSize,
            frameRate: (metadata?.frameRate).flatMap { $0 > 0 ? Double($0) : nil },
            colorLabel: metadata?.gammaMode, representations: representations, deletable: true)
    }
}

private struct LunaMediaOwnedSink: MediaByteSink {
    let sink: any MediaByteSink
    let check: @MainActor @Sendable () throws -> Void
    func write(_ chunk: Data) async throws {
        try await check()
        try await sink.write(chunk)
        try await check()
    }
}

@MainActor final class LunaMediaCursor: MediaCatalogCursor {
    private weak var browse: LunaMediaBrowse?
    private var pending: Task<MediaCatalogDelta, Error>?
    private var closed = false
    private var finished = false
    init(browse: LunaMediaBrowse) { self.browse = browse }

    func next() async throws -> MediaCatalogDelta? {
        guard !closed, let browse else { throw MediaServiceError.retired }
        try browse.check()
        guard !finished else { return nil }
        // A cursor has one outstanding page; competing pulls cannot send a second listing.
        guard pending == nil else { throw MediaServiceError.unavailable }
        let task = Task { try await browse.perform {
            MediaCatalogDelta(reset: true, upserts: try await browse.list(), complete: true)
        } }
        pending = task
        defer { pending = nil }
        let value = try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        guard !closed else { throw MediaServiceError.retired }
        try browse.check(); finished = true
        return value
    }

    func close() { closed = true; pending?.cancel(); pending = nil }
}
