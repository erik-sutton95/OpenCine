import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

/// Bounded source operations for one captured record. The player owns order and retirement;
/// the existing library and SDK ports still own IO, cache receipts and camera acknowledgments.
@MainActor public struct MonitorOperatorPlaybackOperations<Payload: Sendable, Look: Sendable> {
    public let cacheOriginal: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
    public let delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Bool)?
    public let favorite: (@MainActor (MonitorMediaRecord<Payload>) -> Void)?
    public let adoptLook: (@MainActor (MonitorMediaRecord<Payload>, MonitorPlaybackLook<Look>) -> Void)?
    public let access: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess)?
    public let rating: MonitorMediaPlaybackRatingService<Payload>?
    /// Capture frozen consequences and source admission before showing a destructive dialog.
    public let captureDeletion: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorOperatorPlaybackDeletionRequest?)?
    public init(cacheOriginal: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)? = nil,
        delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Bool)? = nil,
        favorite: (@MainActor (MonitorMediaRecord<Payload>) -> Void)? = nil,
        adoptLook: (@MainActor (MonitorMediaRecord<Payload>, MonitorPlaybackLook<Look>) -> Void)? = nil,
        access: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess)? = nil,
        rating: MonitorMediaPlaybackRatingService<Payload>? = nil) {
        self.cacheOriginal = cacheOriginal; self.delete = delete; self.favorite = favorite; self.adoptLook = adoptLook
        self.access = access; self.rating = rating; self.captureDeletion = nil
    }
    /// Additive route; the original initializer and its trailing callback remain unchanged.
    public init(captureDeletion: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorOperatorPlaybackDeletionRequest?,
        cacheOriginal: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)? = nil,
        delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Bool)? = nil,
        favorite: (@MainActor (MonitorMediaRecord<Payload>) -> Void)? = nil,
        adoptLook: (@MainActor (MonitorMediaRecord<Payload>, MonitorPlaybackLook<Look>) -> Void)? = nil,
        access: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess)? = nil,
        rating: MonitorMediaPlaybackRatingService<Payload>? = nil) {
        self.cacheOriginal = cacheOriginal; self.delete = delete; self.favorite = favorite; self.adoptLook = adoptLook
        self.access = access; self.rating = rating; self.captureDeletion = captureDeletion
    }
}

/// Admission after a real removal may accept the outgoing owner's single close revision.
/// A replacement item, gallery or cache generation is never the removed presentation.
public enum MonitorPlaybackRemovalAdmission {
    public static func accepts(removed: MediaAssetID?, captured: MediaAssetID,
        token: MonitorPlaybackItemToken, current: MonitorPlaybackItemToken,
        active: MediaAssetID?, closed: Bool, sameComposition: Bool,
        sameGallery: Bool, sameContent: Bool) -> Bool {
        removed == captured && sameComposition && sameGallery && sameContent && active == captured
            && (current == token || (closed && current == .init(owner: token.owner, revision: token.revision &+ 1)))
    }
}

/// Owns gallery binding and its nested player while the shell keeps one camera owner.
/// Codec, cache namespace and native playback vary; cover and item lifetime do not.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorOperatorMediaModel<Payload: Sendable, Look: Sendable> {
    public let library: MonitorMediaLibraryModel<Payload>
    private struct State {
        var playback: MonitorMediaPlaybackModel<Payload, Look>?
        var galleryOpen = false
        var playerVisible = false
        var deliveryPresented = false
        var ratingStars: Int?
        var ratingPending = false
        var ratingNotice: String?
        var ratingShadeOpen = false
    }
    @ObservationIgnored private var state = State()
    public private(set) var playback: MonitorMediaPlaybackModel<Payload, Look>? {
        get { access(keyPath: \.playback); return state.playback }
        set { state.playback = newValue; withMutation(keyPath: \.playback) {} }
    }
    public private(set) var galleryOpen: Bool {
        get { access(keyPath: \.galleryOpen); return state.galleryOpen }
        set { state.galleryOpen = newValue; withMutation(keyPath: \.galleryOpen) {} }
    }
    public private(set) var playerVisible: Bool {
        get { access(keyPath: \.playerVisible); return state.playerVisible }
        set { state.playerVisible = newValue; withMutation(keyPath: \.playerVisible) {} }
    }
    public private(set) var deliveryPresented: Bool {
        get { access(keyPath: \.deliveryPresented); return state.deliveryPresented }
        set { state.deliveryPresented = newValue; withMutation(keyPath: \.deliveryPresented) {} }
    }
    public private(set) var ratingStars: Int? {
        get { access(keyPath: \.ratingStars); return state.ratingStars }
        set { state.ratingStars = newValue; withMutation(keyPath: \.ratingStars) {} }
    }
    public private(set) var ratingPending: Bool {
        get { access(keyPath: \.ratingPending); return state.ratingPending }
        set { state.ratingPending = newValue; withMutation(keyPath: \.ratingPending) {} }
    }
    public private(set) var ratingNotice: String? {
        get { access(keyPath: \.ratingNotice); return state.ratingNotice }
        set { state.ratingNotice = newValue; withMutation(keyPath: \.ratingNotice) {} }
    }
    public var ratingShadeOpen: Bool {
        get { access(keyPath: \.ratingShadeOpen); return state.ratingShadeOpen }
        set { state.ratingShadeOpen = newValue; withMutation(keyPath: \.ratingShadeOpen) {} }
    }
    @ObservationIgnored private let makePlayback:
        @MainActor (MonitorMediaLibraryModel<Payload>, MonitorPlaybackAdmission) -> MonitorMediaPlaybackModel<Payload, Look>?
    @ObservationIgnored private let recordAdmission:
        (@MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission)?
    @ObservationIgnored private var source: CameraSessionID?
    @ObservationIgnored private var bound = false
    @ObservationIgnored private var page = UUID()
    @ObservationIgnored private var transition = UUID()
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var cacheRequest: MonitorPlaybackItemToken?
    /// Full-resolution downloads started by playback (Full Resolution Caching), keyed by clip.
    /// They run for the library's lifetime, not one player page: closing the player or moving
    /// to the next clip keeps the download running, so the clip reads as cached afterwards.
    /// Closing the gallery this model opened, or the library retiring its source, stops them.
    @ObservationIgnored private var originalTasks: [MediaAssetID: (id: UUID, task: Task<Void, Never>)] = [:]
    private struct CapturedDeletion {
        let request: MonitorOperatorPlaybackDeletionRequest
        let record: MonitorMediaRecord<Payload>
        let owner: MonitorMediaPlaybackModel<Payload, Look>
        let token: MonitorPlaybackItemToken
        let page: UUID
        let generation: UInt64
        let source: MonitorMediaLibraryActionToken
        let survivors: [MonitorMediaRecord<Payload>]
        let successor: MediaAssetID?
    }
    @ObservationIgnored private var deletionRevision = UUID()
    @ObservationIgnored private var pendingDeletion: CapturedDeletion?
    @ObservationIgnored private var enteredDeletion: MonitorOperatorPlaybackDeletionRequest?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var adoptedLook: UUID?
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var ratingRead: MonitorPlaybackItemToken?
    @ObservationIgnored private var ratingRevision = UUID()
    @ObservationIgnored private var confirmedRating: Int?
    @ObservationIgnored private var ratingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var ratingNoticeID: UUID?

    public convenience init(library: MonitorMediaLibraryModel<Payload>,
        recordAdmission: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission)? = nil,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        makePlayback: @escaping @MainActor (MonitorMediaLibraryModel<Payload>)
            -> MonitorMediaPlaybackModel<Payload, Look>) {
        self.init(library: library, recordAdmission: recordAdmission, sleep: sleep,
            makeAdmittedPlayback: { library, _ in makePlayback(library) })
    }

    /// The same open request qualifies cleanup, native construction and publication in its adapter.
    public init(library: MonitorMediaLibraryModel<Payload>,
        recordAdmission: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission)? = nil,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        makeAdmittedPlayback: @escaping @MainActor (MonitorMediaLibraryModel<Payload>, MonitorPlaybackAdmission)
            -> MonitorMediaPlaybackModel<Payload, Look>?) {
        self.library = library; self.makePlayback = makeAdmittedPlayback; self.recordAdmission = recordAdmission
        self.sleep = sleep
    }

    public func bind(_ camera: ConnectedCamera?) {
        let next = camera?.session.id
        guard !bound || source != next else { return }
        guard retireGallery() else { return }
        bound = true; source = next
        library.bind(camera?.services[(any CameraMediaService).self])
    }

    public func showGallery() {
        guard !galleryOpen else { return }
        transition = UUID(); let captured = transition
        galleryOpen = true
        guard transition == captured, galleryOpen else { return }
        library.begin()
    }

    public func closeGallery() {
        _ = retireGallery()
    }

    private func retireGallery() -> Bool {
        guard retirePlayback() else { return false }
        let captured = transition
        let originals = originalTasks.values.map(\.task); originalTasks = [:]
        originals.forEach { $0.cancel() }
        guard transition == captured, playback == nil else { return false }
        guard galleryOpen else { return true }
        galleryOpen = false
        guard transition == captured, !galleryOpen else { return false }
        library.close()
        return transition == captured && !galleryOpen
    }

    /// UI actions keep the gallery authority they displayed; old covers cannot open a new item.
    @discardableResult public func open(_ id: MediaAssetID,
        admitted: MonitorMediaLibraryActionToken) -> Bool {
        guard galleryOpen, library.isCurrent(admitted),
            let record = library.displayedRecords.first(where: { $0.asset.id == id })
        else { return false }
        return open(record, playlist: library.displayedRecords, admitted: admitted)
    }

    /// A full-screen player may borrow an already-open gallery without becoming its browse owner.
    @discardableResult public func open(_ record: MonitorMediaRecord<Payload>,
        playlist: [MonitorMediaRecord<Payload>], admitted: MonitorMediaLibraryActionToken) -> Bool {
        guard record.facts.playbackEligible != false else { return false }
        let capturedPage = page
        transition = UUID(); let request = transition
        guard library.isCurrent(admitted) else { return false }
        let source = recordAdmission?(record)
        guard transition == request, page == capturedPage, library.isCurrent(admitted) else { return false }
        let acceptsRecord = source?.isCurrent() ?? (library.record(record.asset.id) != nil)
        guard acceptsRecord, transition == request, page == capturedPage, library.isCurrent(admitted) else { return false }
        if playback?.closed != false {
            let muted = playback?.muted ?? false, looping = playback?.looping ?? false
            let admission = MonitorPlaybackAdmission { [weak self] in
                guard let self else { return false }
                return self.transition == request && self.page == capturedPage && self.library.isCurrent(admitted)
            }
            guard let next = makePlayback(library, admission) else { return false }
            guard transition == request, page == capturedPage, library.isCurrent(admitted) else {
                if playback !== next { next.close() }; return false
            }
            let initial = next.token
            playback = next
            guard transition == request, page == capturedPage, playback === next else {
                if playback !== next { next.close() }; return false
            }
            guard next.token == initial else { return false }
            next.setMuted(muted)
            guard transition == request, page == capturedPage, playback === next, next.token == initial else { return false }
            next.setLooping(looping)
        }
        guard let owner = playback, transition == request, page == capturedPage else { return false }
        if owner.active?.asset.id != record.asset.id || owner.closed {
            retireWork()
            guard transition == request, page == capturedPage, playback === owner else { return false }
            owner.load(record, playlist: playlist.filter { $0.facts.playbackEligible != false })
        }
        guard transition == request, page == capturedPage, playback === owner, !owner.closed,
            owner.active?.asset.id == record.asset.id else { return false }
        owner.setSceneActive(sceneActive)
        guard transition == request, page == capturedPage, playback === owner else { return false }
        owner.setPresentationActive(playerVisible && !deliveryPresented)
        return transition == request && page == capturedPage && playback === owner && owner.active?.asset.id == record.asset.id
    }

    public func setPlayerVisible(_ value: Bool) {
        let capturedPage = page, owner = playback
        playerVisible = value
        guard page == capturedPage, playback === owner else { return }
        owner?.setPresentationActive(value && !deliveryPresented)
    }

    public func setSceneActive(_ value: Bool) {
        sceneActive = value
        playback?.setSceneActive(value)
    }

    /// Explicit Share pauses the admitted item before delivery and leaves it paused on return.
    @discardableResult public func beginShare(_ token: MonitorPlaybackItemToken) -> Bool {
        guard let owner = playback, isCurrent(token) else { return false }
        owner.setPlaying(false)
        guard isCurrent(token) else { return false }
        setDeliveryPresented(true)
        return isCurrent(token)
    }

    public func setDeliveryPresented(_ value: Bool) {
        let capturedPage = page, owner = playback
        deliveryPresented = value
        guard page == capturedPage, playback === owner else { return }
        owner?.setPresentationActive(playerVisible && !value)
    }

    /// `token` is still this page's item, without running the host's item admission. A host
    /// admission can read the file system (a camera index's file stamps); the playback page reads
    /// presentation facts many times per body pass and its glass backdrop up to 60 times a
    /// second, so presentation reads use this and actions keep ``isCurrent(_:)``. A retired or
    /// replaced item changes the token or closes the owner, so this still refuses it.
    public func presents(_ token: MonitorPlaybackItemToken) -> Bool {
        guard let owner = playback, owner.token == token, !owner.closed else { return false }
        return owner.holdsItem
    }

    public func isCurrent(_ token: MonitorPlaybackItemToken) -> Bool {
        guard let owner = playback, owner.token == token, !owner.closed else { return false }
        let capturedPage = page
        let admitted = owner.isActive
        return admitted && page == capturedPage && playback === owner && owner.token == token && !owner.closed
    }

    @discardableResult public func adjacent(_ offset: Int, admitted: MonitorPlaybackItemToken) -> Bool {
        guard isCurrent(admitted), let owner = playback, let active = owner.active,
            let index = owner.playlist.firstIndex(where: { $0.asset.id == active.asset.id }),
            owner.playlist.indices.contains(index + offset) else { return false }
        return open(owner.playlist[index + offset], playlist: owner.playlist, admitted: library.actionToken)
    }

    public func synchronizePlayback(cacheOriginal: Bool,
        operations: MonitorOperatorPlaybackOperations<Payload, Look>,
        cacheTiming: MonitorPlaybackStartTiming = .afterNativeReadiness) {
        guard let owner = playback, let record = owner.active, isCurrent(owner.token) else { return }
        let token = owner.token, capturedPage = page
        readRating(operations.rating)
        guard page == capturedPage, playback === owner, isCurrent(token) else { return }
        let mayDownload = operations.access.map { $0(record).download == true } ?? true
        guard page == capturedPage, playback === owner, isCurrent(token) else { return }
        if let look = owner.look, let resolution = owner.lookResolution, adoptedLook != resolution,
            let adopt = operations.adoptLook {
            adoptedLook = resolution
            adopt(record, look)
            guard page == capturedPage, playback === owner, isCurrent(token) else { return }
        }
        let mayCache = cacheTiming == .afterNativeItemInstallation ? owner.nativeItemInstalled : owner.ready
        let asset = record.asset.id
        guard cacheOriginal, mayDownload, mayCache, cacheRequest != token,
            library.entries[asset]?.originalURL == nil, let cache = operations.cacheOriginal else { return }
        cacheRequest = token
        guard originalTasks[asset] == nil else { return }
        let library = library, source = library.actionToken, generation = library.cache.directory.generation
        let id = UUID()
        // The library, not this page, keeps the download alive: an app may build this model per
        // player page and release it when the page closes.
        let task = Task { @MainActor [weak self, weak owner] in
            defer { if self?.originalTasks[asset]?.id == id { self?.originalTasks[asset] = nil } }
            guard library.isCurrent(source), library.cache.directory.generation == generation,
                !Task.isCancelled else { return }
            await cache(record)
            guard let self, let owner, self.page == capturedPage, self.playback === owner, self.isCurrent(token),
                library.isCurrent(source), library.cache.directory.generation == generation,
                !Task.isCancelled else { return }
            owner.refreshTransfer()
        }
        originalTasks[asset] = (id, task)
    }

    private func ratingRequest() -> MonitorMediaPlaybackRatingRequest<Payload>? {
        guard let owner = playback, let record = owner.active, isCurrent(owner.token) else { return nil }
        let capturedPage = page, token = owner.token, sourceToken = library.actionToken
        let generation = library.cache.directory.generation
        let source = recordAdmission?(record)
        guard page == capturedPage, playback === owner, isCurrent(token), library.isCurrent(sourceToken),
            library.cache.directory.generation == generation else { return nil }
        let admission = MonitorPlaybackAdmission { [weak self, weak owner] in
            guard let self, let owner, self.page == capturedPage, self.playback === owner,
                self.isCurrent(token), self.library.isCurrent(sourceToken),
                self.library.cache.directory.generation == generation else { return false }
            let current = source?.isCurrent() ?? (self.library.record(record.asset.id) != nil)
            return current && self.page == capturedPage && self.playback === owner && self.isCurrent(token)
                && self.library.isCurrent(sourceToken) && self.library.cache.directory.generation == generation
        }
        guard admission.isCurrent() else { return nil }
        return .init(record: record, item: token, admission: admission)
    }

    public func readRating(_ service: MonitorMediaPlaybackRatingService<Payload>?) {
        let revision = ratingRevision
        guard let service, let request = ratingRequest(), ratingRevision == revision,
            ratingRead != request.item else { return }
        ratingRead = request.item
        let id = UUID()
        ratingTasks[id] = Task { @MainActor [weak self] in
            defer { self?.ratingTasks[id] = nil }
            guard !Task.isCancelled, self?.admitsRating(revision, request: request) == true else { return }
            let value = await service.read(request)
            guard !Task.isCancelled, let self, self.admitsRating(revision, request: request) else { return }
            self.confirmedRating = value; self.ratingStars = value
        }
    }

    public func setRating(_ target: Int, service: MonitorMediaPlaybackRatingService<Payload>) {
        let previousRevision = ratingRevision
        guard target == 0 || service.levels.contains(target), let request = ratingRequest(),
            ratingRevision == previousRevision else { return }
        ratingRevision = UUID(); let revision = ratingRevision, id = UUID()
        ratingStars = target
        guard admitsRating(revision, request: request) else { return }
        ratingPending = true
        guard admitsRating(revision, request: request) else { return }
        ratingTasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.ratingTasks[id] = nil
                if self?.ratingRevision == revision { self?.ratingPending = false }
            }
            guard !Task.isCancelled, self?.admitsRating(revision, request: request) == true else { return }
            let result = await service.commit(target, request)
            guard !Task.isCancelled, let self, self.admitsRating(revision, request: request) else { return }
            switch result {
            case .confirmed(let value):
                self.confirmedRating = value; self.ratingStars = value
                guard self.admitsRating(revision, request: request) else { return }
                self.dismissRatingNotice()
            case .refused(let message):
                self.ratingStars = self.confirmedRating
                guard self.admitsRating(revision, request: request) else { return }
                if let message {
                    self.showRatingNotice(message, request: request, revision: revision, duration: service.noticeDuration)
                }
            case .unavailable:
                self.ratingStars = self.confirmedRating
                guard self.admitsRating(revision, request: request) else { return }
                if let message = service.unavailableMessage {
                    self.showRatingNotice(message, request: request, revision: revision, duration: service.noticeDuration)
                }
            }
        }
    }

    public func dismissRatingNotice() {
        let revision = ratingRevision
        let previous = ratingNoticeID.flatMap { ratingTasks.removeValue(forKey: $0) }
        ratingNoticeID = nil; previous?.cancel()
        guard ratingRevision == revision, ratingNoticeID == nil else { return }
        ratingNotice = nil
    }

    private func showRatingNotice(_ message: String, request: MonitorMediaPlaybackRatingRequest<Payload>,
        revision: UUID, duration: Duration) {
        guard admitsRating(revision, request: request) else { return }
        dismissRatingNotice()
        guard admitsRating(revision, request: request) else { return }
        let id = UUID(); ratingNoticeID = id; ratingNotice = message
        guard ratingNoticeID == id, admitsRating(revision, request: request), ratingNoticeID == id else { return }
        ratingTasks[id] = Task { @MainActor [weak self] in
            defer { self?.ratingTasks[id] = nil }
            guard let self else { return }
            do { try await self.sleep(duration) } catch { return }
            guard !Task.isCancelled, self.ratingNoticeID == id, self.admitsRating(revision, request: request),
                self.ratingNoticeID == id else { return }
            self.ratingNoticeID = nil; self.ratingNotice = nil
        }
    }

    private func admitsRating(_ revision: UUID, request: MonitorMediaPlaybackRatingRequest<Payload>) -> Bool {
        guard ratingRevision == revision else { return false }
        let current = request.isCurrent
        return current && ratingRevision == revision
    }

    /// Captures exactly the consequences displayed by this item's confirmation. No IO begins.
    public func captureDeletion(admitted token: MonitorPlaybackItemToken,
        operations: MonitorOperatorPlaybackOperations<Payload, Look>) -> MonitorPlaybackDeletionConfirmation? {
        guard enteredDeletion == nil, isCurrent(token), let owner = playback, let record = owner.active,
            let capture = operations.captureDeletion else { return nil }
        let capturedPage = page, generation = library.cache.directory.generation, source = library.actionToken
        if let access = operations.access {
            if access(record).delete != true { return nil }
        } else if record.asset.deletable != true { return nil }
        guard page == capturedPage, playback === owner, isCurrent(token) else { return nil }
        cancelPendingDeletion()
        let revision = deletionRevision
        guard let request = capture(record) else { return nil }
        guard deletionRevision == revision, page == capturedPage, playback === owner, isCurrent(token),
            library.isCurrent(source), library.cache.directory.generation == generation, request.authority.isCurrent,
            request.authority.directory === library.cache.directory,
            deletionRevision == revision, page == capturedPage, playback === owner, isCurrent(token),
            library.isCurrent(source), library.cache.directory.generation == generation else {
            request.authority.retire(); return nil
        }
        let index = owner.playlist.firstIndex { $0.asset.id == record.asset.id } ?? 0
        let survivors = owner.playlist.filter { $0.asset.id != record.asset.id }
        pendingDeletion = .init(request: request, record: record, owner: owner, token: token,
            page: capturedPage, generation: generation, source: source, survivors: survivors,
            successor: survivors.isEmpty ? nil : survivors[min(index, survivors.count - 1)].asset.id)
        return request.confirmation
    }

    public func isDeletionCurrent(admitted id: UUID) -> Bool {
        guard let captured = pendingDeletion, captured.request.confirmation.id == id,
            page == captured.page, playback === captured.owner, isCurrent(captured.token),
            library.cache.directory.generation == captured.generation,
            captured.request.authority.isCurrent else { return false }
        return pendingDeletion?.request.confirmation.id == id && page == captured.page &&
            playback === captured.owner && isCurrent(captured.token) &&
            library.cache.directory.generation == captured.generation
    }

    /// Cancel revokes only this displayed request and never enters its native performer.
    public func cancelDeletion(admitted id: UUID) {
        guard pendingDeletion?.request.confirmation.id == id else { return }
        cancelPendingDeletion()
    }
    private func cancelPendingDeletion() {
        deletionRevision = UUID()
        let outgoing = pendingDeletion; pendingDeletion = nil; outgoing?.request.authority.retire()
    }

    /// Consumes the captured request once. Only its existing completion may cross a planned relist.
    public func confirmDeletion(admitted id: UUID) {
        guard let captured = pendingDeletion, captured.request.confirmation.id == id else { return }
        pendingDeletion = nil
        guard page == captured.page, playback === captured.owner, isCurrent(captured.token),
            captured.request.authority.isCurrent,
            library.cache.directory.generation == captured.generation,
            page == captured.page, playback === captured.owner, isCurrent(captured.token) else {
            captured.request.authority.retire(); return
        }
        let previous = deleteTask; deleteTask = nil; previous?.cancel()
        enteredDeletion?.authority.retire(); enteredDeletion = captured.request
        deleteTask = Task { @MainActor [weak self] in
            guard let self else { captured.request.authority.retire(); return }
            defer {
                if self.enteredDeletion?.confirmation.id == id {
                    self.enteredDeletion = nil; self.deleteTask = nil; captured.request.authority.retire()
                }
            }
            guard !Task.isCancelled, self.page == captured.page, self.playback === captured.owner,
                self.isCurrent(captured.token), captured.request.authority.isCurrent,
                self.page == captured.page, self.playback === captured.owner, self.isCurrent(captured.token) else { return }
            await captured.request.perform()
            guard !Task.isCancelled, self.page == captured.page, self.playback === captured.owner,
                self.library.cache.directory.generation == captured.generation,
                let completion = captured.request.authority.completion,
                completion.claim == captured.request.authority.id, completion.isCurrent,
                self.library.isCurrent(completion.admission), self.page == captured.page,
                self.playback === captured.owner,
                self.library.cache.directory.generation == captured.generation else {
                // A declined performer may close its outgoing native item before source IO.
                // Restore only when the original gallery/source still admits this same item.
                if !Task.isCancelled, self.page == captured.page, self.playback === captured.owner,
                    self.library.cache.directory.generation == captured.generation,
                    self.library.isCurrent(captured.source), captured.request.authority.isCurrent,
                    captured.owner.closed, captured.owner.active?.asset.id == captured.record.asset.id,
                    captured.owner.token == .init(owner: captured.token.owner, revision: captured.token.revision &+ 1),
                    self.page == captured.page, self.playback === captured.owner,
                    let retained = self.library.record(captured.record.asset.id) {
                    self.enteredDeletion = nil
                    _ = self.open(retained, playlist: captured.owner.playlist.compactMap { self.library.record($0.asset.id) },
                        admitted: captured.source)
                }
                return
            }
            let removed = self.library.record(captured.record.asset.id) == nil
            guard MonitorPlaybackRemovalAdmission.accepts(
                removed: removed ? captured.record.asset.id : nil, captured: captured.record.asset.id,
                token: captured.token, current: captured.owner.token,
                active: captured.owner.active?.asset.id, closed: captured.owner.closed,
                sameComposition: true, sameGallery: true, sameContent: true) ||
                (!removed && captured.owner.closed && captured.owner.active?.asset.id == captured.record.asset.id &&
                    captured.owner.token == .init(owner: captured.token.owner, revision: captured.token.revision &+ 1))
            else { return }
            self.enteredDeletion = nil
            let preferred = captured.survivors.firstIndex { $0.asset.id == captured.successor } ?? 0
            let successor = captured.survivors.dropFirst(preferred).compactMap { self.library.record($0.asset.id) }.first
                ?? captured.survivors.prefix(preferred).reversed().compactMap { self.library.record($0.asset.id) }.first
            if !removed, let retained = self.library.record(captured.record.asset.id) {
                _ = self.open(retained, playlist: captured.owner.playlist.compactMap { self.library.record($0.asset.id) }, admitted: completion.admission)
            } else if let successor {
                _ = self.open(successor, playlist: captured.survivors.compactMap { self.library.record($0.asset.id) }, admitted: completion.admission)
            } else { self.closePlayback() }
        }
    }

    public func deleteCurrent(admitted token: MonitorPlaybackItemToken,
        operations: MonitorOperatorPlaybackOperations<Payload, Look>) {
        guard isCurrent(token), let owner = playback, let dying = owner.active,
            let delete = operations.delete else { return }
        let capturedPage = page, source = library.actionToken, generation = library.cache.directory.generation
        if let access = operations.access {
            guard access(dying).delete == true, page == capturedPage, playback === owner, isCurrent(token),
                library.isCurrent(source), library.cache.directory.generation == generation else { return }
        }
        let index = owner.playlist.firstIndex { $0.asset.id == dying.asset.id } ?? 0
        let survivors = owner.playlist.filter { $0.asset.id != dying.asset.id }
        let successor = survivors.isEmpty ? nil : survivors[min(index, survivors.count - 1)]
        let previous = deleteTask; deleteTask = nil; previous?.cancel()
        guard page == capturedPage, playback === owner, isCurrent(token) else { return }
        deleteTask = Task { @MainActor [weak self, weak owner] in
            guard let self, let owner, self.page == capturedPage, self.playback === owner,
                self.library.isCurrent(source), self.library.cache.directory.generation == generation,
                self.isCurrent(token), !Task.isCancelled else { return }
            let removed = await delete(dying)
            guard !Task.isCancelled,
                MonitorPlaybackRemovalAdmission.accepts(removed: removed ? dying.asset.id : nil,
                    captured: dying.asset.id, token: token, current: owner.token,
                    active: owner.active?.asset.id, closed: owner.closed,
                    sameComposition: self.page == capturedPage && self.playback === owner,
                    sameGallery: self.library.isCurrent(source),
                    sameContent: self.library.cache.directory.generation == generation),
                self.library.record(dying.asset.id) == nil else { return }
            if let successor, let current = self.library.record(successor.asset.id) {
                _ = self.open(current, playlist: survivors, admitted: source)
            } else { self.closePlayback() }
        }
    }

    private func retireWork() {
        cancelPendingDeletion()
        enteredDeletion?.authority.retire(); enteredDeletion = nil
        let previousDelete = deleteTask
        let previousRating = ratingTasks.values
        ratingTasks = [:]; ratingRevision = UUID(); ratingRead = nil; ratingNoticeID = nil
        confirmedRating = nil
        deleteTask = nil; cacheRequest = nil; adoptedLook = nil
        previousDelete?.cancel()
        previousRating.forEach { $0.cancel() }
        state.ratingStars = nil; state.ratingPending = false; state.ratingNotice = nil
        let revision = ratingRevision
        withMutation(keyPath: \.ratingStars) {}
        guard ratingRevision == revision else { return }
        withMutation(keyPath: \.ratingPending) {}
        guard ratingRevision == revision else { return }
        withMutation(keyPath: \.ratingNotice) {}
    }

    public func closePlayback() {
        _ = retirePlayback()
    }

    private func retirePlayback() -> Bool {
        let previous = playback
        page = UUID(); transition = UUID()
        let capturedPage = page, captured = transition
        retireWork()
        guard transition == captured, page == capturedPage, playback === previous else {
            if playback !== previous { previous?.close() }; return false
        }
        playback = nil
        guard transition == captured, page == capturedPage, playback == nil else { previous?.close(); return false }
        playerVisible = false
        guard transition == captured, page == capturedPage, playback == nil else { previous?.close(); return false }
        deliveryPresented = false
        previous?.close()
        return transition == captured && page == capturedPage && playback == nil
    }

    public func synchronize(cover: ShellModel.Cover?) {
        if cover == .media { showGallery() } else { closeGallery() }
    }
}
