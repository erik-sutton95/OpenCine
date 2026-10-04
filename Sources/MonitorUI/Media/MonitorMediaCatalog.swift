#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    /// The complete shared gallery. The thumbnail slot is the sole image-loading seam;
    /// actions remain intents so another camera storefront supplies its own I/O.
    public struct MonitorMediaCatalog<Thumbnail: View, Empty: View, Filters: View>: View {
        private let brand: String
        private let safeArea: EdgeInsets
        private let items: [MonitorMediaItem]
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
        private let tablet: Bool
        @State private var selectionInteraction = MonitorMediaSelectionInteraction()
        @Environment(\.scenePhase) private var scenePhase

        public init(
            brand: String, safeArea: EdgeInsets, items: [MonitorMediaItem],
            categories: [MonitorMediaCategory], category: String, layout: MonitorMediaLayout,
            thumbnailSize: MonitorThumbnailSize, sortTitle: String, status: String,
            selectedIDs: Set<String>, selecting: Bool, refreshing: Bool, canRefresh: Bool,
            tablet: Bool, action: @escaping (MonitorMediaAction) -> Void,
            @ViewBuilder thumbnail: @escaping (MonitorMediaItem) -> Thumbnail,
            @ViewBuilder empty: () -> Empty, @ViewBuilder filters: () -> Filters
        ) {
            self.brand = brand
            self.safeArea = safeArea
            self.items = items
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
                    gallery
                    if selecting { selectionTray }
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
                    Text("\(items.count) items · \(category.lowercased())")
                        .font(MonitorTheme.font(10.5, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text)
                }
                Text(
                    selecting
                        ? "Swipe to scroll · Hold or drag sideways to select"
                        : "Tap to open · Hold, then drag to select"
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
                        if items.isEmpty {
                            empty.frame(maxWidth: .infinity, minHeight: proxy.size.height)
                        } else if layout == .grid {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 10),
                                    count: thumbnailSize.columns(tablet: tablet)), spacing: 10
                            ) {
                                ForEach(items) { item in gridCard(item) }
                            }
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(items) { item in listRow(item) }
                            }
                            .background(
                                MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .background(
                        MonitorMediaSelectionBridge(
                            interaction: selectionInteraction, ids: items.map(\.id),
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

        private func gridCard(_ item: MonitorMediaItem) -> some View {
            cell(item, layout: .grid)
        }

        private func listRow(_ item: MonitorMediaItem) -> some View {
            cell(item, layout: .list)
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
            .background(MonitorMediaSelectionAnchor(id: item.id, interaction: selectionInteraction))
            .accessibilityIdentifier("monitor.media.clip.\(item.id)")
        }

        private var selectedItems: [MonitorMediaItem] {
            items.filter { selectedIDs.contains($0.id) }
        }

        private func selectionAllows(_ permission: MonitorMediaPermissions, every: Bool = false)
            -> Bool
        {
            !selectedItems.isEmpty
                && (every
                    ? selectedItems.allSatisfy { $0.permissions.contains(permission) }
                    : selectedItems.contains { $0.permissions.contains(permission) })
        }

        private var selectionTray: some View {
            HStack(spacing: 4) {
                Text("\(selectedIDs.count) selected").font(
                    MonitorTheme.font(10.5, weight: .semibold)
                )
                .foregroundStyle(MonitorTheme.text).lineLimit(1)
                Spacer(minLength: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        chip("Select all", icon: .circleCheck, text: "All") {
                            action(.selectAll)
                        }
                        chip("Clear selection", icon: .x, text: "Clear") {
                            action(.clearSelection)
                        }
                        chip(
                            "Share selected", icon: .share, text: "Share",
                            active: true
                        ) {
                            action(.shareSelection)
                        }
                        .disabled(!selectionAllows(.share, every: true))
                        chip("Cache selected", icon: .download) { action(.cacheSelection) }
                            .disabled(!selectionAllows(.cache))
                        chip("Favorite selected", icon: .star) { action(.favoriteSelection) }
                            .disabled(!selectionAllows(.favorite))
                        chip("Delete selected", icon: .trash, danger: true) {
                            action(.deleteSelection)
                        }
                        .disabled(!selectionAllows(.delete, every: true))
                    }
                }
                .monitorScrollFade(.horizontal)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).monitorCardSurface()
        }

        private func chip(
            _ label: String, icon: MonitorIcon, filled: Bool = false, text: String? = nil,
            active: Bool = false,
            iconSize: CGFloat = 13, danger: Bool = false, action: @escaping () -> Void
        ) -> some View {
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
#endif
