#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI
import UIKit

/// The live link gauge on its own: signal bars, tapping to the feed frame rate. The same gauge the
/// status deck draws, for a host that places the link reading elsewhere (a command dashboard).
public struct MonitorOperatorLinkGauge<Palette: LiveChromePalette>: View {
    private let fps: String?
    private let signalBars: Int?
    public init(fps: String?, signalBars: Int?) {
        self.fps = fps
        self.signalBars = signalBars
    }
    public var body: some View {
        MonitorOperatorTelemetry<Palette>(
            fps: fps, signalBars: signalBars, camera: nil, horizontal: true, showsPower: false)
    }
}

/// Reported power and delivery facts share one renderer: the phone's own battery, then the
/// camera's when the source reports one. Coarse camera gauges retain their declared scale;
/// a missing measurement never becomes a zero-percent battery.
struct MonitorOperatorTelemetry<Palette: LiveChromePalette>: View {
    let fps: String?
    let signalBars: Int?
    let camera: MonitorOperatorPowerReading?
    var horizontal = false
    var showsLink = true
    var showsPower = true
    var metrics: MonitorTelemetryMetrics? = nil
    @State private var showsFPS = false
    @Environment(\.monitorAdaptiveTelemetryPadding) private var adaptivePadding
    @State private var phone = MonitorOperatorPowerReading(id: "phone", title: "Phone battery", camera: false)
    static var nativeMetrics: MonitorTelemetryMetrics {
        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
    }
    private var resolvedMetrics: MonitorTelemetryMetrics { metrics ?? Self.nativeMetrics }

    var body: some View {
        let axis = horizontal
            ? (adaptivePadding && showsPower && !showsLink
                ? AnyLayout(MonitorTelemetryPowerLayout()) : AnyLayout(HStackLayout(spacing: 6)))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: resolvedMetrics.stackSpacing))
        axis {
            if showsLink, fps != nil || signalBars != nil {
                Button { showsFPS.toggle() } label: {
                    Self.gauge(icon: showsFPS ? .gauge : .signal,
                        value: MonitorTelemetryValues.linkValue(fps: fps, signalBars: signalBars, showsRate: showsFPS),
                        bars: signalBars ?? 0, color: MonitorTheme.accent, metrics: resolvedMetrics)
                }
                // The landscape layout spaces the gauges for exactly this padded target.
                .buttonStyle(MonitorTapTargetButtonStyle(minSize: FieldMonitorLayout.minimumTapTarget))
                .accessibilityLabel(linkLabel)
                .accessibilityHint(showsFPS ? "Shows signal strength" : "Shows feed frame rate")
                .accessibilityIdentifier("monitor.telemetry.signal")
            }
            if showsPower {
                powerGauge(phone)
                if let camera { powerGauge(camera) }
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            updatePhone()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in updatePhone() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in updatePhone() }
    }

    private var linkLabel: String {
        MonitorTelemetryValues.linkSpokenLabel(fps: fps, signalBars: signalBars)
    }
    /// The phone's own battery. An unknown level or state stays unknown, never 0% or "not charging".
    private func updatePhone() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        phone = .init(id: "phone", title: "Phone battery", camera: false,
            percent: level < 0 ? nil : Int((level * 100).rounded()),
            charging: state == .unknown ? nil : state == .charging || state == .full)
    }
    private func powerGauge(_ reading: MonitorOperatorPowerReading) -> some View {
        MonitorOperatorPowerTelemetry<Palette>(reading: reading, metrics: resolvedMetrics)
    }

    static func batteryColor(_ percent: Int) -> Color {
        batteryColor(MonitorBatteryUrgency.of(percent: percent, bars: nil, barCount: 4, warning: false, exhausted: false))
    }

    static func batteryColor(_ urgency: MonitorBatteryUrgency?) -> Color {
        switch urgency {
        case .depleted: MonitorTheme.recording
        case .low: Palette.amber
        case .nominal: Palette.good
        case nil: Palette.text
        }
    }

    static func gauge(icon: MonitorIcon?, value: String?, bars: Int, color: Color,
        barCount: Int = 4, metrics: MonitorTelemetryMetrics? = nil) -> some View {
        let metrics = metrics ?? nativeMetrics
        let width = value == nil ? MonitorGaugeBars.readoutWidth(filled: bars, count: barCount,
            minimum: icon == nil ? metrics.iconlessWidth : metrics.pillWidth, inset: icon == nil ? 12 : 28)
            : icon == nil ? metrics.iconlessWidth : metrics.pillWidth
        return MonitorTelemetryPill(width: width, height: metrics.pillHeight) {
            HStack(spacing: 4) {
                if let icon {
                    icon.frame(width: metrics.iconSize, height: metrics.iconSize)
                        .foregroundStyle(Palette.text)
                }
                if let value {
                    Text(value).font(MonitorTheme.font(metrics.fontSize, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(color)
                } else {
                    MonitorGaugeBars(
                        filled: bars, count: barCount, tint: color,
                        barHeight: metrics.barHeight)
                }
            }
        }
        .monitorGlass(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
    }
}

private struct MonitorOperatorPowerTelemetry<Palette: LiveChromePalette>: View {
    let reading: MonitorOperatorPowerReading
    let metrics: MonitorTelemetryMetrics
    @State private var pulse = false
    private var tint: Color {
        MonitorOperatorTelemetry<Palette>.batteryColor(MonitorBatteryUrgency.of(percent: reading.percent,
            bars: reading.bars, barCount: reading.barCount, warning: reading.warning, exhausted: reading.exhausted))
    }
    var body: some View {
        let value = MonitorTelemetryValues.batteryValue(percent: reading.percent, bars: reading.bars,
            charging: reading.charging, externalPower: reading.externalPower)
        MonitorOperatorTelemetry<Palette>.gauge(
            icon: reading.charging == true || reading.externalPower == true
                ? .zap : (reading.camera ? .camera : .smartphone),
            value: value, bars: reading.bars ?? 0, color: tint, barCount: reading.barCount, metrics: metrics)
            .opacity(reading.exhausted && pulse ? 0.35 : 1)
            .animation(reading.exhausted ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = reading.exhausted }.onChange(of: reading.exhausted) { _, value in pulse = value }
            .accessibilityLabel(reading.title)
            .accessibilityValue(Text(verbatim: MonitorTelemetryValues.batterySpokenValue(percent: reading.percent,
                bars: reading.bars, barCount: reading.barCount, charging: reading.charging,
                externalPower: reading.externalPower, exhausted: reading.exhausted) ?? "Unavailable"))
            .accessibilityIdentifier(reading.camera ? "monitor.telemetry.camera" : "monitor.telemetry.phone")
            // The passive bitmap spans the viewport; native focus belongs to the visible pill.
            .contentShape(.accessibility, RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
#endif
