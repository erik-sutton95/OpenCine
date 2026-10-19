import Foundation

/// How a camera's level assist draws. Kotlin mirror: `MonitorLevelStyle` in `:monitor-ui`.
public enum MonitorLevelStyle: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// A horizon line through the picture's centre that rolls with the camera.
    case horizon = "Horizon"
    /// The two-axis roll and tilt gauge.
    case gauge = "Gauge"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// The typed assist entries a camera declares beyond the shared cinema set. The standard
/// declaration is the one every app had before (only Instant Playback is photography only, no
/// tool is video only, the level is the shared gauge), so an app that declares nothing keeps its
/// list exactly. Retired tools (Magnify) are never offered; only their saved names still decode.
///
/// Kotlin mirror: `MonitorAssistCapabilities` in `:monitor-ui`, same names.
public struct MonitorAssistCapabilities: Hashable, Sendable {
    /// Tools offered only while the camera shoots stills.
    public var photographyOnly: Set<MonitorAssistSelection>
    /// The level styles the operator chooses between; empty means the shared gauge only.
    public var levelStyles: [MonitorLevelStyle]
    /// Shared tools this camera has no source for.
    public var unavailable: Set<MonitorAssistSelection>
    /// Tools offered and drawn only while the camera records video. A camera whose stills live
    /// view is already display referred declares the LUT here, so a log look never grades it twice.
    public var videoOnly: Set<MonitorAssistSelection>

    public init(
        photographyOnly: Set<MonitorAssistSelection> = [.instantReview],
        levelStyles: [MonitorLevelStyle] = [],
        unavailable: Set<MonitorAssistSelection> = [],
        videoOnly: Set<MonitorAssistSelection> = []
    ) {
        self.photographyOnly = photographyOnly
        self.levelStyles = levelStyles
        self.unavailable = unavailable
        self.videoOnly = videoOnly
    }

    /// The declaration of an app that adds nothing to the shared list.
    public static let standard = Self()

    /// The level has a style to choose.
    public var hasLevelStyle: Bool { levelStyles.count > 1 }

    public func isPhotographyOnly(_ tool: MonitorAssistSelection) -> Bool {
        photographyOnly.contains(tool)
    }

    /// Whether this camera offers `tool` in the current capture mode.
    public func offers(_ tool: MonitorAssistSelection, photography: Bool) -> Bool {
        tool != .magnification && !unavailable.contains(tool)
            && (photography || !photographyOnly.contains(tool))
            && (!photography || !videoOnly.contains(tool))
    }
}
