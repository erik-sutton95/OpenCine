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
    public var clipByte: Int?
    public var metadata: [MonitorPlaybackMetadataValue]
    public var clockStyle: MonitorPlaybackClockStyle
    public init(availability: MonitorPlaybackAvailability? = nil, progress: Double? = nil,
        buffered: Double? = nil, colorLabel: String? = nil, transfer: MonitorTransfer? = nil,
        clipByte: Int? = nil, metadata: [MonitorPlaybackMetadataValue] = [],
        clockStyle: MonitorPlaybackClockStyle = .elapsed, bufferedThroughSeconds: Double? = nil) {
        self.availability = availability; self.progress = progress; self.buffered = buffered
        self.colorLabel = colorLabel; self.transfer = transfer; self.clipByte = clipByte
        self.metadata = metadata
        self.clockStyle = clockStyle
        self.bufferedThroughSeconds = bufferedThroughSeconds
    }
    /// Maps a native temporal observation only when its actual native duration is known.
    public func bufferedTemporalFraction(nativeDuration: Double?) -> Double? {
        guard let through = bufferedThroughSeconds, through.isFinite, through >= 0,
            let nativeDuration, nativeDuration.isFinite, nativeDuration > 0
        else { return nil }
        return min(1, max(0, through / nativeDuration))
    }
    public var sourceLabel: String? {
        guard let availability else { return nil }
        if availability == .original { return "ORIGINAL · ON PHONE" }
        let label = availability == .proxy ? "PROXY" : "ON CAMERA"
        guard let progress, progress.isFinite else { return label }
        return "\(label) · CACHING ORIGINAL \(Int(min(1, max(0, progress)) * 100))%"
    }
}
