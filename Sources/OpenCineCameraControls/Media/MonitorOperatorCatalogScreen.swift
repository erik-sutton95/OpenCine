#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia
import SwiftUI

/// Source metadata only. Filters, labels, permissions and confirmation policy remain shared.
public struct MonitorMediaGalleryFileFacts {
    public let resolution: String?
    public let byteCount: UInt64?
    public let durationSeconds: Int?
    public let dateKey: String?
    public let colorLabel: String?
    public let progress: Double?
    public init(resolution: String?, byteCount: UInt64?, durationSeconds: Int?, dateKey: String?,
        colorLabel: String?, progress: Double? = nil) {
        self.resolution = resolution; self.byteCount = byteCount; self.durationSeconds = durationSeconds
        self.dateKey = dateKey; self.colorLabel = colorLabel; self.progress = progress
    }
}

@MainActor public struct MonitorMediaGalleryThumbnail<Payload: Sendable> {
    public let record: MonitorMediaRecord<Payload>
    public let cached: MonitorMediaCacheEntry?
    public let list: Bool
    public let resolvedDuration: String?
    public let isCurrent: @MainActor () -> Bool
    public let duration: @MainActor (String) -> Void
}

/// Complete catalog/filter/calendar/selection owner; native routing receives admitted records.
/// Gallery state belongs to one library owner: a replaced owner gets a fresh gallery, so the
/// grid, counts and actions can never read two owners at once.
public struct MonitorOperatorCatalogScreen<Payload: Sendable, Thumbnail: View>: View {
    private let content: MonitorOperatorCatalogContent<Payload, Thumbnail>

    public init(library: MonitorMediaLibraryModel<Payload>, brand: String, safeArea: EdgeInsets = .init(),
        sourceAvailable: Bool, operations: MonitorMediaGalleryOperations<Payload>,
        presentation: MonitorMediaGalleryPresentation? = nil,
        navigation: (@MainActor (MonitorMediaGalleryNavigation) -> Void)? = nil,
        sourceFilter: (@MainActor (MonitorMediaGalleryFilterAction) -> Void)? = nil,
        managesVisibility: Bool = true,
        deletionDetail: (@MainActor (MonitorMediaDeletionProgress) -> String?)? = nil,
        colorChoices: [MonitorMediaFilterChoice] = [],
        resolutionLevels: [MonitorMediaResolutionLevel] = MonitorMediaResolutionLevel.standard,
        facts: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryFileFacts,
        cell: (@MainActor (MonitorMediaRecord<Payload>, MonitorMediaGalleryCellContext) -> MonitorMediaItem)? = nil,
        begin: (@MainActor () -> Void)? = nil, refresh: (@MainActor () -> Void)? = nil,
        close: @escaping @MainActor () -> Void,
        open: @escaping @MainActor (MonitorMediaGalleryOpen<Payload>) -> Void,
        share: (@MainActor ([MonitorMediaRecord<Payload>], MonitorMediaLibraryActionToken) -> Void)? = nil,
        cachingActive: (@MainActor () -> Bool)? = nil,
        @ViewBuilder thumbnail: @escaping @MainActor (MonitorMediaGalleryThumbnail<Payload>) -> Thumbnail) {
        content = .init(library: library, brand: brand, safeArea: safeArea, sourceAvailable: sourceAvailable,
            operations: operations, presentation: presentation, navigation: navigation,
            sourceFilter: sourceFilter, managesVisibility: managesVisibility, deletionDetail: deletionDetail,
            colorChoices: colorChoices, resolutionLevels: resolutionLevels, facts: facts, cell: cell,
            begin: begin, refresh: refresh, close: close, open: open, share: share,
            cachingActive: cachingActive, thumbnail: thumbnail)
    }

    public var body: some View { content.id(content.source) }
}

private struct MonitorOperatorCatalogContent<Payload: Sendable, Thumbnail: View>: View {
    private let library: MonitorMediaLibraryModel<Payload>
    private let brand: String
    private let safeArea: EdgeInsets
    private let sourceAvailable: Bool
    private let presentation: MonitorMediaGalleryPresentation?
    private let navigation: (@MainActor (MonitorMediaGalleryNavigation) -> Void)?
    private let sourceFilter: (@MainActor (MonitorMediaGalleryFilterAction) -> Void)?
    private let managesVisibility: Bool
    private let deletionDetail: (@MainActor (MonitorMediaDeletionProgress) -> String?)?
    private let operations: MonitorMediaGalleryOperations<Payload>
    private let colorChoices: [MonitorMediaFilterChoice]
    private let resolutionLevels: [MonitorMediaResolutionLevel]
    private let cell: (@MainActor (MonitorMediaRecord<Payload>, MonitorMediaGalleryCellContext) -> MonitorMediaItem)?
    private let facts: @MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryFileFacts
    private let begin: @MainActor () -> Void
    private let refresh: @MainActor () -> Void
    private let close: @MainActor () -> Void
    private let open: @MainActor (MonitorMediaGalleryOpen<Payload>) -> Void
    private let share: (@MainActor ([MonitorMediaRecord<Payload>], MonitorMediaLibraryActionToken) -> Void)?
    private let cachingActive: (@MainActor () -> Bool)?
    private let thumbnail: @MainActor (MonitorMediaGalleryThumbnail<Payload>) -> Thumbnail
    @State private var gallery: MonitorMediaGalleryModel<Payload>
    @Environment(\.monitorWindowGeometry) private var windowGeometry

    var source: ObjectIdentifier { ObjectIdentifier(library) }

    init(library: MonitorMediaLibraryModel<Payload>, brand: String, safeArea: EdgeInsets = .init(),
        sourceAvailable: Bool, operations: MonitorMediaGalleryOperations<Payload>,
        presentation: MonitorMediaGalleryPresentation? = nil,
        navigation: (@MainActor (MonitorMediaGalleryNavigation) -> Void)? = nil,
        sourceFilter: (@MainActor (MonitorMediaGalleryFilterAction) -> Void)? = nil,
        managesVisibility: Bool = true,
        deletionDetail: (@MainActor (MonitorMediaDeletionProgress) -> String?)? = nil,
        colorChoices: [MonitorMediaFilterChoice] = [],
        resolutionLevels: [MonitorMediaResolutionLevel] = MonitorMediaResolutionLevel.standard,
        facts: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryFileFacts,
        cell: (@MainActor (MonitorMediaRecord<Payload>, MonitorMediaGalleryCellContext) -> MonitorMediaItem)? = nil,
        begin: (@MainActor () -> Void)? = nil, refresh: (@MainActor () -> Void)? = nil,
        close: @escaping @MainActor () -> Void,
        open: @escaping @MainActor (MonitorMediaGalleryOpen<Payload>) -> Void,
        share: (@MainActor ([MonitorMediaRecord<Payload>], MonitorMediaLibraryActionToken) -> Void)? = nil,
        cachingActive: (@MainActor () -> Bool)? = nil,
        @ViewBuilder thumbnail: @escaping @MainActor (MonitorMediaGalleryThumbnail<Payload>) -> Thumbnail) {
        self.library = library; self.brand = brand; self.safeArea = safeArea
        self.presentation = presentation; self.navigation = navigation; self.sourceFilter = sourceFilter
        self.managesVisibility = managesVisibility; self.deletionDetail = deletionDetail
        self.sourceAvailable = sourceAvailable; self.operations = operations; self.colorChoices = colorChoices
        self.resolutionLevels = resolutionLevels; self.facts = facts; self.cell = cell
        self.begin = begin ?? { library.begin() }; self.refresh = refresh ?? { library.refresh() }
        self.close = close; self.open = open; self.share = share; self.thumbnail = thumbnail
        self.cachingActive = cachingActive
        _gallery = State(initialValue: MonitorMediaGalleryModel(library: library))
    }

    public var body: some View {
        let snapshot = gallery.snapshot(projection: presentation?.projection)
        let deleteID = gallery.deleteRequestID
        let dateID = gallery.pickingDate?.id
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MonitorTheme.canvas
                // Items are built per realized cell (MonitorMediaCatalog is lazy); building all of
                // them here called the host once or more per record on every render.
                MonitorMediaCatalog(brand: brand, safeArea: safeArea,
                    ids: snapshot.records.map(\.asset.id.rawValue),
                    item: { id in snapshot.displayed(MediaAssetID(id)).map(item) },
                    permissions: { id in snapshot.displayed(MediaAssetID(id)).map(permissions) },
                    categories: presentation?.categories ?? MonitorMediaCategoryFilter.allCases.map {
                        .init(id: $0.rawValue, title: $0.rawValue.capitalized, count: library.records(in: $0).count)
                    }, category: presentation?.category ?? library.category.rawValue,
                    layout: presentation?.layout ?? library.layout,
                    thumbnailSize: presentation?.thumbnailSize ?? library.thumbnailSize,
                    sortTitle: presentation?.sortTitle ?? library.sort.rawValue.capitalized,
                    status: presentation?.status ?? (sourceAvailable ? "Camera + local cache" : "Available on this phone"),
                    selectedIDs: Set(library.selectedIDs.map(\.rawValue)), selecting: library.selecting,
                    refreshing: library.fetching, canRefresh: sourceAvailable,
                    tablet: UIDevice.current.userInterfaceIdiom == .pad,
                    hint: MonitorMediaGalleryCopy.galleryHint(sourceAvailable: sourceAvailable, selecting: library.selecting),
                    action: { action($0, snapshot: snapshot) }, thumbnail: { value in
                        if let record = snapshot.record(MediaAssetID(value.id)) {
                            thumbnail(.init(record: record, cached: library.entries[record.asset.id],
                                list: (presentation?.layout ?? library.layout) == .list,
                                resolvedDuration: gallery.resolvedDurations[record.asset.id],
                                isCurrent: { gallery.isCurrent(snapshot) && snapshot.record(record.asset.id) != nil },
                                duration: { gallery.duration($0, for: record.asset.id, admitted: snapshot) }))
                                .onAppear { library.ensureThumbnail(record.asset.id) }
                        }
                    }, empty: { empty }, filters: {
                        MonitorCatalogFilterButton(activeCount: presentation?.activeFilterCount ?? library.activeFilterCount, open: gallery.filterPopupPresented) {
                            if gallery.isCurrent(snapshot) { gallery.filterPopupPresented.toggle() }
                        }
                    }, sidebar: {
                        VStack(spacing: 8) {
                            ForEach(presentation?.storage ?? []) { value in
                                MonitorMediaGalleryStorageCard(value: value) {
                                    filter(.storage(value.id), admitted: snapshot)
                                }
                            }
                        }
                    }, accessory: {
                        MonitorOperatorCachingHeader(records: snapshot.records, hidden: library.selecting,
                            active: cachingActive, facts: facts)
                    })
                    .id(catalogIdentity)
                if gallery.filterPopupPresented { filterPopup(snapshot: snapshot, size: proxy.size) }
                if let progress = library.deletionProgress {
                    MonitorMediaDeletionOverlay(progress: progress, detail: deletionDetail?(progress))
                }
                if let notice = gallery.notice {
                    VStack { Spacer(); Text(notice).font(MonitorTheme.font(13, weight: .medium))
                        .foregroundStyle(MonitorTheme.text).padding(.horizontal, 14).padding(.vertical, 9)
                        .liquidGlass(in: Capsule()).padding(.bottom, max(safeArea.bottom + 24, 24))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea().preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: presentation?.thumbnailSize ?? library.thumbnailSize)
        .animation(.easeInOut(duration: 0.2), value: presentation?.layout ?? library.layout)
        .onAppear { gallery.activate(); begin() }
        // A playback or photo cover hides the catalog without ending it; Back retires it.
        .onDisappear { gallery.suspend() }
        .onChange(of: library.lifetimeToken) { _, _ in gallery.sourceChanged() }
        .onChange(of: presentation?.projection.displayIDs, initial: true) { _, _ in
            if presentation?.retainsVisibleSelection == true { gallery.retainSelection(admitted: snapshot) }
        }
        .onChange(of: sourceAvailable, initial: true) { _, live in if managesVisibility { library.visibility = live ? .allRecords : .cachedOnly } }
        .confirmationDialog(gallery.deletionMessage ?? "Delete \(gallery.deleteCount) items from the camera?",
            isPresented: Binding(get: { gallery.confirmationPresented }, set: { if !$0 { gallery.cancelDelete(admitted: deleteID) } }),
            titleVisibility: .visible) {
                Button("Delete", role: .destructive) { gallery.confirmDelete(admitted: deleteID) }
                Button("Cancel", role: .cancel) { gallery.cancelDelete(admitted: deleteID) }
            }
        .sheet(item: Binding(get: { gallery.pickingDate }, set: { if $0 == nil { gallery.cancelDate(admitted: dateID) } })) { request in
            MonitorMediaCalendarSheet(request: request, range: dateBounds ?? Date.distantPast...Date.distantFuture,
                key: request.bound == .start ? library.dateStart : library.dateEnd,
                commit: { gallery.date($0, admitted: request) })
        }
    }

    /// A cover returns to one source and presentation, never to a replacement's old position.
    private var catalogIdentity: MonitorOperatorCatalogIdentity {
        .init(source: ObjectIdentifier(library), lifetime: library.lifetimeToken,
            navigation: [presentation?.category ?? library.category.rawValue,
                (presentation?.layout ?? library.layout).rawValue,
                (presentation?.thumbnailSize ?? library.thumbnailSize).rawValue,
                presentation?.sortTitle ?? library.sort.rawValue],
            filters: [library.formats, library.resolutions, library.colors,
                presentation?.filters.formatSelection ?? [],
                presentation?.filters.resolutionSelection ?? [],
                presentation?.filters.photoSizeSelection ?? []],
            dates: [library.dateStart, library.dateEnd,
                presentation?.filters.dateWindow, presentation?.filters.storageID])
    }

    private func item(_ record: MonitorMediaRecord<Payload>) -> MonitorMediaItem {
        let reported = facts(record), cached = library.entries[record.asset.id]
        let photo = (record.facts.presentationKind ?? record.asset.kind) == .photo
        let duration = gallery.resolvedDurations[record.asset.id]
            ?? reported.durationSeconds.map { MediaClipFormatting.durationLabel(seconds: $0) }
        let metadata = [reported.colorLabel,
            MonitorMediaGalleryLabels.resolution(reported.resolution, levels: resolutionLevels),
            reported.byteCount.map(MediaClipFormatting.byteLabel), photo ? nil : duration]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let allowed = permissions(record)
        if let value = cell?(record, .init(list: (presentation?.layout ?? library.layout) == .list,
            selecting: library.selecting, duration: gallery.resolvedDurations[record.asset.id],
            selected: library.selectedIDs.contains(record.asset.id))) {
            return .init(id: record.asset.id.rawValue, filename: value.filename, metadata: value.metadata,
                format: value.format, color: value.color, duration: value.duration, date: value.date,
                availability: value.availability, progress: value.progress, favorite: record.favorite,
                photo: value.photo, permissions: allowed,
                burstCount: library.selecting ? nil : value.burstCount,
                mediaBadge: library.selecting ? nil : value.mediaBadge,
                completionBadge: library.selecting ? nil : value.completionBadge, transferCaption: value.transferCaption)
        }
        return .init(id: record.asset.id.rawValue, filename: record.asset.filename,
            metadata: metadata, format: reported.resolution ?? "", color: reported.colorLabel ?? "",
            duration: photo ? "" : (gallery.resolvedDurations[record.asset.id]
                ?? (reported.durationSeconds.flatMap { $0 > 0 ? MediaClipFormatting.durationLabel(seconds: $0) : nil } ?? "")),
            date: reported.dateKey.map(MonitorMediaGalleryLabels.date) ?? "",
            availability: cached?.originalURL != nil ? .original : cached?.proxyURL != nil ? .proxy : .camera,
            progress: reported.progress ?? library.progress[record.asset.id], favorite: record.favorite, photo: photo,
            permissions: allowed)
    }
    private func permissions(_ record: MonitorMediaRecord<Payload>) -> MonitorMediaPermissions {
        var permissions: MonitorMediaPermissions = [.favorite]
        if gallery.canDownload(record, operations: operations) { permissions.insert(.cache) }
        if share != nil, gallery.canShare(record, operations: operations) { permissions.insert(.share) }
        if gallery.canDelete(record, operations: operations) { permissions.insert(.delete) }
        return permissions
    }
    private var dateBounds: ClosedRange<Date>? {
        let dates = library.records(in: library.category).compactMap { $0.facts.dateKey.flatMap { MediaLibraryQuery.date(fromKey: $0) } }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }
    private func filterPopup(snapshot: MonitorMediaGallerySnapshot<Payload>, size: CGSize) -> some View {
        let physical = windowGeometry.safeArea
        let card = MonitorMediaFilterPopupLayout.card(viewportWidth: size.width, viewportHeight: size.height,
            safeTop: max(safeArea.top, physical.top), safeLeading: max(safeArea.leading, physical.leading),
            safeBottom: max(safeArea.bottom, physical.bottom), safeTrailing: max(safeArea.trailing, physical.trailing),
            topControlInset: windowGeometry.topControlInset)
        let id = gallery.filterRequestID
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { gallery.dismissFilter(admitted: id) }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("FILTER").font(MonitorTheme.font(10, weight: .bold)).monospacedDigit().kerning(0.8)
                        .foregroundStyle(MonitorTheme.muted)
                    Spacer()
                    Button { gallery.dismissFilter(admitted: id) } label: {
                        MonitorIcon.x.frame(width: 10, height: 10).frame(width: 26, height: 26).glassCircle(interactive: true)
                    }.buttonStyle(.monitorTapTarget).accessibilityLabel("Close filters")
                }
                ScrollView { filterForm(snapshot, admitted: id) }.monitorScrollFade()
            }
            .padding(16).frame(width: card.width, height: card.height, alignment: .topLeading)
            .liquidGlass(in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous))
            .offset(x: card.x, y: card.y).accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.media.filter.popup")
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
    @ViewBuilder private func filterForm(_ snapshot: MonitorMediaGallerySnapshot<Payload>, admitted id: UUID?) -> some View {
        if let presentation {
            MonitorMediaFilterForm(presentation: presentation,
                onAction: { popupFilter($0, snapshot: snapshot, id: id) })
        } else { standardFilterForm(snapshot, admitted: id) }
    }
    private func filter(_ action: MonitorMediaGalleryFilterAction, admitted snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard gallery.isCurrent(snapshot) else { return }
        sourceFilter?(action)
        if presentation?.filterClearsSelection == true, gallery.isCurrent(snapshot) { library.clearSelection() }
    }
    private func popupFilter(_ action: MonitorMediaGalleryFilterAction, snapshot: MonitorMediaGallerySnapshot<Payload>, id: UUID?) {
        guard gallery.admitsFilter(snapshot, admitted: id) else { return }
        sourceFilter?(action)
        if presentation?.filterClearsSelection == true, gallery.isCurrent(snapshot) { library.clearSelection() }
    }
    private func standardFilterForm(_ snapshot: MonitorMediaGallerySnapshot<Payload>, admitted id: UUID?) -> some View {
        let source = library.records(in: library.category)
        let colors = Set(source.compactMap(\.facts.color))
        return MonitorMediaFilterForm(
            formats: Array(Set(source.compactMap(\.facts.format))).filter { !$0.isEmpty }.sorted(),
            resolutions: Array(Set(source.compactMap(\.facts.resolution))).filter { !$0.isEmpty }.sorted(), colors: [],
            formatSelection: library.formats, resolutionSelection: library.resolutions, colorSelection: [],
            dateStartLabel: library.dateStart.map(MonitorMediaGalleryLabels.date),
            dateEndLabel: library.dateEnd.map(MonitorMediaGalleryLabels.date), hasDates: dateBounds != nil,
            onToggleFormat: { if gallery.admitsFilter(snapshot, admitted: id) { toggle($0, in: \.formats, snapshot: snapshot) } },
            onToggleResolution: { if gallery.admitsFilter(snapshot, admitted: id) { toggle($0, in: \.resolutions, snapshot: snapshot) } }, onToggleColor: { _ in },
            onPickStart: { if gallery.admitsFilter(snapshot, admitted: id) { gallery.pickDate(.start, admitted: snapshot) } },
            onPickEnd: { if gallery.admitsFilter(snapshot, admitted: id) { gallery.pickDate(.end, admitted: snapshot) } },
            onClear: { if gallery.admitsFilter(snapshot, admitted: id) { library.resetFilters() } },
            colorChoices: colorChoices.filter { colors.contains($0.id) }, colorIDs: library.colors,
            onToggleColorID: { if gallery.admitsFilter(snapshot, admitted: id) { toggle($0, in: \.colors, snapshot: snapshot) } })
    }
    private func toggle(_ value: String, in field: ReferenceWritableKeyPath<MonitorMediaLibraryModel<Payload>, Set<String>>,
        snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard gallery.isCurrent(snapshot) else { return }
        var values = library[keyPath: field]
        if !values.insert(value).inserted { values.remove(value) }
        library[keyPath: field] = values
    }
    private var empty: some View {
        VStack(spacing: 12) {
            if library.fetching { ProgressView().controlSize(.large).tint(MonitorTheme.muted) }
            else { MonitorIcon.film.frame(width: 40, height: 40).foregroundStyle(MonitorTheme.faint) }
            Text(MonitorMediaGalleryCopy.emptyTitle(fetching: library.fetching, sourceAvailable: sourceAvailable,
                hasRecords: !library.records.isEmpty,
                activeFilterCount: presentation?.activeFilterCount ?? library.activeFilterCount))
                .font(MonitorTheme.font(15, weight: .medium)).foregroundStyle(MonitorTheme.muted)
            Text(library.fetching ? (library.fetchedCount == 0 ? "Querying card storage…"
                : "\(library.fetchedCount) clip\(library.fetchedCount == 1 ? "" : "s") found so far")
                : library.note ?? emptySubtitle)
                .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.faint)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptySubtitle: String {
        let tab: String
        switch library.category {
        case .all: tab = MonitorMediaGalleryCopy.emptyAll
        case .videos: tab = MonitorMediaGalleryCopy.emptyVideos
        case .photos: tab = MonitorMediaGalleryCopy.emptyPhotos
        case .favorites: tab = MonitorMediaGalleryCopy.emptyFavorites
        }
        return MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: sourceAvailable, hasRecords: !library.records.isEmpty,
            activeFilterCount: presentation?.activeFilterCount ?? library.activeFilterCount, tab: tab)
    }
    private func selectionFeedback(_ began: Bool) { if began { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    private func navigate(_ action: MonitorMediaGalleryNavigation, snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard gallery.isCurrent(snapshot) else { return }
        navigation?(action)
        if presentation?.navigationClearsSelection == true, gallery.isCurrent(snapshot) { library.clearSelection() }
    }
    private func action(_ action: MonitorMediaAction, snapshot: MonitorMediaGallerySnapshot<Payload>) {
        guard gallery.isCurrent(snapshot) else { return }
        switch action {
        case .back: gallery.leave(); close()
        case .refresh: refresh()
        case .cycleSort:
            if navigation != nil { navigate(.cycleSort, snapshot: snapshot); return }
            let cases = MonitorMediaSort.allCases, index = cases.firstIndex(of: library.sort) ?? 0
            library.sort = cases[(index + 1) % cases.count]
        case .category(let id):
            if navigation != nil { navigate(.category(id), snapshot: snapshot); return }
            if let category = MonitorMediaCategoryFilter(rawValue: id) { library.category = category }
        case .layout(let layout):
            if navigation != nil { navigate(.layout(layout), snapshot: snapshot); return }
            library.layout = layout
        case .thumbnailSize(let size):
            if navigation != nil { navigate(.thumbnailSize(size), snapshot: snapshot); return }
            library.thumbnailSize = size
        case .open(let id):
            if let request = gallery.open(MediaAssetID(id), admitted: snapshot, operations: operations,
                sourceAvailable: sourceAvailable) { open(request) }
        case .select(let id): selectionFeedback(gallery.toggleSelection(MediaAssetID(id), admitted: snapshot))
        case .selection(let ids): selectionFeedback(gallery.select(Set(ids.map { MediaAssetID($0) }), admitted: snapshot))
        case .favorite(let id): gallery.favorite(MediaAssetID(id), admitted: snapshot, operations: operations)
        case .selectAll: gallery.selectAll(admitted: snapshot)
        case .clearSelection: library.clearSelection()
        case .favoriteSelection: gallery.favoriteSelection(admitted: snapshot, operations: operations)
        case .cacheSelection: gallery.cacheSelection(admitted: snapshot, operations: operations)
        case .deleteSelection: gallery.requestDelete(admitted: snapshot, operations: operations)
        case .shareSelection:
            if let records = gallery.shareSelection(admitted: snapshot, operations: operations) { share?(records, snapshot.token) }
        }
    }
}

/// The caching readout. Its own view: per-chunk progress re-renders this header, not the grid.
private struct MonitorOperatorCachingHeader<Payload: Sendable>: View {
    let records: [MonitorMediaRecord<Payload>]
    let hidden: Bool
    /// The owner's own signal that any record it reports progress for is caching; when false the
    /// header skips asking every record's facts. Nil keeps the scan.
    let active: (@MainActor () -> Bool)?
    let facts: @MainActor (MonitorMediaRecord<Payload>) -> MonitorMediaGalleryFileFacts
    var body: some View {
        if !hidden, active?() ?? true, let (record, progress) = caching {
            HStack(spacing: 10) {
                ProgressView(value: progress).tint(MonitorTheme.accent).frame(maxWidth: 120)
                Text("CACHING \(record.asset.filename) \(Int(progress * 100))%")
                    .font(MonitorTheme.font(10, weight: .medium)).foregroundStyle(MonitorTheme.muted).lineLimit(1)
            }.padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(in: Capsule(), interactive: false)
        }
    }
    private var caching: (MonitorMediaRecord<Payload>, Double)? {
        for record in records { if let progress = facts(record).progress { return (record, progress) } }
        return nil
    }
}

private struct MonitorMediaCalendarSheet: View {
    let request: MonitorMediaGalleryDateRequest
    let range: ClosedRange<Date>
    let commit: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    init(request: MonitorMediaGalleryDateRequest, range: ClosedRange<Date>, key: String?, commit: @escaping (String?) -> Void) {
        self.request = request; self.range = range; self.commit = commit
        _date = State(initialValue: min(max(key.flatMap { MediaLibraryQuery.date(fromKey: $0) } ?? Date(), range.lowerBound), range.upperBound))
    }
    var body: some View {
        NavigationStack {
            DatePicker(request.bound.title, selection: $date, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical).environment(\.calendar, MediaLibraryQuery.filenameCalendar())
                .tint(MonitorTheme.accent).padding(.horizontal, 8).navigationTitle(request.bound.title)
                .navigationBarTitleDisplayMode(.inline).toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Clear") { commit(nil); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { commit(MediaLibraryQuery.dateKey(from: date)); dismiss() } }
                }
        }.presentationDetents([.medium, .large]).preferredColorScheme(.dark)
    }
}

extension MonitorMediaFilterForm {
    /// Builds the shared declared-source form; the caller retains captured action admission.
    @MainActor public init(presentation: MonitorMediaGalleryPresentation,
        onAction: @escaping @MainActor (MonitorMediaGalleryFilterAction) -> Void) {
        let filters = presentation.filters
        self.init(formats: filters.formats, resolutions: filters.resolutions, colors: [],
            formatSelection: filters.formatSelection, resolutionSelection: filters.resolutionSelection,
            colorSelection: [], dateStartLabel: nil, dateEndLabel: nil, hasDates: false,
            onToggleFormat: { onAction(.format($0)) },
            onToggleResolution: { onAction(.resolution($0)) },
            onToggleColor: { _ in }, onPickStart: {}, onPickEnd: {},
            onClear: { onAction(.reset) },
            photoSizes: filters.photoSizes.isEmpty ? nil : .init(options: filters.photoSizes,
                selectedIds: filters.photoSizeSelection, onToggle: { onAction(.photoSize($0)) }),
            dateWindows: filters.dateWindows.isEmpty ? nil : .init(options: filters.dateWindows,
                selectedId: filters.dateWindow, onToggle: { onAction(.dateWindow($0)) }),
            storage: filters.storage.isEmpty ? nil : .init(options: filters.storage,
                selectedId: filters.storageID, onToggle: { onAction(.storage($0)) }),
            hasActiveFilters: presentation.activeFilterCount > 0)
    }
}

private struct MonitorOperatorCatalogIdentity: Hashable {
    let source: ObjectIdentifier
    let lifetime: UUID
    let navigation: [String]
    let filters: [Set<String>]
    let dates: [String?]
}
#endif
