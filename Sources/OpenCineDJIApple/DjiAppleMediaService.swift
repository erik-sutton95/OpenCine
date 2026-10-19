import Foundation
import OpenCineDJI
import OpenCineMedia

/// Identity captured from the actual native connection before queued input or an operation.
public struct DjiAppleMediaIdentity: Equatable, Sendable {
    public let session: DJICameraSessionID
    public let epoch: DJIControlEpoch
    public let cameraID: String
    public init(session: DJICameraSessionID, epoch: DJIControlEpoch, cameraID: String) {
        self.session = session
        self.epoch = epoch
        self.cameraID = cameraID
    }
    func sameConnection(as other: Self) -> Bool {
        session == other.session && cameraID == other.cameraID
    }
}

public struct DjiAppleMediaFacts: Sendable {
    public let identity: DjiAppleMediaIdentity
    public let canQuery: Bool
    public let bodyGalleryOpen: Bool
    public let inPlayback: Bool
    public let model: CameraModel?
    public let sourcePolicy: DJIMediaSourcePolicy?
    public init(
        identity: DjiAppleMediaIdentity, canQuery: Bool,
        bodyGalleryOpen: Bool, inPlayback: Bool, model: CameraModel? = nil,
        sourcePolicy: DJIMediaSourcePolicy? = nil
    ) {
        self.identity = identity
        self.canQuery = canQuery
        self.bodyGalleryOpen = bodyGalleryOpen
        self.inPlayback = inPlayback
        self.model = model
        self.sourcePolicy = sourcePolicy
    }
}

/// Optional native exchange primitive, implemented only by hosts with real mutation IO.
@MainActor public protocol DjiAppleMediaMutationPort: DjiAppleMediaPort {
    func requestMedia(_ frame: Duml.Frame, source: DjiAppleMediaIdentity, timeout: Duration)
        async throws -> Duml.Frame
}

/// Primitive native IO and authority only. This port never supplies browse/query/retry loops.
@MainActor public protocol DjiAppleMediaPort: AnyObject, Sendable {
    var mediaFacts: DjiAppleMediaFacts? { get }
    func mediaBrowseChanged(
        _ active: Bool, binding: MediaBrowseBinding,
        source: DjiAppleMediaIdentity)
    func setMediaWireHeld(_ held: Bool, source: DjiAppleMediaIdentity)
    func writeMedia(_ frame: Duml.Frame, source: DjiAppleMediaIdentity) throws
    /// Exactly one enter transaction through the actual shared control exchange.
    func enterMediaPlayback(source: DjiAppleMediaIdentity, timeout: Duration) async throws
        -> Duml.Frame
    /// Claims current PictureRecovery/ConnectionRun authority, including a nil-driver rejoin gap.
    /// Does not invoke a retained app return loop. Only the admitted operation can run commands.
    func claimMediaReturn(
        binding: MediaBrowseBinding, source: DjiAppleMediaIdentity,
        operation: @escaping @MainActor (DjiAppleMediaReturnAuthority) async -> Void) async
}

/// Immutable integration preservation record for an app-supplied cache codec.
public struct DJIMediaCatalogRecord: Sendable {
    public let asset: MediaAssetID
    public let file: MediaFile
}

@MainActor public protocol DJIMediaCatalogRecordSource: AnyObject, Sendable {
    func mediaCatalogRecord(_ asset: MediaAssetID, binding: MediaBrowseBinding)
        -> DJIMediaCatalogRecord?
}

/// Captured before queueing raw input, fencing an old query/cursor/browse/endpoint.
public struct DjiAppleMediaIngress: Equatable, Sendable {
    fileprivate let source: DjiAppleMediaIdentity
    fileprivate let binding: MediaBrowseBinding
    fileprivate let query: UUID
}

/// The actual browse/catalog producer; IO capabilities remain absent until their real adoption.
@MainActor public final class DjiAppleMediaService: CameraMediaService, DJIMediaCatalogRecordSource
{
    public let sessionID: DJICameraSessionID
    private weak var port: (any DjiAppleMediaPort)?
    private let timing: DjiAppleMediaTiming
    private let journal: (String) -> Void
    private var ingress: DjiAppleMediaIngressSlot
    private var current: DjiAppleMediaBrowse?
    private var returnTask: Task<Void, Never>?
    private var actionCounter: UInt32 = 1
    public var isReturning: Bool { returnTask != nil }
    public var sourcePolicy: DJIMediaSourcePolicy? { port?.mediaFacts?.sourcePolicy }

    public init(
        session: DJICameraSessionID, port: any DjiAppleMediaPort,
        timing: DjiAppleMediaTiming = .continuous, ingress: DjiAppleMediaIngressSlot = .init(),
        journal: @escaping (String) -> Void = { _ in }
    ) {
        sessionID = session
        self.port = port
        self.timing = timing
        self.ingress = ingress
        self.journal = journal
    }

    /// Native endpoint replacement retires old queued ingress before binding its new slot.
    public func attachIngress(_ ingress: DjiAppleMediaIngressSlot) {
        if self.ingress === ingress { return }
        current?.retireCatalog()
        if let ticket = self.ingress.capture() { self.ingress.retire(ticket) }
        self.ingress = ingress
    }

    fileprivate func retireIngress(binding: MediaBrowseBinding) {
        if let ticket = ingress.capture(), ticket.binding == binding { ingress.retire(ticket) }
    }

    public func openBrowse() async throws -> any CameraMediaBrowse {
        guard let facts = port?.mediaFacts, facts.identity.session == sessionID,
            facts.canQuery
        else { throw MediaServiceError.unavailable }
        returnTask?.cancel()
        returnTask = nil
        current?.retire()
        let browse = DjiAppleMediaBrowse(
            owner: self, source: facts.identity,
            bodyGalleryHeld: facts.bodyGalleryOpen)
        current = browse
        port?.mediaBrowseChanged(true, binding: browse.binding, source: browse.source)
        do {
            try check(browse)
            port?.setMediaWireHeld(true, source: browse.source)
            if !facts.bodyGalleryOpen { browse.playbackHeld = try await enterPlayback(browse) }
            try check(browse)
            if !facts.bodyGalleryOpen, !browse.playbackHeld {
                port?.setMediaWireHeld(false, source: browse.source)
            }
            return browse
        } catch {
            if current === browse { await browse.close() }
            throw error
        }
    }

    /// Local connection retirement never sends a camera command.
    public func retire() {
        let previous = current
        current = nil
        previous?.retire()
        returnTask?.cancel()
        returnTask = nil
    }

    public func mediaCatalogRecord(_ asset: MediaAssetID, binding: MediaBrowseBinding)
        -> DJIMediaCatalogRecord?
    {
        guard let current, current.binding == binding, (try? check(current)) != nil,
            let file = current.records[asset]
        else { return nil }
        return .init(asset: asset, file: file)
    }

    /// A false result means no camera acknowledgement was confirmed. It never removes local data.
    public func deleteAsset(_ asset: MediaAssetID, binding: MediaBrowseBinding) async throws -> Bool {
        let (browse, file, port) = try mutationSource(asset, binding: binding)
        guard file.isDeletable else { throw MediaServiceError.unavailable }
        let frame = Commands.deleteMedia(handle: file.handle, counter: nextActionCounter())
        let reply = try await port.requestMedia(frame, source: browse.source, timeout: .seconds(2))
        try check(browse)
        return CameraReply.parse(reply.payload).isSuccess || reply.payload.starts(with: [0, 0])
    }

    public func setFavorite(_ asset: MediaAssetID, on: Bool, binding: MediaBrowseBinding) async throws {
        let (browse, file, port) = try mutationSource(asset, binding: binding)
        guard file.favoriteHandle != 0 else { throw MediaServiceError.unavailable }
        let frame = Commands.setMediaFavorite(handle: file.favoriteHandle, on: on,
            counter: nextActionCounter(), model: port.mediaFacts?.model)
        _ = try await port.requestMedia(frame, source: browse.source, timeout: .milliseconds(900))
        try check(browse)
    }

    private func mutationSource(_ asset: MediaAssetID, binding: MediaBrowseBinding) throws
        -> (DjiAppleMediaBrowse, MediaFile, any DjiAppleMediaMutationPort) {
        guard let current, current.binding == binding else { throw MediaServiceError.retired }
        try check(current)
        guard let file = current.records[asset], let port = port as? any DjiAppleMediaMutationPort
        else { throw MediaServiceError.unavailable }
        return (current, file, port)
    }

    private func nextActionCounter() -> UInt32 {
        let value = actionCounter
        actionCounter &+= 1
        if actionCounter == 0 { actionCounter = 1 }
        return value
    }

    public func captureIngress(source: DjiAppleMediaIdentity) -> DjiAppleMediaIngress? {
        guard let current, current.source == source, (try? check(current)) != nil,
            let query = current.query
        else { return nil }
        return .init(source: source, binding: current.binding, query: query.id)
    }

    @discardableResult public func ingest(_ frame: Duml.Frame, admission: DjiAppleMediaIngress)
        -> Bool
    {
        guard let current, current.binding == admission.binding,
            current.source == admission.source, (try? check(current)) != nil,
            let query = current.query, query.id == admission.query
        else { return false }
        return query.assembler.ingest(frame)
    }

    /// Deletion reconciliation uses the same real query owner, with the newest page only.
    public func newestCatalog(binding: MediaBrowseBinding) throws -> any MediaCatalogCursor {
        guard let current, current.binding == binding else { throw MediaServiceError.retired }
        try check(current)
        return current.makeCursor(newestOnly: true)
    }

    fileprivate func check(_ browse: DjiAppleMediaBrowse) throws {
        try Task.checkCancellation()
        guard current === browse, !browse.closed, !browse.catalogRetired,
            let facts = port?.mediaFacts, facts.identity == browse.source, facts.canQuery
        else { throw MediaServiceError.retired }
    }

    private func returnCurrent(_ browse: DjiAppleMediaBrowse) -> Bool {
        guard current === browse, let identity = port?.mediaFacts?.identity else { return false }
        return identity.sameConnection(as: browse.source)
    }

    fileprivate func returnToLive(_ browse: DjiAppleMediaBrowse) async {
        guard returnCurrent(browse) else { return }
        let task = Task { [weak self] in
            guard let self, self.returnCurrent(browse), let port = self.port else { return }
            await port.claimMediaReturn(binding: browse.binding, source: browse.source) {
                authority in
                guard self.returnCurrent(browse), authority.isCurrent(), !Task.isCancelled else {
                    return
                }
                let result = await DjiAppleMediaLiveReturn.run(
                    timing: self.timing,
                    isCurrent: { self.returnCurrent(browse) && authority.isCurrent() },
                    inPlayback: authority.inPlayback, pictureFresh: authority.pictureFresh,
                    exitPlayback: authority.exitPlayback, enableLiveView: authority.enableLiveView)
                guard self.returnCurrent(browse), authority.isCurrent(), !Task.isCancelled else {
                    return
                }
                authority.completed(result)
            }
            guard self.returnCurrent(browse), !Task.isCancelled else { return }
            port.mediaBrowseChanged(false, binding: browse.binding, source: browse.source)
        }
        returnTask = task
        await task.value
        if current === browse { returnTask = nil }
    }

    private func enterPlayback(_ browse: DjiAppleMediaBrowse) async throws -> Bool {
        for attempt in 1...3 {
            try check(browse)
            do {
                guard let port else { throw MediaServiceError.retired }
                let reply = try await port.enterMediaPlayback(
                    source: browse.source, timeout: .milliseconds(900))
                try check(browse)
                if CameraReply.parse(reply.payload).isSuccess || port.mediaFacts?.inPlayback == true
                {
                    journal("media: enter playback ok attempt=\(attempt)")
                    return true
                }
            } catch {
                try check(browse)
                if port?.mediaFacts?.inPlayback == true { return true }
            }
            try await timing.sleep(.milliseconds(120))
        }
        try check(browse)
        return port?.mediaFacts?.inPlayback == true
    }

    fileprivate func query(
        _ browse: DjiAppleMediaBrowse, cursor: DjiAppleMediaCursor,
        sd: UInt32, internalStore: UInt32, retryEmptySD: Bool
    ) async throws -> DjiAppleMediaPage {
        try check(browse)
        guard browse.cursor === cursor, browse.query == nil else {
            throw MediaServiceError.unavailable
        }
        let query = DjiAppleMediaQuery()
        browse.query = query
        let slot = ingress
        let ticket = DjiAppleMediaIngress(
            source: browse.source, binding: browse.binding, query: query.id)
        slot.publish(ticket)
        defer {
            slot.retire(ticket)
            if browse.query === query { browse.query = nil }
        }
        let deadline = timing.now() + 12
        func admitted() throws {
            try check(browse)
            guard browse.cursor === cursor, browse.query === query, !cursor.closed else {
                throw MediaServiceError.retired
            }
        }
        func send(_ frame: Duml.Frame) throws {
            try admitted()
            guard let port else { throw MediaServiceError.retired }
            try port.writeMedia(frame, source: browse.source)
            try admitted()
        }
        try send(Commands.mediaList(counter: MediaListCommand.sdCounter, cursor: sd))
        try await collect(
            query, counter: MediaListCommand.sdCounter, floor: 0.8, idle: 1,
            deadline: deadline, admitted: admitted)
        try send(Commands.mediaListTrigger())
        try await collect(
            query, counter: nil, floor: 0.4, idle: 0.2,
            deadline: deadline, admitted: admitted)
        try send(
            Commands.mediaList(counter: MediaListCommand.internalCounter, cursor: internalStore))
        try await collect(
            query, counter: MediaListCommand.internalCounter, floor: 0.8, idle: 1,
            deadline: deadline, admitted: admitted)
        if retryEmptySD, query.assembler.assembled(counter: MediaListCommand.sdCounter).isEmpty,
            timing.now() < deadline
        {
            query.assembler.reset(counter: MediaListCommand.sdCounter)
            try send(Commands.mediaList(counter: MediaListCommand.sdCounter, cursor: sd))
            try await collect(
                query, counter: MediaListCommand.sdCounter, floor: 0.8, idle: 1,
                deadline: deadline, admitted: admitted)
            try send(Commands.mediaListTrigger())
            try await collect(
                query, counter: MediaListCommand.sdCounter, floor: 0.4, idle: 1,
                deadline: deadline, admitted: admitted)
        }
        try admitted()
        guard query.assembler.hasResponse else { throw MediaServiceError.unavailable }
        return .init(
            files: MediaManifest.decodeStores(assembler: query.assembler),
            slices: [
                MediaListCommand.sdStorage: MediaManifest.sliceInfo(
                    assembler: query.assembler,
                    counter: MediaListCommand.sdCounter),
                MediaListCommand.internalStorage: MediaManifest.sliceInfo(
                    assembler: query.assembler,
                    counter: MediaListCommand.internalCounter),
            ])
    }

    private func collect(
        _ query: DjiAppleMediaQuery, counter: UInt8?, floor: TimeInterval,
        idle: TimeInterval, deadline: TimeInterval, admitted: () throws -> Void
    ) async throws {
        let start = timing.now()
        var lastChange = start
        var lastCount =
            counter.map { query.assembler.chunkCount(counter: $0) } ?? query.assembler.chunkCount
        while true {
            try admitted()
            let now = timing.now()
            if now >= deadline { break }
            if let counter, now - start >= floor, query.assembler.didEnd(counter: counter) { break }
            try await timing.sleep(.milliseconds(50))
            try admitted()
            let count =
                counter.map { query.assembler.chunkCount(counter: $0) }
                ?? query.assembler.chunkCount
            if count != lastCount {
                lastCount = count
                lastChange = timing.now()
            }
            let afterSleep = timing.now()
            if afterSleep - start >= floor, afterSleep - lastChange >= idle { break }
        }
    }
}

private struct DjiAppleMediaPage {
    let files: [MediaFile]
    let slices: [Int: MediaPageSliceInfo]
}

@MainActor private final class DjiAppleMediaQuery {
    let id = UUID()
    var assembler = MediaChunkAssembler()
}

@MainActor private final class DjiAppleMediaBrowse: CameraMediaBrowse {
    let binding: MediaBrowseBinding
    let source: DjiAppleMediaIdentity
    let bodyGalleryHeld: Bool
    var heldBySource: Bool? { bodyGalleryHeld }
    weak var owner: DjiAppleMediaService?
    var closed = false
    var catalogRetired = false
    var playbackHeld = false
    var records: [MediaAssetID: MediaFile] = [:]
    var cursor: DjiAppleMediaCursor?
    var query: DjiAppleMediaQuery?
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }

    init(owner: DjiAppleMediaService, source: DjiAppleMediaIdentity, bodyGalleryHeld: Bool) {
        self.owner = owner
        self.source = source
        self.bodyGalleryHeld = bodyGalleryHeld
        binding = .init(session: source.session, epoch: source.epoch)
    }
    func retire() {
        closed = true
        retireCatalog()
    }
    func retireCatalog() {
        catalogRetired = true
        owner?.retireIngress(binding: binding)
        cursor?.close()
        query = nil
    }
    func close() async {
        guard !closed else { return }
        retire()
        await owner?.returnToLive(self)
    }
    func catalog() async throws -> any MediaCatalogCursor {
        guard let owner else { throw MediaServiceError.retired }
        try owner.check(self)
        return makeCursor(newestOnly: false)
    }
    func makeCursor(newestOnly: Bool) -> DjiAppleMediaCursor {
        cursor?.close()
        let next = DjiAppleMediaCursor(browse: self, newestOnly: newestOnly)
        cursor = next
        return next
    }
}

@MainActor private final class DjiAppleMediaCursor: MediaCatalogCursor {
    weak var browse: DjiAppleMediaBrowse?
    let newestOnly: Bool
    var closed = false
    private var finished = false
    private var first = true
    private var seen = Set<String>()
    private var sd = MediaListCommand.newestSD
    private var internalStore = MediaListCommand.newestInternal
    private var pending: Task<MediaCatalogDelta, Error>?
    private var pendingID: UUID?
    init(browse: DjiAppleMediaBrowse, newestOnly: Bool) {
        self.browse = browse
        self.newestOnly = newestOnly
    }
    func next() async throws -> MediaCatalogDelta? {
        guard !closed, let browse, let owner = browse.owner, browse.cursor === self else {
            throw MediaServiceError.retired
        }
        try owner.check(browse)
        guard !finished else { return nil }
        // The body owns its gallery. Never turn this into an empty-camera reset or a listing.
        if browse.bodyGalleryHeld {
            finished = true
            return nil
        }
        guard pending == nil else { throw MediaServiceError.unavailable }
        let id = UUID()
        let task = Task {
            let page = try await owner.query(
                browse, cursor: self, sd: self.sd,
                internalStore: self.internalStore, retryEmptySD: self.first && browse.playbackHeld)
            try owner.check(browse)
            guard !self.closed, browse.cursor === self else { throw MediaServiceError.retired }
            let step =
                self.first
                ? MediaListCommand.seedPagination(
                    page: page.files, seen: &self.seen, slices: page.slices)
                : MediaListCommand.stepPagination(
                    sdCursor: self.sd, internalCursor: self.internalStore,
                    page: page.files, seen: &self.seen, slices: page.slices)
            let reset = self.first
            self.first = false
            self.sd = step.sdCursor
            self.internalStore = step.internalCursor
            self.finished = self.newestOnly || !browse.playbackHeld || !step.moreAvailable
            let assets = step.fresh.map { DjiAppleMediaAssets.asset(for: $0) }
            if reset && !self.newestOnly { browse.records.removeAll() }
            // Newest-page reconciliation preserves old locations unless this actual source page
            // proves new content at the same store/path. Only its exact old asset ID is removed.
            var removed = Set<MediaAssetID>()
            if self.newestOnly {
                let incoming = Dictionary(zip(assets, step.fresh).map {
                    (MediaListCommand.pageKey($0.1), $0.0.id)
                }, uniquingKeysWith: { _, newer in newer })
                for (oldID, file) in browse.records {
                    if let newID = incoming[MediaListCommand.pageKey(file)], oldID != newID {
                        removed.insert(oldID)
                    }
                }
                for id in removed { browse.records[id] = nil }
            }
            for (asset, file) in zip(assets, step.fresh) { browse.records[asset.id] = file }
            return MediaCatalogDelta(
                reset: reset && !self.newestOnly, upserts: assets,
                removed: removed.sorted { $0.rawValue < $1.rawValue }, complete: self.finished)
        }
        pending = task
        pendingID = id
        defer {
            if pendingID == id {
                pending = nil
                pendingID = nil
            }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try owner.check(browse)
        guard !closed, browse.cursor === self else { throw MediaServiceError.retired }
        return result
    }
    func close() {
        closed = true
        if let browse, browse.cursor === self {
            browse.owner?.retireIngress(binding: browse.binding)
            browse.query = nil
        }
        pending?.cancel()
        pending = nil
        pendingID = nil
    }


}


/// One integration-owned identity/representation factory shared by the producer and legacy codec.
/// Callers pass actual immutable MediaFile facts; no app parses or constructs opaque asset IDs.
public enum DjiAppleMediaAssets {
    public static func asset(for file: MediaFile) -> MediaAsset {
        // Store/path are source routing; content evidence prevents recycled-path removal.
        let stamp = file.filenameTimestamp.map { "stamp=\($0)" }
        let size = file.sizeBytes > 0 ? "size=\(file.sizeBytes)" : nil
        let content = [MediaListCommand.pageKey(file)] + [stamp, size].compactMap { $0 }
        let id = MediaAssetID(Data(content.joined(separator: "|").utf8).base64EncodedString())
        var representations = [
            MediaRepresentation(
                id: .init(id.rawValue + ":original"),
                role: .original, byteCount: file.sizeBytes > 0 ? file.sizeBytes : nil)
        ]
        if !MediaHTTP.proxyPaths(file).isEmpty {
            representations.append(.init(id: .init(id.rawValue + ":proxy"), role: .proxy))
        }
        let kind: MediaAssetKind? =
            MediaManifest.videoExtensions.contains(file.fileExtension)
            ? .video
            : MediaManifest.photoExtensions.contains(file.fileExtension) ? .photo : nil
        let dimensions = file.resolution?.split(separator: "x").compactMap { Int($0) }
        let pixels: MediaPixelSize?
        if let dimensions, dimensions.count == 2, dimensions[0] > 0, dimensions[1] > 0 {
            pixels = .init(width: dimensions[0], height: dimensions[1])
        } else {
            pixels = nil
        }
        return .init(
            id: id, filename: file.filename, kind: kind, capturedAt: file.captureDate,
            durationSeconds: file.durationSeconds > 0 ? Double(file.durationSeconds) : nil,
            pixelSize: pixels, frameRate: file.fps.flatMap { $0 > 0 ? Double($0) : nil },
            representations: representations, deletable: file.isDeletable)
    }
}
