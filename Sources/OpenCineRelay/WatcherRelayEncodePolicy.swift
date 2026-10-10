import Foundation

/// Bounded encode admission, adapted from OpenZCine's RelayEncodeLane.
/// Dropping before encode preserves the reference chain; dropping after encode requires an IDR.
public struct WatcherRelayEncodePolicy: Equatable, Sendable {
    public private(set) var inFlight = 0
    public static let capacity = 2
    public let depth: Int
    public let minimumKeyframeSeconds: TimeInterval
    private var lastKeyAt: TimeInterval = -.infinity

    public init(
        depth: Int = WatcherRelayEncodePolicy.capacity, minimumKeyframeSeconds: TimeInterval = 1
    ) {
        self.depth = max(1, depth)
        self.minimumKeyframeSeconds = minimumKeyframeSeconds
    }

    public mutating func admit() -> Bool {
        guard inFlight < depth else { return false }
        inFlight += 1
        return true
    }

    public mutating func complete() { inFlight = max(0, inFlight - 1) }

    /// A peer's repeated request must never reset this cooldown.
    public mutating func forceKeyframe(requested: Bool, now: TimeInterval) -> Bool {
        guard requested, now - lastKeyAt >= minimumKeyframeSeconds else { return false }
        lastKeyAt = now
        return true
    }
}
