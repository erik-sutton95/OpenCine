import Foundation
import OpenCineCore
import OpenCineMedia

/// Nikon's actual cached-identity/category/R3D producer over native primitive IO.
@MainActor public final class NikonMediaService: CameraMediaService, NikonMediaCatalogRecordSource {
    public let sessionID: CameraSessionID
    public private(set) var coveredCategory: NikonMediaCategory?
    public private(set) var listedCount = 0
    public var storageRecords: [NikonMediaStorageRecord] {
        storageSource == io.sourceIdentity ? acceptedStorage : []
    }
    private var acceptedStorage: [NikonMediaStorageRecord] = []
    private var storageSource: NikonMediaSourceIdentity?
    private final class StorageRead {}
    private var storageRead: StorageRead?
    private let io: any NikonMediaIO
    private let now: @Sendable () -> Duration
    private var current: NikonMediaBrowse?
    private var request = NikonMediaCatalogRequest(cached: [], category: .all)
    public init(
        session: CameraSessionID, io: any NikonMediaIO,
        now: (@Sendable () -> Duration)? = nil
    ) {
        let origin = ContinuousClock.now
        sessionID = session
        self.io = io
        self.now = now ?? { origin.duration(to: .now) }
    }
    public func configure(_ request: NikonMediaCatalogRequest) {
        self.request = request
        coveredCategory = nil
    }
    public func openBrowse() async throws -> any CameraMediaBrowse {
        guard let source = io.sourceIdentity, source.session == sessionID else {
            throw MediaServiceError.unavailable
        }
        current?.retire()
        if storageSource != source {
            acceptedStorage = []
            storageSource = nil
        }
        let browse = NikonMediaBrowse(owner: self, source: source)
        current = browse
        return browse
    }
    /// The app requests this at the donor's actual per-appearance cadence, including local views.
    /// Facts require the same actual source on both sides; an already-open lease also stays exact.
    public func refreshStorage() async throws {
        guard let source = io.sourceIdentity, source.session == sessionID else {
            throw MediaServiceError.unavailable
        }
        if let current, current.closed || current.source != source {
            current.retire()
            self.current = nil
            coveredCategory = nil
            listedCount = 0
        }
        let existing = current
        if let existing { try check(existing) }
        let read = StorageRead()
        storageRead = read
        acceptedStorage = []
        storageSource = nil
        let storage = try await io.storage(source: source)
        try Task.checkCancellation()
        guard io.sourceIdentity == source, storageRead === read else {
            throw MediaServiceError.retired
        }
        if let existing { try check(existing) }
        // With no lease at invocation, a new lease of this same actual source may use its facts.
        // Storage facts are not old/new object records and carry no consumer persistence action.
        if let current, current.source != source { throw MediaServiceError.retired }
        acceptedStorage = storage
        storageSource = source
    }
    public func invalidateCatalogCoverage() { coveredCategory = nil }
    public func isCurrent(_ binding: MediaBrowseBinding) -> Bool {
        guard let current, current.binding == binding else { return false }
        return (try? check(current)) != nil
    }
    public func cancelCatalog() {
        current?.cursor?.close()
        current?.cursor = nil
        coveredCategory = nil
    }
    public func retire() {
        current?.retire()
        current = nil
        coveredCategory = nil
        listedCount = 0
        acceptedStorage = []
        storageSource = nil
        storageRead = nil
    }
    public func mediaPairingUpdates(binding: MediaBrowseBinding) -> [NikonMediaPairingUpdate]? {
        guard let current, current.binding == binding, (try? check(current)) != nil else {
            return nil
        }
        return current.pairingUpdates
    }
    public func mediaCatalogRecord(_ asset: MediaAssetID, binding: MediaBrowseBinding)
        -> NikonMediaCatalogRecord?
    {
        guard let current, current.binding == binding, (try? check(current)) != nil,
            let object = current.records[asset]
        else { return nil }
        return .init(asset: asset, object: object)
    }
    fileprivate func check(_ browse: NikonMediaBrowse) throws {
        try Task.checkCancellation()
        guard current === browse, !browse.closed, io.sourceIdentity == browse.source else {
            throw MediaServiceError.retired
        }
    }
    fileprivate func makeCursor(_ browse: NikonMediaBrowse) throws -> NikonMediaCursor {
        try check(browse)
        browse.cursor?.close()
        browse.pairingUpdates = []
        listedCount = 0
        coveredCategory = nil
        let cursor = NikonMediaCursor(owner: self, browse: browse, request: request, now: now)
        browse.cursor = cursor
        return cursor
    }
    fileprivate func check(_ cursor: NikonMediaCursor) throws {
        try check(cursor.browse)
        guard !cursor.closed, cursor.browse.cursor === cursor else {
            throw MediaServiceError.retired
        }
    }
    fileprivate func handles(_ cursor: NikonMediaCursor) async throws -> NikonMediaHandleSnapshot {
        try check(cursor)
        let value = try await io.handles(source: cursor.browse.source)
        try check(cursor)
        return value
    }
    fileprivate func handles(formats: [UInt32], cursor: NikonMediaCursor) async throws
        -> [MediaObjectHandle]?
    {
        try check(cursor)
        do {
            let value = try await io.handles(formats: formats, source: cursor.browse.source)
            try check(cursor)
            return value
        } catch {
            try check(cursor)
            if error is CancellationError { throw error }
            return nil  // Preserve rejected-format fallback, never swallow retirement.
        }
    }
    fileprivate func object(_ location: MediaObjectHandle, cursor: NikonMediaCursor) async throws
        -> NikonMediaObjectRecord?
    {
        try check(cursor)
        let value = try await io.object(location, source: cursor.browse.source)
        try check(cursor)
        return value
    }
    fileprivate func header(_ location: MediaObjectHandle, cursor: NikonMediaCursor) async throws
        -> Data?
    {
        try check(cursor)
        do {
            let value = try await io.header(location, source: cursor.browse.source)
            try check(cursor)
            return value
        } catch {
            try check(cursor)
            if error is CancellationError { throw error }
            return nil
        }
    }
    fileprivate func publish(
        _ objects: [NikonMediaObjectRecord], removed: [NikonMediaObjectRecord],
        cursor: NikonMediaCursor, complete: Bool, volumes: [StorageVolume]?,
        pairingUpdates: [NikonMediaPairingUpdate] = []
    ) throws -> MediaCatalogDelta {
        try check(cursor)
        let namespace = io.cameraNamespace
        for object in objects + removed {
            cursor.browse.records[object.asset(namespace: namespace).id] = object
        }
        cursor.browse.pairingUpdates = pairingUpdates
        listedCount = cursor.listedCount
        if complete { coveredCategory = cursor.request.category }
        let reset = !cursor.hasPublished
        cursor.hasPublished = true
        return .init(
            reset: reset, upserts: objects.map { $0.asset(namespace: namespace) },
            removed: removed.map { $0.asset(namespace: namespace).id }, volumes: volumes,
            complete: complete)
    }
}

@MainActor private final class NikonMediaBrowse: CameraMediaBrowse {
    let binding: MediaBrowseBinding
    let source: NikonMediaSourceIdentity
    weak var owner: NikonMediaService?
    var closed = false
    var cursor: NikonMediaCursor?
    // Immutable capture records are kept for this browse only, including accepted tombstones.
    var records: [MediaAssetID: NikonMediaObjectRecord] = [:]
    var pairingUpdates: [NikonMediaPairingUpdate] = []
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    init(owner: NikonMediaService, source: NikonMediaSourceIdentity) {
        self.owner = owner
        self.source = source
        binding = .init(session: source.session, epoch: source.epoch)
    }
    func catalog() async throws -> any MediaCatalogCursor {
        guard let owner else { throw MediaServiceError.retired }
        return try owner.makeCursor(self)
    }
    func retire() {
        closed = true
        cursor?.close()
        cursor = nil
        records.removeAll()
        pairingUpdates.removeAll()
    }
    func close() async { retire() }
}

@MainActor private final class NikonMediaCursor: MediaCatalogCursor {
    weak var owner: NikonMediaService?
    let browse: NikonMediaBrowse
    let request: NikonMediaCatalogRequest
    let now: @Sendable () -> Duration
    var closed = false
    var listedCount = 0
    var hasPublished = false
    private var pulling = false
    private var initialized = false
    private var finished = false
    private var incomplete = false
    private var handles: [MediaObjectHandle] = []
    private var position = 0
    private var fallback = false
    private var seenThisPass: Set<MediaObjectHandle> = []
    private var refetchable: Set<MediaObjectHandle> = []
    private var cached: [MediaObjectHandle: NikonMediaObjectRecord] = [:]
    private var live: [MediaObjectHandle: NikonMediaObjectRecord] = [:]
    private var reuse: Set<MediaObjectHandle> = []
    private var pending: [NikonMediaObjectRecord] = []
    private var removals: [NikonMediaObjectRecord] = []
    private var volumes: [StorageVolume]?
    private var firstPage = true
    private var r3d = R3DClipIndex()
    private var pairing: [String: NikonMediaPairingRecord] = [:]
    private var pendingPairingUpdates: [NikonMediaPairingUpdate] = []

    init(
        owner: NikonMediaService, browse: NikonMediaBrowse, request: NikonMediaCatalogRequest,
        now: @escaping @Sendable () -> Duration
    ) {
        self.owner = owner
        self.browse = browse
        self.request = request
        self.now = now
        for object in request.cached {
            cached[object.location] = object
            live[object.location] = object
        }
        for object in request.pairing {
            pairing[object.filename] = object
            if MediaClipFilename.isR3D(object.filename), let width = object.pixelWidth,
                let height = object.pixelHeight
            {
                r3d.registerR3D(filename: object.filename, width: width, height: height)
            } else if MediaClipFilename.isPlayableProxy(object.filename) {
                r3d.noteProxy(object.filename)
            }
        }
    }
    func close() {
        closed = true
        pending.removeAll()
        removals.removeAll()
        pendingPairingUpdates.removeAll()
    }

    func next() async throws -> MediaCatalogDelta? {
        guard let owner else { throw MediaServiceError.retired }
        try owner.check(self)
        guard !pulling else { throw MediaServiceError.refused }
        if finished {
            if incomplete { throw MediaServiceError.unavailable }
            return nil
        }
        pulling = true
        defer { pulling = false }
        if !initialized {
            try await initialize(owner)
            initialized = true
        }
        // Apply old content tombstones before emitting any replacement at those locations.
        // Large removals drain in bounded pages, so a late old removal cannot erase a successor.
        if !removals.isEmpty {
            let removed = Array(removals.prefix(32))
            removals.removeFirst(removed.count)
            let pageVolumes = firstPage ? volumes : nil
            firstPage = false
            return try owner.publish(
                [], removed: removed, cursor: self, complete: false, volumes: pageVolumes)
        }
        let began = now()
        while pending.count + pendingPairingUpdates.count < 32 && now() - began < .milliseconds(120)
        {
            try owner.check(self)
            if position >= handles.count {
                if !fallback {
                    try await prepareFallback(owner)
                    continue
                }
                finished = true
                break
            }
            let location = handles[position]
            position += 1
            let object: NikonMediaObjectRecord?
            if !fallback, reuse.contains(location) {
                object = cached[location]
            } else {
                object = try await owner.object(location, cursor: self)
            }
            try owner.check(self)
            if let object, let record = try await enrich(object, owner: owner) {
                live[record.location] = record
                pending.append(record)
                if matchesCategory(record) { listedCount += 1 }
            }
        }
        try owner.check(self)
        let objects = Array(pending.prefix(32))
        pending.removeFirst(objects.count)
        let removed = Array(removals.prefix(32))
        removals.removeFirst(removed.count)
        let updates = Array(pendingPairingUpdates.prefix(32))
        pendingPairingUpdates.removeFirst(updates.count)
        let complete =
            finished && pending.isEmpty && removals.isEmpty
            && pendingPairingUpdates.isEmpty && !incomplete
        // Continue draining staged changes after the source has finished issuing commands.
        if finished && (!pending.isEmpty || !removals.isEmpty || !pendingPairingUpdates.isEmpty) {
            finished = false
        }
        let pageVolumes = firstPage ? volumes : nil
        firstPage = false
        return try owner.publish(
            objects, removed: removed, cursor: self, complete: complete, volumes: pageVolumes,
            pairingUpdates: updates)
    }

    private func initialize(_ owner: NikonMediaService) async throws {
        let snapshot = try await owner.handles(self)
        incomplete = !snapshot.complete
        let authoritativeCached = Set(
            cached.keys.filter { location in
                snapshot.authoritativeStorages.contains(location.storageID)
                    || (snapshot.storageListAuthoritative
                        && !snapshot.failedStorages.contains(location.storageID))
            })
        var delta = MediaClipDiscoveryDelta.compute(
            cachedHandles: authoritativeCached, cameraHandles: snapshot.handles)
        var probed: [MediaObjectHandle: MediaClipObjectIdentity] = [:]
        let identities = cached.mapValues(\.identity)
        for location in delta.identityProbeHandles(budget: request.identityProbeBudget) {
            try owner.check(self)
            guard delta.reuseHandles.contains(location) else { continue }
            let fetched = try await owner.object(location, cursor: self)
            probed[location] =
                fetched?.identity
                ?? .init(location: location, filename: "", captureDate: "", sizeBytes: 0)
            delta = delta.verifyingReusedIdentities(cached: identities, probed: probed)
        }
        refetchable = delta.removedHandles.union(delta.supersededHandles)
        removals = refetchable.compactMap { cached[$0] }
        for location in refetchable { live[location] = nil }
        reuse = delta.reuseHandles
        var scopedCache = cached
        for location in delta.supersededHandles { scopedCache[location] = nil }
        handles = try await scoped(snapshot.handles, cache: scopedCache, owner: owner)
        seenThisPass = Set(handles)
        let storage = owner.storageRecords
        if snapshot.complete && snapshot.authoritativeStorages.isEmpty {
            volumes = []
        } else if !storage.isEmpty {
            volumes = storage.map { record in
                let free: ObservedValue<UInt64> =
                    record.info.freeSpaceBytes == PTPStorageInfo.unknownCapacityBytes
                    ? .unknown : .init(record.info.freeSpaceBytes, origin: .cameraReported, at: nil)
                return .init(id: String(record.id), freeBytes: free)
            }
        }
    }

    private func scoped(
        _ all: [MediaObjectHandle], cache: [MediaObjectHandle: NikonMediaObjectRecord],
        owner: NikonMediaService
    ) async throws -> [MediaObjectHandle] {
        let wantsVideo: Bool
        switch request.category {
        case .videos: wantsVideo = true
        case .photos: wantsVideo = false
        case .all, .favorites: return all.sorted { $0.handle > $1.handle }
        }
        var wanted: [MediaObjectHandle] = []
        var unknown: [MediaObjectHandle] = []
        for location in all {
            if let known = cache[location] {
                if !known.isPhoto == wantsVideo { wanted.append(location) }
            } else {
                unknown.append(location)
            }
        }
        guard !unknown.isEmpty else { return wanted.sorted { $0.handle > $1.handle } }
        let wantedFormats = wantsVideo ? MediaObjectFormats.video : MediaObjectFormats.photo
        let otherFormats = wantsVideo ? MediaObjectFormats.photo : MediaObjectFormats.video
        if let partition = try await owner.handles(formats: wantedFormats, cursor: self),
            let other = try await owner.handles(formats: otherFormats, cursor: self)
        {
            // Preserve the donor's dual-query honor test and learn-then-skip fallback.
            let wantedSet = Set(partition.map(\.handle))
            let otherSet = Set(other.map(\.handle))
            wanted.append(
                contentsOf: wantedSet != otherSet
                    ? unknown.filter {
                        wantedSet.contains($0.handle) || !otherSet.contains($0.handle)
                    }
                    : unknown)
        } else {
            wanted.append(contentsOf: unknown)
        }
        return wanted.sorted { $0.handle > $1.handle }
    }

    private func matchesCategory(_ record: NikonMediaObjectRecord) -> Bool {
        switch request.category {
        case .videos: !record.isPhoto
        case .photos: record.isPhoto
        case .all, .favorites: true
        }
    }

    private func enrich(_ object: NikonMediaObjectRecord, owner: NikonMediaService) async throws
        -> NikonMediaObjectRecord?
    {
        guard MediaClipFilename.safeCameraBasename(object.filename) == object.filename else {
            return nil
        }
        var record = object
        if MediaClipFilename.isR3D(record.filename),
            (record.pixelWidth ?? 0) == 0 || (record.pixelHeight ?? 0) == 0
        {
            if let header = try await owner.header(record.location, cursor: self),
                let size = R3DHeaderParser.parseDimensions(from: header)
            {
                record.pixelWidth = size.width
                record.pixelHeight = size.height
            }
        }
        if MediaClipFilename.isR3D(record.filename), let width = record.pixelWidth,
            let height = record.pixelHeight
        {
            r3d.registerR3D(filename: record.filename, width: width, height: height)
            let stem = MediaClipFilename.stem(of: record.filename)
            for existing in Array(live.values)
            where MediaClipFilename.isPlayableProxy(existing.filename)
                && MediaClipFilename.stem(of: existing.filename) == stem
                && existing.linkedR3DFilename == nil
            {
                var proxy = existing
                proxy.sourcePixelWidth = width
                proxy.sourcePixelHeight = height
                proxy.linkedR3DFilename = record.filename
                live[proxy.location] = proxy
                pending.append(proxy)
            }
            // The donor also backfilled downloaded proxy rows without a camera location.
            for previous in Array(pairing.values)
            where MediaClipFilename.isPlayableProxy(previous.filename)
                && MediaClipFilename.stem(of: previous.filename) == stem
                && previous.linkedR3DFilename == nil
            {
                pendingPairingUpdates.append(
                    .init(
                        previous: previous, width: width, height: height,
                        masterFilename: record.filename))
                pairing[previous.filename] = .init(
                    filename: previous.filename,
                    captureDate: previous.captureDate, sizeBytes: previous.sizeBytes,
                    pixelWidth: previous.pixelWidth, pixelHeight: previous.pixelHeight,
                    sourcePixelWidth: width, sourcePixelHeight: height,
                    linkedR3DFilename: record.filename)
            }
        } else if MediaClipFilename.isPlayableProxy(record.filename) {
            r3d.noteProxy(record.filename)
            if let sibling = r3d.siblingForProxy(record.filename) {
                record.sourcePixelWidth = sibling.width
                record.sourcePixelHeight = sibling.height
                record.linkedR3DFilename = sibling.filename
            }
        }
        return record
    }

    private func prepareFallback(_ owner: NikonMediaService) async throws {
        fallback = true
        position = 0
        // The donor's post-removal census includes downloaded rows even without camera locations.
        // Host storage facts preserve those rows; removed remote-only metadata cannot invent one.
        let filenames = Array(
            Set(live.values.map(\.filename)).union(
                request.pairing.filter { request.retainedLocalFilenames.contains($0.filename) }.map(
                    \.filename)))
        let proxies = MediaClipFilename.playableProxyStems(in: filenames)
        guard
            filenames.contains(where: {
                MediaClipFilename.isR3D($0) && !proxies.contains(MediaClipFilename.stem(of: $0))
            }),
            let videos = try await owner.handles(formats: MediaObjectFormats.video, cursor: self)
        else {
            handles = []
            return
        }
        handles = videos.filter {
            !seenThisPass.contains($0) && (cached[$0] == nil || refetchable.contains($0))
        }
    }
}
