import Foundation

public enum MonitorPlaybackAvailability: Equatable, Sendable { case original, proxy, camera }
public enum MonitorPlaybackClockStyle: Equatable, Sendable {
    case elapsed, roundedMinutesSeconds, elapsedMinutesSeconds
    /// Nil leaves the established product duration formatter in control.
    public func timeLabel(seconds: Double) -> String? {
        guard self != .elapsed else { return nil }
        let rounded = self == .roundedMinutesSeconds
        let value = rounded ? seconds.rounded() : seconds.rounded(.down)
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return rounded ? "00:00" : "0:00" }
        let total = Int(value)
        return String(format: rounded ? "%02d:%02d" : "%d:%02d", total / 60, total % 60)
    }
}

/// Ordered source facts, such as a lens or storage slot. Values have no UI or native owner.
public struct MonitorPlaybackMetadataValue: Equatable, Sendable {
    public let title: String
    public let value: String
    public init(_ title: String, _ value: String) { self.title = title; self.value = value }
}

/// Actual source/cache labels and native buffering, separate from player transport state.
/// Integrations resolve clip colour; common UI formats the accepted content facts.
public struct MonitorPlaybackSourceValues: Sendable {
    public var availability: MonitorPlaybackAvailability?
    public var progress: Double?
    /// Legacy Swift presentation seconds. New native adapters use bufferedThroughSeconds.
    public var buffered: Double?
    /// Furthest native loaded-time-range end, in source seconds; nil is unknown.
    /// This is not a continuous-range guarantee or a downloaded byte fraction.
    public var bufferedThroughSeconds: Double?
    public var colorLabel: String?
    public var transfer: MonitorTransfer?
    /// Legacy hosts may use player/effect transfer fallback. Explicit unknown sources opt out.
    public var allowsSignalFallback: Bool
    public var clipByte: Int?
    public var metadata: [MonitorPlaybackMetadataValue]
    public var clockStyle: MonitorPlaybackClockStyle
    /// A source condition the operator should read now (a share waiting on the camera cache).
    public var notice: String?
    /// The running cache download's speed ("42 MB/s", "Stalled"); nil hides it.
    public var transferRate: String?
    /// Why this source cannot bring the clip to the player now (a camera that does not share its
    /// files over the current connection). Read in place of the player's generic failure.
    public var unavailableReason: String?
    public init(availability: MonitorPlaybackAvailability? = nil, progress: Double? = nil,
        buffered: Double? = nil, colorLabel: String? = nil, transfer: MonitorTransfer? = nil,
        clipByte: Int? = nil, metadata: [MonitorPlaybackMetadataValue] = [],
        clockStyle: MonitorPlaybackClockStyle = .elapsed, bufferedThroughSeconds: Double? = nil,
        allowsSignalFallback: Bool = true, notice: String? = nil, transferRate: String? = nil,
        unavailableReason: String? = nil) {
        self.notice = notice
        self.transferRate = transferRate
        self.unavailableReason = unavailableReason
        self.availability = availability; self.progress = progress; self.buffered = buffered
        self.colorLabel = colorLabel; self.transfer = transfer; self.clipByte = clipByte
        self.metadata = metadata
        self.clockStyle = clockStyle
        self.bufferedThroughSeconds = bufferedThroughSeconds
        self.allowsSignalFallback = allowsSignalFallback
    }
    /// The header line under the title: the source's notice while it has one, else the clip facts.
    public func headerSubtitle(facts: String) -> String {
        if let notice, !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return notice }
        return facts
    }
    /// The failure the player shows: the source's reason while it has one, else the player's own
    /// error. Nil while the player has not failed, so a reason never hides a clip that plays.
    public func loadError(player error: String?) -> String? {
        guard let error else { return nil }
        if let unavailableReason, !unavailableReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return unavailableReason
        }
        return error
    }
    /// Maps a native temporal observation only when its actual native duration is known.
    public func bufferedTemporalFraction(nativeDuration: Double?) -> Double? {
        guard let through = bufferedThroughSeconds, through.isFinite, through >= 0,
            let nativeDuration, nativeDuration.isFinite, nativeDuration > 0
        else { return nil }
        return min(1, max(0, through / nativeDuration))
    }
    /// Resolves current source facts without turning an explicitly unknown source into a default.
    public func resolvedTransfer(fallback: @autoclosure () -> MonitorTransfer?) -> MonitorTransfer? {
        transfer ?? (allowsSignalFallback ? fallback() : nil)
    }
    public var sourceLabel: String? {
        guard let availability else { return nil }
        if availability == .original { return "ORIGINAL · ON PHONE" }
        let label = availability == .proxy ? "PROXY" : "ON CAMERA"
        guard let progress, progress.isFinite else { return label }
        let caption = MediaTransferRate.caption(fraction: progress, rate: transferRate) ?? ""
        return "\(label) · CACHING ORIGINAL \(caption)"
    }
}
