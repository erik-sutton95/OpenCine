/// How urgently a battery reads, on the live telemetry pills. Kotlin twin: `MonitorBatteryUrgency`.
public enum MonitorBatteryUrgency: Equatable, Sendable {
    case nominal
    case low
    case depleted

    /// The tint tier of one reading on one scale: a fifth or less (or a reported exhaustion) is
    /// depleted, two fifths low, more nominal. A coarse gauge keeps the three tiers its body
    /// shows (five bars: three fine, two find a spare, one swap now); a source `warning` reads
    /// at least low. Unknown charge has no urgency.
    public static func of(percent: Int?, bars: Int?, barCount: Int, warning: Bool,
        exhausted: Bool) -> MonitorBatteryUrgency? {
        if exhausted { return .depleted }
        let fraction: Double
        if let bars, barCount > 0, (0...barCount).contains(bars) {
            fraction = Double(bars) / Double(barCount)
        } else if bars == nil, let percent, (0...100).contains(percent) {
            fraction = Double(percent) / 100
        } else {
            return warning ? .low : nil
        }
        if fraction <= 0.2 { return .depleted }
        return fraction <= 0.4 || warning ? .low : .nominal
    }
}

/// The text of the live telemetry pills, apart from their drawing. Kotlin twin: `MonitorTelemetryValues`.
public enum MonitorTelemetryValues {
    /// The printed battery value: nil while bars draw the reading, a percentage, "EXT" for a body
    /// on external power that reports no level, else a dash.
    public static func batteryValue(percent: Int?, bars: Int?, charging: Bool?, externalPower: Bool?) -> String? {
        if bars != nil { return nil }
        if let percent { return "\(percent)%" }
        return charging == true || externalPower == true ? "EXT" : "\u{2014}"
    }

    /// The spoken battery value after its title, or nil when nothing is known: the level, then
    /// "exhausted" and the power source when reported.
    public static func batterySpokenValue(percent: Int?, bars: Int?, barCount: Int, charging: Bool?,
        externalPower: Bool?, exhausted: Bool) -> String? {
        let power = externalPower == true ? "external power" : charging == true ? "charging" : nil
        let level = bars.map { "\($0) of \(barCount) bars" } ?? percent.map { "\($0) percent" }
        let parts = [level, exhausted ? "exhausted" : nil, power].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The link pill's printed value: nil while bars draw the link, else the frame rate or a dash.
    /// A state word in place of a rate (NO LINK, RECOV, FAIL, LINK) always shows: bars alone
    /// cannot say the picture is held or restarting.
    public static func linkValue(fps: String?, signalBars: Int?, showsRate: Bool) -> String? {
        if let fps, isStateWord(fps) { return fps }
        if showsRate {
            guard let fps else { return "\u{2014}" }
            // Only a finite rate in frame-rate range is rounded; anything else prints as reported.
            guard let rate = Double(fps), rate.isFinite, abs(rate) <= maximumRate else { return fps }
            return "\(Int(rate.rounded())) fps"
        }
        return signalBars == nil ? "\u{2014}" : nil
    }

    /// The link pill's spoken label. A held or failed feed (NO LINK, FAIL) delivers nothing, so it
    /// names no delivery bars; any other state word is the feed state, not a frame rate.
    public static func linkSpokenLabel(fps: String?, signalBars: Int?) -> String {
        let word = fps.flatMap { isStateWord($0) ? $0 : nil }
        let signal: String
        if let word, linkDownWords.contains(word) {
            signal = "down"
        } else if let signalBars {
            signal = "\(signalBars) of 4 delivery bars"
        } else {
            signal = "unavailable"
        }
        let feed: String
        if let word {
            feed = word
        } else if let fps, fps != "\u{2014}" {
            feed = "\(fps) frames per second"
        } else {
            feed = "unavailable"
        }
        return "Live link \(signal), feed \(feed)"
    }

    /// The held-frame badge (`SessionRecoveryCopy.heldFrameBadge`) and the failed-link word.
    private static let linkDownWords: Set<String> = ["NO LINK", "FAIL"]

    /// The largest rate printed as a rounded frame rate.
    static let maximumRate = 100_000.0

    /// A link reading that is a word rather than a measured rate or the idle dash.
    static func isStateWord(_ fps: String) -> Bool {
        !fps.isEmpty && fps != "\u{2014}" && Double(fps) == nil
    }
}
