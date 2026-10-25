import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

/// A coherent captured deletion port; its executor uses the existing Library scheduler.
@MainActor public struct MonitorMediaGalleryDeletion<Payload: Sendable> {
    public let capture: @MainActor ([MonitorMediaRecord<Payload>]) -> MonitorMediaLibraryDeletionAuthority?
    public let perform: @MainActor ([MonitorMediaRecord<Payload>], MonitorMediaLibraryDeletionAuthority) async -> Void
    public init(capture: @escaping @MainActor ([MonitorMediaRecord<Payload>]) -> MonitorMediaLibraryDeletionAuthority?,
        perform: @escaping @MainActor ([MonitorMediaRecord<Payload>], MonitorMediaLibraryDeletionAuthority) async -> Void) {
        self.capture = capture; self.perform = perform
    }
}

/// Explicit source admission facts. Unknown values retain the common service/asset decision.
public struct MonitorMediaGalleryAccess: Equatable, Sendable {
    public let download: Bool?
    public let share: Bool?
    public let delete: Bool?
    public init(download: Bool? = nil, share: Bool? = nil, delete: Bool? = nil) {
        self.download = download; self.share = share; self.delete = delete
    }
}

/// One-operation ports preserve source ACKs, addresses and reconciliation below the catalog.
/// The catalog owns captured bulk order and cancellation, never raw transport policy.
@MainActor public struct MonitorMediaGalleryOperations<Payload: Sendable> {
    public let download: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
    public let delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)?
    public let favorite: (@MainActor (MonitorMediaRecord<Payload>) -> Void)?
    public let acceptedDeletion: MonitorMediaGalleryDeletion<Payload>?
    public let access: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess)?
    public let deletionMessage: (@MainActor ([MonitorMediaRecord<Payload>]) -> String?)?
    public let openNotice: (@MainActor (MonitorMediaRecord<Payload>) -> String?)?
    public init(download: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)? = nil,
        delete: (@MainActor (MonitorMediaRecord<Payload>) async -> Void)? = nil,
        favorite: (@MainActor (MonitorMediaRecord<Payload>) -> Void)? = nil,
        acceptedDeletion: MonitorMediaGalleryDeletion<Payload>? = nil,
        access: (@MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryAccess)? = nil,
        deletionMessage: (@MainActor ([MonitorMediaRecord<Payload>]) -> String?)? = nil,
        openNotice: (@MainActor (MonitorMediaRecord<Payload>) -> String?)? = nil) {
        self.download = download; self.delete = delete; self.favorite = favorite
        self.acceptedDeletion = acceptedDeletion; self.access = access
        self.deletionMessage = deletionMessage; self.openNotice = openNotice
    }
}

/// An immutable displayed window. Reused file paths cannot retarget a held UI action.
@available(macOS 14, *) @MainActor
public struct MonitorMediaGallerySnapshot<Payload: Sendable> {
    public let token: MonitorMediaLibraryActionToken
    public let records: [MonitorMediaRecord<Payload>]
    public let projection: MonitorMediaProjectionResult?
    private let available: [MediaAssetID: MonitorMediaRecord<Payload>]
    private let selectionOrder: [MediaAssetID]
    /// Displayed ids and projected group members: O(1) admission (it was a linear scan per
    /// record, quadratic for select-all and selection expansion on a large card).
    private let allowed: Set<MediaAssetID>
    private let shown: Set<MediaAssetID>
    fileprivate let presentation: UUID
    private weak var library: MonitorMediaLibraryModel<Payload>?
    fileprivate init(library: MonitorMediaLibraryModel<Payload>, presentation: UUID,
        projection: MonitorMediaProjectionResult?) {
        token = library.actionToken; self.library = library; self.projection = projection
        let supplied = projection == nil ? library.displayedRecords : library.records
        let byID = Dictionary(uniqueKeysWithValues: supplied.map { ($0.asset.id, $0) })
        let order = projection?.displayIDs ?? supplied.map(\.asset.id)
        available = byID; selectionOrder = order
        var allowed = Set(order)
        for group in projection?.groups ?? [] { allowed.formUnion(group.members) }
        self.allowed = allowed
        records = (projection?.gridIDs ?? order).compactMap { byID[$0] }
        shown = Set(records.map(\.asset.id))
        self.presentation = presentation
    }
    public var isCurrent: Bool { library?.isCurrent(token) == true }
    public func record(_ id: MediaAssetID) -> MonitorMediaRecord<Payload>? {
        guard allowed.contains(id), isCurrent, let record = available[id],
            library?.record(id) != nil else { return nil }
        return record
    }
    public func selected(_ ids: Set<MediaAssetID>, expanded: Bool = true) -> [MonitorMediaRecord<Payload>] {
        guard isCurrent else { return [] }
        let basis = selectionOrder.filter { ids.contains($0) }
        guard expanded, let projection else { return basis.compactMap(record) }
        return projection.expansion(basis, availableMemberIDs: Set(available.keys)).compactMap { entry in
            switch entry {
            case .supplied(let id): return record(id)
            case .member(let id): return record(id) == nil ? nil : library?.record(id)
            }
        }
    }
    public var selectableIDs: Set<MediaAssetID> { Set(selectionOrder.filter { record($0) != nil }) }
    /// A shown (grid) record for a cell, without admission checks; actions still use record(_:).
    public func displayed(_ id: MediaAssetID) -> MonitorMediaRecord<Payload>? {
        shown.contains(id) ? available[id] : nil
    }
}

@available(macOS 14, *) @MainActor
public struct MonitorMediaGalleryOpen<Payload: Sendable>: Identifiable {
    public let id = UUID()
    public let record: MonitorMediaRecord<Payload>
    public let playlist: [MonitorMediaRecord<Payload>]
    public let admission: MonitorMediaLibraryActionToken
    public init(record: MonitorMediaRecord<Payload>, playlist: [MonitorMediaRecord<Payload>],
        admission: MonitorMediaLibraryActionToken) {
        self.record = record; self.playlist = playlist; self.admission = admission
    }
}

public enum MonitorMediaDateBound: String, Identifiable, Sendable {
    case start, end
    public var id: String { rawValue }
    public var title: String { self == .start ? "Start date" : "End date" }
}

public struct MonitorMediaGalleryDateRequest: Identifiable, Sendable {
    public let id: UUID
    public let bound: MonitorMediaDateBound
    public let admission: MonitorMediaLibraryActionToken
    fileprivate let lifetime: UUID
}

/// Catalog presentation/actions over the existing library/cache/source owner.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorMediaGalleryModel<Payload: Sendable> {
    public let library: MonitorMediaLibraryModel<Payload>
    public var filterPopupPresented = false {
        didSet {
            if filterPopupPresented != oldValue {
                filterRequestID = filterPopupPresented ? UUID() : nil
                if !filterPopupPresented { pickingDate = nil }
            }
        }
    }
    public private(set) var filterRequestID: UUID?
    public private(set) var pickingDate: MonitorMediaGalleryDateRequest?
    public private(set) var deleteCount = 0
    public private(set) var deletionMessage: String?
    public private(set) var notice: String?
    public private(set) var confirmationPresented = false
    public private(set) var deleteRequestID: UUID?
    public private(set) var resolvedDurations: [MediaAssetID: String] = [:]
    private var lifetime = UUID()
    @ObservationIgnored private var active = true
    @ObservationIgnored private var deletion: (MonitorMediaGallerySnapshot<Payload>, [MonitorMediaRecord<Payload>],
        MonitorMediaGalleryOperations<Payload>, UUID)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var acceptedDeletions: [UUID: MonitorMediaLibraryDeletionAuthority] = [:]
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var noticeID = UUID()
    public init(library: MonitorMediaLibraryModel<Payload>,
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)) {
        self.library = library; self.sleep = sleep
    }
    public func snapshot(projection: MonitorMediaProjectionResult? = nil) -> MonitorMediaGallerySnapshot<Payload> {
        .init(library: library, presentation: lifetime, projection: projection)
    }

    public func activate() { active = true }
    /// A cover hides the catalog: transient prompts close, while presentation lifetime,
    /// resolved durations and accepted work stay with the gallery the operator returns to.
    public func suspend() {
        dismissNotice(); filterPopupPresented = false; pickingDate = nil; cancelDelete()
    }
    /// Back or a source change ends this presentation. Bulk cache belongs to the library.
    public func retire() {
        active = false; lifetime = UUID(); dismissNotice()
        acceptedDeletions.values.forEach { $0.retire() }; acceptedDeletions.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        filterPopupPresented = false; pickingDate = nil
        cancelDelete(); resolvedDurations.removeAll()
    }
    /// The operator closes the browser: the next visit starts without a selection, as covers keep it.
    public func leave() { library.clearSelection(); retire() }
    public func sourceChanged() {
        let retained = Set(acceptedDeletions.filter { $0.value.isPrepared && $0.value.isCurrent }.map(\.key))
        if !retained.isEmpty {
            for id in Array(tasks.keys) where !retained.contains(id) { tasks.removeValue(forKey: id)?.cancel() }
            for id in Array(acceptedDeletions.keys) where !retained.contains(id) {
                acceptedDeletions.removeValue(forKey: id)?.retire()
            }
            dismissNotice(); filterPopupPresented = false; pickingDate = nil; cancelDelete(); resolvedDurations.removeAll()
        } else { retire(); activate() }
    }
    public func isCurrent(_ snapshot: MonitorMediaGallerySnapshot<Payload>) -> Bool {
        active && snapshot.presentation == lifetime && snapshot.isCurrent && library.isCurrent(snapshot.token)
    }
    public func admitsFilter(_ snapshot: MonitorMediaGallerySnapshot<Payload>, admitted id: UUID?) -> Bool {
        id != nil && id == filterRequestID && filterPopupPresented && isCurrent(snapshot)
    }
    public func dismissFilter(admitted id: UUID?) {
        guard let id, id == filterRequestID else { return }
        filterPopupPresented = false
    }
    public func duration(_ label: String, for id: MediaAssetID,
        admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard isCurrent(snapshot), snapshot.record(id) != nil else { return }
        resolvedDurations[id] = label
    }
    public func canDownload(_ record: MonitorMediaRecord<Payload>, operations: MonitorMediaGalleryOperations<Payload>) -> Bool {
        guard operations.download != nil else { return false }
        if let known = operations.access?(record).download { return known }
        return library.entries[record.asset.id]?.originalURL == nil
            && record.asset.representations.contains { $0.role == .original }
    }
    public func canShare(_ record: MonitorMediaRecord<Payload>, operations: MonitorMediaGalleryOperations<Payload>) -> Bool {
        if let known = operations.access?(record).share { return known }
        return library.entries[record.asset.id]?.originalURL != nil || (operations.download != nil
            && record.asset.representations.contains { $0.role == .original })
    }
    public func canDelete(_ record: MonitorMediaRecord<Payload>, operations: MonitorMediaGalleryOperations<Payload>) -> Bool {
        guard operations.delete != nil || operations.acceptedDeletion != nil else { return false }
        return operations.access?(record).delete ?? (record.asset.deletable == true)
    }
    public func dismissNotice() {
        noticeID = UUID(); noticeTask?.cancel(); noticeTask = nil; notice = nil
    }
    private func showNotice(_ message: String, admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        dismissNotice()
        guard isCurrent(snapshot) else { return }
        let id = noticeID
        notice = message
        noticeTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(.milliseconds(2600)) } catch { return }
            guard !Task.isCancelled, self.noticeID == id, self.isCurrent(snapshot) else { return }
            self.noticeTask = nil; self.notice = nil
        }
    }
    /// Returns true only when selection began, for the original medium selection haptic.
    @discardableResult public func select(_ ids: Set<MediaAssetID>,
        admitted snapshot: MonitorMediaGallerySnapshot<Payload>) -> Bool {
        guard isCurrent(snapshot), ids.allSatisfy({ snapshot.record($0) != nil }) else { return false }
        let began = !library.selecting
        library.select(ids)
        return began
    }
    @discardableResult public func toggleSelection(_ id: MediaAssetID,
        admitted snapshot: MonitorMediaGallerySnapshot<Payload>) -> Bool {
        guard isCurrent(snapshot), snapshot.record(id) != nil else { return false }
        var ids = library.selectedIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        return select(ids, admitted: snapshot)
    }
    public func retainSelection(admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard isCurrent(snapshot) else { return }
        let retained = library.selectedIDs.intersection(snapshot.selectableIDs)
        if retained != library.selectedIDs { library.select(retained) }
        if retained.isEmpty { library.selecting = false }
    }
    public func open(_ id: MediaAssetID, admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>, sourceAvailable: Bool = false) -> MonitorMediaGalleryOpen<Payload>? {
        guard isCurrent(snapshot), let record = snapshot.record(id) else { return nil }
        guard !library.selecting else { toggleSelection(id, admitted: snapshot); return nil }
        if let notice = operations.openNotice?(record) {
            showNotice(notice, admitted: snapshot); return nil
        }
        guard isCurrent(snapshot), record.facts.playbackEligible != false,
            (record.facts.presentationKind ?? record.asset.kind) != nil else { return nil }
        guard sourceAvailable || operations.download != nil || library.entries[id]?.isPlayableOffline == true else { return nil }
        let kind = record.facts.presentationKind ?? record.asset.kind
        return .init(record: record, playlist: snapshot.records.filter {
            ($0.facts.presentationKind ?? $0.asset.kind) == kind && $0.facts.playbackEligible != false
        }, admission: snapshot.token)
    }
    public func shareSelection(admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>) -> [MonitorMediaRecord<Payload>]? {
        let records = selected(snapshot)
        guard !records.isEmpty, records.allSatisfy({ canShare($0, operations: operations) }),
            isCurrent(snapshot) else { return nil }
        return records
    }
    public func favorite(_ id: MediaAssetID, admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>) {
        guard isCurrent(snapshot), let record = snapshot.record(id) else { return }
        if let favorite = operations.favorite { favorite(record) } else { library.toggleFavorite(id) }
    }
    public func favoriteSelection(admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>, toggleUniform: Bool = false) {
        let records = selected(snapshot, expanded: false)
        let target = !toggleUniform || records.contains { library.record($0.asset.id)?.favorite == false }
        for record in records where library.record(record.asset.id)?.favorite != target {
            favorite(record.asset.id, admitted: snapshot, operations: operations)
        }
    }
    public func cacheSelection(admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>) {
        guard let download = operations.download, isCurrent(snapshot) else { return }
        let records = selected(snapshot).filter { canDownload($0, operations: operations) }
        library.cacheBatch(records, admitted: snapshot.token, download: download)
    }
    public func requestDelete(admitted snapshot: MonitorMediaGallerySnapshot<Payload>,
        operations: MonitorMediaGalleryOperations<Payload>, supportedSubset: Bool = false) {
        let selected = selected(snapshot)
        let records = supportedSubset ? selected.filter { canDelete($0, operations: operations) } : selected
        guard !records.isEmpty, records.allSatisfy({ canDelete($0, operations: operations) }) else { return }
        guard isCurrent(snapshot) else { return }
        let message = operations.deletionMessage?(records)
        guard isCurrent(snapshot) else { return }
        deletion = (snapshot, records, operations, lifetime); deleteRequestID = UUID()
        deleteCount = records.count; deletionMessage = message; confirmationPresented = true
    }
    public func cancelDelete() { deletion = nil; deleteCount = 0; deletionMessage = nil; confirmationPresented = false; deleteRequestID = nil }
    public func cancelDelete(admitted id: UUID?) {
        guard let id, id == deleteRequestID else { return }
        cancelDelete()
    }
    public func confirmDelete(admitted id: UUID?) {
        guard id != nil, id == deleteRequestID else { return }
        let captured = deletion
        cancelDelete()
        guard let (snapshot, records, operations, origin) = captured, lifetime == origin,
            isCurrent(snapshot) else { return }
        if let port = operations.acceptedDeletion {
            guard let authority = port.capture(records) else { return }
            guard isCurrent(snapshot), authority.isCurrent else { authority.retire(); return }
            authority.clearsSelection = true
            let id = UUID()
            acceptedDeletions[id] = authority
            tasks[id] = Task { @MainActor [weak self] in
                defer { self?.acceptedDeletions[id] = nil; self?.tasks[id] = nil }
                guard let self, self.active, authority.isCurrent else { authority.retire(); return }
                await port.perform(records, authority)
            }
            return
        }
        guard let delete = operations.delete else { return }
        perform(records, snapshot: snapshot, clearSelection: true, operation: delete)
    }
    public func pickDate(_ bound: MonitorMediaDateBound, admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard isCurrent(snapshot) else { return }
        pickingDate = .init(id: UUID(), bound: bound, admission: snapshot.token, lifetime: lifetime)
    }
    public func cancelDate() { pickingDate = nil }
    public func cancelDate(admitted id: UUID?) {
        guard let id, id == pickingDate?.id else { return }
        pickingDate = nil
    }
    public func date(_ key: String?, admitted request: MonitorMediaGalleryDateRequest) {
        guard active, pickingDate?.id == request.id, lifetime == request.lifetime,
            library.isCurrent(request.admission) else { return }
        if request.bound == .start {
            library.dateStart = key
            if let key, let end = library.dateEnd, key > end { library.dateEnd = key }
        } else {
            library.dateEnd = key
            if let key, let start = library.dateStart, key < start { library.dateStart = key }
        }
    }
    public func selectAll(admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard isCurrent(snapshot) else { return }
        library.select(snapshot.selectableIDs)
    }
    public func selected(_ snapshot: MonitorMediaGallerySnapshot<Payload>,
        expanded: Bool = true) -> [MonitorMediaRecord<Payload>] {
        guard isCurrent(snapshot) else { return [] }
        return snapshot.selected(library.selectedIDs, expanded: expanded)
    }
    private func perform(_ records: [MonitorMediaRecord<Payload>], snapshot: MonitorMediaGallerySnapshot<Payload>,
        clearSelection: Bool = false, operation: @escaping @MainActor (MonitorMediaRecord<Payload>) async -> Void) {
        guard !records.isEmpty, isCurrent(snapshot) else { return }
        let id = UUID(), origin = lifetime
        tasks[id] = Task { @MainActor [weak self] in
            defer { self?.tasks[id] = nil }
            for record in records {
                guard !Task.isCancelled, let self, self.lifetime == origin,
                    self.isCurrent(snapshot), snapshot.record(record.asset.id) != nil else { return }
                await operation(record)
            }
            guard !Task.isCancelled, let self, self.lifetime == origin, self.isCurrent(snapshot) else { return }
            if clearSelection { self.library.clearSelection() }
        }
    }
}
