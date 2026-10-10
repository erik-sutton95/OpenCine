#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Persisted display choices belong to their existing source namespace.
public enum MonitorMediaGalleryNavigation: Sendable {
    case category(String), layout(MonitorMediaLayout), thumbnailSize(MonitorThumbnailSize), cycleSort
}

/// Source-specific filter domains use the same common form and captured action admission.
public enum MonitorMediaGalleryFilterAction: Sendable {
    case format(String), resolution(String), photoSize(String), dateWindow(String), storage(String), reset
}
public struct MonitorMediaGalleryFilters: Sendable {
    public let formats: [String]
    public let resolutions: [String]
    public let photoSizes: [MonitorMediaFilterChoice]
    public let dateWindows: [MonitorMediaFilterChoice]
    public let storage: [MonitorMediaFilterChoice]
    public let formatSelection: Set<String>
    public let resolutionSelection: Set<String>
    public let photoSizeSelection: Set<String>
    public let dateWindow: String?
    public let storageID: String?
    public init(formats: [String], resolutions: [String], photoSizes: [MonitorMediaFilterChoice] = [],
        dateWindows: [MonitorMediaFilterChoice] = [], storage: [MonitorMediaFilterChoice] = [],
        formatSelection: Set<String>, resolutionSelection: Set<String>, photoSizeSelection: Set<String> = [],
        dateWindow: String? = nil, storageID: String? = nil) {
        self.formats = formats; self.resolutions = resolutions; self.photoSizes = photoSizes
        self.dateWindows = dateWindows; self.storage = storage; self.formatSelection = formatSelection
        self.resolutionSelection = resolutionSelection; self.photoSizeSelection = photoSizeSelection
        self.dateWindow = dateWindow; self.storageID = storageID
    }
}
public struct MonitorMediaGalleryStorage: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let selected: Bool
    public init(id: String, title: String, summary: String, selected: Bool) {
        self.id = id; self.title = title; self.summary = summary; self.selected = selected
    }
}
public struct MonitorMediaGalleryCellContext: Sendable {
    public let list: Bool
    public let selecting: Bool
    public let duration: String?
    public let selected: Bool
}

/// Integration-produced projection and display facts, with no task, page, transport or storage owner.
public struct MonitorMediaGalleryPresentation: Sendable {
    public let projection: MonitorMediaProjectionResult
    public let categories: [MonitorMediaCategory]
    public let category: String
    public let layout: MonitorMediaLayout
    public let thumbnailSize: MonitorThumbnailSize
    public let sortTitle: String
    public let status: String
    public let activeFilterCount: Int
    public let filters: MonitorMediaGalleryFilters
    public let storage: [MonitorMediaGalleryStorage]
    public let navigationClearsSelection: Bool
    public let filterClearsSelection: Bool
    public let retainsVisibleSelection: Bool
    public init(projection: MonitorMediaProjectionResult, categories: [MonitorMediaCategory], category: String,
        layout: MonitorMediaLayout, thumbnailSize: MonitorThumbnailSize, sortTitle: String, status: String,
        activeFilterCount: Int, filters: MonitorMediaGalleryFilters, storage: [MonitorMediaGalleryStorage] = [],
        navigationClearsSelection: Bool = false, filterClearsSelection: Bool = false, retainsVisibleSelection: Bool = false) {
        self.projection = projection; self.categories = categories; self.category = category
        self.layout = layout; self.thumbnailSize = thumbnailSize; self.sortTitle = sortTitle; self.status = status
        self.activeFilterCount = activeFilterCount; self.filters = filters; self.storage = storage
        self.navigationClearsSelection = navigationClearsSelection; self.filterClearsSelection = filterClearsSelection
        self.retainsVisibleSelection = retainsVisibleSelection
    }
}

struct MonitorMediaGalleryStorageCard: View {
    let value: MonitorMediaGalleryStorage
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.title).font(MonitorTheme.font(11, weight: .semibold)).foregroundStyle(MonitorTheme.text)
                    Text(value.summary).font(MonitorTheme.font(10, weight: .medium)).foregroundStyle(MonitorTheme.muted)
                }.lineLimit(1)
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(value.selected ? MonitorTheme.accent.opacity(0.15) : MonitorTheme.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                    .stroke(value.selected ? MonitorTheme.accent.opacity(0.5) : MonitorTheme.border, lineWidth: 1))
        }.buttonStyle(.monitorTapTarget)
    }
}
#endif
