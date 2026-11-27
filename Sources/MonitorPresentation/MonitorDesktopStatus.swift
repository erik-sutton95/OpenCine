import Foundation

/// The desktop status row under a window's title bar (`MonitorChromeStyle.desktop`): what a phone
/// shows on top of the picture, in one row. Built from the same values the top strip and the side
/// gauges show. A value the camera does not report is left out, never shown as a dash.
public struct MonitorDesktopStatus: Equatable, Sendable {
    /// How a chip is coloured: the camera's accent, a link that is up, or a warning level.
    public enum Tint: Equatable, Sendable {
        case plain, accent, good, low, depleted
    }

    public struct Chip: Equatable, Sendable, Identifiable {
        /// The chips in row order.
        public enum Kind: Equatable, Hashable, Sendable {
            case link, battery, card, format, logProfile, mode
        }

        public var kind: Kind
        /// Nil when the chip draws signal bars alone.
        public var text: String?
        /// Link signal bars, out of four.
        public var bars: Int?
        public var tint: Tint
        public var id: Kind { kind }

        public init(kind: Kind, text: String?, bars: Int? = nil, tint: Tint) {
            self.kind = kind
            self.text = text
            self.bars = bars
            self.tint = tint
        }
    }

    /// A camera battery as its source reports it: a percentage, or steps of a coarse gauge.
    public struct Battery: Equatable, Sendable {
        public var percent: Int?
        public var bars: Int?
        public var barCount: Int
        public var warning: Bool
        public var exhausted: Bool
        public var charging: Bool?
        public var externalPower: Bool?

        public init(percent: Int? = nil, bars: Int? = nil, barCount: Int = 5, warning: Bool = false,
            exhausted: Bool = false, charging: Bool? = nil, externalPower: Bool? = nil) {
            self.percent = percent
            self.bars = bars
            self.barCount = barCount
            self.warning = warning
            self.exhausted = exhausted
            self.charging = charging
            self.externalPower = externalPower
        }
    }

    public var link: Chip?
    public var battery: Chip?
    public var card: Chip?
    public var format: Chip?
    public var logProfile: Chip?
    public var mode: Chip?

    public init(link: Chip? = nil, battery: Chip? = nil, card: Chip? = nil, format: Chip? = nil,
        logProfile: Chip? = nil, mode: Chip? = nil) {
        self.link = link
        self.battery = battery
        self.card = card
        self.format = format
        self.logProfile = logProfile
        self.mode = mode
    }

    /// The chips that show, in order: link, battery, card, format, log profile, mode.
    public var chips: [Chip] { [link, battery, card, format, logProfile, mode].compactMap { $0 } }

    /// `fps` and `signalBars` are the link gauge's values, `storage` the card readout, `format`
    /// the format readouts in order, `logProfile` the colour readout and `mode` the shooting mode.
    public static func from(
        fps: String?, signalBars: Int?, battery: Battery?, storage: String?, format: [String],
        logProfile: String?, mode: String?
    ) -> Self {
        let formatText = format.compactMap(shown).joined(separator: " ")
        return Self(
            link: link(fps: fps, signalBars: signalBars),
            battery: battery.flatMap(batteryChip),
            card: shown(storage).map { Chip(kind: .card, text: $0, tint: .plain) },
            format: shown(formatText).map { Chip(kind: .format, text: $0, tint: .plain) },
            logProfile: shown(logProfile).map { Chip(kind: .logProfile, text: $0, tint: .accent) },
            mode: shown(mode).map { Chip(kind: .mode, text: $0, tint: .plain) })
    }

    /// A readout's text, or nil for nothing, blank or a placeholder dash.
    static func shown(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            !placeholders.contains(value)
        else { return nil }
        return value
    }

    private static let placeholders: Set<String> = ["-", "--", "\u{2013}", "\u{2014}", "--:--:--"]

    private static func link(fps: String?, signalBars: Int?) -> Chip? {
        let word = MonitorTelemetryValues.linkValue(fps: fps, signalBars: signalBars, showsRate: false)
        if let bars = signalBars, word == nil {
            return Chip(kind: .link, text: nil, bars: bars, tint: .good)
        }
        if let word = shown(word) {
            // A state word (NO LINK, FAIL, RECOV): down is a warning, a restart is not yet.
            let down = MonitorTelemetryValues.linkSpokenLabel(fps: fps, signalBars: signalBars)
                .hasPrefix("Live link down")
            return Chip(kind: .link, text: word, bars: signalBars, tint: down ? .depleted : .low)
        }
        // Without bars the link shows the feed's rate, when one is known.
        guard fps != nil,
            let rate = shown(MonitorTelemetryValues.linkValue(fps: fps, signalBars: nil, showsRate: true))
        else { return nil }
        return Chip(kind: .link, text: rate, tint: .good)
    }

    private static func batteryChip(_ battery: Battery) -> Chip? {
        let text: String?
        if let bars = battery.bars {
            text = battery.barCount > 0 && (0...battery.barCount).contains(bars) ? "\(bars)/\(battery.barCount)" : nil
        } else {
            text = shown(
                MonitorTelemetryValues.batteryValue(
                    percent: battery.percent, bars: nil, charging: battery.charging,
                    externalPower: battery.externalPower))
        }
        guard let text else { return nil }
        let urgency = MonitorBatteryUrgency.of(
            percent: battery.percent, bars: battery.bars, barCount: battery.barCount,
            warning: battery.warning, exhausted: battery.exhausted)
        let tint: Tint =
            switch urgency {
            case .depleted: .depleted
            case .low: .low
            case .nominal, nil: .plain
            }
        return Chip(kind: .battery, text: text, tint: tint)
    }
}
