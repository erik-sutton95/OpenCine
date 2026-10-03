#if os(iOS)
import OpenCineMedia
import SwiftUI

public enum MonitorTrafficLightsGeometry {
    public static let baseSize = MonitorScopePanelSize.trafficLights
    public static let meterTitle = "TL"
    public static let accessibilityTitle = "Traffic Lights"
    public static let titleSize: CGFloat = 8.5
    public static let titleSpacing: CGFloat = 6
    public static let columnSpacing: CGFloat = 6
    public static let postSpacing: CGFloat = 4
    public static let panelPad: CGFloat = 8
    public static let trackWidth: CGFloat = 11
    public static let columnHeight: CGFloat = 108
    public static let indicatorSize: CGFloat = 8
    public static let fillsWidthMaxColumn: CGFloat = 44
    public static let trackCorner: CGFloat = 2
    public static let minBarHeight: CGFloat = 1.5
    public static let centerLineFactor: CGFloat = 0.85
    public static let meterRedRGB: (Double, Double, Double) = (255, 92, 82)
    public static let meterGreenRGB: (Double, Double, Double) = (86, 235, 132)
    public static let meterBlueRGB: (Double, Double, Double) = (96, 158, 255)
    public static let leanBalanced = "balanced"
    public static let leanOver = "over"
    public static let leanUnder = "under"
    public static let flagClip = "clip"
    public static let flagCrush = "crush"
    public static let channelNames = ["red", "green", "blue"]

    public static let balanceCenter = 0.5
    public static let balanceDeadZone = 0.03
    public enum BarSide: Equatable, Sendable {
        case neutral
        case over
        case under
    }

    public struct ChannelDisplay: Equatable, Sendable {
        public let side: BarSide
        public let barFill: Double

        public static let neutral = ChannelDisplay(side: .neutral, barFill: 0)
    }

    public static func channelDisplay(
        for channel: ScopeChannelLight,
        balanceCenter center: Double = balanceCenter,
        deadZone: Double = balanceDeadZone
    ) -> ChannelDisplay {
        channelDisplay(level: channel.level, balanceCenter: center, deadZone: deadZone)
    }

    public static func channelDisplay(
        level: Double,
        balanceCenter center: Double = balanceCenter,
        deadZone: Double = balanceDeadZone
    ) -> ChannelDisplay {
        let deviation = level - center
        if abs(deviation) <= deadZone { return .neutral }
        if deviation > 0 {
            let span = max(1 - center, .leastNonzeroMagnitude)
            return ChannelDisplay(side: .over, barFill: min(1, deviation / span))
        }
        let span = max(center, .leastNonzeroMagnitude)
        return ChannelDisplay(side: .under, barFill: min(1, abs(deviation) / span))
    }

    public static func columnWidth(fillsWidth: Bool, panelWidth: CGFloat, uiScale: CGFloat) -> CGFloat {
        if fillsWidth {
            return min(
                fillsWidthMaxColumn,
                max(trackWidth * uiScale, (panelWidth - 16 * uiScale) / 6))
        }
        return trackWidth * uiScale
    }

    public static func meterColor(_ rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }

    public static func accessibilityValue(for reading: ScopeTrafficLightsReading) -> String {
        func channel(_ name: String, _ ch: ScopeChannelLight) -> String {
            let shown = channelDisplay(for: ch)
            let lean: String
            switch shown.side {
            case .neutral: lean = leanBalanced
            case .over: lean = leanOver
            case .under: lean = leanUnder
            }
            let flags = [ch.clip ? flagClip : nil, ch.crush ? flagCrush : nil].compactMap { $0 }
            let flagSuffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return "\(name) \(lean)\(flagSuffix)"
        }
        return [
            channel(channelNames[0], reading.red),
            channel(channelNames[1], reading.green),
            channel(channelNames[2], reading.blue),
        ].joined(separator: ", ")
    }

}

public struct MonitorTrafficLightsMeter: View {
    let reading: ScopeTrafficLightsReading
    var fillsWidth: Bool = false

    public init(reading: ScopeTrafficLightsReading, fillsWidth: Bool = false) {
        self.reading = reading; self.fillsWidth = fillsWidth
    }

    public var body: some View {
        GeometryReader { proxy in
            let uiScale = min(
                proxy.size.width / MonitorTrafficLightsGeometry.baseSize.width,
                proxy.size.height / MonitorTrafficLightsGeometry.baseSize.height)
            let columnWidth = MonitorTrafficLightsGeometry.columnWidth(
                fillsWidth: fillsWidth, panelWidth: proxy.size.width, uiScale: uiScale)
            VStack(spacing: MonitorTrafficLightsGeometry.titleSpacing * uiScale) {
                Text(MonitorTrafficLightsGeometry.meterTitle)
                    .font(
                        .system(
                            size: MonitorTrafficLightsGeometry.titleSize * uiScale, weight: .bold,
                            design: .monospaced)
                    )
                    .foregroundStyle(MonitorTheme.text.opacity(0.58))
                    .lineLimit(1)
                HStack(alignment: .bottom, spacing: MonitorTrafficLightsGeometry.columnSpacing * uiScale) {
                    goalPost(
                        color: MonitorTrafficLightsGeometry.meterColor(MonitorTrafficLightsGeometry.meterRedRGB),
                        channel: reading.red, uiScale: uiScale, columnWidth: columnWidth)
                    goalPost(
                        color: MonitorTrafficLightsGeometry.meterColor(MonitorTrafficLightsGeometry.meterGreenRGB),
                        channel: reading.green, uiScale: uiScale, columnWidth: columnWidth)
                    goalPost(
                        color: MonitorTrafficLightsGeometry.meterColor(MonitorTrafficLightsGeometry.meterBlueRGB),
                        channel: reading.blue, uiScale: uiScale, columnWidth: columnWidth)
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .padding(.horizontal, MonitorTrafficLightsGeometry.panelPad * uiScale)
            .padding(.vertical, MonitorTrafficLightsGeometry.panelPad * uiScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .monitorGlass(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous), density: .scope
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 11, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MonitorTrafficLightsGeometry.accessibilityTitle)
        .accessibilityValue(MonitorTrafficLightsGeometry.accessibilityValue(for: reading))
    }

    private func goalPost(
        color: Color, channel: ScopeChannelLight, uiScale: CGFloat, columnWidth: CGFloat
    ) -> some View {
        let columnHeight = MonitorTrafficLightsGeometry.columnHeight * uiScale
        let indicatorSize = MonitorTrafficLightsGeometry.indicatorSize * uiScale
        let shown = MonitorTrafficLightsGeometry.channelDisplay(for: channel)
        return VStack(spacing: MonitorTrafficLightsGeometry.postSpacing * uiScale) {
            trafficIndicator(
                color: color, active: channel.clip, size: indicatorSize, uiScale: uiScale)
            GeometryReader { proxy in
                let height = proxy.size.height
                let centerLineHeight = max(1, uiScale * MonitorTrafficLightsGeometry.centerLineFactor)
                let halfHeight = (height - centerLineHeight) / 2
                let barHeight = halfHeight * CGFloat(shown.barFill)
                let track = RoundedRectangle(
                    cornerRadius: MonitorTrafficLightsGeometry.trackCorner * uiScale, style: .continuous
                )
                .fill(MonitorTheme.text.opacity(0.08))
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        track
                        if shown.side == .over, barHeight > 0 {
                            goalPostFill(
                                color: color,
                                height: max(MonitorTrafficLightsGeometry.minBarHeight * uiScale, barHeight),
                                uiScale: uiScale, towardClip: true)
                        }
                    }
                    .frame(height: halfHeight)
                    .clipped()
                    Rectangle()
                        .fill(MonitorTheme.text.opacity(0.14))
                        .frame(height: centerLineHeight)
                    ZStack(alignment: .top) {
                        track
                        if shown.side == .under, barHeight > 0 {
                            goalPostFill(
                                color: color,
                                height: max(MonitorTrafficLightsGeometry.minBarHeight * uiScale, barHeight),
                                uiScale: uiScale, towardClip: false)
                        }
                    }
                    .frame(height: halfHeight)
                    .clipped()
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MonitorTrafficLightsGeometry.trackCorner * uiScale, style: .continuous)
                )
                .animation(.easeOut(duration: 0.12), value: shown.barFill)
                .animation(.easeOut(duration: 0.12), value: shown.side)
            }
            .frame(width: columnWidth, height: columnHeight)
            trafficIndicator(
                color: color, active: channel.crush, size: indicatorSize, uiScale: uiScale)
        }
        .frame(maxWidth: .infinity)
    }

    private func goalPostFill(
        color: Color, height: CGFloat, uiScale: CGFloat, towardClip: Bool
    ) -> some View {
        RoundedRectangle(
            cornerRadius: MonitorTrafficLightsGeometry.trackCorner * uiScale, style: .continuous
        )
        .fill(
            LinearGradient(
                colors: [color.opacity(0.35), color.opacity(0.92)],
                startPoint: towardClip ? .bottom : .top,
                endPoint: towardClip ? .top : .bottom)
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func trafficIndicator(color: Color, active: Bool, size: CGFloat, uiScale: CGFloat)
        -> some View
    {
        Circle()
            .fill(active ? color : Color.clear)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(
                        color.opacity(active ? 1 : 0.75), lineWidth: max(1, 1.5 * uiScale))
            )
            .shadow(color: active ? color.opacity(0.45) : .clear, radius: active ? 4 * uiScale : 0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}
#endif
