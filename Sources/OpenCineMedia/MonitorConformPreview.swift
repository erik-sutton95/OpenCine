import Foundation

/// Slow-motion conform preview: play a high-frame-rate clip at the rate it will be
/// conformed to in the edit. Preview only; never rewrites the file.
public enum MonitorConformPreview {
    public static let targetRates: [Double] = [23.976, 24, 25, 29.97, 30]
    public static let rateTolerance: Double = 0.01
    public static let conformFloor: Double = 0.99

    public struct Source: Equatable, Sendable {
        public var captureRate: Double?
        public var isVariableFrameRate: Bool
        public var isAlreadyConformed: Bool

        public init(
            captureRate: Double? = nil,
            isVariableFrameRate: Bool = false,
            isAlreadyConformed: Bool = false
        ) {
            self.captureRate = captureRate
            self.isVariableFrameRate = isVariableFrameRate
            self.isAlreadyConformed = isAlreadyConformed
        }
    }

    public enum Availability: Equatable, Sendable {
        case available([Double])
        case unknownRate
        case variableRate
        case alreadyConformed
        case notHighFrameRate

        public var targets: [Double] {
            if case .available(let rates) = self { return rates }
            return []
        }

        public var isAvailable: Bool { !targets.isEmpty }

        public var unavailableReason: String? {
            switch self {
            case .available: nil
            case .unknownRate: "Frame rate unavailable for this clip"
            case .variableRate: "Variable frame rate: conform preview unavailable"
            case .alreadyConformed: "Already conformed in camera"
            case .notHighFrameRate: "Not a high-frame-rate clip"
            }
        }
    }

    /// Rates we treat as a single capture cadence (including 50 / 100 / 120).
    public static let cinemaRates: [Double] = [
        23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 100, 119.88, 120, 240,
    ]

    public static func availability(for source: Source) -> Availability {
        guard let rate = source.captureRate, rate.isFinite, rate > 0 else { return .unknownRate }
        if source.isVariableFrameRate { return .variableRate }
        if source.isAlreadyConformed { return .alreadyConformed }
        let targets = targetRates.filter { $0 < rate * conformFloor }
        return targets.isEmpty ? .notHighFrameRate : .available(targets)
    }

    /// Resolve a capture rate from the file being played plus the camera listing.
    ///
    /// Source MP4s can report `nominalFrameRate == 0` or a `minFrameDuration` that is just
    /// the media timescale (1/1000, 1/60000); that is not VFR. Prefer the asset's
    /// snapped cinema rate; fall back to the listed fps. 50 vs 25 is treated as 50 fps
    /// capture (integer multiple), not variable rate.
    public static func probe(
        nominalFrameRate: Double? = nil,
        minFrameDurationSeconds: Double? = nil,
        listedRate: Double? = nil
    ) -> Source {
        var assetRates: [Double] = []
        if let rate = usableRate(nominalFrameRate) { assetRates.append(rate) }
        if let seconds = minFrameDurationSeconds, seconds.isFinite, seconds > 0 {
            if let implied = usableRate(1 / seconds) { assetRates.append(implied) }
        }
        let snappedAsset = uniqueSnapped(assetRates)
        if let capture = snappedAsset.max() {
            let varies = snappedAsset.contains { candidate in
                !isIntegerMultiple(capture, candidate)
                    && abs(capture - candidate) / max(capture, 1) > 0.08
            }
            return Source(captureRate: capture, isVariableFrameRate: varies)
        }
        if let raw = assetRates.max() {
            return Source(captureRate: raw)
        }
        if let listed = snap(listedRate) ?? usableRate(listedRate) {
            return Source(captureRate: listed)
        }
        return Source()
    }

    public static func snap(_ rate: Double?) -> Double? {
        guard let rate = usableRate(rate) else { return nil }
        guard let nearest = cinemaRates.min(by: { abs($0 - rate) < abs($1 - rate) }) else {
            return nil
        }
        let tolerance = max(0.51, nearest * 0.03)
        return abs(nearest - rate) <= tolerance ? nearest : nil
    }

    private static func usableRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 1, rate <= 250 else { return nil }
        return rate
    }

    private static func uniqueSnapped(_ rates: [Double]) -> [Double] {
        var seen = Set<Double>()
        var out: [Double] = []
        for rate in rates {
            guard let snapped = snap(rate), seen.insert(snapped).inserted else { continue }
            out.append(snapped)
        }
        return out
    }

    private static func isIntegerMultiple(_ a: Double, _ b: Double) -> Bool {
        let hi = max(a, b)
        let lo = min(a, b)
        guard lo > 0 else { return false }
        let ratio = hi / lo
        let nearest = ratio.rounded()
        return nearest >= 1 && abs(ratio - nearest) < 0.06
    }

    public static func speed(captureRate: Double, targetRate: Double) -> Double {
        guard captureRate.isFinite, captureRate > 0, targetRate.isFinite, targetRate > 0 else {
            return 1
        }
        return targetRate / captureRate
    }

    public static func conformedDuration(sourceSeconds: Double, speed: Double) -> Double {
        guard sourceSeconds.isFinite, sourceSeconds >= 0, speed.isFinite, speed > 0 else {
            return 0
        }
        return sourceSeconds / speed
    }

    /// Maps a conformed playhead to a source frame for finite, representable inputs.
    /// The preview changes the clock; seeking remains anchored to source frames.
    public static func sourceFrameIndex(
        conformedSeconds: Double, captureRate: Double, speed: Double
    ) -> Int {
        guard conformedSeconds.isFinite, conformedSeconds >= 0, captureRate > 0, speed > 0 else {
            return 0
        }
        return Int((conformedSeconds * speed * captureRate).rounded(.down))
    }

    public static func rateLabel(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "\u{2014}" }
        let whole = rate.rounded()
        if abs(rate - whole) < rateTolerance { return String(Int(whole)) }
        return String(format: "%.2f", rate)
    }

    public static func label(captureRate: Double, targetRate: Double) -> String {
        let percent = speed(captureRate: captureRate, targetRate: targetRate) * 100
        let formatted =
            abs(percent - percent.rounded()) < 0.05
            ? String(Int(percent.rounded())) : String(format: "%.1f", percent)
        return "\(rateLabel(captureRate)) → \(rateLabel(targetRate)) fps · \(formatted)%"
    }

    public static func targetLabel(captureRate: Double, targetRate: Double) -> String {
        let percent = speed(captureRate: captureRate, targetRate: targetRate) * 100
        let formatted =
            abs(percent - percent.rounded()) < 0.05
            ? String(Int(percent.rounded())) : String(format: "%.1f", percent)
        return "\(rateLabel(targetRate)) fps · \(formatted)%"
    }

    public static func menuHeader(captureRate: Double) -> String {
        "Conform \(rateLabel(captureRate)) fps to"
    }

    public static let audioLabel = "Audio muted during conform preview"
}
