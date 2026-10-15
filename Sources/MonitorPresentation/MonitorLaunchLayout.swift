import Foundation

/// Cold-start launch timing, shared by the native splash and startup lifetime.
/// Kotlin twin: MonitorLaunchTiming in appkit.
public enum MonitorLaunchTiming {
    public static let visibleDuration: Duration = .milliseconds(2_250)
    public static let fadeOutDuration: TimeInterval = 0.35
}

/// The launch layout mechanics; the host supplies its actual mark, wordmark and backdrop.
public struct MonitorLaunchLayout: Equatable, Sendable {
    public let landscape: Bool
    public let logoSize: Double
    public let wordmarkSize: Double
    public let spacing: Double
    public let horizontalInset: Double

    public init(width: Double, height: Double, compact: Bool = false) {
        landscape = width >= height
        logoSize = min(width * (landscape ? 0.16 : 0.28), compact ? 72 : 96)
        wordmarkSize = landscape ? (compact ? 28 : 34) : 30
        spacing = landscape ? max(32, width * 0.06) : 24
        horizontalInset = landscape ? max(32, width * 0.08) : 0
    }
}
