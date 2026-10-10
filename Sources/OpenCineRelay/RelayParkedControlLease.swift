import Foundation

/// A dropped socket's recognized install identity may claim its existing control for a bounded
/// window. Source retirement/reclaim/release clears the claim and never invokes a camera command.
public struct RelayParkedControlLease: Equatable, Sendable {
    public static let defaultWindowSeconds: TimeInterval = 20
    public let windowSeconds: TimeInterval
    private struct Parked: Equatable, Sendable {
        let watcherID: String
        let until: Date
    }
    private var parked: Parked?

    public init(windowSeconds: TimeInterval = RelayParkedControlLease.defaultWindowSeconds) {
        self.windowSeconds = windowSeconds
    }

    public func isParked(at now: Date) -> Bool { parked.map { now < $0.until } ?? false }
    public func parkedWatcherID(at now: Date) -> String? {
        isParked(at: now) ? parked?.watcherID : nil
    }

    @discardableResult public mutating func park(watcherID: String?, now: Date) -> Bool {
        guard let watcherID, !watcherID.isEmpty else {
            parked = nil
            return false
        }
        parked = Parked(watcherID: watcherID, until: now.addingTimeInterval(windowSeconds))
        return true
    }

    @discardableResult public mutating func claim(watcherID: String?, now: Date) -> Bool {
        guard let watcherID, !watcherID.isEmpty, isParked(at: now), parked?.watcherID == watcherID
        else { return false }
        parked = nil
        return true
    }

    public mutating func clear() { parked = nil }
}
