import Foundation
import OpenCineMedia
import Testing

/// The removed pre-correction facade algorithm is frozen below to pin every Float and wire byte.
@Suite struct MonitorFalseColorLatticeParityTests {
    @Test func signalCubesMatchTheFrozenFacade() {
        let size = 16
        let profile = ScopeClipProfile(calibrations: [
            .dlog: ScopeClipCalibration(referenceISO: 400, referenceByte: 223),
            .dlog2: ScopeClipCalibration(referenceISO: 1600, referenceByte: 247),
        ], defaultISO: 1600)
        for transfer in MonitorTransfer.allCases {
            let ceiling = OpenCineMedia.ScopeExposureCeiling(profile: profile)
            // A declared sampling fixture is independent of any integration's official catalog.
            let curve: [Double]? = transfer == .rec709 ? nil : [0, 0.04, 0.41, 0.75, 1, 1]
            for scale in LiveFalseColorScale.allCases {
                for rec709 in [false, true] {
                    let lattice = MonitorFalseColorLattice.signal(scale: scale, transfer: transfer,
                        clipByte: ceiling.clipByte(transfer: transfer), lookCurve: curve,
                        readThroughLook: rec709, size: size)
                    for component in [MonitorFalseColorCubeComponent.paint, .weight] {
                        let legacy = FrozenSignalFacade.overlayCube(scale: scale, transfer: transfer,
                            ceiling: ceiling, lookCurve: curve, size: size, rec709: rec709) { paint in
                            component == .paint ? (paint.red, paint.green, paint.blue)
                                : (paint.weight, paint.weight, paint.weight)
                        }
                        let actual = lattice.cube(component)
                        let floatsMatch = zip(actual.rgb, legacy.rgb).allSatisfy {
                            $0.0.bitPattern == $0.1.bitPattern
                        }
                        #expect(floatsMatch, "\(transfer) \(scale) read709=\(rec709) \(component)")
                        let bytesMatch = actual.packedRGBA.elementsEqual(legacy.packedRGBA)
                        #expect(bytesMatch, "\(transfer) \(scale) read709=\(rec709) \(component) wire bytes")
                    }
                }
            }
        }
    }

    @Test func packedGridKeepsRedFastestFloatCoordinatesAndRounding() {
        let cube = CubeLUT(size: 2, rgb: [
            -1, 0, 1, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
            1.1, 0.25, 0.75, 0.125, 0.375, 0.625, 0.875, 0.0625, 0.1875, 0.3125, 0.4375, 0.5625,
        ])
        #expect(cube.packedRGBA == [
            0, 0, 255, 255, 26, 51, 77, 255, 255, 64, 191, 255, 32, 96, 159, 255,
            102, 128, 153, 255, 179, 204, 230, 255, 223, 16, 48, 255, 80, 112, 143, 255,
        ])
    }

    @Test func limitsKeepSeparatePaintWeightAndSourceGaps() {
        let bands = [LiveFalseColorBand(lowerBound: 0, upperBound: 10,
            red: 0.4, green: 0.2, blue: 0.8, label: "shadow")]
        let painting = MonitorFalseColorPainting(bands: bands, edgeSoftness: 0.5,
            domain: .monitorPercent, background: .source)
        let hole = painting.paint(value: 50, monitorGray: 0.5)
        #expect(hole.weight == 0 && hole.red == 0 && hole.green == 0 && hole.blue == 0)
        let source = painting.compositeColor(value: 50, monitorGray: 0.5, source: (0.2, 0.4, 0.6))
        #expect(source.red == 0.2 && source.green == 0.4 && source.blue == 0.6)
        let edge = painting.paint(value: 10, monitorGray: 0.5)
        #expect(edge.weight == 0.5 && edge.red == 0.4 && edge.green == 0.2 && edge.blue == 0.8)
    }

    @Test func managedPaintDecodesBeforeTheFloatConversionAndNeverDecodesMasks() {
        let lattice = MonitorFalseColorLattice.signal(scale: .ire, transfer: .rec709,
            clipByte: 255, size: 2)
        let expected = Float(SRGB.decode(115.0 / 255))
        #expect(lattice.cube(.paint, paintEncoding: .linearSRGB).rgb[0].bitPattern == expected.bitPattern)
        #expect(lattice.cube(.weight, paintEncoding: .linearSRGB).rgb.allSatisfy { $0 == 1 })
    }

    @Test func sceneLinearUsesSuppliedDecodedChannelsAndDetailBlend() {
        let painting = MonitorFalseColorPainting(bands: [
            LiveFalseColorBand(lowerBound: -.infinity, upperBound: .infinity,
                red: 0.4, green: 0.2, blue: 0.8, label: "declared")
        ], edgeSoftness: 0.05, domain: .sceneStops, background: .monitorGray, detailBlend: 0.4)
        let tone = MonitorSceneToneMap(sceneWhite: 1)
        let cube = MonitorFalseColorLattice.sceneLinear(decodedChannels: [0, 1],
            luminanceCoefficients: (0.2126, 0.7152, 0.0722), tone: tone, painting: painting).cube(.composite)
        let gray = tone.displayCode(sceneLinear: 0.2126)
        #expect(cube.rgb[3].bitPattern == Float(0.4 * 0.6 + gray * 0.4).bitPattern)
        #expect(cube.rgb[4].bitPattern == Float(0.2 * 0.6 + gray * 0.4).bitPattern)
        #expect(cube.rgb[5].bitPattern == Float(0.8 * 0.6 + gray * 0.4).bitPattern)
    }
}

private enum FrozenSignalFacade {
    static func overlayCube(
        scale: LiveFalseColorScale,
        transfer: MonitorTransfer,
        ceiling: OpenCineMedia.ScopeExposureCeiling,
        lookCurve: [Double]?, size: Int,
        rec709: Bool,
        component: ((red: Double, green: Double, blue: Double, weight: Double)) -> (
            Double, Double, Double
        )
    ) -> CubeLUT {
        let denom = Double(size - 1)
        // 709 reading: every scale evaluates the official look as a Rec.709 feed.
        let clip = LiveColorScience.falseColorClip(
            scale: scale, transfer: transfer, rec709: rec709,
            lookCurve: lookCurve, clipEncoded: Double(ceiling.clipByte(transfer: transfer)) / 255)
        let bandList = LiveColorScience.falseColorBands(
            scale, transfer: clip.transfer, clipEncoded: clip.ceiling, latticeSize: size)
        var rgb = [Float]()
        rgb.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let er = Double(r) / denom
                    let eg = Double(g) / denom
                    let eb = Double(b) / denom
                    let yEnc = encodedLuma(red: er, green: eg, blue: eb, transfer: transfer)
                    let read = LiveColorScience.falseColorReading(
                        encoded: yEnc, transfer: transfer, rec709: rec709, lookCurve: lookCurve, scale: scale)
                    let ire = ScopeDisplayScale.monitorPercent(
                        read.encoded, transfer: read.transfer,
                        clipByte: ceiling.clipByte(transfer: read.transfer))
                    let value =
                        scale.usesSceneStops
                        ? LiveColorScience.stops(encoded: read.encoded, transfer: read.transfer) : ire
                    let chosen = component(
                        overlayPaint(
                            value: value, scale: scale, bands: bandList,
                            monitorGray: ire / 100))
                    rgb.append(Float(chosen.0))
                    rgb.append(Float(chosen.1))
                    rgb.append(Float(chosen.2))
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    private static func encodedLuma(
        red: Double, green: Double, blue: Double, transfer: MonitorTransfer
    ) -> Double {
        let w = LiveColorScience.lumaWeights(transfer)
        return w.red * red + w.green * green + w.blue * blue
    }

    private static func overlayPaint(
        value: Double, scale: LiveFalseColorScale, bands: [LiveFalseColorBand],
        monitorGray: Double
    ) -> (red: Double, green: Double, blue: Double, weight: Double) {
        switch scale {
        case .stops, .ire, .sceneStops:
            let color = renderedColor(
                value: value, scale: scale, bands: bands,
                source: (0, 0, 0), monitorGray: monitorGray)
            return (color.red, color.green, color.blue, 1)
        case .limits:
            break
        }
        let width = transitionWidth(scale)
        var paint = (red: 0.0, green: 0.0, blue: 0.0)
        var total = 0.0
        for item in bands {
            let weight = bandWeight(value: value, band: item, width: width)
            let color = renderedBandColor(item, scale: scale, detailGray: monitorGray)
            paint.red += color.red * weight
            paint.green += color.green * weight
            paint.blue += color.blue * weight
            total += weight
        }
        guard total > 0 else { return (0, 0, 0, 0) }
        return (paint.red / total, paint.green / total, paint.blue / total, min(1, total))
    }

    private static func renderedColor(
        value: Double,
        scale: LiveFalseColorScale,
        bands: [LiveFalseColorBand],
        source: (red: Double, green: Double, blue: Double),
        monitorGray: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let base: (red: Double, green: Double, blue: Double)
        switch scale {
        case .stops, .ire, .sceneStops:
            let gray = min(1, max(0, monitorGray))
            base = (gray, gray, gray)
        case .limits:
            base = (
                min(1, max(0, source.red)),
                min(1, max(0, source.green)),
                min(1, max(0, source.blue))
            )
        }
        let weighted = bands.map {
            ($0, bandWeight(value: value, band: $0, width: transitionWidth(scale)))
        }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return base }
        let normalization = max(1, total)
        let baseWeight = max(0, 1 - total)
        let painted = weighted.reduce(
            (
                red: base.red * baseWeight, green: base.green * baseWeight,
                blue: base.blue * baseWeight
            )
        ) { result, item in
            let color = renderedBandColor(item.0, scale: scale, detailGray: monitorGray)
            return (
                result.red + color.red * item.1,
                result.green + color.green * item.1,
                result.blue + color.blue * item.1
            )
        }
        return (
            painted.red / normalization,
            painted.green / normalization,
            painted.blue / normalization
        )
    }

    private static func renderedBandColor(
        _ band: LiveFalseColorBand, scale: LiveFalseColorScale, detailGray: Double
    ) -> (red: Double, green: Double, blue: Double) {
        _ = detailGray
        return (band.red, band.green, band.blue)
    }

    private static func bandWeight(
        value: Double, band: LiveFalseColorBand, width: Double
    ) -> Double {
        let rising =
            band.lowerBound.isFinite && band.lowerBound != 0
            ? smoothStep(
                edge0: band.lowerBound - width, edge1: band.lowerBound + width, value: value)
            : 1
        let falling =
            band.upperBound.isFinite
            ? 1
                - smoothStep(
                    edge0: band.upperBound - width, edge1: band.upperBound + width, value: value)
            : 1
        return rising * falling
    }

    private static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        let span = edge1 - edge0
        guard span != 0 else { return value >= edge1 ? 1 : 0 }
        let progress = min(1, max(0, (value - edge0) / span))
        return progress * progress * (3 - 2 * progress)
    }

    private static func transitionWidth(_ scale: LiveFalseColorScale) -> Double {
        scale.edgeSoftness
    }

}
