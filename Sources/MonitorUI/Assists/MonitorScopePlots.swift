#if os(iOS)
import MetalKit
import OpenCineMedia
import MonitorPresentation
import SwiftUI

/// Complete trace and guide composition, independent of source lifetime and operator storage.
public struct MonitorWaveformScopePlot: View {
    let samples: ScopeSamples
    let trail: ScopeSamples
    let mode: MonitorScopeTraceMetal.Mode
    let axis: ScopeLevelAxis
    let revision: UInt64
    let intensity: Double
    let guides: MonitorScopeGuides
    let size: CGSize
    let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    public init(samples: ScopeSamples, trail: ScopeSamples = .empty, mode: MonitorScopeTraceMetal.Mode,
        transfer: MonitorTransfer, clipByte: Int, revision: UInt64, intensity: Double,
        guides: MonitorScopeGuides = .default, size: CGSize,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr }) {
        self.init(samples: samples, trail: trail, mode: mode,
            axis: ScopeLevelAxis(transfer: transfer, clipByte: clipByte), revision: revision,
            intensity: intensity, guides: guides, size: size, configureDisplay: configureDisplay)
    }
    /// A source with its own measured code placement passes its axis directly.
    public init(samples: ScopeSamples, trail: ScopeSamples = .empty, mode: MonitorScopeTraceMetal.Mode,
        axis: ScopeLevelAxis, revision: UInt64, intensity: Double,
        guides: MonitorScopeGuides = .default, size: CGSize,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr }) {
        self.samples = samples; self.trail = trail; self.mode = mode; self.axis = axis
        self.revision = revision; self.intensity = intensity
        self.guides = guides; self.size = size; self.configureDisplay = configureDisplay
    }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if MonitorScopeTraceMetal.isAvailable {
                let plot = MonitorWaveformAxis.plotRect(in: size)
                MonitorScopeTraceMetalView(samples: samples, trail: trail, mode: mode,
                    axis: axis, revision: revision, opacity: intensity,
                    layoutSize: plot.size, configureDisplay: configureDisplay)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
            } else {
                switch mode {
                case .waveform(let mode):
                    WaveformCanvasPlot(samples: samples, trail: trail, mode: mode,
                        table: axis.table, opacity: intensity)
                        .frame(width: size.width, height: size.height)
                case .parade(let mode):
                    ParadeCanvasPlot(samples: samples, trail: trail, mode: mode,
                        table: axis.table, opacity: intensity)
                        .frame(width: size.width, height: size.height)
                }
            }
            ScopeGuideOverlay(clip: axis.supportsCalibratedReferences && guides.clip,
                crush: axis.supportsCalibratedReferences && guides.crush,
                middle: axis.supportsCalibratedReferences && guides.middle,
                middleGrayIRE: axis.middleGrayIRE)
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(axis.supportsCalibratedReferences ? "Calibrated scope references" : "Encoded code range")
        }
    }
}

public struct MonitorVectorscopeScopePlot: View {
    let points: [ScopePoint]
    let trail: [ScopePoint]
    let zoom: MonitorVectorscopeZoom
    let brightness: Int
    let revision: UInt64
    let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    public init(points: [ScopePoint], trail: [ScopePoint] = [], zoom: MonitorVectorscopeZoom = .x1,
        brightness: Int = 100, revision: UInt64 = 0,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr }) {
        self.points = points; self.trail = trail; self.zoom = zoom
        self.brightness = brightness; self.revision = revision; self.configureDisplay = configureDisplay
    }
    public var body: some View {
        ZStack {
            if MonitorScopeTraceMetal.isAvailable {
                Canvas { context, size in
                    drawMonitorVectorscopeGraticule(in: context, rect: MonitorScopeGeometry.vectorscopeSquare(in: size))
                }
                MonitorVectorscopeMetalView(points: points, trailPoints: trail, zoom: zoom,
                    brightness: brightness, revision: revision, configureDisplay: configureDisplay)
            } else {
                VectorscopeCanvasPlot(points: points, trailPoints: trail, zoom: zoom, brightness: brightness)
            }
        }
    }
}

private struct WaveformCanvasPlot: View, Equatable {
    var samples: ScopeSamples
    var trail: ScopeSamples = .empty
    var mode: MonitorWaveformMode = .rgb
    var table: [Float]
    var opacity: Double = 1

    var body: some View {
        Canvas { context, size in
            let rect = MonitorWaveformAxis.plotRect(in: size)
            var traces = context
            traces.clip(to: Path(MonitorScopeGeometry.traceClipRect(rect)))
            drawTrace(
                trail.points, rect: rect, table: table, context: traces,
                opacity: opacity * MonitorScopeTraceMetal.trailDecay)
            drawTrace(
                samples.points, rect: rect, table: table, context: traces, opacity: opacity)
        }
    }

    private func drawTrace(
        _ points: [ScopePoint], rect: CGRect, table: [Float],
        context: GraphicsContext, opacity: Double
    ) {
        guard !points.isEmpty, opacity > 0 else { return }
        var ctx = context
        ctx.opacity = opacity
        ctx.blendMode = .plusLighter
        func y(_ byte: UInt8) -> CGFloat { MonitorWaveformAxis.plotY(Double(table[Int(byte)]), rect) }
        switch mode {
        case .luma:
            for (index, point) in points.enumerated() {
                let x = rect.minX + CGFloat(point.xRatio) * rect.width
                let tickY = y(point.luma)
                ctx.fill(
                    Path(CGRect(x: x, y: tickY - 1, width: 2, height: 2)),
                    with: .color(MonitorScopePalette.lumaGhost.color))
                ctx.fill(
                    Path(CGRect(x: x, y: tickY - 0.5, width: 1, height: 1)),
                    with: .color(MonitorScopePalette.luma.color))
                if index % 4 == 0 {
                    ctx.fill(
                        Path(CGRect(x: x, y: tickY - 0.5, width: 1, height: 1)),
                        with: .color(MonitorScopePalette.lumaHot.color))
                }
            }
        case .rgb:
            let channels: [(Color, (ScopePoint) -> UInt8)] = [
                (MonitorScopePalette.overlayRed.color, { $0.red }),
                (MonitorScopePalette.overlayGreen.color, { $0.green }),
                (MonitorScopePalette.overlayBlue.color, { $0.blue }),
            ]
            for point in points {
                let x = rect.minX + CGFloat(point.xRatio) * rect.width
                for channel in channels {
                    ctx.fill(
                        Path(CGRect(x: x, y: y(channel.1(point)) - 0.5, width: 1, height: 1)),
                        with: .color(channel.0))
                }
            }
        }
    }
}

private struct ScopeGuideOverlay: View {
    var clip = true
    var crush = true
    var middle = true
    var middleGrayIRE: Double

    var body: some View {
        Canvas { context, size in
            let rect = MonitorWaveformAxis.plotRect(in: size)
            func line(_ y: CGFloat, _ color: Color, _ style: StrokeStyle) {
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(path, with: .color(color), style: style)
            }
            let grayIRE = middleGrayIRE
            for stroke in MonitorWaveformAxis.guideStrokes(
                clip: clip, crush: crush, middle: middle, middleGrayIRE: grayIRE)
            {
                let y = MonitorWaveformAxis.scaleLineY(stroke.ire, rect)
                let isGray = abs(stroke.ire - grayIRE) < 0.05
                let color: Color =
                    stroke.usesCrushClipColor
                    ? MonitorScopePalette.clip
                    : (isGray ? MonitorScopePalette.middle : MonitorScopePalette.boundary)
                let style =
                    stroke.dashed
                    ? StrokeStyle(lineWidth: 1.25, dash: MonitorWaveformAxis.crushClipDash)
                    : StrokeStyle(lineWidth: isGray ? 1 : 1.25)
                line(y, color, style)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ParadeCanvasPlot: View, Equatable {
    var samples: ScopeSamples
    var trail: ScopeSamples = .empty
    var mode: MonitorParadeMode = .rgb
    var table: [Float]
    var opacity: Double = 1

    var body: some View {
        Canvas { context, size in
            let rect = MonitorWaveformAxis.plotRect(in: size)
            var traces = context
            traces.clip(to: Path(MonitorScopeGeometry.traceClipRect(rect)))
            drawLanes(
                trail.points, rect: rect, table: table, context: traces,
                opacity: opacity * MonitorScopeTraceMetal.trailDecay)
            drawLanes(
                samples.points, rect: rect, table: table, context: traces, opacity: opacity)
        }
    }

    private func drawLanes(
        _ points: [ScopePoint], rect: CGRect, table: [Float],
        context: GraphicsContext, opacity: Double
    ) {
        guard !points.isEmpty, opacity > 0 else { return }
        let lumaLane: [(Color, (ScopePoint) -> UInt8)] =
            mode == .yrgb ? [(MonitorScopePalette.luma.color, { $0.luma })] : []
        let lanes: [(Color, (ScopePoint) -> UInt8)] =
            lumaLane + [
                (MonitorScopePalette.paradeRed.color, { $0.red }),
                (MonitorScopePalette.paradeGreen.color, { $0.green }),
                (MonitorScopePalette.paradeBlue.color, { $0.blue }),
            ]
        var ctx = context
        ctx.opacity = opacity
        ctx.blendMode = .plusLighter
        for (index, lane) in lanes.enumerated() {
            for point in points {
                let x = MonitorScopeGeometry.laneX(
                    xRatio: point.xRatio, lane: index, mode: mode, plot: rect)
                let y = MonitorWaveformAxis.plotY(Double(table[Int(lane.1(point))]), rect)
                ctx.fill(
                    Path(CGRect(x: x, y: y - 0.5, width: 1, height: 1)),
                    with: .color(lane.0))
            }
        }
    }
}

private struct VectorscopeCanvasPlot: View, Equatable {
    var points: [ScopePoint]
    var trailPoints: [ScopePoint] = []
    var zoom: MonitorVectorscopeZoom = .x1
    var brightness: Int = 100

    nonisolated static func == (lhs: VectorscopeCanvasPlot, rhs: VectorscopeCanvasPlot) -> Bool {
        lhs.points == rhs.points && lhs.trailPoints == rhs.trailPoints && lhs.zoom == rhs.zoom
            && lhs.brightness == rhs.brightness
    }

    var body: some View {
        Canvas { context, size in
            let rect = MonitorScopeGeometry.vectorscopeSquare(in: size)
            let side = rect.width
            drawMonitorVectorscopeGraticule(in: context, rect: rect)
            let intensity = MonitorScopeGeometry.vectorscopeIntensity(brightness)
            if !trailPoints.isEmpty,
                let trail = VectorscopeRaster.image(
                    from: trailPoints, gain: zoom.gain, intensity: intensity)
            {
                var ghost = context
                ghost.blendMode = .plusLighter
                ghost.opacity = MonitorScopeTraceMetal.trailDecay
                ghost.addFilter(.blur(radius: side / CGFloat(VectorscopeRaster.bins) * 1.1))
                ghost.draw(Image(decorative: trail, scale: 1), in: rect)
            }
            if let image = VectorscopeRaster.image(
                from: points, gain: zoom.gain, intensity: intensity)
            {

                var blur = context
                blur.blendMode = .plusLighter
                blur.addFilter(.blur(radius: side / CGFloat(VectorscopeRaster.bins) * 1.1))
                blur.draw(Image(decorative: image, scale: 1), in: rect)
                var crisp = context
                crisp.blendMode = .plusLighter
                crisp.opacity = 0.35
                crisp.draw(Image(decorative: image, scale: 1), in: rect)
            }
        }
    }
}

public enum MonitorVectorscopeGraticule {
    public static let skinAngleDegrees = 123.0
    public static let skinLength = 0.92
    public static let boxSide: CGFloat = 7
    public static let labelPush: CGFloat = 10
    public static let crossArm: CGFloat = 8
    public static let ring = MonitorScopePalette.rgba(220, 235, 225, 0.55)
    public static let faint = MonitorScopePalette.rgba(220, 235, 225, 0.30)
    public static let box = MonitorScopePalette.rgba(220, 235, 225, 0.6)
    public static let label = MonitorScopePalette.rgba(220, 235, 225, 0.55)

    public static let targets: [(label: String, red: UInt8, green: UInt8, blue: UInt8)] = [
        ("R", 191, 0, 0), ("Mg", 191, 0, 191), ("B", 0, 0, 191),
        ("Cy", 0, 191, 191), ("G", 0, 191, 0), ("Yl", 191, 191, 0),
    ]

    public static var skinAngleRadians: Double { skinAngleDegrees * .pi / 180 }

    public static func skinEnd(in rect: CGRect) -> CGPoint {
        let radius = rect.width / 2
        let angle = skinAngleRadians
        return CGPoint(
            x: rect.midX + CGFloat(cos(angle)) * radius * skinLength,
            y: rect.midY - CGFloat(sin(angle)) * radius * skinLength)
    }

    public static func targetCenter(
        red: UInt8, green: UInt8, blue: UInt8, in rect: CGRect
    ) -> CGPoint {
        let chroma = ScopeChroma.rec709(red: red, green: green, blue: blue)
        return CGPoint(
            x: rect.midX + CGFloat(chroma.cb) * rect.width,
            y: rect.midY - CGFloat(chroma.cr) * rect.height)
    }
}

private func drawMonitorVectorscopeGraticule(in context: GraphicsContext, rect: CGRect) {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    context.stroke(Path(ellipseIn: rect), with: .color(MonitorVectorscopeGraticule.ring), lineWidth: 1.25)
    let arm = MonitorVectorscopeGraticule.crossArm
    var cross = Path()
    cross.move(to: CGPoint(x: centre.x - arm, y: centre.y))
    cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
    cross.move(to: CGPoint(x: centre.x, y: centre.y - arm))
    cross.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
    context.stroke(cross, with: .color(MonitorVectorscopeGraticule.faint), lineWidth: 1)
    var skin = Path()
    skin.move(to: centre)
    skin.addLine(to: MonitorVectorscopeGraticule.skinEnd(in: rect))
    context.stroke(
        skin, with: .color(MonitorScopePalette.middle), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    let boxSide = MonitorVectorscopeGraticule.boxSide
    let push = MonitorVectorscopeGraticule.labelPush
    for target in MonitorVectorscopeGraticule.targets {
        let point = MonitorVectorscopeGraticule.targetCenter(
            red: target.red, green: target.green, blue: target.blue, in: rect)
        let box = CGRect(
            x: point.x - boxSide / 2, y: point.y - boxSide / 2, width: boxSide, height: boxSide)
        context.stroke(Path(box), with: .color(MonitorVectorscopeGraticule.box), lineWidth: 1)
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        context.draw(
            Text(target.label)
                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                .foregroundStyle(MonitorVectorscopeGraticule.label),
            at: CGPoint(x: point.x + dx / length * push, y: point.y + dy / length * push))
    }
}
#endif
