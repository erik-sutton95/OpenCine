import Foundation
import Observation
import OpenCineCore
import OpenCineMedia

/// The one download-speed source every app's progress UI reads: one estimator per running
/// download, read again on a steady tick so a stall shows without a new byte (the tick rests
/// once every download reads Stalled). The media library
/// feeds it for the transfers it owns; an app that streams clips itself feeds its own.
/// Android twin: `MonitorTransferRates`.
@available(macOS 14, *)
@MainActor @Observable public final class MonitorTransferRates<Key: Hashable & Sendable> {
    /// How often a running download's reading is refreshed.
    public static var tick: Duration { .milliseconds(500) }

    /// The current reading per running download. A key is absent once its download ended.
    public private(set) var rates: [Key: MediaTransferRate] = [:]

    @ObservationIgnored private let clock: HostClock
    @ObservationIgnored private var estimators: [Key: MediaTransferRateEstimator] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(clock: HostClock = .live) {
        self.clock = clock
    }

    /// The reading for `key`, nil when no download for it is running.
    public func rate(_ key: Key) -> MediaTransferRate? { rates[key] }

    /// A download for `key` starts (again). `bytes` already present, such as a resumed offset,
    /// do not count as speed.
    public func begin(_ key: Key, bytes: UInt64 = 0) {
        estimators[key] = .init(startedAt: clock.now(), bytes: bytes)
        publish(key, .measuring)
        startTicking()
    }

    /// The download's running byte total. Starts the download when `begin` was not called.
    public func record(_ key: Key, totalBytes: UInt64) {
        guard estimators[key] != nil else {
            begin(key, bytes: totalBytes)
            return
        }
        estimators[key]?.record(totalBytes: totalBytes, at: clock.now())
        startTicking()
    }

    /// The download for `key` ended: its reading disappears now.
    public func end(_ key: Key) {
        estimators[key] = nil
        if rates[key] != nil { rates[key] = nil }
        if estimators.isEmpty { stopTicking() }
    }

    /// Ends every download not in `keys`, for an owner that retired several at once.
    public func retain(_ keys: Set<Key>) {
        for key in estimators.keys where !keys.contains(key) { end(key) }
    }

    private func publish(_ key: Key, _ rate: MediaTransferRate) {
        if rates[key] != rate { rates[key] = rate }
    }

    private func refresh() {
        let now = clock.now()
        for (key, estimator) in estimators { publish(key, estimator.rate(at: now)) }
        // A stalled reading changes only with a new byte, which starts the tick again: no timer
        // runs for a download that went quiet.
        if rates.values.allSatisfy({ $0 == .stalled }) { stopTicking() }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let clock = clock
        // Holds the owner weakly: a dropped owner ends the ticker at its next turn.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(Self.tick) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
