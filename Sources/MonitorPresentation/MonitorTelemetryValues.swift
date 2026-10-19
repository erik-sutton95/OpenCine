/// How urgently a battery reads, on the live telemetry pills. Kotlin twin: `MonitorBatteryUrgency`.
public enum MonitorBatteryUrgency: Equatable, Sendable {
    case nominal
    case low
    case depleted

    /// The tint tier of one reading. Unknown charge has no urgency.
    public static func of(percent: Int?, bars: Int?, barCount: Int, warning: Bool,
        exhausted: Bool) -> MonitorBatteryUrgency? {
        if warning || exhausted { return .depleted }
        guard let percent, (0...100).contains(percent) else { return nil }
        return percent <= 20 ? .depleted : percent <= 40 ? .low : .nominal
    }
}

/// The text of the live telemetry pills, apart from their drawing. Kotlin twin: `MonitorTelemetryValues`.
public enum MonitorTelemetryValues {
    /// The printed battery value: nil while bars draw the reading, a percentage, else a dash.
    public static func batteryValue(percent: Int?, bars: Int?, charging: Bool?, externalPower: Bool?) -> String? {
        if bars != nil { return nil }
        return percent.map { "\($0)%" } ?? "\u{2014}"
    }

    /// The spoken battery value after its title, or nil when nothing is known.
    public static func batterySpokenValue(percent: Int?, bars: Int?, barCount: Int, charging: Bool?,
        externalPower: Bool?, exhausted: Bool) -> String? {
        bars.map { "\($0) of \(barCount) bars" } ?? percent.map { "\($0) percent" }
    }

    /// The link pill's printed value: nil while bars draw the link, else the frame rate or a dash.
    public static func linkValue(fps: String?, signalBars: Int?, showsRate: Bool) -> String? {
        if showsRate {
            guard let fps else { return "\u{2014}" }
            return Double(fps).map { "\(Int($0.rounded())) fps" } ?? fps
        }
        return signalBars == nil ? "\u{2014}" : nil
    }
}
