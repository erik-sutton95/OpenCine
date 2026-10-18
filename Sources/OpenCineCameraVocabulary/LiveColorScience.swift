import Foundation
import OpenCineMedia

// Shared color-mode to transfer vocabulary and published gamut interchange.
// Measured source ceilings and official look samples are integration-owned inputs.

/// Maps the shared recording-color vocabulary to its mathematical transfer.
extension MonitorTransfer {
    public init(_ colorMode: ColorMode) {
        switch colorMode {
        case .normal, .normal10: self = .rec709
        case .hdr: self = .hdr
        case .dLog: self = .dlog
        case .dLogM: self = .dlogm
        case .dLog2: self = .dlog2
        case .iLog: self = .ilog
        case .dolbyVision: self = .rec709
        }
    }

    /// The source curve a reported mode names, or nil before the first colour report and in Dolby
    /// Vision, which names no curve the tools can read (product ruling 2026-10-16). False colour,
    /// zebra and LUT exposure wait for it.
    public static func known(_ colorMode: ColorMode?) -> MonitorTransfer? {
        guard let colorMode, colorMode != .dolbyVision else { return nil }
        return MonitorTransfer(colorMode)
    }

    /// Curve for LUT exposure compensation and export bakes. D-Log M keeps the D-Log
    /// curve while its exposure model is uncalibrated, so the empirical scope estimate
    /// never silently changes baked images.
    public var lutExposureTransfer: MonitorTransfer {
        self == .dlogm ? .dlog : self
    }
}

/// Compatibility name for an uncalibrated portable source ceiling.
/// Integrations pass their measured `ScopeClipProfile` explicitly.
public typealias ScopeExposureCeiling = OpenCineMedia.ScopeExposureCeiling

// MARK: - D-Gamut2 (Gamut unofficial white paper, Rev 1.0, 2026-06-30)

/// Scene-linear D-Gamut2 interchange. Decode D-Log2 **before** applying these.
/// Display rendering, contrast, highlight roll-off, and gamut mapping stay
/// downstream. Scopes do **not** call this: they plot encoded codes.
public enum DGamut2 {
    /// Linear D-Gamut2 RGB → ITU-R BT.709 RGB.
    public static let rgbToRec709 = ColorMatrix3(
        1.8577, -0.7712, -0.0869,
        -0.2018, 1.4176, -0.2158,
        -0.0125, -0.1621, 1.1746)

    /// ITU-R BT.709 RGB → linear D-Gamut2 RGB.
    public static let rec709ToRGB = ColorMatrix3(
        0.5742, 0.3240, 0.1020,
        0.0844, 0.7682, 0.1474,
        0.0177, 0.1094, 0.8728)
}

// MARK: - D-Gamut (DJI 2017 white paper)

/// Scene-linear D-Gamut (v1) interchange, for D-Log footage. Same 2017 white
/// paper as the D-Log curve. Decode D-Log **before** applying.
enum DGamut {
    /// Linear D-Gamut RGB → ITU-R BT.709 RGB.
    public static let rgbToRec709 = ColorMatrix3(
        1.6746, -0.5797, -0.0949,
        -0.0981, 1.3340, -0.2359,
        -0.0410, -0.2430, 1.2840)

    /// ITU-R BT.709 RGB → linear D-Gamut RGB.
    public static let rec709ToRGB = ColorMatrix3(
        0.6163, 0.2857, 0.0980,
        0.0505, 0.7990, 0.1505,
        0.0292, 0.1604, 0.8104)
}
