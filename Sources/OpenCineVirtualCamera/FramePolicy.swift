import Foundation

/// Serial-owner state for the virtual camera's single retained frame.
/// All calls must use the extension's serial delivery queue.
public final class FramePolicy<Frame: AnyObject> {
    public enum Slate { case feedOff, noFeed }
    public enum Output {
        case frame(Frame, repeated: Bool)
        case slate(Slate)
    }
    public private(set) var replaced: UInt64 = 0
    public private(set) var rejected: UInt64 = 0
    public private(set) var repeats: UInt64 = 0
    public private(set) var generation: UInt64 = 0
    private var producer: UUID?
    private var latest: Frame?
    private var latestTimestamp: UInt64?
    private var wasDelivered = false
    private var lastOutputTime: UInt64?

    public init() {}

    /// Reserves the only producer slot and returns its reconnect epoch.
    public func claim(_ producer: UUID) -> UInt64? {
        if self.producer == producer { return generation }
        guard self.producer == nil else { return nil }
        generation &+= 1
        self.producer = producer
        latest = nil
        latestTimestamp = nil
        wasDelivered = false
        return generation
    }

    /// Releases the producer and every picture it supplied.
    public func retire(_ producer: UUID) {
        guard self.producer == producer else { return }
        self.producer = nil
        latest = nil
        latestTimestamp = nil
        wasDelivered = false
        generation &+= 1
    }

    /// Replaces the retained frame, rejecting retired, old, future, or reordered input.
    @discardableResult
    public func offer(
        _ frame: Frame, producer: UUID, generation: UInt64, timestamp: UInt64, now: UInt64
    ) -> Bool {
        guard self.producer == producer, self.generation == generation,
            timestamp <= now || timestamp - now <= 100_000_000,
            now <= timestamp || now - timestamp <= 500_000_000,
            latestTimestamp.map({ timestamp > $0 }) ?? true
        else {
            rejected &+= 1
            return false
        }
        if latest != nil && !wasDelivered { replaced &+= 1 }
        latest = frame
        latestTimestamp = timestamp
        wasDelivered = false
        return true
    }

    /// Returns a fresh frame, a counted repeat, or a reusable slate after 500 ms.
    public func output(now: UInt64) -> Output {
        guard producer != nil else { return .slate(.feedOff) }
        guard let frame = latest, let timestamp = latestTimestamp,
            now <= timestamp || now - timestamp <= 500_000_000
        else {
            latest = nil
            return .slate(.noFeed)
        }
        let repeated = wasDelivered
        if repeated { repeats &+= 1 }
        wasDelivered = true
        return .frame(frame, repeated: repeated)
    }

    /// Uses the host clock while preventing timestamp reversal across sleep or format changes.
    public func outputTimestamp(now: UInt64) -> UInt64 {
        let value = lastOutputTime.map { max(now, $0 + 1) } ?? now
        lastOutputTime = value
        return value
    }
}
