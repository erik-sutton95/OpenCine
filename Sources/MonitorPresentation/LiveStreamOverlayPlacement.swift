import Foundation

/// Where the Go live control hangs on the live monitor: under the status row (the timecode block)
/// at its trailing edge, inside the trailing safe area. With the status row turned off it keeps
/// the same top trailing corner. Kotlin twin: `LiveStreamOverlayPlacement` (monitor-ui).
public enum LiveStreamOverlayPlacement {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    static let edgeGap = 8.0
    static let statusGap = 6.0

    /// The top trailing point of the control, in viewport coordinates.
    public static func anchor(status: MonitorRect, viewportWidth: Double, safeTop: Double,
        safeTrailing: Double) -> Point {
        let trailingEdge = viewportWidth - max(0, safeTrailing)
        guard status.height > 1 else {
            return Point(x: trailingEdge - edgeGap, y: max(0, safeTop, edgeGap) + edgeGap)
        }
        return Point(x: min(status.maxX, trailingEdge) - edgeGap, y: status.maxY + statusGap)
    }
}
