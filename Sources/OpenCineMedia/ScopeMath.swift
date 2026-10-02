import Foundation

// MARK: - Anchored scope axis

/// Per-transfer anchors on the tap's curve-fraction axis (`byte / 255`).
///
/// `black = encode(0)`, `mid = encode(0.18)`, `clip` = the source's live clip ceiling,
/// **not** the curve top. The ceiling is per source: the integration measures it (ISO,
/// tap maxima) and passes it in. Nothing here reads shared state.
public struct ScopeAnchors: Equatable, Sendable {
    /// Clipped detail sits on a shelf a few codes under the live ceiling. Every clip tool
    /// (traffic lights, HISTO lamps, zebra 100%, CineStop red) keys this shelf so they agree.
    /// 7 codes is about ⅓ stop at the D-Log2 top of an 8-bit tap.
    public static let clipShelfCodes = 7

    /// Encode-of-zero-light (D-Log2 0.062561 → byte ≈ 16, D-Log 0.0929 → ≈ 24, others 0).
    public let black: Double
    /// Encode-of-18%-grey (D-Log2 0.304985 → byte ≈ 78).
    public let mid: Double
    /// Live clip ceiling (`clipByte / 255`). Rec.709 / HLG sources pass 255 → 1.0.
    public let clip: Double
    /// Plot level of 18% grey, pinned at paper IRE (`encoded × 100`).
    public let midLevel: Double

    /// Traffic-light band edges on the 0…255 byte axis.
    /// `clipFloorByte…255` is the clip shelf (``clipShelfCodes`` under the ceiling), the
    /// same clip every tool uses. `clipEdgeByte` is the 100-line ceiling.
    public let clipEdgeByte: Int
    public let clipFloorByte: Int
    public let crushFloorByte: Int
    public let crushEdgeByte: Int

    /// - Parameter clipByte: the source's live clip ceiling on the 0…255 tap axis.
    public static func make(transfer: MonitorTransfer, clipByte: Int) -> ScopeAnchors {
        let black = transfer == .dlogm ? 0 : LiveColorScience.encode(0, transfer: transfer)
        let mid = LiveColorScience.encode(0.18, transfer: transfer)
        let clipEdge = clipByte
        let clip = Double(clipEdge) / 255.0
        let midLevel =
            ScopeDisplayScale.crushLevel
            + LiveColorScience.paperIRE(mid) / 100.0
            * (ScopeDisplayScale.clipLevel - ScopeDisplayScale.crushLevel)
        let span = max(0, clip - black) * 255
        let crushFloor = Int((black * 255).rounded(.down))
        let crushEdge = Int((black * 255 + 0.02 * span).rounded(.up))
        let clipFloor = max(0, clipEdge - clipShelfCodes)
        return ScopeAnchors(
            black: black, mid: mid, clip: clip, midLevel: midLevel,
            clipEdgeByte: clipEdge,
            clipFloorByte: clipFloor,
            crushFloorByte: crushFloor,
            crushEdgeByte: crushEdge)
    }

    /// First byte of the clip shelf for zebra (never below 1; D-Log2 ceiling 247 → 240).
    public static func clipShelfByte(clipByte: Int) -> Int {
        max(1, clipByte - clipShelfCodes)
    }

    private init(
        black: Double, mid: Double, clip: Double, midLevel: Double,
        clipEdgeByte: Int, clipFloorByte: Int,
        crushFloorByte: Int, crushEdgeByte: Int
    ) {
        self.black = black
        self.mid = mid
        self.clip = clip
        self.midLevel = midLevel
        self.clipEdgeByte = clipEdgeByte
        self.clipFloorByte = clipFloorByte
        self.crushFloorByte = crushFloorByte
        self.crushEdgeByte = crushEdgeByte
    }
}

/// HISTO / PARADE / ZEBRA / FALSE / LIGHTS axis. WAVE uses the same IRE
/// numbers on a full-height plot (0 / 100 on the edges, gray at paper IRE).
///
/// 0 and 100 scale lines sit at 5% / 95% of plot height. Paper black lands on
/// the 0 line, the live clip ceiling on the 100 line, 18% grey is pinned at
/// its published paper IRE. Sub-black noise and codes above the ceiling
/// (including 255) draw in the margins: 255 is **not** stretched onto 100.
/// Every entry point takes the source's `clipByte` (see ``ScopeAnchors/make(transfer:clipByte:)``).
public enum ScopeDisplayScale {
    public static let crushLevel = 0.05
    public static let clipLevel = 0.95

    /// Plot level (0…1 of plot height) of a normalized tap byte.
    public static func waveformLevel(
        _ c: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        waveformLevel(c, anchors: ScopeAnchors.make(transfer: transfer, clipByte: clipByte))
    }

    /// Immutable exposure anchors for an asynchronous color-map build.
    public static func waveformLevel(_ c: Double, anchors a: ScopeAnchors) -> Double {
        let v = min(1, max(0, c))
        if v < a.black {
            return a.black <= 0 ? crushLevel : v / a.black * crushLevel
        }
        if a.clip <= a.mid || a.mid <= a.black {
            if v <= a.clip {
                return crushLevel
                    + (v - a.black) / max(a.clip - a.black, 1e-9)
                    * (clipLevel - crushLevel)
            }
            return overshoot(v, clip: a.clip)
        }
        if v <= a.mid {
            return crushLevel + (v - a.black) / (a.mid - a.black) * (a.midLevel - crushLevel)
        }
        if v <= a.clip {
            return a.midLevel + (v - a.mid) / (a.clip - a.mid) * (clipLevel - a.midLevel)
        }
        return overshoot(v, clip: a.clip)
    }

    /// Level of a 0…100 scale value (0 → crush line, 100 → clip line).
    public static func level(scaleIRE: Double) -> Double {
        crushLevel + scaleIRE / 100.0 * (clipLevel - crushLevel)
    }

    /// WAVE IRE: 0 = paper black, 18% grey = paper IRE (D-Log2 30.50,
    /// D-Log 39.88), 100 = live clip ceiling. Codes above the ceiling
    /// clamp to 100 (zebra / FALSE clip).
    public static func monitorPercent(
        _ c: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        let level = waveformLevel(c, transfer: transfer, clipByte: clipByte)
        return min(100, max(0, (level - crushLevel) / (clipLevel - crushLevel) * 100))
    }

    /// Normalized tap code whose ``monitorPercent(_:transfer:clipByte:)`` equals `percent`.
    public static func signalNative(
        monitorPercent percent: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        let a = ScopeAnchors.make(transfer: transfer, clipByte: clipByte)
        let p = min(100, max(0, percent))
        if p <= 0 { return a.black }
        if p >= 100 { return a.clip }
        let target = crushLevel + p / 100.0 * (clipLevel - crushLevel)
        if a.clip <= a.mid || a.mid <= a.black {
            return a.black + p / 100.0 * (a.clip - a.black)
        }
        if target <= a.midLevel {
            let t = (target - crushLevel) / max(a.midLevel - crushLevel, 1e-9)
            return a.black + t * (a.mid - a.black)
        }
        let t = (target - a.midLevel) / max(clipLevel - a.midLevel, 1e-9)
        return a.mid + t * (a.clip - a.mid)
    }

    /// Zebra highlight threshold: the monitor percentage, but never above the clip
    /// shelf, so 100% paints clipped detail (which sits a few codes under the ceiling).
    public static func zebraHighlightNative(
        monitorPercent percent: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        min(
            signalNative(monitorPercent: percent, transfer: transfer, clipByte: clipByte),
            Double(ScopeAnchors.clipShelfByte(clipByte: clipByte)) / 255)
    }

    /// 256-entry `waveformLevel` lookup for the hot sampling/vertex paths.
    /// The memo is keyed by every input, so it is safe to share across sources.
    public static func levelTable(for transfer: MonitorTransfer, clipByte: Int) -> [Float] {
        tables.withLock { cache in
            let key = ScopeLevelTableKey(transfer: transfer, clipByte: clipByte)
            if let hit = cache[key] { return hit }
            let built = (0...255).map {
                Float(waveformLevel(Double($0) / 255.0, transfer: transfer, clipByte: clipByte))
            }
            cache[key] = built
            return built
        }
    }

    /// Move native-code histogram counts into display buckets on the waveform
    /// axis (`round(level × 255)`), so histogram x and waveform y agree
    /// column-for-column. Conserves total count.
    public static func remapHistogram(
        _ bins: [Int], transfer: MonitorTransfer, clipByte: Int
    ) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        let table = levelTable(for: transfer, clipByte: clipByte)
        for code in 0..<min(bins.count, 256) where bins[code] != 0 {
            let bucket = Int((table[code] * 255).rounded())
            out[min(255, max(0, bucket))] += bins[code]
        }
        return out
    }

    private static func overshoot(_ v: Double, clip: Double) -> Double {
        let headroom = 1.0 - clip
        guard headroom > 0 else { return clipLevel }
        return clipLevel + (v - clip) / headroom * (1.0 - clipLevel)
    }

    private static let tables = TableCache()
}

private struct ScopeLevelTableKey: Hashable {
    var transfer: MonitorTransfer
    var clipByte: Int
}

// ponytail: unbounded memo; distinct (transfer, clipByte) pairs stay in the low hundreds.
private final class TableCache: @unchecked Sendable {
    private var cache: [ScopeLevelTableKey: [Float]] = [:]
    private let lock = NSLock()
    func withLock<T>(_ body: (inout [ScopeLevelTableKey: [Float]]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&cache)
    }
}

// MARK: - Traffic lights (OpenZCine ScopeSampler / TrafficLightsMeter port)

/// One channel of the goal-post meter. `level` is the histogram median on the
/// waveform axis, re-centred so 18% grey reads exactly 0.5.
public struct ScopeChannelLight: Equatable, Sendable {
    public var clip: Bool
    public var crush: Bool
    public var level: Double

    public init(clip: Bool, crush: Bool, level: Double) {
        self.clip = clip
        self.crush = crush
        self.level = level
    }

    /// Within ±0.03 of centre the bar reads neutral (OpenZCine balanceDeadZone).
    public var isNeutral: Bool { abs(level - 0.5) <= 0.03 }
}

public struct ScopeTrafficLightsReading: Equatable, Sendable {
    public var red: ScopeChannelLight
    public var green: ScopeChannelLight
    public var blue: ScopeChannelLight

    public init(red: ScopeChannelLight, green: ScopeChannelLight, blue: ScopeChannelLight) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let none = ScopeTrafficLightsReading(
        red: ScopeChannelLight(clip: false, crush: false, level: 0.5),
        green: ScopeChannelLight(clip: false, crush: false, level: 0.5),
        blue: ScopeChannelLight(clip: false, crush: false, level: 0.5))

    public var anyClip: Bool { red.clip || green.clip || blue.clip }
    public var anyCrush: Bool { red.crush || green.crush || blue.crush }
}

public enum ScopeTrafficLights {
    /// Default pixel-fraction threshold = 0 stop compensation (stops / 10).
    public static let defaultThreshold = 0.0
    /// Stay lit until energy falls to half the fire threshold (stops blink).
    public static let holdRatio = 0.5

    /// Meter from the 256-bin native histograms, never from the point array.
    public static func reading(
        red: [Int], green: [Int], blue: [Int],
        transfer: MonitorTransfer, clipByte: Int,
        threshold: Double = defaultThreshold,
        previous: ScopeTrafficLightsReading? = nil
    ) -> ScopeTrafficLightsReading {
        reading(
            red: red, green: green, blue: blue, luma: nil,
            transfer: transfer, clipByte: clipByte, threshold: threshold, previous: previous)
    }

    public static func reading(
        red: [Int], green: [Int], blue: [Int],
        luma: [Int]? = nil,
        transfer: MonitorTransfer, clipByte: Int,
        threshold: Double = defaultThreshold,
        previous: ScopeTrafficLightsReading? = nil
    ) -> ScopeTrafficLightsReading {
        let a = ScopeAnchors.make(transfer: transfer, clipByte: clipByte)
        let redClip = edgeEnergy(red, from: a.clipFloorByte, to: 255)
        let greenClip = edgeEnergy(green, from: a.clipFloorByte, to: 255)
        let blueClip = edgeEnergy(blue, from: a.clipFloorByte, to: 255)
        let lumaClip = luma.map { edgeEnergy($0, from: a.clipFloorByte, to: 255) } ?? 0
        // Zebra is luma. A blown door can clip Y while reconstructed R/B sit
        // a few codes lower, and the frame median is still the subject, not
        // the door. If luma (or any channel) is clipped, light every lamp.
        let pictureClip =
            lumaClip > threshold || redClip > threshold
            || greenClip > threshold || blueClip > threshold
        let pictureEnergy = max(lumaClip, redClip, greenClip, blueClip)
        return ScopeTrafficLightsReading(
            red: channel(
                red, anchors: a, threshold: threshold,
                ownClipEnergy: redClip, pictureEnergy: pictureEnergy,
                pictureClip: pictureClip, previous: previous?.red),
            green: channel(
                green, anchors: a, threshold: threshold,
                ownClipEnergy: greenClip, pictureEnergy: pictureEnergy,
                pictureClip: pictureClip, previous: previous?.green),
            blue: channel(
                blue, anchors: a, threshold: threshold,
                ownClipEnergy: blueClip, pictureEnergy: pictureEnergy,
                pictureClip: pictureClip, previous: previous?.blue))
    }

    private static func channel(
        _ bins: [Int], anchors a: ScopeAnchors, threshold: Double,
        ownClipEnergy: Double, pictureEnergy: Double,
        pictureClip: Bool,
        previous: ScopeChannelLight?
    ) -> ScopeChannelLight {
        guard bins.count >= 256 else {
            return ScopeChannelLight(clip: false, crush: false, level: 0.5)
        }
        var total = 0
        for count in bins { total += count }
        guard total > 0 else {
            return ScopeChannelLight(clip: false, crush: false, level: 0.5)
        }

        var crushed = 0
        for code in a.crushFloorByte...a.crushEdgeByte { crushed += bins[code] }
        let crushEnergy = Double(crushed) / Double(total)

        var seen = 0
        var median = 0
        let half = (total + 1) / 2
        for code in 0..<256 {
            seen += bins[code]
            if seen >= half {
                median = code
                break
            }
        }
        let rawClip = ownClipEnergy > threshold || pictureClip
        let clip = latched(
            now: rawClip, was: previous?.clip ?? false,
            energy: max(ownClipEnergy, pictureEnergy), threshold: threshold)
        let crush = latched(
            now: crushEnergy > threshold, was: previous?.crush ?? false,
            energy: crushEnergy, threshold: threshold)
        let level = balance(
            ScopeDisplayScale.waveformLevel(Double(median) / 255.0, anchors: a),
            midLevel: a.midLevel)
        return ScopeChannelLight(clip: clip, crush: crush, level: level)
    }

    /// Fraction of counts in `from...to`, or 0 if the histogram is unusable.
    static func edgeEnergy(_ bins: [Int], from: Int, to: Int) -> Double {
        guard bins.count >= 256, from <= to, from >= 0, to <= 255 else { return 0 }
        var total = 0
        var band = 0
        for code in 0..<256 {
            total += bins[code]
            if code >= from, code <= to { band += bins[code] }
        }
        guard total > 0 else { return 0 }
        return Double(band) / Double(total)
    }

    static func latched(
        now: Bool, was: Bool, energy: Double, threshold: Double
    ) -> Bool {
        if now { return true }
        guard was else { return false }
        return energy > threshold * holdRatio
    }

    /// Re-centre the anchored level so the transfer's grey lands at exactly 0.5.
    static func balance(_ level: Double, midLevel: Double) -> Double {
        if level <= midLevel {
            guard midLevel > 0 else { return 0.5 }
            return 0.5 * level / midLevel
        }
        let span = 1.0 - midLevel
        guard span > 0 else { return 0.5 }
        return 0.5 + 0.5 * (level - midLevel) / span
    }
}
