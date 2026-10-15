import Foundation

/// Estimates remaining recording time from codec, resolution, frame rate, and free space.
///
/// Bitrates are approximate, derived from Nikon-published ranges for the Z cinema line. The
/// estimate scales by pixel count (relative to a 4K reference) and frame rate (relative to 24fps)
/// so higher resolutions / frame rates consume space faster. Values are intentionally conservative
/// (rounded up on bitrate) so the on-screen "Min" readout tends to under-promise. Kotlin twin:
/// `Android/nikon` `RecordDurationEstimator`; both read the `estimate` rows of
/// `Fixtures/nikon-monitor-text.tsv`.
public enum RecordDurationEstimator {
    /// Per-codec base bitrate in Mbps at the UHD reference (3840×2160), 24fps. The label keys match
    /// `MonitorTextFormat.codecShortLabel` output exactly (H.264, H.265, N-RAW, ProRes 422 HQ,
    /// ProRes RAW HQ, R3D NE) so the lookup hits rather than falling back.
    ///
    /// ProRes is a fixed-rate codec and its value is precise (Apple publishes ~707 Mbps for 422 HQ
    /// at UHD 24p; RAW HQ is variable but averages ~2.4×). The compressed-raw codecs (R3D NE, N-RAW)
    /// vary with a compression/quality setting the body doesn't expose over PTP, so their values are
    /// midpoints of the published ranges.
    // Nikon ZR published bitrates (imaging.nikon.com / onlinemanual) at UHD 24p, back-solved from the
    // 6K 25p R3D NE figure (1590 Mbps) via the pixel×fps scaling below. Tune only this table.
    private static let baseBitrateMbps: [String: Double] = [
        "R3D NE": 600,
        "N-RAW": 470,
        "ProRes RAW HQ": 1700,
        "ProRes 422 HQ": 707,
        "H.265": 190,
        "H.264": 75,
    ]

    /// An observation requires a supported codec and positive reported geometry and cadence.
    /// Free bytes stay exact until the final conservative whole-minute rounding. Unknown format
    /// returns nil; a known format with no space reports zero rather than an invented duration.
    public static func estimateMinutes(
        codec: String?, resolution: String?, frameRate: Int?, freeBytes: UInt64
    ) -> Int? {
        guard let codec, let resolution, let frameRate, frameRate > 0,
            let base = baseBitrateMbps[MonitorTextFormat.codecShortLabel(codec)] else { return nil }
        let dimensions = resolution.split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
            width > 0, height > 0 else { return nil }
        let bitrate = base * Double(width) * Double(height) / referencePixels
            * Double(frameRate) / referenceFrameRate
        let minutes = Double(freeBytes) * 8 / (bitrate * 1_000_000 * 60)
        guard bitrate.isFinite, bitrate > 0, minutes.isFinite, minutes >= 0,
            minutes < Double(Int32.max) else { return nil }
        return Int(minutes)
    }

    /// Fallback bitrate when the codec is unknown; a mid-range assumption so the estimate stays
    /// plausible rather than wildly optimistic.
    private static let fallbackBitrateMbps = 250.0

    /// Pixels of the 4K reference used to scale bitrate with resolution.
    private static let referencePixels = 3840.0 * 2160.0
    /// Reference frame rate used to scale bitrate.
    private static let referenceFrameRate = 24.0

    /// Estimated recording bitrate in Mbps for the given codec + resolution + frame rate.
    public static func bitrateMbps(
        codec: String, resolutionWidth: Int, resolutionHeight: Int, frameRate: Int
    ) -> Double {
        let base = baseBitrateMbps[codec] ?? fallbackBitrateMbps
        let pixelScale = (Double(resolutionWidth) * Double(resolutionHeight)) / referencePixels
        let fpsScale = Double(frameRate) / referenceFrameRate
        return base * pixelScale * fpsScale
    }

    /// Estimated whole minutes of recording remaining. `codec` is the short label ("R3D NE",
    /// matching the picker/formatter output); `gigabytesFree` is decimal GB (1 GB = 1e9 bytes).
    /// Returns 0 when there is no free space.
    public static func minutesRemaining(
        codec: String, resolutionWidth: Int, resolutionHeight: Int, frameRate: Int,
        gigabytesFree: Int
    ) -> Int {
        guard gigabytesFree > 0 else { return 0 }
        let mbps = bitrateMbps(
            codec: codec, resolutionWidth: resolutionWidth, resolutionHeight: resolutionHeight,
            frameRate: frameRate)
        // No bitrate (resolution/fps not known yet, e.g. just after a reconnect) → no estimate.
        // Without this guard the division below is +∞ and `Int(+∞)` traps.
        guard mbps > 0 else { return 0 }
        // free space in megabits; 1 GB = 8000 megabits (decimal).
        let freeMegabits = Double(gigabytesFree) * 8000
        let minutes = freeMegabits / mbps / 60
        guard minutes.isFinite else { return 0 }
        return Int(minutes)
    }
}
