import Foundation

// MARK: - Zebra / false colour supporting types

/// False-colour / limits zone. Bounds are stops or WAVE IRE depending on the scale.
public struct LiveFalseColorBand: Equatable, Sendable {
    public var lowerBound: Double
    public var upperBound: Double
    public var red: Double
    public var green: Double
    public var blue: Double
    public var label: String

    public init(
        lowerBound: Double, upperBound: Double,
        red: Double, green: Double, blue: Double,
        label: String
    ) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.red = red
        self.green = green
        self.blue = blue
        self.label = label
    }

    public func contains(_ value: Double) -> Bool {
        value >= lowerBound && value < upperBound
    }
}

/// False-colour scale names. Video (`stops`) / IRE / Limits key WAVE IRE;
/// CineStop (`sceneStops`) keys scene stops around 18% grey.
public enum LiveFalseColorScale: String, CaseIterable, Sendable {
    case stops = "Stops"
    case ire = "IRE"
    case limits = "Limits"
    case sceneStops = "SceneStops"

    public var usesSceneStops: Bool { self == .sceneStops }

    /// Half-width of the soft band edge in the cube bakes: half an IRE on the WAVE
    /// axis, a twentieth of a stop on CineStop.
    public var edgeSoftness: Double { usesSceneStops ? 0.05 : 0.5 }
}

/// Zebra defaults on the ``ScopeDisplayScale/monitorPercent(_:transfer:clipByte:)`` axis.
/// Midtone 55 is OpenZCine's (`AssistConfiguration.Zebra`). Highlight is **99**,
/// not OpenZCine's 100: 100 is the live ceiling byte itself (D-Log2 247),
/// and the ceiling ratchets to the frame max, so at 100 only that one code
/// paints. A typical D-Log2 preview shelf is 243–247 (245 ≈ IRE 99.2), so 99
/// reads "approaching clip". Operators who saved 100 keep 100.
public enum LiveZebra {
    public static let highlightIRE = 99.0
    public static let midtoneIRE = 55.0
    /// Half-width of the midtone stripe, in monitor IRE.
    public static let midtoneHalfWidthIRE = 5.0
}

// MARK: - False colour

extension LiveColorScience {
    /// Video / IRE / Limits ride the WAVE axis. CineStop rides scene stops.
    /// `clipEncoded` is the source's ceiling for `transfer`: Limits and CineStop start
    /// their clip band on its clip shelf. Cube bakes pass `latticeSize` so the shelf snaps
    /// to the lattice point below it, or trilinear sampling would blend a blown
    /// highlight between the clip colour and the band under it.
    public static func falseColorBands(
        _ scale: LiveFalseColorScale, transfer: MonitorTransfer, clipEncoded: Double? = nil,
        latticeSize: Int? = nil
    ) -> [LiveFalseColorBand] {
        let shelf = clipEncoded.map { clipShelf(ceiling: $0, latticeSize: latticeSize) }
        // On a lattice the shelf point itself must be fully clip, not a 50/50 soft edge.
        let soften = latticeSize == nil ? 0 : scale.edgeSoftness
        switch scale {
        case .stops: return cineStopBands
        case .ire: return ireBands
        case .limits:
            // The shelf is measured on the WAVE axis of the same ceiling.
            let clipByte = clipEncoded.map { Int(($0 * 255).rounded()) } ?? 255
            return limitBands(
                shelfIRE: shelf.map {
                    ScopeDisplayScale.monitorPercent($0, transfer: transfer, clipByte: clipByte)
                        - soften
                })
        case .sceneStops:
            return sceneStopBands(
                clipStops: shelf.map { stops(encoded: $0, transfer: transfer) - soften })
        }
    }

    /// Limits with its clip band starting on the clip shelf (never above 99 IRE).
    fileprivate static func limitBands(shelfIRE: Double?) -> [LiveFalseColorBand] {
        guard let edge = shelfIRE, edge < 99, edge > limitBands[2].lowerBound else {
            return limitBands
        }
        var bands = limitBands
        bands[2].upperBound = edge
        bands[3].lowerBound = edge
        return bands
    }

    public static func falseColorBand(
        value: Double, scale: LiveFalseColorScale, transfer: MonitorTransfer,
        clipEncoded: Double? = nil
    ) -> LiveFalseColorBand? {
        let candidate = scale.usesSceneStops ? value : clamp(value, 0, 100)
        return falseColorBands(scale, transfer: transfer, clipEncoded: clipEncoded)
            .first { $0.contains(candidate) }
    }

    /// Video level (0…100 IRE) of an encoded neutral code through a camera's official
    /// Rec.709 look, given that look's grey-axis luma curve (evenly spaced over `0…1`
    /// encoded). Official cubes are neutral on their grey axis, so their tone curve is the
    /// whole story for luma. The integration supplies the curve (it owns the cube); `nil`
    /// means the curve has no official look and stays on the signal.
    public static func rec709LookIRE(encoded: Double, lookCurve: [Double]?) -> Double? {
        guard let curve = lookCurve, curve.count >= 2 else { return nil }
        let position = clamp01(encoded) * Double(curve.count - 1)
        let index = min(Int(position), curve.count - 2)
        let fraction = position - Double(index)
        return (curve[index] + (curve[index + 1] - curve[index]) * fraction) * 100
    }

    /// True when the 709 reading applies: the operator picked 709 and the curve has an
    /// official Rec.709 look. Every false colour scale then reads the look as Rec.709.
    public static func readsThroughLook(lookCurve: [Double]?, rec709: Bool) -> Bool {
        rec709 && lookCurve != nil
    }

    /// The code and curve a false colour scale evaluates: the camera signal (LOG), or with
    /// the 709 reading the official look's Rec.709 code, as if the camera sent Rec.709.
    /// CineStop always reads real scene stops; 709 only moves its clip (see
    /// ``falseColorClip(scale:transfer:rec709:lookCurve:clipEncoded:)``).
    public static func falseColorReading(
        encoded: Double, transfer: MonitorTransfer, rec709: Bool, lookCurve: [Double]?,
        scale: LiveFalseColorScale = .ire
    ) -> (encoded: Double, transfer: MonitorTransfer) {
        guard rec709, !scale.usesSceneStops,
            let look = rec709LookIRE(encoded: encoded, lookCurve: lookCurve)
        else { return (encoded, transfer) }
        return (look / 100, .rec709)
    }

    /// The curve a scale's bands are built on and the ceiling its clip band keys: the
    /// source's live ceiling `clipEncoded` (LOG), the Rec.709 top (709, video-level scales),
    /// or for CineStop at 709 the log code where the official look saturates.
    public static func falseColorClip(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool,
        lookCurve: [Double]?, clipEncoded: Double
    ) -> (transfer: MonitorTransfer, ceiling: Double) {
        guard readsThroughLook(lookCurve: lookCurve, rec709: rec709), let curve = lookCurve
        else { return (transfer, clipEncoded) }
        // A Rec.709 signal has no measured preview ceiling: encoded 1.0.
        guard scale.usesSceneStops else { return (.rec709, 1) }
        let top = curve.firstIndex { $0 >= 0.9999 } ?? (curve.count - 1)
        return (transfer, Double(top) / Double(curve.count - 1))
    }

    /// Encoded clip shelf under a ceiling (``ScopeAnchors/clipShelfCodes``),
    /// snapped down to a cube lattice point when `latticeSize` is given.
    public static func clipShelf(ceiling: Double, latticeSize: Int? = nil) -> Double {
        let shelf = max(0, ceiling - Double(ScopeAnchors.clipShelfCodes) / 255)
        guard let size = latticeSize, size > 1 else { return shelf }
        return (shelf * Double(size - 1)).rounded(.down) / Double(size - 1)
    }

    /// Scene stops where clip starts when the camera ceiling is unknown (+11).
    public static let sceneStopDefaultClip = 10.5

    // MARK: - False-colour tables (WAVE IRE / EI-relative stops)

    /// Video (formerly CineStop): published Video Mode IRE on the WAVE axis. Gaps are grayscale.
    /// Rec.709 18% (~41) hits 41–48 green; D-Log2 18% (30.50) is a gap.
    fileprivate static let cineStopBands: [LiveFalseColorBand] = [
        ire(0, 5, 0.44, 0.22, 0.76, "0–4"),
        ire(5, 6, 0.28, 0.37, 0.85, "5"),
        ire(10, 13, 0.18, 0.58, 0.64, "10–12"),
        ire(41, 49, 0.38, 0.63, 0.35, "41–48"),
        ire(61, 71, 0.83, 0.53, 0.71, "61–70"),
        ire(92, 94, 0.83, 0.77, 0.45, "92–93"),
        ire(94, 96, 0.89, 0.72, 0.29, "94–95"),
        ire(96, 99, 0.85, 0.55, 0.22, "96–98"),
        ire(99, .infinity, 0.78, 0.28, 0.18, "99–100"),
    ]

    /// IRE: six video-level zones on the WAVE axis. Gaps are grayscale.
    /// Rec.709 18% (~41) hits 18%MG green; D-Log2 18% (30.50) is a gap.
    /// Palette sampled from the published six-chip IRE chart (BDL / NBDL /
    /// 18%MG / MG+1 / 80%WC / 95%WC).
    fileprivate static let ireBands: [LiveFalseColorBand] = [
        band(0, 2.5, 115, 33, 120, "BDL"),
        band(2.5, 10, 29, 2, 221, "NBDL"),
        band(38, 42, 123, 207, 87, "18%MG"),
        band(52, 56, 241, 190, 198, "MG+1"),
        band(80, 95, 255, 255, 88, "80%WC"),
        band(95, .infinity, 220, 51, 33, "95%WC"),
    ]

    fileprivate static let limitBands: [LiveFalseColorBand] = [
        ire(0, 5, 0.44, 0.22, 0.76, "0–4"),
        ire(5, 10, 0.28, 0.37, 0.85, "5–9"),
        ire(94, 99, 0.89, 0.72, 0.29, "94–98"),
        ire(99, .infinity, 0.78, 0.28, 0.18, "99–100"),
    ]

    /// CineStop: five whole-stop zones around 18% grey, identical on every camera:
    /// −2 dark green, −1 yellow-green, 0 grey, +1 light pink (skin anchor), +2 soft
    /// yellow (upper skin limit). Violet is crushed (−7 and below) and red is
    /// clipped from the camera ceiling. Other shadows are one flat dark grey and
    /// other highlights one flat light grey, so scene texture never distracts.
    /// Zones past the ceiling never paint.
    fileprivate static func sceneStopBands(clipStops: Double?) -> [LiveFalseColorBand] {
        let clip = clipStops.flatMap { $0.isFinite ? $0 : nil } ?? sceneStopDefaultClip
        let zones = [
            band(-2.5, -1.5, 39, 76, 0, "−2"),
            band(-1.5, -0.5, 155, 196, 56, "−1"),
            band(-0.5, 0.5, 127, 127, 127, "18%"),
            band(0.5, 1.5, 221, 174, 180, "+1"),
            band(1.5, 2.5, 252, 232, 96, "+2"),
        ]
        var bands = [
            band(-.infinity, -6.5, 75, 8, 165, "crush"),
            band(-6.5, -2.5, 102, 102, 102, "shadows"),
        ]
        for var zone in zones where zone.lowerBound < clip {
            zone.upperBound = min(zone.upperBound, clip)
            bands.append(zone)
        }
        if clip > 2.5 { bands.append(band(2.5, clip, 179, 178, 178, "highlights")) }
        bands.append(band(clip, .infinity, 245, 39, 0, "clip"))
        return bands
    }

    private static func band(
        _ lo: Double, _ hi: Double,
        _ r: Double, _ g: Double, _ b: Double,
        _ label: String
    ) -> LiveFalseColorBand {
        LiveFalseColorBand(
            lowerBound: lo, upperBound: hi,
            red: r / 255, green: g / 255, blue: b / 255,
            label: label)
    }

    private static func ire(
        _ lo: Double, _ hi: Double,
        _ r: Double, _ g: Double, _ b: Double,
        _ label: String
    ) -> LiveFalseColorBand {
        LiveFalseColorBand(
            lowerBound: lo, upperBound: hi,
            red: r, green: g, blue: b,
            label: label)
    }
}
