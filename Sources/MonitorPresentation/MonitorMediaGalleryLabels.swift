import Foundation

public struct MonitorMediaResolutionLevel: Equatable, Sendable {
    public let minimumWidth: Int
    public let label: String
    public init(minimumWidth: Int, label: String) { self.minimumWidth = minimumWidth; self.label = label }
    public static let standard: [Self] = [
        .init(minimumWidth: 7680, label: "8K"), .init(minimumWidth: 5120, label: "6K"),
        .init(minimumWidth: 3840, label: "4K"), .init(minimumWidth: 2880, label: "3K"),
        .init(minimumWidth: 2560, label: "2.7K"), .init(minimumWidth: 1920, label: "1080p"),
        .init(minimumWidth: 1280, label: "720p"),
    ]
}

public enum MonitorMediaGalleryLabels {
    public static func resolution(_ value: String?, levels: [MonitorMediaResolutionLevel] = MonitorMediaResolutionLevel.standard) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let width = value.split(separator: "x").first.flatMap({ Int($0) }) else { return value }
        return levels.first { width >= $0.minimumWidth }?.label ?? value
    }
    public static func date(_ key: String) -> String {
        guard key.count == 8 else { return key }
        return "\(key.prefix(4))-\(key.dropFirst(4).prefix(2))-\(key.suffix(2))"
    }
    public static func metadata(resolution: String?, bytes: String?, duration: String?,
        levels: [MonitorMediaResolutionLevel] = MonitorMediaResolutionLevel.standard) -> String {
        [self.resolution(resolution, levels: levels), bytes, duration]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

}

public enum MonitorMediaGalleryCopy {
    public static let filterEmpty = "Nothing in this tab matches the filters."
    public static let emptyAll = "Nothing on this camera yet. Record a clip, then pull to refresh."
    public static let emptyFavorites = "Nothing favorited yet. Star a clip to find it here."
    public static let emptyVideos = "No videos on this camera yet. Record a clip, then pull to refresh."
    public static let emptyPhotos = "No photos on this camera yet. Capture a still, then pull to refresh."
    public static let disconnected = "Connect the camera to list clips on the body."
    public static let disconnectedEmptyCache = "No cached clips here. Connect the camera to list clips on the body."
    /// Offline, the gallery shows only clips cached on this phone; the last card listing stays
    /// hidden (the documented offline browse: downloaded clips only), and the gallery says so.
    public static let disconnectedCachedOnly = "Camera disconnected. Showing clips cached on this phone."
    public static let browseHint = "Tap to open · Hold, then drag to select"
    public static let selectingHint = "Swipe to scroll · Hold or drag sideways to select"
    /// The gallery's hint line under its item count.
    public static func galleryHint(sourceAvailable: Bool, selecting: Bool) -> String {
        selecting ? selectingHint : sourceAvailable ? browseHint : disconnectedCachedOnly
    }
    public static let listingTitle = "Listing clips on camera…"
    public static let filterEmptyTitle = "No matching clips"
    public static let disconnectedTitle = "Camera disconnected"
    public static let noCachedTitle = "No cached clips"
    public static let emptyTitle = "No clips yet"
    /// The empty gallery's heading, in the same order as [emptySubtitle]: "No clips yet" only
    /// when a connected camera listed nothing for this tab.
    public static func emptyTitle(fetching: Bool, sourceAvailable: Bool, hasRecords: Bool,
        activeFilterCount: Int) -> String {
        if fetching { return listingTitle }
        if !sourceAvailable && !hasRecords { return disconnectedTitle }
        if activeFilterCount > 0 { return filterEmptyTitle }
        return sourceAvailable ? emptyTitle : noCachedTitle
    }
    /// The empty gallery's line: offline with nothing listed, filtered (before the cache is
    /// blamed, ZIB-413), offline with listed clips, or the tab's own [tab] line.
    public static func emptySubtitle(sourceAvailable: Bool, hasRecords: Bool, activeFilterCount: Int,
        tab: String) -> String {
        if !sourceAvailable && !hasRecords { return disconnected }
        if activeFilterCount > 0 { return filterEmpty }
        return sourceAvailable ? tab : disconnectedEmptyCache
    }
    public static let proxyTag = "Proxy"
    public static let proxyHelp = "720p preview. Connect the camera to share the original."
}
