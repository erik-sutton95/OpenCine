#if os(iOS)
import MonitorUI
import SwiftUI
import UIKit

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
    @State private var showsFPS = false
    @State private var phone = MonitorOperatorPowerReading(id: "phone", title: "Phone battery", camera: false)
    private static var tablet: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        let axis = horizontal
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.tablet ? 5 : 4))
        axis {
            if showsLink, fps != nil || signalBars != nil {
                Button { showsFPS.toggle() } label: {
                    Self.gauge(icon: showsFPS ? .gauge : .signal,
                        value: showsFPS ? fpsValue : (signalBars == nil ? "\u{2014}" : nil),
                        bars: signalBars ?? 0, color: MonitorTheme.accent)
                }
                .buttonStyle(.monitorTapTarget)
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

    private var fpsValue: String {
        guard let fps else { return "\u{2014}" }
        return Double(fps).map { "\(Int($0.rounded())) fps" } ?? fps
    }
    private var linkLabel: String {
        let signal = signalBars.map { "\($0) of 4 bars" } ?? "unavailable"
        let rate = fps.map { "\($0) frames per second" } ?? "unavailable"
        return "Live link \(signal), feed \(rate)"
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
        MonitorOperatorPowerTelemetry<Palette>(reading: reading)
    }

    static func batteryColor(_ percent: Int) -> Color {
        guard (0...100).contains(percent) else { return Palette.text }
        return percent <= 20 ? MonitorTheme.recording : percent <= 40 ? Palette.amber : Palette.good
    }

    static func gauge(icon: MonitorIcon?, value: String?, bars: Int, color: Color,
        barCount: Int = 4) -> some View {
        let tablet = Self.tablet
        let height: CGFloat = tablet ? 22 : 20
        return HStack(spacing: 4) {
            if let icon {
                icon.frame(width: tablet ? 12 : 11, height: tablet ? 12 : 11)
                    .foregroundStyle(Palette.text)
            }
            if let value {
                Text(value).font(MonitorTheme.font(tablet ? 11 : 10, weight: .semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(color)
            } else {
                HStack(spacing: 1.5) {
                    ForEach(0..<max(1, barCount), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(index < bars ? color : color.opacity(0.2))
                            .frame(width: 3.5, height: tablet ? 10 : 9)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(width: icon == nil ? (tablet ? 44 : 40) : (tablet ? 64 : 58), height: height, alignment: .leading)
        .monitorGlass(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
    }
}

private struct MonitorOperatorPowerTelemetry<Palette: LiveChromePalette>: View {
    let reading: MonitorOperatorPowerReading
    @State private var pulse = false
    private var tint: Color {
        if reading.warning || reading.exhausted { return MonitorTheme.recording }
        if let percent = reading.percent { return MonitorOperatorTelemetry<Palette>.batteryColor(percent) }
        return Palette.text
    }
    var body: some View {
        let value = reading.bars == nil ? reading.percent.map { "\($0)%" } ?? "\u{2014}" : nil
        MonitorOperatorTelemetry<Palette>.gauge(
            icon: reading.charging == true ? .zap : (reading.camera ? .camera : .smartphone),
            value: value, bars: reading.bars ?? 0, color: tint, barCount: reading.barCount)
            .opacity(reading.exhausted && pulse ? 0.35 : 1)
            .animation(reading.exhausted ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = reading.exhausted }.onChange(of: reading.exhausted) { _, value in pulse = value }
            .accessibilityLabel(reading.title)
            .accessibilityValue(reading.bars.map { "\($0) of \(reading.barCount) bars" }
                ?? reading.percent.map { "\($0) percent" } ?? "Unavailable")
            .accessibilityIdentifier(reading.camera ? "monitor.telemetry.camera" : "monitor.telemetry.phone")
    }
}
#endif
