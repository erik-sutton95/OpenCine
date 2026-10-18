import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

public enum MonitorMediaPictureLoadPolicy: Equatable, Sendable {
    /// Show a preview immediately, then replace it with the cached or source original.
    case previewThenOriginal
    /// The first decoded cached picture, preview or source representation is sufficient.
    case firstAvailable
}

/// A captured one-record read or mutation. The native adapter checks this before SDK dispatch.
@MainActor public struct MonitorMediaPictureRequest<Payload: Sendable> {
    public let record: MonitorMediaRecord<Payload>
    public let admission: MonitorMediaLibraryActionToken
    public let isCurrent: @MainActor () -> Bool
}

/// Native decoding and source addresses vary; fallback order and publication do not.
@MainActor public struct MonitorMediaPictureLoaders<Payload: Sendable, Picture> {
    public typealias Load = @MainActor (MonitorMediaPictureRequest<Payload>) async -> Picture?
    public let preview: Load?
    public let cached: Load?
    public let source: Load?
    public let progressive: (@MainActor (MonitorMediaPicturePublication<Payload, Picture>) async -> Picture?)?
    public init(preview: Load? = nil, cached: Load? = nil, source: Load? = nil,
        progressive: (@MainActor (MonitorMediaPicturePublication<Payload, Picture>) async -> Picture?)? = nil) {
        self.preview = preview; self.cached = cached; self.source = source
        self.progressive = progressive
    }
}

/// One borrowed still-picture presentation over the existing library/source/cache owners.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorMediaPictureModel<Payload: Sendable, Picture> {
    public let library: MonitorMediaLibraryModel<Payload>
    public let baseRecord: MonitorMediaRecord<Payload>
    public private(set) var record: MonitorMediaRecord<Payload>
    public let variants: [MonitorMediaPictureVariant<Payload>]
    public private(set) var admission: MonitorMediaLibraryActionToken
    public private(set) var deletionCompletion: MonitorMediaDeletionCompletion?
    public private(set) var picture: Picture?
    public private(set) var loading = false
    public private(set) var closing = false
    public private(set) var presentation = UUID()
    public private(set) var deleteRequestID: UUID?
    public private(set) var deletionMessage: String?
    public private(set) var variantSwitching = false
    public private(set) var preparingShare = false
    public private(set) var ratingStars: Int?
    /// A rating read is in flight; the photo screen shows neither control until it answers.
    public private(set) var ratingReading = false
    public private(set) var ratingPending = false
    public private(set) var ratingNotice: String?
    public private(set) var failure: String?
    public private(set) var status = MonitorMediaPictureStatus()
    public var optionsPresented = false
    public var helpPresented = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private let sourceCurrent: @MainActor () -> Bool
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deletion: (MonitorMediaPictureRequest<Payload>, [MonitorMediaRecord<Payload>])?
    @ObservationIgnored private var acceptedDeletions: [UUID: MonitorMediaLibraryDeletionAuthority] = [:]
    @ObservationIgnored private var loadID: UUID?
    @ObservationIgnored private var loadRevision = UUID()
    @ObservationIgnored private var variantRevision = UUID()
    @ObservationIgnored private var ratingRevision = UUID()
    @ObservationIgnored private var ratingReadID: UUID?
    @ObservationIgnored private var confirmedRating: Int?
    @ObservationIgnored private var noticeID: UUID?
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void

    public init(library: MonitorMediaLibraryModel<Payload>, record: MonitorMediaRecord<Payload>,
        admission: MonitorMediaLibraryActionToken? = nil,
        variants: [MonitorMediaPictureVariant<Payload>] = [],
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        sourceCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.library = library; baseRecord = record; self.record = record
        self.variants = variants; self.admission = admission ?? library.actionToken
        self.sourceCurrent = sourceCurrent; self.sleep = sleep
    }
    public var isCurrent: Bool {
        guard active, library.isCurrent(admission) else { return false }
        let available = sourceCurrent()
        return available && active && library.isCurrent(admission)
    }
    public var favorite: Bool { library.record(baseRecord.asset.id)?.favorite ?? baseRecord.favorite }
    public func activate() { active = library.isCurrent(admission) && sourceCurrent() }
    public func retire() {
        active = false; presentation = UUID()
        loadRevision = UUID(); variantRevision = UUID(); ratingRevision = UUID(); loadID = nil; noticeID = nil
        acceptedDeletions.values.forEach { $0.retire() }; acceptedDeletions.removeAll()
        deletionCompletion?.retire(); deletionCompletion = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        ratingReadID = nil; ratingReading = false
        loading = false; closing = false; variantSwitching = false; preparingShare = false; ratingPending = false; ratingNotice = nil
        optionsPresented = false; helpPresented = false; failure = nil; cancelDelete()
    }
    /// Return waits for entered native work to clean up, while revoking all new picture actions.
    public func close(completed: @escaping @MainActor () -> Void) {
        guard !closing else { return }
        let entered = Array(tasks.values)
        retire(); closing = true
        let origin = presentation, id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            defer { self?.tasks[id] = nil }
            for task in entered { await task.value }
            guard let self, !Task.isCancelled, !self.active, self.presentation == origin else { return }
            self.closing = false; completed()
        }
    }
    private func stopLoading() async {
        loadRevision = UUID(); let revision = loadRevision, origin = presentation
        let previous = loadID.flatMap { tasks[$0] }
        loadID = nil; previous?.cancel()
        await previous?.value
        if presentation == origin, loadRevision == revision { loading = false }
    }
    /// Selecting another shot returns the borrowed picture before the next native load enters.
    public func navigate(to id: MediaAssetID, selected: @escaping @MainActor (MonitorMediaRecord<Payload>) -> Void) {
        guard id != baseRecord.asset.id, let request = request(for: baseRecord, variant: false),
            let target = library.record(id), request.isCurrent() else { return }
        let generation = library.cache.directory.generation
        close { [weak self] in
            guard let self, self.library.isCurrent(request.admission),
                self.library.cache.directory.generation == generation, self.library.record(id) != nil else { return }
            let available = self.sourceCurrent()
            guard available, self.library.isCurrent(request.admission),
                self.library.cache.directory.generation == generation, self.library.record(id) != nil else { return }
            selected(target)
        }
    }
    public func sourceChanged() {
        guard !isCurrent else { return }
        let retained = Set(acceptedDeletions.filter {
            $0.value.isPrepared && ($0.value.isCurrent || $0.value.isCompleting || $0.value.completion?.isCurrent == true)
        }.map(\.key))
        guard !retained.isEmpty else { retire(); return }
        for id in Array(tasks.keys) where !retained.contains(id) { tasks.removeValue(forKey: id)?.cancel() }
        loadRevision = UUID(); variantRevision = UUID(); ratingRevision = UUID(); loadID = nil; noticeID = nil
        ratingReadID = nil; ratingReading = false
        loading = false; variantSwitching = false; preparingShare = false; ratingPending = false; ratingNotice = nil
        optionsPresented = false; helpPresented = false; cancelDelete()
    }
    public func request() -> MonitorMediaPictureRequest<Payload>? {
        request(for: record, variant: true)
    }
    public func request(for id: MediaAssetID) -> MonitorMediaPictureRequest<Payload>? {
        guard let value = library.record(id) else { return nil }
        return request(for: value, variant: false)
    }
    public func dismissFailure() { failure = nil }
    private func request(for value: MonitorMediaRecord<Payload>, variant: Bool) -> MonitorMediaPictureRequest<Payload>? {
        guard isCurrent, library.record(value.asset.id) != nil else { return nil }
        let origin = presentation, selected = variantRevision, generation = library.cache.directory.generation
        let token = admission
        return .init(record: value, admission: token, isCurrent: { [weak self] in
            guard let self else { return false }
            return self.isCurrent && self.admission == token && self.presentation == origin
                && self.library.cache.directory.generation == generation
                && (!variant || self.variantRevision == selected)
        })
    }
    public func load(_ loaders: MonitorMediaPictureLoaders<Payload, Picture>,
        policy: MonitorMediaPictureLoadPolicy = .previewThenOriginal) {
        guard let request = request() else { return }
        if let loadID { tasks[loadID]?.cancel() }
        loadRevision = UUID(); let revision = loadRevision
        loading = true; status = .init()
        let id = UUID(), origin = presentation
        loadID = id
        let loadRequest = MonitorMediaPictureRequest(record: request.record, admission: request.admission,
            isCurrent: { [weak self] in request.isCurrent() && self?.loadRevision == revision })
        let progressive: MonitorMediaPictureLoaders<Payload, Picture>.Load?
        if let port = loaders.progressive {
            progressive = { [weak self] request in
                await port(.init(request: request,
                    picture: { [weak self] value in if request.isCurrent() { self?.picture = value } },
                    status: { [weak self] value in if request.isCurrent() { self?.status = value } }))
            }
        } else {
            progressive = nil
        }
        let preview = loaders.preview
        let stages: [(MonitorMediaPictureLoaders<Payload, Picture>.Load?, Bool)] =
            policy == .previewThenOriginal
            ? [(preview, false), (loaders.cached, true), (progressive, true), (loaders.source, true)]
            : [(loaders.cached, true), (preview, true), (progressive, true), (loaders.source, true)]
        tasks[id] = Task { @MainActor [weak self] in
            defer {
                if self?.tasks.removeValue(forKey: id) != nil, self?.presentation == origin, self?.loadID == id {
                    self?.loading = false; self?.loadID = nil
                }
            }
            for (stage, complete) in stages {
                guard !Task.isCancelled, loadRequest.isCurrent() else { return }
                guard let stage else { continue }
                let value = await stage(loadRequest)
                guard !Task.isCancelled, loadRequest.isCurrent() else { return }
                if let value { self?.picture = value; if complete { return } }
            }
        }
    }
    /// Selection is presentation-only. The old native load cleans up before its replacement enters.
    public func selectVariant(_ id: MediaAssetID, loaders: MonitorMediaPictureLoaders<Payload, Picture>,
        policy: MonitorMediaPictureLoadPolicy = .previewThenOriginal) {
        guard !variantSwitching, id != record.asset.id, let choice = variants.first(where: { $0.id == id }),
            let source = request(for: baseRecord, variant: false), library.record(id) != nil else { return }
        variantRevision = UUID(); let selected = variantRevision, origin = presentation
        loadRevision = UUID(); let previous = loadID.flatMap { tasks[$0] }
        loadID = nil; previous?.cancel(); variantSwitching = true; preparingShare = false
        let taskID = UUID()
        tasks[taskID] = Task { @MainActor [weak self] in
            defer {
                self?.tasks[taskID] = nil
                if self?.presentation == origin, self?.variantRevision == selected { self?.variantSwitching = false }
            }
            await previous?.value
            guard let self, !Task.isCancelled, source.isCurrent(), self.variantRevision == selected else { return }
            self.record = choice.record
            self.load(loaders, policy: policy)
        }
    }
    public func toggleFavorite(_ operations: MonitorMediaGalleryOperations<Payload>) {
        guard let request = request(for: baseRecord, variant: false), request.isCurrent() else { return }
        if let favorite = operations.favorite { favorite(request.record) }
        else { library.toggleFavorite(baseRecord.asset.id) }
    }
    public func canDelete(_ operations: MonitorMediaGalleryOperations<Payload>) -> Bool {
        guard operations.delete != nil || operations.acceptedDeletion != nil else { return false }
        let allowed = operations.access?(baseRecord).delete ?? (baseRecord.asset.deletable == true)
        return allowed && isCurrent
    }
    public func requestDelete(_ operations: MonitorMediaGalleryOperations<Payload>,
        records: [MonitorMediaRecord<Payload>]? = nil) {
        guard canDelete(operations), let request = request(for: baseRecord, variant: false) else { return }
        let targets = records ?? [baseRecord]
        guard !targets.isEmpty, targets.allSatisfy({ library.record($0.asset.id) != nil }) else { return }
        let message = operations.deletionMessage?(targets)
        guard request.isCurrent() else { return }
        deletion = (request, targets); deletionMessage = message; deleteRequestID = UUID()
    }
    public func cancelDelete() { deletion = nil; deleteRequestID = nil; deletionMessage = nil }
    public func cancelDelete(admitted id: UUID?) {
        if let id, id == deleteRequestID { cancelDelete() }
    }
    public func confirmDelete(_ id: UUID?, operations: MonitorMediaGalleryOperations<Payload>,
        completed: @escaping @MainActor () -> Void) {
        guard id != nil, id == deleteRequestID, let (request, records) = deletion else { return }
        cancelDelete()
        guard request.isCurrent() else { return }
        let taskID = UUID()
        if let port = operations.acceptedDeletion {
            guard let authority = port.capture(records) else { return }
            guard request.isCurrent(), authority.isCurrent else { authority.retire(); return }
            let origin = presentation
            acceptedDeletions[taskID] = authority
            tasks[taskID] = Task { @MainActor [weak self] in
                defer { self?.acceptedDeletions[taskID] = nil; self?.tasks[taskID] = nil }
                guard let self, !Task.isCancelled, self.active, authority.isCurrent else { authority.retire(); return }
                await self.stopLoading()
                guard !Task.isCancelled, self.active, self.presentation == origin, authority.isCurrent else { authority.retire(); return }
                await port.perform(records, authority)
                guard !Task.isCancelled, self.active, self.presentation == origin else { return }
                if let proof = authority.completion {
                    guard proof.claim == authority.id, proof.isCurrent, self.library.isCurrent(proof.admission) else { return }
                    let available = self.sourceCurrent()
                    guard available, !Task.isCancelled, self.active, self.presentation == origin,
                        proof.isCurrent, self.library.isCurrent(proof.admission) else { return }
                    self.admission = proof.admission; self.deletionCompletion = proof
                    if proof.removedCount > 0 { completed() }
                } else if authority.isCurrent, self.active, self.presentation == origin {
                    completed()
                }
            }
            return
        }
        guard let delete = operations.delete else { return }
        tasks[taskID] = Task { @MainActor [weak self] in
            defer { self?.tasks[taskID] = nil }
            guard !Task.isCancelled, request.isCurrent() else { return }
            for record in records {
                guard !Task.isCancelled, request.isCurrent() else { return }
                await delete(record)
            }
            guard !Task.isCancelled, request.isCurrent() else { return }
            completed()
        }
    }
    public func share(_ present: (MonitorMediaPictureRequest<Payload>) -> Void) {
        guard let request = request(), request.isCurrent() else { return }
        optionsPresented = false; helpPresented = false; present(request)
    }
    public func canShare(_ sharing: MonitorMediaPictureSharing<Payload>?) -> Bool {
        guard let request = request() else { return false }
        let allowed = sharing?.readiness(request) != .unavailable
        return allowed && request.isCurrent() && !variantSwitching && !preparingShare
    }
    public func share(_ present: @escaping @MainActor (MonitorMediaPictureRequest<Payload>) -> Void,
        sharing: MonitorMediaPictureSharing<Payload>?) {
        guard let sharing else { share(present); return }
        guard canShare(sharing), let request = request() else { return }
        optionsPresented = false; helpPresented = false; preparingShare = true
        let id = UUID(), origin = presentation, selected = variantRevision
        tasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.tasks[id] = nil
                if self?.presentation == origin, self?.variantRevision == selected { self?.preparingShare = false }
            }
            while !Task.isCancelled, request.isCurrent() {
                let readiness = sharing.readiness(request)
                guard request.isCurrent() else { return }
                switch readiness {
                case .ready:
                    do { try await sharing.perform?(request) }
                    catch {
                        if !Task.isCancelled, request.isCurrent() { self?.failure = error.localizedDescription }
                        return
                    }
                    guard !Task.isCancelled, request.isCurrent() else { return }
                    present(request); return
                case .unavailable: return
                case .waiting:
                    guard let self else { return }
                    do { try await self.sleep(.milliseconds(300)) } catch { return }
                }
            }
        }
    }
    public func readRating(_ service: MonitorMediaPictureRatingService<Payload>?) {
        guard let service, let request = request(for: baseRecord, variant: false) else { return }
        if let ratingReadID { tasks[ratingReadID]?.cancel() }
        let id = UUID(), revision = ratingRevision, origin = presentation
        ratingReadID = id; ratingReading = true
        tasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.tasks[id] = nil
                if self?.presentation == origin, self?.ratingReadID == id {
                    self?.ratingReadID = nil; self?.ratingReading = false
                }
            }
            guard !Task.isCancelled, request.isCurrent(), self?.ratingReadID == id else { return }
            let value = await service.read(request)
            guard !Task.isCancelled, request.isCurrent(), self?.ratingReadID == id,
                self?.ratingRevision == revision else { return }
            self?.ratingStars = value; self?.confirmedRating = value
        }
    }

    public func setRating(_ target: Int, service: MonitorMediaPictureRatingService<Payload>) {
        guard target == 0 || service.levels.contains(target),
            let request = request(for: baseRecord, variant: false) else { return }
        ratingRevision = UUID(); let revision = ratingRevision, id = UUID()
        ratingStars = target; ratingPending = true
        tasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.tasks[id] = nil
                if self?.ratingRevision == revision { self?.ratingPending = false }
            }
            guard !Task.isCancelled, request.isCurrent() else { return }
            let result = await service.commit(target, request)
            guard !Task.isCancelled, request.isCurrent(), let self, self.ratingRevision == revision else { return }
            switch result {
            case .confirmed(let value): self.ratingStars = value; self.confirmedRating = value; self.dismissRatingNotice()
            case .refused(let message):
                self.ratingStars = self.confirmedRating
                if let message { self.showRatingNotice(message, admitted: request) }
            case .unavailable: self.ratingStars = self.confirmedRating
            }
        }
    }
    public func dismissRatingNotice() {
        if let noticeID { tasks.removeValue(forKey: noticeID)?.cancel() }
        noticeID = nil; ratingNotice = nil
    }
    private func showRatingNotice(_ message: String, admitted request: MonitorMediaPictureRequest<Payload>) {
        dismissRatingNotice()
        guard request.isCurrent() else { return }
        let id = UUID(); noticeID = id; ratingNotice = message
        tasks[id] = Task { @MainActor [weak self] in
            defer { self?.tasks[id] = nil }
            guard let self else { return }
            do { try await self.sleep(.seconds(4)) } catch { return }
            guard !Task.isCancelled, self.noticeID == id, request.isCurrent() else { return }
            self.noticeID = nil; self.ratingNotice = nil
        }
    }
    /// Options and confirmations consume Back before returning to the catalog.
    public func back() -> Bool {
        if optionsPresented { optionsPresented = false; helpPresented = false; return true }
        if deleteRequestID != nil { cancelDelete(); return true }
        return false
    }
}
