#if os(iOS)
    import MonitorPresentation
    import SwiftUI

    public struct MonitorMediaNavigationCategory: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let count: Int?

        public init(id: String, title: String, count: Int? = nil) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    /// The enclosing page owns scrolling so storage and category rows share its viewport.
    public struct MonitorMediaNavigation: View {
        private let categories: [MonitorMediaNavigationCategory]
        private let selectedID: String
        private let vertical: Bool
        private let onSelect: (String) -> Void

        public init(
            categories: [MonitorMediaNavigationCategory], selectedID: String, vertical: Bool,
            onSelect: @escaping (String) -> Void
        ) {
            self.categories = categories
            self.selectedID = selectedID
            self.vertical = vertical
            self.onSelect = onSelect
        }

        public var body: some View {
            MonitorTabStrip(vertical: vertical) {
                ForEach(categories) { category in
                    MonitorNavigationItem(
                        category.title, count: category.count.map(String.init),
                        selected: category.id == selectedID,
                        separator: category.id != categories.first?.id
                    ) { onSelect(category.id) }
                    .fixedSize(horizontal: !vertical, vertical: false)
                    .accessibilityLabel("Show \(category.title) media")
                    .accessibilityIdentifier("monitor.media.category.\(category.id)")
                }
            }
        }
    }

    /// The catalog's existing layout and density controls. Persisted values remain host-owned.
    public struct MonitorCatalogDisplayControls: View {
        private let layout: MonitorMediaLayout
        private let thumbnailSize: MonitorThumbnailSize
        private let onLayout: (MonitorMediaLayout) -> Void
        private let onThumbnailSize: (MonitorThumbnailSize) -> Void

        public init(
            layout: MonitorMediaLayout, thumbnailSize: MonitorThumbnailSize,
            onLayout: @escaping (MonitorMediaLayout) -> Void,
            onThumbnailSize: @escaping (MonitorThumbnailSize) -> Void
        ) {
            self.layout = layout
            self.thumbnailSize = thumbnailSize
            self.onLayout = onLayout
            self.onThumbnailSize = onThumbnailSize
        }

        public var body: some View {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    layoutButton(.grid, icon: .layoutGrid, label: "Grid view")
                    layoutButton(.list, icon: .menu, label: "List view")
                }
                .padding(3)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 2) {
                    ForEach(MonitorThumbnailSize.allCases, id: \.self) { size in
                        sizeButton(size)
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Media layout and thumbnail size")
            .accessibilityIdentifier("monitor.media.displayControls")
        }

        private func layoutButton(
            _ mode: MonitorMediaLayout, icon: MonitorIcon, label: String
        ) -> some View {
            let selected = layout == mode
            return Button {
                onLayout(mode)
            } label: {
                icon.view().frame(width: 13, height: 13)
                    .foregroundStyle(selected ? Color.white : MonitorTheme.muted)
                    .frame(width: 32, height: 28)
                    .background(
                        selected ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("monitor.media.layout.\(mode.rawValue)")
        }

        private func sizeButton(_ size: MonitorThumbnailSize) -> some View {
            let selected = size == thumbnailSize
            let dot: CGFloat = size == .small ? 7 : size == .medium ? 10 : 13
            return Button {
                onThumbnailSize(size)
            } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(selected ? Color.white : MonitorTheme.faint)
                    .frame(width: dot, height: dot)
                    .frame(width: 28, height: 28)
                    .background(
                        selected ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel("\(size.rawValue.capitalized) thumbnails")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("monitor.media.thumbnail.\(size.rawValue)")
        }
    }

    /// The catalog toolbar's filter toggle; `open` keeps it lit while the host's popup shows.
    public struct MonitorCatalogFilterButton: View {
        private let activeCount: Int
        private let open: Bool
        private let action: () -> Void

        public init(activeCount: Int, open: Bool, action: @escaping () -> Void) {
            self.activeCount = activeCount
            self.open = open
            self.action = action
        }

        public var body: some View {
            let on = open || activeCount > 0
            Button(action: action) {
                HStack(spacing: 7) {
                    MonitorIcon.listFilter.view().frame(width: 13, height: 13)
                    Text("Filter").font(MonitorTheme.font(10.5, weight: .semibold)).lineLimit(1)
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(MonitorTheme.font(10.5, weight: .semibold))
                    }
                }
                .foregroundStyle(on ? MonitorTheme.text : MonitorTheme.secondary)
                .padding(.horizontal, 11).frame(minWidth: 44, minHeight: 44)
                .background(
                    on ? MonitorTheme.accent.opacity(0.18) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(MonitorButtonStyle())
            .accessibilityLabel("Filter library")
            .accessibilityValue(activeCount == 0 ? "Off" : "\(activeCount) active")
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("monitor.media.filter")
        }
    }
#endif
