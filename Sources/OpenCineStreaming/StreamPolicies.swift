import Foundation
import OpenCineCore

/// Picks the encoder bitrate from how far the send queue is behind, on the host's clock.
///
/// Behind by more than a second: step down by a quarter, at most every 2 seconds, never below the
/// floor. Clear (under a quarter second) for 10 seconds: step up by a tenth of the target, then
/// wait another 10 clear seconds, never above the target. In between, hold.
public struct StreamBitratePolicy: Sendable {
    public let targetBps: Int
    public let floorBps: Int
    public private(set) var currentBps: Int

    private static let behind: Duration = .seconds(1)
    private static let clear: Duration = .milliseconds(250)
    private static let stepDownInterval: Duration = .seconds(2)
    private static let clearBeforeRise: Duration = .seconds(10)

    private var lastDecrease: MonotonicInstant?
    private var clearSince: MonotonicInstant?

    public init(targetBps: Int, floorBps: Int) {
        self.targetBps = targetBps
        self.floorBps = min(floorBps, targetBps)
        self.currentBps = targetBps
    }

    /// The bitrate to use after this observation.
    public mutating func observe(queuedDuration: Duration, at now: MonotonicInstant) -> Int {
        if queuedDuration > Self.behind {
            clearSince = nil
            if lastDecrease.map({ now - $0 >= Self.stepDownInterval }) ?? true {
                currentBps = max(floorBps, currentBps * 3 / 4)
                lastDecrease = now
            }
        } else if queuedDuration < Self.clear {
            guard let since = clearSince else {
                clearSince = now
                return currentBps
            }
            if now - since >= Self.clearBeforeRise, currentBps < targetBps {
                currentBps = min(targetBps, currentBps + targetBps / 10)
                clearSince = now
            }
        } else {
            clearSince = nil
        }
        return currentBps
    }
}

/// Decides whether and when to reconnect after a connection ends.
///
/// Backoff doubles from 1 second up to 15 seconds. Retries stop 2 minutes after the window opens:
/// at `startedAt` until the stream first goes live, then at the first failure after each time it
/// went live. A refusal (wrong key, rejected stream) never retries.
public struct StreamReconnectPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case retry(after: Duration)
        case giveUp
    }

    private static let window: Duration = .seconds(120)
    private static let firstDelay: Duration = .seconds(1)
    private static let maxDelay: Duration = .seconds(15)

    private var windowStart: MonotonicInstant?
    private var nextDelay = Self.firstDelay

    public init(startedAt: MonotonicInstant) {
        windowStart = startedAt
    }

    /// `failure` is what the session reported, or `nil` when the connection itself failed.
    public mutating func decide(after failure: StreamFailure?, at now: MonotonicInstant) -> Decision {
        if case .refused = failure { return .giveUp }
        let start = windowStart ?? now
        windowStart = start
        guard now - start < Self.window else { return .giveUp }
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, Self.maxDelay)
        return .retry(after: delay)
    }

    /// The stream is live again: the next failure opens a fresh window and backoff starts over.
    public mutating func wentLive() {
        windowStart = nil
        nextDelay = Self.firstDelay
    }
}
