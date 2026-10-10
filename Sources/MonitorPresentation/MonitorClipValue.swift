import Foundation

/// Immutable cell facts. Source adapters retain URLs, cache policy and camera operations.
public struct MonitorClipValue: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let duration: String?
    public let source: String?
    public let favorite: Bool
    public let progress: Double?
    public let burstCount: Int?
    public let mediaBadge: String?
    public let completionBadge: String?
    public let transferCaption: String?
    public let format: String?
    public let color: String?
    public let accessibilityDescription: String?
    public let favoriteLabel: String?
    public let selectionEntryLabel: String?

    public init(
        id: String, title: String, detail: String, duration: String?, source: String?,
        favorite: Bool, progress: Double? = nil, burstCount: Int? = nil,
        mediaBadge: String? = nil, completionBadge: String? = nil,
        transferCaption: String? = nil, format: String? = nil, color: String? = nil,
        accessibilityDescription: String? = nil, favoriteLabel: String? = nil,
        selectionEntryLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.duration = duration
        self.source = source
        self.favorite = favorite
        self.progress = progress
        self.burstCount = burstCount
        self.mediaBadge = mediaBadge
        self.completionBadge = completionBadge
        self.transferCaption = transferCaption
        self.format = format
        self.color = color
        self.accessibilityDescription = accessibilityDescription
        self.favoriteLabel = favoriteLabel
        self.selectionEntryLabel = selectionEntryLabel
    }

    /// Preserves the complete catalog's existing state, metadata and duration presentation.
    public init(item: MonitorMediaItem) {
        self.init(
            id: item.id, title: item.filename, detail: item.metadata,
            duration: item.duration.isEmpty ? nil : item.duration,
            source: item.stateLabel, favorite: item.favorite, progress: item.progress,
            burstCount: item.burstCount, mediaBadge: item.mediaBadge,
            completionBadge: item.completionBadge, transferCaption: item.transferCaption,
            format: item.format.isEmpty ? nil : item.format,
            color: item.color.isEmpty ? nil : item.color)
    }
}
