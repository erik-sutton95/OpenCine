import Foundation

public enum MonitorScopeByteLayout: Equatable, Sendable { case bgra, rgba }

/// Ready-to-display scope data and one-pass encoded-source analysis.
public struct ScopePoint: Equatable, Sendable {
    public var xRatio: Double
    public var yRatio: Double
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var luma: UInt8
    public var sampleX: Int?
    public var sampleY: Int?

    public init(xRatio: Double, yRatio: Double, red: UInt8, green: UInt8, blue: UInt8, luma: UInt8, sampleX: Int? = nil, sampleY: Int? = nil) {
        self.xRatio = xRatio; self.yRatio = yRatio
        self.red = red; self.green = green; self.blue = blue; self.luma = luma
        self.sampleX = sampleX; self.sampleY = sampleY
    }
}

/// Shared `ScopeSamples`  -  one shared tap product for every scope surface.
/// Histograms are 256-bin **native code** counts (display remap is downstream).
public struct ScopeSamples: Equatable, Sendable {
    public var histogramLuma: [Int]
    public var histogramRed: [Int]
    public var histogramGreen: [Int]
    public var histogramBlue: [Int]
    public var points: [ScopePoint]

    public init(histogramLuma: [Int], histogramRed: [Int], histogramGreen: [Int], histogramBlue: [Int], points: [ScopePoint]) {
        self.histogramLuma = histogramLuma; self.histogramRed = histogramRed
        self.histogramGreen = histogramGreen; self.histogramBlue = histogramBlue; self.points = points
    }

    public static let empty = ScopeSamples(
        histogramLuma: Array(repeating: 0, count: 256),
        histogramRed: Array(repeating: 0, count: 256),
        histogramGreen: Array(repeating: 0, count: 256),
        histogramBlue: Array(repeating: 0, count: 256),
        points: [])
}

/// Ready-to-draw histogram curves on the WAVE IRE axis: remapped so paper
/// black is bucket 0 and live-tap clip is bucket 255, temporally blended
/// 0.65/0.35, box-blurred (r = 2). The HISTO SwiftUI body only strokes these.
public struct ScopeHistogramDisplay: Equatable, Sendable {
    public var luma: [Float]
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(luma: [Float], red: [Float], green: [Float], blue: [Float]) {
        self.luma = luma; self.red = red; self.green = green; self.blue = blue
    }

    public static let empty = ScopeHistogramDisplay(
        luma: Array(repeating: 0, count: 256),
        red: Array(repeating: 0, count: 256),
        green: Array(repeating: 0, count: 256),
        blue: Array(repeating: 0, count: 256))
}

/// Shared `ScopeAssistBundle`  -  published once per throttle tick so SwiftUI/Metal
/// invalidates one value instead of re-reading a recycled `CVPixelBuffer`.
public struct ScopeAssistBundle: Equatable, Sendable {
    /// Cheap identity for redraw gating. Compare this, not 5,600 points, on main.
    public var revision: UInt64 = 0
    public var samples = ScopeSamples.empty
    /// Monitor-domain points for VECTOR (through the operator LUT or the source-provided
    /// display cube  -  log chroma collapses without it). Empty when hidden.
    public var vectorscopePoints: [ScopePoint] = []
    public var trailSamples = ScopeSamples.empty
    public var trailVectorscopePoints: [ScopePoint] = []
    public var traffic = ScopeTrafficLightsReading.none
    public var histogramDisplay = ScopeHistogramDisplay.empty
    public var transfer: MonitorTransfer = .rec709
    /// The source's live-tap clip byte for `transfer` once this tap was measured. WAVE /
    /// PARADE place the points on it, so a bundle carries its own ceiling (STATE-01).
    public var clipByte = 255
    /// Optional measured code placement supplied by the source that produced these samples.
    public var levelAxis: ScopeLevelAxis?

    public init(revision: UInt64 = 0, samples: ScopeSamples = .empty, vectorscopePoints: [ScopePoint] = [],
        trailSamples: ScopeSamples = .empty, trailVectorscopePoints: [ScopePoint] = [],
        traffic: ScopeTrafficLightsReading = .none, histogramDisplay: ScopeHistogramDisplay = .empty,
        transfer: MonitorTransfer = .rec709, clipByte: Int = 255, levelAxis: ScopeLevelAxis? = nil) {
        self.revision = revision; self.samples = samples; self.vectorscopePoints = vectorscopePoints
        self.trailSamples = trailSamples; self.trailVectorscopePoints = trailVectorscopePoints
        self.traffic = traffic; self.histogramDisplay = histogramDisplay
        self.transfer = transfer; self.clipByte = clipByte
        self.levelAxis = levelAxis
    }

    public static let empty = ScopeAssistBundle()
}

public enum ScopeSampler {
    /// Measured sampling width. 128 + extra pack/vImage was slower on device.
    public static let maxWidth = 200
    public static let pointStride = 2
    /// Typical SoftAP is 25 fps. 1–2 scopes track that picture; a 50 Hz
    /// proxy still skips. Deadline cannot catch up.
    public static let baseMinInterval: TimeInterval = 1.0 / 25.0
    /// More scopes share one tap  -  go slower, not faster.
    public static let denseMinInterval: TimeInterval = 1.0 / 10.0
    public static let denseAssistThreshold = 2

    public static func sampleInterval(activeScopeCount: Int, thermalMultiplier: Double = 1) -> TimeInterval {
        let base = activeScopeCount > denseAssistThreshold ? denseMinInterval : baseMinInterval
        return base * thermalMultiplier
    }

    /// One neutral raw-buffer walk. Existing bundle sampling keeps BGRA and stride2 on Apple.
    public static func sampleRaw(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        transfer: MonitorTransfer, includePoints: Bool, layout: MonitorScopeByteLayout = .bgra,
        stride: Int = pointStride, includeSampleCoordinates: Bool = false,
        requireCompleteRows: Bool = false) -> ScopeSamples {
        guard stride > 0 else { return .empty }
        if requireCompleteRows {
            guard width > 0, height > 0, width <= Int.max / 4,
                bytesPerRow >= width * 4, height <= Int.max / bytesPerRow,
                bytes.count >= bytesPerRow * height else { return .empty }
        }
        var histY = [Int](repeating: 0, count: 256)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var points = [ScopePoint]()
        if includePoints {
            let columns = (width + stride - 1) / stride
            let rows = (height + stride - 1) / stride
            points.reserveCapacity(max(0, columns * rows))
        }
        let widthDivisor = Double(max(width, 1))
        let heightDivisor = Double(max(height, 1))
        let lumaW = LiveColorScience.lumaWeights(transfer)
        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0
            while x < width {
                let i = rowStart + x * 4
                guard i + 2 < bytes.count else { break }
                let r = bytes[i + (layout == .rgba ? 0 : 2)]
                let g = bytes[i + 1]
                let b = bytes[i + (layout == .rgba ? 2 : 0)]
                // Rounded, not floored  -  floor pushed pure white off the top bin.
                let lumaValue =
                    lumaW.red * Double(r) + lumaW.green * Double(g) + lumaW.blue * Double(b)
                let luma = UInt8(min(255, max(0, lumaValue.rounded())))
                histY[Int(luma)] += 1
                histR[Int(r)] += 1
                histG[Int(g)] += 1
                histB[Int(b)] += 1
                if includePoints {
                    points.append(
                        ScopePoint(
                            xRatio: Double(x) / widthDivisor,
                            yRatio: Double(y) / heightDivisor,
                            red: r, green: g, blue: b, luma: luma,
                            sampleX: includeSampleCoordinates ? x : nil,
                            sampleY: includeSampleCoordinates ? y : nil))
                }
                x += stride
            }
            y += stride
        }
        return ScopeSamples(histogramLuma: histY, histogramRed: histR, histogramGreen: histG,
            histogramBlue: histB, points: points)
    }

    /// The one walk. 200-wide tap × stride 2 ≈ 5,600 pixels per tick.
    public static func sample(
        bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        transfer: MonitorTransfer, clipByte: Int, includePoints: Bool,
        includeVectorPoints: Bool = false,
        look: CubeLUT?,
        trafficThreshold: Double = ScopeTrafficLights.defaultThreshold,
        previous: ScopeAssistBundle
    ) -> ScopeAssistBundle {
        bundle(
            samples: sampleRaw(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                transfer: transfer, includePoints: includePoints || includeVectorPoints),
            transfer: transfer, clipByte: clipByte, includePoints: includePoints,
            includeVectorPoints: includeVectorPoints, look: look,
            trafficThreshold: trafficThreshold, previous: previous)
    }

    /// One bundle from samples a source already walked with `sampleRaw`: the shared lamps,
    /// histogram axis and VECTOR look for its transfer and ceiling.
    public static func bundle(
        samples raw: ScopeSamples, transfer: MonitorTransfer, clipByte: Int,
        includePoints: Bool, includeVectorPoints: Bool = false, look: CubeLUT?,
        trafficThreshold: Double = ScopeTrafficLights.defaultThreshold,
        previous: ScopeAssistBundle
    ) -> ScopeAssistBundle {
        let histY = raw.histogramLuma, histR = raw.histogramRed
        let histG = raw.histogramGreen, histB = raw.histogramBlue
        let points = raw.points
        let samples = ScopeSamples(
            histogramLuma: histY, histogramRed: histR, histogramGreen: histG,
            histogramBlue: histB, points: includePoints ? points : [])
        let vectorPoints =
            includeVectorPoints ? monitorPoints(points, look: look) : []
        return ScopeAssistBundle(
            revision: previous.revision &+ 1,
            samples: samples,
            vectorscopePoints: vectorPoints,
            trailSamples: previous.samples,
            trailVectorscopePoints: previous.vectorscopePoints,
            traffic: ScopeTrafficLights.reading(
                red: histR, green: histG, blue: histB, luma: histY,
                transfer: transfer, clipByte: clipByte, threshold: trafficThreshold,
                previous: previous.traffic),
            histogramDisplay: histogramDisplay(
                samples: samples, previous: previous.histogramDisplay, transfer: transfer,
                clipByte: clipByte),
            transfer: transfer,
            clipByte: clipByte)
    }

    /// VECTOR input: sampled points through the display look (operator LUT if
    /// armed, else the source-provided display cube for log, else the codes as-is).
    /// Trilinear `CubeLUT.map` per point is the benchmark-accepted cost  -  no
    /// transcendental math per pixel anywhere in the analysis path.
    public static func monitorPoints(_ points: [ScopePoint], look: CubeLUT?) -> [ScopePoint] {
        guard let look else { return points }
        return points.map { point in
            let mapped = look.map(
                red: Float(point.red) / 255,
                green: Float(point.green) / 255,
                blue: Float(point.blue) / 255)
            let red = Double(mapped.red)
            let green = Double(mapped.green)
            let blue = Double(mapped.blue)
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return ScopePoint(
                xRatio: point.xRatio,
                yRatio: point.yRatio,
                red: displayByte(red),
                green: displayByte(green),
                blue: displayByte(blue),
                luma: displayByte(luma), sampleX: point.sampleX, sampleY: point.sampleY)
        }
    }

    private static func displayByte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }

    // MARK: - Histogram display pipeline (off-main, once per tick)

    public static func histogramDisplay(
        samples: ScopeSamples, previous: ScopeHistogramDisplay, transfer: MonitorTransfer,
        clipByte: Int
    ) -> ScopeHistogramDisplay {
        histogramDisplay(
            samples: samples, previous: previous,
            axis: ScopeLevelAxis(transfer: transfer, clipByte: clipByte))
    }

    public static func histogramDisplay(
        samples: ScopeSamples, previous: ScopeHistogramDisplay, axis: ScopeLevelAxis
    ) -> ScopeHistogramDisplay {
        func channel(_ native: [Int], _ previous: [Float]) -> [Float] {
            displayChannel(native, previous: previous, axis: axis)
        }
        return ScopeHistogramDisplay(
            luma: channel(samples.histogramLuma, previous.luma),
            red: channel(samples.histogramRed, previous.red),
            green: channel(samples.histogramGreen, previous.green),
            blue: channel(samples.histogramBlue, previous.blue)
        )
    }

    public static func displayChannel(
        _ native: [Int], previous: [Float], transfer: MonitorTransfer, clipByte: Int
    ) -> [Float] {
        displayChannel(
            native, previous: previous, axis: ScopeLevelAxis(transfer: transfer, clipByte: clipByte))
    }

    public static func displayChannel(
        _ native: [Int], previous: [Float], axis: ScopeLevelAxis
    ) -> [Float] {
        let remapped = axis.remapHistogram(native)
        var blended = [Float](repeating: 0, count: 256)
        let hasPrevious = previous.count == 256
        for i in 0..<256 {
            let current = Float(remapped[i])
            blended[i] = hasPrevious ? 0.65 * current + 0.35 * previous[i] : current
        }
        return boxBlur(blended, radius: 2)
    }

    public static func boxBlur(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, values.count > 1 else { return values }
        var out = [Float](repeating: 0, count: values.count)
        for i in 0..<values.count {
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            var sum: Float = 0
            for j in lo...hi { sum += values[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }
}
