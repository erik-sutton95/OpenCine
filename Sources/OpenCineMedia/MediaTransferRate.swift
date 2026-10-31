import Foundation
import OpenCineCore

/// What a download's speed readout says at one instant. Android twin: `MediaTransferRate`.
public enum MediaTransferRate: Equatable, Sendable {
    /// Too little data yet for an honest number: the readout shows nothing.
    case measuring
    /// Bytes per second over the sliding window.
    case bytesPerSecond(UInt64)
    /// No byte arrived for `MediaTransferRateEstimator.stallAfter`.
    case stalled

    /// "42 MB/s", "Stalled", or nil while measuring.
    public var label: String? {
        switch self {
        case .measuring: return nil
        case .stalled: return "Stalled"
        case .bytesPerSecond(let rate): return Self.label(bytesPerSecond: rate)
        }
    }

    /// Decimal units, like `ByteCountLabel`: KB/s under 1 MB/s, MB/s with one decimal under
    /// 10 MB/s, whole MB/s above. Integer half-up rounding, so both platforms agree.
    public static func label(bytesPerSecond rate: UInt64) -> String {
        let kilobytes = (rate + 500) / 1000
        if kilobytes < 1000 { return "\(kilobytes) KB/s" }
        let tenths = (rate + 50_000) / 100_000
        if tenths < 100 { return "\(tenths / 10).\(tenths % 10) MB/s" }
        return "\((rate + 500_000) / 1_000_000) MB/s"
    }

    /// The progress line every download surface shows: "18% · 42 MB/s", or "18%" without a rate.
    /// Nil when there is no progress.
    public static func caption(fraction: Double?, rate: String?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        let percent = "\(Int(min(1, max(0, fraction)) * 100))%"
        return rate.map { "\(percent) · \($0)" } ?? percent
    }
}

/// A download's speed: bytes over a sliding window, measured on instants the owner passes in
/// (its injected clock), so tests never read the wall clock. The window average is the smoothing:
/// a chunk boundary moves it by at most one chunk over the window. Android twin:
/// `MediaTransferRateEstimator`.
public struct MediaTransferRateEstimator: Sendable {
    public static let window: Duration = .seconds(2)
    /// No reading until this long has passed since the start...
    public static let settleTime: Duration = .milliseconds(500)
    /// ...unless this many bytes arrived over at least `earlyTime`.
    public static let settleBytes: UInt64 = 256_000
    public static let earlyTime: Duration = .milliseconds(250)
    public static let stallAfter: Duration = .seconds(3)

    private struct Sample: Sendable {
        let instant: MonotonicInstant
        let total: UInt64
    }

    private var start: MonotonicInstant
    private var startBytes: UInt64
    private var samples: [Sample]
    private var lastArrival: MonotonicInstant

    /// - Parameters:
    ///   - instant: when the transfer began (time to first byte counts as measured time).
    ///   - bytes: bytes already present, such as a resumed download's offset; they are not speed.
    public init(startedAt instant: MonotonicInstant, bytes: UInt64 = 0) {
        start = instant
        startBytes = bytes
        samples = [.init(instant: instant, total: bytes)]
        lastArrival = instant
    }

    /// The transfer's running byte total at `instant`. A smaller total (a retried attempt starting
    /// over) restarts the measurement there.
    public mutating func record(totalBytes: UInt64, at instant: MonotonicInstant) {
        guard let latest = samples.last else { return }
        if totalBytes < latest.total {
            self = .init(startedAt: instant, bytes: totalBytes)
            return
        }
        guard totalBytes > latest.total else { return }
        samples.append(.init(instant: instant, total: totalBytes))
        lastArrival = instant
        // Keep one sample at or before the window's start: it anchors the interpolation.
        let windowStart = MonotonicInstant(instant.sinceReference - Self.window)
        while samples.count > 2, samples[1].instant <= windowStart { samples.removeFirst() }
    }

    public func rate(at now: MonotonicInstant) -> MediaTransferRate {
        guard let first = samples.first, let latest = samples.last else { return .measuring }
        if now - lastArrival >= Self.stallAfter { return .stalled }
        let elapsed = now - start
        let received = latest.total - startBytes
        guard received > 0 else { return .measuring }
        let settled = elapsed >= Self.settleTime
            || (elapsed >= Self.earlyTime && received >= Self.settleBytes)
        guard settled else { return .measuring }
        // Bytes at the window's start, interpolated between the samples around it.
        let windowStart = MonotonicInstant(now.sinceReference - Self.window)
        let from: MonotonicInstant
        let base: Double
        if first.instant >= windowStart {
            from = first.instant
            base = Double(first.total)
        } else {
            let next = samples.first(where: { $0.instant > windowStart }) ?? latest
            from = windowStart
            if next.instant <= first.instant {
                base = Double(next.total)
            } else {
                let span = seconds(next.instant - first.instant)
                let part = seconds(windowStart - first.instant) / span
                base = Double(first.total) + Double(next.total - first.total) * min(1, part)
            }
        }
        let span = seconds(now - from)
        guard span > 0 else { return .measuring }
        let rate = max(0, (Double(latest.total) - base) / span)
        return .bytesPerSecond(UInt64(rate.rounded()))
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
