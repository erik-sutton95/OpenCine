import MonitorPresentation
import Testing

/// Kotlin twin: `MonitorTelemetryValuesTest`. The live telemetry pills keep the readings the
/// standalone apps showed before the shared surface (behavior audit ZAA-302/304/307/334,
/// ZIA-227/230/240/364).
struct MonitorTelemetryValuesTests {
    /// A coarse gauge keeps three tiers: three fifths and up nominal, two fifths low, one depleted.
    @Test func aCameraGaugeKeepsItsLowTierApartFromDepleted() {
        func gauge(_ bars: Int, _ count: Int = 5, exhausted: Bool = false) -> MonitorBatteryUrgency? {
            MonitorBatteryUrgency.of(percent: nil, bars: bars, barCount: count,
                warning: Double(bars) / Double(count) <= 0.4, exhausted: exhausted)
        }
        #expect(gauge(5) == .nominal)
        #expect(gauge(3) == .nominal)
        #expect(gauge(2) == .low)
        #expect(gauge(1) == .depleted)
        #expect(gauge(1, exhausted: true) == .depleted)
        #expect(gauge(0) == .depleted)
        #expect(MonitorBatteryUrgency.of(percent: nil, bars: nil, barCount: 5, warning: false, exhausted: false) == nil)
        // Percentages keep the scale they already had.
        #expect(MonitorBatteryUrgency.of(percent: 15, bars: nil, barCount: 5, warning: false, exhausted: false) == .depleted)
        #expect(MonitorBatteryUrgency.of(percent: 30, bars: nil, barCount: 5, warning: false, exhausted: false) == .low)
        #expect(MonitorBatteryUrgency.of(percent: 80, bars: nil, barCount: 5, warning: false, exhausted: false) == .nominal)
        #expect(MonitorBatteryUrgency.of(percent: 80, bars: nil, barCount: 5, warning: false, exhausted: true) == .depleted)
        #expect(MonitorBatteryUrgency.of(percent: 101, bars: nil, barCount: 5, warning: false, exhausted: false) == nil)
    }

    @Test func theSpokenBatteryNamesExhaustionAndPower() {
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: nil, bars: 1, barCount: 5, charging: nil,
            externalPower: nil, exhausted: true) == "1 of 5 bars, exhausted")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: nil, bars: 3, barCount: 5, charging: true,
            externalPower: true, exhausted: false) == "3 of 5 bars, external power")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: 60, bars: nil, barCount: 5, charging: true,
            externalPower: nil, exhausted: false) == "60 percent, charging")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: 60, bars: nil, barCount: 5, charging: false,
            externalPower: false, exhausted: false) == "60 percent")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: nil, bars: nil, barCount: 5, charging: true,
            externalPower: true, exhausted: false) == "external power")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: nil, bars: nil, barCount: 5, charging: true,
            externalPower: true, exhausted: true) == "exhausted, external power")
        #expect(MonitorTelemetryValues.batterySpokenValue(percent: nil, bars: nil, barCount: 5, charging: nil,
            externalPower: nil, exhausted: false) == nil)
    }

    /// A body on external power that reports no level reads EXT, as it did before the shared pill.
    @Test func externalPowerWithoutALevelReadsEXT() {
        #expect(MonitorTelemetryValues.batteryValue(percent: nil, bars: nil, charging: true, externalPower: true) == "EXT")
        #expect(MonitorTelemetryValues.batteryValue(percent: nil, bars: nil, charging: true, externalPower: nil) == "EXT")
        #expect(MonitorTelemetryValues.batteryValue(percent: nil, bars: nil, charging: nil, externalPower: nil) == "\u{2014}")
        #expect(MonitorTelemetryValues.batteryValue(percent: 60, bars: nil, charging: true, externalPower: nil) == "60%")
        #expect(MonitorTelemetryValues.batteryValue(percent: nil, bars: 3, charging: true, externalPower: true) == nil)
    }

    /// The link pill stays bars-first, but a state word (no rate) always shows without a tap.
    @Test func linkStateWordsShowWithoutATap() {
        for word in ["NO LINK", "RECOV", "FAIL", "LINK", "BUSY", "READY"] {
            #expect(MonitorTelemetryValues.linkValue(fps: word, signalBars: 2, showsRate: false) == word)
            #expect(MonitorTelemetryValues.linkValue(fps: word, signalBars: 2, showsRate: true) == word)
        }
        #expect(MonitorTelemetryValues.linkValue(fps: "25.00", signalBars: 3, showsRate: false) == nil)
        #expect(MonitorTelemetryValues.linkValue(fps: "25.00", signalBars: 3, showsRate: true) == "25 fps")
        #expect(MonitorTelemetryValues.linkValue(fps: "\u{2014}", signalBars: 0, showsRate: false) == nil)
        #expect(MonitorTelemetryValues.linkValue(fps: nil, signalBars: 1, showsRate: false) == nil)
        #expect(MonitorTelemetryValues.linkValue(fps: nil, signalBars: nil, showsRate: false) == "\u{2014}")
        // A rate outside any frame rate prints as reported instead of trapping on conversion.
        #expect(MonitorTelemetryValues.linkValue(fps: "1e100", signalBars: 3, showsRate: true) == "1e100")
        #expect(MonitorTelemetryValues.linkValue(fps: "-1e100", signalBars: 3, showsRate: true) == "-1e100")
        #expect(MonitorTelemetryValues.linkValue(fps: "1e100", signalBars: 3, showsRate: false) == nil)
    }

    /// Hardware pass 7.2a: a held frame was read as "3 of 4 delivery bars, feed NO LINK".
    @Test func aHeldOrFailedFeedNamesNoDeliveryBars() {
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: "NO LINK", signalBars: 3) == "Live link down, feed NO LINK")
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: "FAIL", signalBars: 3) == "Live link down, feed FAIL")
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: "RECOV", signalBars: 3)
            == "Live link 3 of 4 delivery bars, feed RECOV")
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: "25.00", signalBars: 3)
            == "Live link 3 of 4 delivery bars, feed 25.00 frames per second")
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: "\u{2014}", signalBars: 0)
            == "Live link 0 of 4 delivery bars, feed unavailable")
        #expect(MonitorTelemetryValues.linkSpokenLabel(fps: nil, signalBars: nil)
            == "Live link unavailable, feed unavailable")
    }
}
