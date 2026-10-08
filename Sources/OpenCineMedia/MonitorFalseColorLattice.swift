import Foundation

public enum MonitorFalseColorReadingDomain: Sendable {
    case monitorPercent
    case sceneStops
}

public enum MonitorFalseColorBackground: Sendable {
    case monitorGray
    case source
}

/// Paint and weight are composited over an existing grade. Composite includes unpainted source RGB.
public enum MonitorFalseColorCubeComponent: Sendable {
    case composite
    case paint
    case weight
}

/// Managed display bakes need linear sRGB paint before their output encoding; masks stay linear.
public enum MonitorFalseColorPaintEncoding: Sendable {
    case displayRGB
    case linearSRGB
}

/// Supplied false-color zones and their treatment of gaps and scene detail.
public struct MonitorFalseColorPainting: Sendable {
    public let bands: [LiveFalseColorBand]
    public let edgeSoftness: Double
    public let domain: MonitorFalseColorReadingDomain
    public let background: MonitorFalseColorBackground
    public let detailBlend: Double

    public init(bands: [LiveFalseColorBand], edgeSoftness: Double,
        domain: MonitorFalseColorReadingDomain, background: MonitorFalseColorBackground,
        detailBlend: Double = 0) {
        precondition(edgeSoftness >= 0 && edgeSoftness.isFinite)
        precondition((0...1).contains(detailBlend))
        self.bands = bands
        self.edgeSoftness = edgeSoftness
        self.domain = domain
        self.background = background
        self.detailBlend = detailBlend
    }

    public func paint(value: Double, monitorGray: Double)
        -> (red: Double, green: Double, blue: Double, weight: Double) {
        if background == .monitorGray {
            let color = compositeColor(value: value, monitorGray: monitorGray, source: (0, 0, 0))
            return (color.red, color.green, color.blue, 1)
        }
        var paint = (red: 0.0, green: 0.0, blue: 0.0)
        var total = 0.0
        for band in bands {
            let weight = bandWeight(value: value, band: band)
            let color = bandColor(band, detailGray: monitorGray)
            paint.red += color.red * weight
            paint.green += color.green * weight
            paint.blue += color.blue * weight
            total += weight
        }
        guard total > 0 else { return (0, 0, 0, 0) }
        return (paint.red / total, paint.green / total, paint.blue / total, min(1, total))
    }

    public func compositeColor(value: Double, monitorGray: Double,
        source: (red: Double, green: Double, blue: Double))
        -> (red: Double, green: Double, blue: Double) {
        let base: (red: Double, green: Double, blue: Double)
        switch background {
        case .monitorGray:
            let gray = min(1, max(0, monitorGray))
            base = (gray, gray, gray)
        case .source:
            base = (min(1, max(0, source.red)), min(1, max(0, source.green)),
                min(1, max(0, source.blue)))
        }
        let weighted = bands.map { ($0, bandWeight(value: value, band: $0)) }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return base }
        let normalization = max(1, total)
        let baseWeight = max(0, 1 - total)
        let painted = weighted.reduce((red: base.red * baseWeight, green: base.green * baseWeight,
            blue: base.blue * baseWeight)) { result, item in
            let color = bandColor(item.0, detailGray: monitorGray)
            return (result.red + color.red * item.1, result.green + color.green * item.1,
                result.blue + color.blue * item.1)
        }
        return (painted.red / normalization, painted.green / normalization,
            painted.blue / normalization)
    }

    private func bandColor(_ band: LiveFalseColorBand, detailGray: Double)
        -> (red: Double, green: Double, blue: Double) {
        guard detailBlend > 0 else { return (band.red, band.green, band.blue) }
        let gray = min(1, max(0, detailGray))
        let colorWeight = 1 - detailBlend
        return (band.red * colorWeight + gray * detailBlend,
            band.green * colorWeight + gray * detailBlend,
            band.blue * colorWeight + gray * detailBlend)
    }

    private func bandWeight(value: Double, band: LiveFalseColorBand) -> Double {
        let rising = band.lowerBound.isFinite && band.lowerBound != 0
            ? Self.smoothStep(edge0: band.lowerBound - edgeSoftness,
                edge1: band.lowerBound + edgeSoftness, value: value) : 1
        let falling = band.upperBound.isFinite
            ? 1 - Self.smoothStep(edge0: band.upperBound - edgeSoftness,
                edge1: band.upperBound + edgeSoftness, value: value) : 1
        return rising * falling
    }

    private static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        let span = edge1 - edge0
        guard span != 0 else { return value >= edge1 ? 1 : 0 }
        let progress = min(1, max(0, (value - edge0) / span))
        return progress * progress * (3 - 2 * progress)
    }
}

/// Portable red-fastest lattice production. Source adapters supply calibration and look samples.
public struct MonitorFalseColorLattice: Sendable {
    private enum Source: Sendable {
        case signal(transfer: MonitorTransfer, clipByte: Int, rec709ClipByte: Int,
            lookCurve: [Double]?, readThroughLook: Bool)
        case sceneLinear(channels: [Double], coefficients: (red: Double, green: Double, blue: Double),
            tone: MonitorSceneToneMap)
    }

    public let size: Int
    public let painting: MonitorFalseColorPainting
    private let source: Source

    private init(size: Int, painting: MonitorFalseColorPainting, source: Source) {
        precondition(CubeLUT.supportedSizeRange.contains(size) && size <= CubeLUT.colorCubeMaxDimension)
        self.size = size
        self.painting = painting
        self.source = source
    }

    public static func signal(scale: LiveFalseColorScale, transfer: MonitorTransfer,
        clipByte: Int, rec709ClipByte: Int = 255, lookCurve: [Double]? = nil,
        readThroughLook: Bool = false, size: Int = 64) -> Self {
        precondition((1...255).contains(clipByte) && (1...255).contains(rec709ClipByte))
        precondition(lookCurve == nil || lookCurve!.count >= 2)
        let clip = LiveColorScience.falseColorClip(scale: scale, transfer: transfer,
            rec709: readThroughLook, lookCurve: lookCurve, clipEncoded: Double(clipByte) / 255)
        let bands = LiveColorScience.falseColorBands(scale, transfer: clip.transfer,
            clipEncoded: clip.ceiling, latticeSize: size)
        let painting = MonitorFalseColorPainting(bands: bands, edgeSoftness: scale.edgeSoftness,
            domain: scale.usesSceneStops ? .sceneStops : .monitorPercent,
            background: scale == .limits ? .source : .monitorGray)
        return Self(size: size, painting: painting,
            source: .signal(transfer: transfer, clipByte: clipByte, rec709ClipByte: rec709ClipByte,
                lookCurve: lookCurve, readThroughLook: readThroughLook))
    }

    /// Each channel is decoded by the integration at the matching encoded lattice coordinate.
    public static func sceneLinear(decodedChannels: [Double],
        luminanceCoefficients: (red: Double, green: Double, blue: Double),
        tone: MonitorSceneToneMap, painting: MonitorFalseColorPainting) -> Self {
        Self(size: decodedChannels.count, painting: painting,
            source: .sceneLinear(channels: decodedChannels, coefficients: luminanceCoefficients,
                tone: tone))
    }

    public func cube(_ component: MonitorFalseColorCubeComponent = .paint,
        paintEncoding: MonitorFalseColorPaintEncoding = .displayRGB) -> CubeLUT {
        let denominator = Double(size - 1)
        let encoded = (0..<size).map { Double($0) / denominator }
        var rgb = [Float]()
        rgb.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let read = reading(r: r, g: g, b: b, encoded: encoded)
                    let color: (Double, Double, Double)
                    switch component {
                    case .composite:
                        color = painting.compositeColor(value: read.value,
                            monitorGray: read.gray, source: (encoded[r], encoded[g], encoded[b]))
                    case .paint, .weight:
                        let paint = painting.paint(value: read.value, monitorGray: read.gray)
                        color = component == .paint ? (paint.red, paint.green, paint.blue)
                            : (paint.weight, paint.weight, paint.weight)
                    }
                    let output = paintEncoding == .linearSRGB && component != .weight
                        ? (SRGB.decode(color.0), SRGB.decode(color.1), SRGB.decode(color.2)) : color
                    rgb.append(Float(output.0))
                    rgb.append(Float(output.1))
                    rgb.append(Float(output.2))
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    public func packedCube(_ component: MonitorFalseColorCubeComponent = .paint,
        paintEncoding: MonitorFalseColorPaintEncoding = .displayRGB) -> [UInt8] {
        cube(component, paintEncoding: paintEncoding).packedRGBA
    }

    private func reading(r: Int, g: Int, b: Int, encoded: [Double])
        -> (value: Double, gray: Double) {
        switch source {
        case .signal(let transfer, let clipByte, let rec709ClipByte, let lookCurve, let readThroughLook):
            let weights = LiveColorScience.lumaWeights(transfer)
            let luminance = weights.red * encoded[r] + weights.green * encoded[g]
                + weights.blue * encoded[b]
            let read = LiveColorScience.falseColorReading(encoded: luminance, transfer: transfer,
                rec709: readThroughLook, lookCurve: lookCurve,
                scale: painting.domain == .sceneStops ? .sceneStops : .ire)
            let percent = ScopeDisplayScale.monitorPercent(read.encoded, transfer: read.transfer,
                clipByte: read.transfer == transfer ? clipByte : rec709ClipByte)
            let value = painting.domain == .sceneStops
                ? LiveColorScience.stops(encoded: read.encoded, transfer: read.transfer) : percent
            return (value, percent / 100)
        case .sceneLinear(let channels, let coefficients, let tone):
            let luminance = coefficients.red * channels[r] + coefficients.green * channels[g]
                + coefficients.blue * channels[b]
            let value: Double
            switch painting.domain {
            case .sceneStops:
                value = luminance > 0 ? log2(luminance / 0.18) : -.infinity
            case .monitorPercent:
                value = tone.ire(sceneLinear: luminance)
            }
            return (value, tone.displayCode(sceneLinear: luminance))
        }
    }
}
