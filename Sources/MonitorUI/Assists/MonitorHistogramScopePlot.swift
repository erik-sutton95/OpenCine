#if os(iOS)
import OpenCineMedia
import SwiftUI

public enum MonitorHistogramGeometry {
    public static let clipZoneIRE = 95.0
    public static let trafficLampWidth: CGFloat = 7.5
    public static let trafficLampHeight: CGFloat = 15
    public static let trafficOuterPad: CGFloat = 6
    public static let trafficLineGap: CGFloat = 4
    public static var trafficGutter: CGFloat { trafficOuterPad + trafficLampWidth + trafficLineGap }
    public static var trafficHorizontalInset: CGFloat { trafficOuterPad }
    public static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: trafficGutter, y: MonitorWaveformAxis.titleHeight,
            width: max(1, size.width - trafficGutter * 2),
            height: max(1, size.height - MonitorWaveformAxis.titleHeight - MonitorWaveformAxis.bottomPad))
    }
    public static func plotX(_ ire: Double, in rect: CGRect) -> CGFloat {
        MonitorWaveformAxis.plotX(ire, rect)
    }
    public static func ireX(_ ire: Double, in rect: CGRect) -> CGFloat { plotX(ire, in: rect) }
}

public struct MonitorHistogramScopePlot: View, Equatable {
    public var display: ScopeHistogramDisplay
    public var traffic: ScopeTrafficLightsReading = .none
    public var showTrafficLights = true

    public init(display: ScopeHistogramDisplay, traffic: ScopeTrafficLightsReading = .none,
        showTrafficLights: Bool = true) {
        self.display = display; self.traffic = traffic; self.showTrafficLights = showTrafficLights
    }

    public var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = MonitorHistogramGeometry.plotRect(in: size)
                // One shared peak so channel heights stay comparable (floor 1).
                let peak = max(
                    display.red.max() ?? 0, display.green.max() ?? 0,
                    display.blue.max() ?? 0, display.luma.max() ?? 0, 1)
                drawHistogramReferenceGrid(in: context, rect: rect)
                if showTrafficLights, traffic.anyClip {
                    let clipStart = MonitorHistogramGeometry.ireX(MonitorHistogramGeometry.clipZoneIRE, in: rect)
                    let clipEnd = MonitorHistogramGeometry.ireX(100, in: rect)
                    context.fill(
                        Path(
                            CGRect(
                                x: clipStart, y: rect.minY,
                                width: max(0, clipEnd - clipStart), height: rect.height)),
                        with: .color(MonitorScopePalette.clip.opacity(0.14)))
                }
                // Traces first, clipped to 0…100; min/max strokes sit on top.
                var signal = context
                signal.clip(to: Path(histogramSignalRect(in: rect)))
                var additive = signal
                additive.opacity = 0.92
                additive.blendMode = .plusLighter
                drawHistogramChannel(
                    in: additive, bins: display.red, rect: rect, peak: peak,
                    fill: MonitorScopePalette.histogramRedFill,
                    stroke: MonitorScopePalette.rgba(255, 48, 44, 0.96))
                drawHistogramChannel(
                    in: additive, bins: display.green, rect: rect, peak: peak,
                    fill: MonitorScopePalette.histogramGreenFill,
                    stroke: MonitorScopePalette.rgba(0, 238, 70, 0.92))
                drawHistogramChannel(
                    in: additive, bins: display.blue, rect: rect, peak: peak,
                    fill: MonitorScopePalette.histogramBlueFill,
                    stroke: MonitorScopePalette.rgba(45, 76, 255, 0.94))
                var lumaContext = signal
                lumaContext.opacity = 0.58
                drawHistogramLumaStroke(
                    in: lumaContext, bins: display.luma, rect: rect, peak: peak,
                    stroke: MonitorScopePalette.rgba(245, 242, 232, 0.58))
                drawHistogramBoundaries(in: context, rect: rect)
            }
            if showTrafficLights {
                HStack {
                    trafficColumn(
                        red: traffic.red.crush, green: traffic.green.crush,
                        blue: traffic.blue.crush)
                    Spacer()
                    trafficColumn(
                        red: traffic.red.clip, green: traffic.green.clip,
                        blue: traffic.blue.clip)
                }
                .padding(.horizontal, MonitorHistogramGeometry.trafficHorizontalInset)
                .padding(.top, 12)
            }
        }
    }

    private func trafficColumn(red: Bool, green: Bool, blue: Bool) -> some View {
        VStack(spacing: 3) {
            trafficBlock(MonitorScopePalette.rgba(255, 92, 82, 1), hot: red)
            trafficBlock(MonitorScopePalette.rgba(86, 235, 132, 1), hot: green)
            trafficBlock(MonitorScopePalette.rgba(96, 158, 255, 1), hot: blue)
        }
    }

    private func trafficBlock(_ color: Color, hot: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(hot ? color : Color.clear)
            .frame(
                width: MonitorHistogramGeometry.trafficLampWidth,
                height: MonitorHistogramGeometry.trafficLampHeight
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(color.opacity(hot ? 1 : 0.8), lineWidth: 1.5)
            )
            .shadow(color: hot ? color.opacity(0.45) : .clear, radius: hot ? 5 : 0)
            .animation(.easeOut(duration: 0.15), value: hot)
    }
}

private func drawHistogramReferenceGrid(in context: GraphicsContext, rect: CGRect) {
    for step in 1..<4 {
        let y = rect.minY + rect.height * CGFloat(step) / 4
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(line, with: .color(MonitorScopePalette.rgba(220, 235, 225, 0.06)), lineWidth: 1)
    }
}

private func drawHistogramBoundaries(in context: GraphicsContext, rect: CGRect) {
    for scale in [0.0, 100.0] {
        let x = MonitorHistogramGeometry.ireX(scale, in: rect)
        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(line, with: .color(MonitorScopePalette.rgba(220, 235, 225, 0.8)), lineWidth: 1.25)
    }
}

/// The WAVE 0…100 band. Traces clip here so stroke/fill cannot pass min/max.
private func histogramSignalRect(in rect: CGRect) -> CGRect {
    let x0 = MonitorHistogramGeometry.ireX(0, in: rect)
    let x100 = MonitorHistogramGeometry.ireX(100, in: rect)
    return CGRect(x: x0, y: rect.minY, width: max(1, x100 - x0), height: rect.height)
}

private func histogramPaths(bins: [Float], rect: CGRect, peak: Float) -> (fill: Path, stroke: Path)
{
    guard bins.count > 1, peak > 0, bins.contains(where: { $0 > 0 }) else {
        return (Path(), Path())
    }
    let last = bins.count - 1
    func point(at index: Int) -> CGPoint {
        let x = MonitorHistogramGeometry.plotX(Double(index) / Double(last) * 100, in: rect)
        let height = CGFloat(bins[index] / peak) * rect.height
        return CGPoint(x: x, y: rect.maxY - height)
    }
    var fill = Path()
    fill.move(to: CGPoint(x: MonitorHistogramGeometry.plotX(0, in: rect), y: rect.maxY))
    fill.addLine(to: point(at: 0))
    var stroke = Path()
    stroke.move(to: point(at: 0))
    for index in 1...last {
        let previous = point(at: index - 1)
        let current = point(at: index)
        let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
        fill.addQuadCurve(to: midpoint, control: previous)
        stroke.addQuadCurve(to: midpoint, control: previous)
    }
    fill.addLine(to: CGPoint(x: MonitorHistogramGeometry.plotX(100, in: rect), y: rect.maxY))
    fill.closeSubpath()
    return (fill, stroke)
}

private func drawHistogramChannel(
    in context: GraphicsContext, bins: [Float], rect: CGRect, peak: Float, fill: Color,
    stroke: Color
) {
    let paths = histogramPaths(bins: bins, rect: rect, peak: peak)
    context.fill(paths.fill, with: .color(fill))
    context.stroke(
        paths.stroke, with: .color(stroke),
        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
}

private func drawHistogramLumaStroke(
    in context: GraphicsContext, bins: [Float], rect: CGRect, peak: Float, stroke: Color
) {
    let paths = histogramPaths(bins: bins, rect: rect, peak: peak)
    context.stroke(
        paths.stroke, with: .color(stroke),
        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
}

#endif
