#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The complete shared gallery. The thumbnail slot is the sole image-loading seam;
    /// actions remain intents so another camera storefront supplies its own I/O. The sidebar
    /// (landscape navigation, under the library status) and the accessory (under the header)
    /// are optional camera slots.
    public struct MonitorMediaCatalog<
        Thumbnail: View, Empty: View, Filters: View, Sidebar: View, Accessory: View
    >: View {
        private let brand: String
        private let safeArea: EdgeInsets
        /// Displayed order. Items are built per cell, only for cells the lazy grid realizes, so a
        /// 3200-item card does not build 3200 items (and call the host per item) on every render.
        private let ids: [String]
        private let item: (String) -> MonitorMediaItem?
        private let permissions: (String) -> MonitorMediaPermissions?
        private let categories: [MonitorMediaCategory]
        private let category: String
        private let layout: MonitorMediaLayout
        private let thumbnailSize: MonitorThumbnailSize
        private let sortTitle: String
        private let status: String
        private let selectedIDs: Set<String>
        private let selecting: Bool
        private let refreshing: Bool
        private let canRefresh: Bool
        private let action: (MonitorMediaAction) -> Void
        private let thumbnail: (MonitorMediaItem) -> Thumbnail
        private let empty: Empty
        private let filters: Filters
        private let sidebar: Sidebar
        private let accessory: Accessory
        private let tablet: Bool
        private let hint: String?
        @State private var selectionInteraction = MonitorMediaSelectionInteraction()
        @Environment(\.scenePhase) private var scenePhase

        public init(
            brand: String, safeArea: EdgeInsets, items: [MonitorMediaItem],
            categories: [MonitorMediaCategory], category: String, layout: MonitorMediaLayout,
            thumbnailSize: MonitorThumbnailSize, sortTitle: String, status: String,
            selectedIDs: Set<String>, selecting: Bool, refreshing: Bool, canRefresh: Bool,
            tablet: Bool, hint: String? = nil, action: @escaping (MonitorMediaAction) -> Void,
            @ViewBuilder thumbnail: @escaping (MonitorMediaItem) -> Thumbnail,
            @ViewBuilder empty: () -> Empty, @ViewBuilder filters: () -> Filters,
            @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder accessory: () -> Accessory
        ) {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.init(
                brand: brand, safeArea: safeArea, ids: items.map(\.id), item: { byID[$0] },
                categories: categories, category: category, layout: layout,
                thumbnailSize: thumbnailSize, sortTitle: sortTitle, status: status,
                selectedIDs: selectedIDs, selecting: selecting, refreshing: refreshing,
                canRefresh: canRefresh, tablet: tablet, hint: hint, action: action,
                thumbnail: thumbnail, empty: empty, filters: filters, sidebar: sidebar,
                accessory: accessory)
        }

        /// Lazy items: `item` is called only for realized cells, inside their own views, and
        /// `permissions` (derived from `item` when nil) for selected ids in the selection tray, so a value a cell reads (such as transfer
        /// progress) re-renders that cell, not the whole catalog.
        public init(
            brand: String, safeArea: EdgeInsets, ids: [String],
            item: @escaping (String) -> MonitorMediaItem?,
            permissions: ((String) -> MonitorMediaPermissions?)? = nil,
            categories: [MonitorMediaCategory], category: String, layout: MonitorMediaLayout,
            thumbnailSize: MonitorThumbnailSize, sortTitle: String, status: String,
            selectedIDs: Set<String>, selecting: Bool, refreshing: Bool, canRefresh: Bool,
            tablet: Bool, hint: String? = nil, action: @escaping (MonitorMediaAction) -> Void,
            @ViewBuilder thumbnail: @escaping (MonitorMediaItem) -> Thumbnail,
            @ViewBuilder empty: () -> Empty, @ViewBuilder filters: () -> Filters,
            @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder accessory: () -> Accessory
        ) {
            self.hint = hint
            self.brand = brand
            self.safeArea = safeArea
            self.ids = ids
            self.item = item
            self.permissions = permissions ?? { item($0)?.permissions }
            self.categories = categories
            self.category = category
            self.layout = layout
            self.thumbnailSize = thumbnailSize
            self.sortTitle = sortTitle
            self.status = status
            self.selectedIDs = selectedIDs
            self.selecting = selecting
            self.refreshing = refreshing
            self.canRefresh = canRefresh
            self.tablet = tablet
            self.action = action
            self.thumbnail = thumbnail
            self.empty = empty()
            self.filters = filters()
            self.sidebar = sidebar()
            self.accessory = accessory()
        }

        public var body: some View {
            MonitorPage(
                safeArea: safeArea, navigationWidth: 206,
                heading: MonitorPageHeading(brand: brand, title: "Media"), backLabel: "Back",
                back: dismiss
            ) { portrait in
                navigation(portrait: portrait)
            } detail: { portrait in
                VStack(alignment: .leading, spacing: 8) {
                    header(portrait: portrait)
                    accessory
                    gallery
                    if selecting {
                        MonitorMediaSelectionTray(
                            selectedIDs: selectedIDs, permissions: permissions, action: action)
                    }
                    if portrait { displayControls }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { selectionInteraction.cancel() }
            }
            .onDisappear { selectionInteraction.detach() }
        }

        private func dismiss() { action(.back) }

        private func navigation(portrait: Bool) -> some View {
            VStack(alignment: .leading, spacing: 9) {
                ScrollView(portrait ? .horizontal : .vertical, showsIndicators: false) {
                    MonitorMediaNavigation(
                        categories: categories.map {
                            MonitorMediaNavigationCategory(id: $0.id, title: $0.title, count: $0.count)
                        }, selectedID: category, vertical: !portrait
                    ) { action(.category($0)) }
                }
                .monitorScrollFade(portrait ? .horizontal : .vertical)
                .frame(height: portrait ? 44 : nil)
                if !portrait {
                    VStack(alignment: .leading, spacing: 5) {
                        MonitorSectionHeader("Library")
                        Text(status).font(MonitorTheme.font(9.5)).foregroundStyle(
                            MonitorTheme.muted
                        )
                        .lineLimit(3)
                    }
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    sidebar
                }
                if !portrait { displayControls }
            }
        }

        private var displayControls: some View {
            MonitorCatalogDisplayControls(
                layout: layout, thumbnailSize: thumbnailSize,
                onLayout: { action(.layout($0)) },
                onThumbnailSize: { action(.thumbnailSize($0)) })
        }

        @ViewBuilder private func header(portrait: Bool) -> some View {
            if portrait {
                stackedHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        headerCaption.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        toolbar.fixedSize(horizontal: true, vertical: true)
                    }
                    stackedHeader
                }
            }
        }

        private var stackedHeader: some View {
            VStack(alignment: .leading, spacing: 8) {
                headerCaption
                ScrollView(.horizontal, showsIndicators: false) { toolbar }
                    .monitorScrollFade(.horizontal)
            }
        }

        private var headerCaption: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if refreshing {
                        ProgressView().controlSize(.mini).tint(MonitorTheme.accent)
                    }
                    Text("\(ids.count) items · \(category.lowercased())")
                        .font(MonitorTheme.font(10.5, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                }
                // The source's hint wins: offline it says only cached clips are shown.
                Text(
                    hint
                        ?? (selecting
                            ? MonitorMediaGalleryCopy.selectingHint : MonitorMediaGalleryCopy.browseHint)
                )
                .font(MonitorTheme.font(9)).foregroundStyle(MonitorTheme.faint).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var toolbar: some View {
            HStack(spacing: 6) {
                chip("Sort", icon: .arrowUpDown, text: sortTitle) {
                    action(.cycleSort)
                }
                filters
            }
        }

        private var gallery: some View {
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        if ids.isEmpty {
                            empty.frame(maxWidth: .infinity, minHeight: proxy.size.height)
                        } else if layout == .grid {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 10),
                                    count: thumbnailSize.columns(tablet: tablet)), spacing: 10
                            ) {
                                ForEach(ids, id: \.self) { id in
                                    MonitorMediaLazyCell(id: id) { gridCard($0) }
                                }
                            }
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(ids, id: \.self) { id in
                                    MonitorMediaLazyCell(id: id) { listRow($0) }
                                }
                            }
                            .background(
                                MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .background(
                        MonitorMediaSelectionBridge(
                            interaction: selectionInteraction, ids: ids,
                            selected: selectedIDs, selecting: selecting,
                            context:
                                "\(category)/\(layout.rawValue)/\(thumbnailSize.rawValue)/\(sortTitle)"
                        ) { [action] selection in action(.selection(selection)) })
                }
                .scrollBounceBehavior(.always)
                .refreshable { refresh() }
                .accessibilityIdentifier("monitor.media.gallery")
                .monitorScrollFade()
            }
        }

        private func refresh() {
            if canRefresh && !refreshing { action(.refresh) }
        }

        @ViewBuilder private func gridCard(_ id: String) -> some View {
            if let value = item(id) { cell(value, layout: .grid) }
        }

        @ViewBuilder private func listRow(_ id: String) -> some View {
            if let value = item(id) { cell(value, layout: .list) }
        }

        private func cell(_ item: MonitorMediaItem, layout: MonitorMediaLayout) -> some View {
            MonitorMediaCell(
                clip: MonitorClipValue(item: item), layout: layout, tablet: tablet,
                selecting: selecting, selected: selectedIDs.contains(item.id),
                favoriteEnabled: item.permissions.contains(.favorite),
                sourceTint: item.availability == .original ? MonitorTheme.color(0x3FD3A3) : MonitorTheme.muted,
                onOpen: { action(.open(item.id)) }, onSelect: { action(.select(item.id)) },
                onFavorite: { action(.favorite(item.id)) }
            ) { thumbnail(item) }
            // On the cell's own element, before the selection anchor joins it: after it, both
            // carried the identifier and a clip no longer resolved to one element.
            .accessibilityIdentifier("monitor.media.clip.\(item.id)")
            .background(MonitorMediaSelectionAnchor(id: item.id, interaction: selectionInteraction))
        }

        private func chip(
            _ label: String, icon: MonitorIcon, filled: Bool = false, text: String? = nil,
            active: Bool = false,
            iconSize: CGFloat = 13, danger: Bool = false, action: @escaping () -> Void
        ) -> some View {
            MonitorMediaCatalogChip(
                label: label, icon: icon, filled: filled, text: text, active: active,
                iconSize: iconSize, danger: danger, action: action)
        }

    }

    private struct MonitorMediaCatalogChip: View {
        let label: String
        let icon: MonitorIcon
        var filled = false
        var text: String? = nil
        var active = false
        var iconSize: CGFloat = 13
        var danger = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 7) {
                    icon.view(filled: filled).frame(width: iconSize, height: iconSize)
                    if let text {
                        Text(text).font(MonitorTheme.font(10.5, weight: .semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(
                    danger
                        ? MonitorTheme.recording
                        : active ? MonitorTheme.text : MonitorTheme.secondary
                )
                .padding(.horizontal, text == nil ? 9 : 11).frame(minWidth: 44, minHeight: 44)
                .background(
                    active ? MonitorTheme.accent.opacity(0.18) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(MonitorButtonStyle()).accessibilityLabel(label)
        }
    }

    /// One realized cell. Its body builds the item, so what the item reads is tracked here.
    private struct MonitorMediaLazyCell<Content: View>: View {
        let id: String
        @ViewBuilder let content: (String) -> Content
        var body: some View { content(id) }
    }

    /// The selection actions. Permissions are read from the selected items only, in this view.
    private struct MonitorMediaSelectionTray: View {
        let selectedIDs: Set<String>
        let permissions: (String) -> MonitorMediaPermissions?
        let action: (MonitorMediaAction) -> Void

        var body: some View {
            let selected = selectedIDs.compactMap(permissions)
            HStack(spacing: 4) {
                Text("\(selectedIDs.count) selected").font(
                    MonitorTheme.font(10.5, weight: .semibold)
                )
                .foregroundStyle(MonitorTheme.text).lineLimit(1)
                Spacer(minLength: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        MonitorMediaCatalogChip(label: "Select all", icon: .circleCheck, text: "All") {
                            action(.selectAll)
                        }
                        MonitorMediaCatalogChip(label: "Clear selection", icon: .x, text: "Clear") {
                            action(.clearSelection)
                        }
                        MonitorMediaCatalogChip(
                            label: "Share selected", icon: .share, text: "Share", active: true
                        ) {
                            action(.shareSelection)
                        }
                        .disabled(!Self.allows(.share, in: selected, every: true))
                        MonitorMediaCatalogChip(label: "Cache selected", icon: .download) {
                            action(.cacheSelection)
                        }
                        .disabled(!Self.allows(.cache, in: selected))
                        MonitorMediaCatalogChip(label: "Favorite selected", icon: .star) {
                            action(.favoriteSelection)
                        }
                        .disabled(!Self.allows(.favorite, in: selected))
                        MonitorMediaCatalogChip(
                            label: "Delete selected", icon: .trash, danger: true
                        ) {
                            action(.deleteSelection)
                        }
                        .disabled(!Self.allows(.delete, in: selected, every: true))
                    }
                }
                .monitorScrollFade(.horizontal)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).monitorCardSurface()
        }

        private static func allows(
            _ permission: MonitorMediaPermissions, in selected: [MonitorMediaPermissions],
            every: Bool = false
        ) -> Bool {
            !selected.isEmpty
                && (every
                    ? selected.allSatisfy { $0.contains(permission) }
                    : selected.contains { $0.contains(permission) })
        }
    }

    extension MonitorMediaCatalog where Sidebar == EmptyView, Accessory == EmptyView {
        public init(
            brand: String, safeArea: EdgeInsets, items: [MonitorMediaItem],
            categories: [MonitorMediaCategory], category: String, layout: MonitorMediaLayout,
            thumbnailSize: MonitorThumbnailSize, sortTitle: String, status: String,
            selectedIDs: Set<String>, selecting: Bool, refreshing: Bool, canRefresh: Bool,
            tablet: Bool, action: @escaping (MonitorMediaAction) -> Void,
            @ViewBuilder thumbnail: @escaping (MonitorMediaItem) -> Thumbnail,
            @ViewBuilder empty: () -> Empty, @ViewBuilder filters: () -> Filters
        ) {
            self.init(
                brand: brand, safeArea: safeArea, items: items, categories: categories,
                category: category, layout: layout, thumbnailSize: thumbnailSize,
                sortTitle: sortTitle, status: status, selectedIDs: selectedIDs,
                selecting: selecting, refreshing: refreshing, canRefresh: canRefresh,
                tablet: tablet, action: action, thumbnail: thumbnail, empty: empty,
                filters: filters, sidebar: { EmptyView() }, accessory: { EmptyView() })
        }
    }
#endif
