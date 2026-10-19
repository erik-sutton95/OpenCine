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
    public static let disconnectedEmptyCache = "Nothing cached on this phone. Connect the camera to list clips on the body."
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
