#if os(iOS)
import MonitorPresentation
import SwiftUI

public typealias MonitorAudioOrientation = MonitorPresentation.MonitorAudioOrientation
public typealias MonitorAudioReadout = MonitorPresentation.MonitorAudioReadout

public enum MonitorAudioMetrics {
    public static let panelSize = CGSize(width: 28, height: 168)
    public static let barCrossAxis: CGFloat = 10
    public static func panelSize(orientation: MonitorAudioOrientation) -> CGSize {
        orientation == .vertical ? panelSize : CGSize(width: panelSize.height, height: panelSize.width)
    }
}

private struct MonitorAudioChannel {
    let levelDB: Double
    let peakDB: Double
}

/// Presentation only: authoritative levels and held peaks arrive from the source adapter.
public struct MonitorAudioMeter: View {
    let left: Double
    let leftPeak: Double
    let right: Double
    let rightPeak: Double
    var orientation: MonitorAudioOrientation
    var showDB: Bool
    let sensitivityLabel: String?
    public init(left: Double, leftPeak: Double, right: Double, rightPeak: Double,
        orientation: MonitorAudioOrientation = .vertical, showDB: Bool = false,
        sensitivityLabel: String? = nil) {
        self.left = left; self.leftPeak = leftPeak; self.right = right; self.rightPeak = rightPeak
        self.orientation = orientation; self.showDB = showDB; self.sensitivityLabel = sensitivityLabel
    }
    private static let yellowFromDB = -18.0
    private static let redFromDB = -6.0
    private static let guideMarks: [Double] = [0, -6, -18, -36]
    private static let gap: CGFloat = 2
    private static let inset: CGFloat = 1
    private static let green = Color(red: 86 / 255, green: 235 / 255, blue: 132 / 255).opacity(0.9)
    private static let yellow = Color(red: 245 / 255, green: 208 / 255, blue: 82 / 255).opacity(
        0.95)
    private static let red = Color(red: 1, green: 92 / 255, blue: 82 / 255).opacity(0.95)

    public var body: some View {
        let size = MonitorAudioMetrics.panelSize(orientation: orientation)
        Self.meters(left: MonitorAudioChannel(levelDB: left, peakDB: leftPeak),
            right: MonitorAudioChannel(levelDB: right, peakDB: rightPeak),
            orientation: orientation, showsDB: showDB)
            .frame(width: size.width, height: size.height)
            .monitorGlass(in: RoundedRectangle(cornerRadius: 10), density: .scope)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio Levels")
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let levels = "Left \(MonitorAudioReadout.label(left)) dBFS, right \(MonitorAudioReadout.label(right)) dBFS"
        return sensitivityLabel.map { "\(levels), sensitivity \($0)" } ?? levels
    }

    private nonisolated static func meters(
        left: MonitorAudioChannel, right: MonitorAudioChannel,
        orientation: MonitorAudioOrientation, showsDB: Bool
    ) -> some View {
        Canvas { context, size in
            let vertical = orientation == .vertical
            let labelReserve: CGFloat = vertical ? 10 : 0
            let barsRect =
                vertical
                ? CGRect(x: 0, y: 2, width: size.width, height: size.height - labelReserve - 2)
                : CGRect(
                    x: 9, y: inset, width: size.width - 9 - (showsDB ? 22 : 1),
                    height: size.height - inset * 2)
            func fraction(_ db: Double) -> CGFloat {
                CGFloat(MonitorAudioReadout.fraction(db))
            }
            func along(_ db: Double) -> CGFloat {
                let t = fraction(db)
                return vertical
                    ? barsRect.maxY - t * barsRect.height : barsRect.minX + t * barsRect.width
            }
            if vertical {
                for mark in guideMarks {
                    let y = along(mark)
                    var line = Path()
                    line.move(to: CGPoint(x: barsRect.minX, y: y))
                    line.addLine(to: CGPoint(x: barsRect.maxX, y: y))
                    context.stroke(
                        line, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
                }
            }
            let barThickness = MonitorAudioMetrics.barCrossAxis
            let pairSpan = barThickness * 2 + gap
            for (index, pair) in [("L", left), ("R", right)].enumerated() {
                let track: CGRect
                if vertical {
                    let x =
                        barsRect.midX - pairSpan / 2 + CGFloat(index) * (barThickness + gap)
                    track = CGRect(
                        x: x, y: barsRect.minY, width: barThickness, height: barsRect.height)
                } else {
                    let y =
                        barsRect.midY - pairSpan / 2 + CGFloat(index) * (barThickness + gap)
                    track = CGRect(
                        x: barsRect.minX, y: y, width: barsRect.width, height: barThickness)
                }
                context.fill(
                    Path(roundedRect: track, cornerRadius: 2),
                    with: .color(Color.white.opacity(0.08)))
                let level = pair.1.levelDB
                let filled =
                    vertical
                    ? CGRect(
                        x: track.minX, y: along(level), width: track.width,
                        height: max(0, track.maxY - along(level)))
                    : CGRect(
                        x: track.minX, y: track.minY,
                        width: max(0, along(level) - track.minX), height: track.height)
                if filled.height > 0.5 && filled.width > 0.5 {
                    var zones = context
                    zones.clip(to: Path(roundedRect: filled, cornerRadius: 2))
                    let bands: [(Double, Double, Color)] = [
                        (MonitorAudioReadout.floorDB, yellowFromDB, green),
                        (yellowFromDB, redFromDB, yellow),
                        (redFromDB, 0, red),
                    ]
                    for band in bands {
                        let start = along(band.0)
                        let end = along(band.1)
                        let slice =
                            vertical
                            ? CGRect(
                                x: track.minX, y: min(start, end), width: track.width,
                                height: abs(end - start))
                            : CGRect(
                                x: min(start, end), y: track.minY, width: abs(end - start),
                                height: track.height)
                        zones.fill(Path(slice), with: .color(band.2))
                    }
                }
                if pair.1.peakDB > MonitorAudioReadout.floorDB + 0.5 {
                    let peak = along(pair.1.peakDB)
                    var tick = Path()
                    if vertical {
                        tick.move(to: CGPoint(x: track.minX, y: peak))
                        tick.addLine(to: CGPoint(x: track.maxX, y: peak))
                    } else {
                        tick.move(to: CGPoint(x: peak, y: track.minY))
                        tick.addLine(to: CGPoint(x: peak, y: track.maxY))
                    }
                    context.stroke(tick, with: .color(zoneColor(pair.1.peakDB)), lineWidth: 1.5)
                }
                context.draw(
                    Text(pair.0)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.58)),
                    at: vertical
                        ? CGPoint(x: track.midX, y: size.height - labelReserve / 2)
                        : CGPoint(x: 5, y: track.midY))
                if showsDB {
                    context.draw(
                        Text(MonitorAudioReadout.label(pair.1.levelDB))
                            .font(.system(size: 6, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.72)),
                        at: vertical
                            ? CGPoint(x: track.midX, y: track.minY + 7)
                            : CGPoint(x: size.width - 11, y: track.midY))
                }
            }
        }
    }

    private nonisolated static func zoneColor(_ db: Double) -> Color {
        if db >= redFromDB { return red }
        if db >= yellowFromDB { return yellow }
        return green
    }
}
#endif
