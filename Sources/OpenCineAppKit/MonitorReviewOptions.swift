import Foundation

/// How long a captured picture remains visible after its full image is ready.
public enum MonitorReviewDuration: Int, CaseIterable, Codable, Hashable, Sendable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case sevenSeconds = 7
    case untilDismissed = 0

    public var label: String { rawValue > 0 ? "\(rawValue)s" : "∞" }

    /// No deadline means the operator closes the review explicitly.
    public var automaticDismissDuration: Duration? { rawValue > 0 ? .seconds(rawValue) : nil }

    /// Restore only a declared duration; malformed preferences use the shared default.
    public static func fromSeconds(_ seconds: Int) -> Self { Self(rawValue: seconds) ?? .fiveSeconds }
}

/// Operator preferences for captured-picture review, independent of camera or app identity.
public struct MonitorReviewOptions: Codable, Hashable, Sendable {
    public var duration: MonitorReviewDuration
    public var showsFocusPoint: Bool
    public var showsCaptureInfo: Bool

    public init(duration: MonitorReviewDuration = .fiveSeconds, showsFocusPoint: Bool = true,
        showsCaptureInfo: Bool = true) {
        self.duration = duration
        self.showsFocusPoint = showsFocusPoint
        self.showsCaptureInfo = showsCaptureInfo
    }
}
