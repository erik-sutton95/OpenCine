import Foundation

/// Transfer curve a monitored picture carries, named by its published curve.
///
/// This is a curve id only. Mapping a camera's raw colour mode, metadata or a tap
/// fingerprint to a curve belongs to the integration that knows the camera. Everything
/// here speaks **curve fractions** (`byte / 255` is the papers' own encoded axis) after
/// the integration has expanded any legal-range container.
public enum MonitorTransfer: String, CaseIterable, Sendable, Identifiable {
    /// ITU-R BT.709-6 inverse OETF.
    case rec709
    /// HLG (ITU-R BT.2100 / BT.2408), not PQ.
    case hdr
    /// DJI D-Log (2017 Cinema Color System white paper).
    case dlog
    /// DJI D-Log2 (Gamut white paper Rev 1.0, 2026-06-30).
    case dlog2
    /// D-Log M: signal-native scopes; scene-stop math is an empirical Pocket 3 estimate.
    case dlogm
    /// Insta360 I-Log (June 2026 white paper). Scene-referred BT.2020.
    case ilog
    /// IEC 61966-2-1 sRGB. Display-referred: linear 1.0 is display white and anything above clips.
    case srgb
    /// Nikon N-Log (specification 1.0.0). BT.2020.
    case nlog
    /// RED Log3G10 (white paper 915-0187 Rev C). REDWideGamutRGB.
    case log3G10

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rec709: "Rec.709"
        case .hdr: "HLG"
        case .dlog: "D-Log"
        case .dlog2: "D-Log2"
        case .dlogm: "D-Log M"
        case .ilog: "I-Log"
        case .srgb: "sRGB"
        case .nlog: "N-Log"
        case .log3G10: "Log3G10"
        }
    }

    /// Scene reflectance at encoded 1.0 (D-Log M is an empirical estimate). D-Log white paper: 4200% = 42. D-Log2 paper: 47500% = 475.
    public var peakLinear: Double {
        switch self {
        case .rec709: 1
        case .hdr: HLG.decode(1)
        case .dlog: DLog.peakLinear
        case .dlog2: DLog2.peakLinear
        case .ilog: ILog.decode(1)
        case .dlogm: DLogM.decode(1)
        case .srgb: 1
        case .nlog: NLog.decode(1)
        case .log3G10: Log3G10.decode(1)
        }
    }

    /// Encoded curve fraction of 18% grey (D-Log2 0.304985, D-Log 0.398765, …).
    public var middleGrayEncoded: Double {
        LiveColorScience.encode(0.18, transfer: self)
    }

    /// Published paper IRE of 18% grey (`encoded × 100`). D-Log2 = 30.50.
    public var middleGrayPaperIRE: Double {
        LiveColorScience.paperIRE(middleGrayEncoded)
    }

    public func encodeLinear(_ linear: Double) -> Double {
        LiveColorScience.encode(linear, transfer: self)
    }

    public func linearize(_ encoded: Double) -> Double {
        LiveColorScience.linearize(encoded, transfer: self)
    }
}

// MARK: - Color science entry points

/// Linearize encoded codes and map them for the display-referred assists
/// (false colour, zebra, LUT generation). Scopes do NOT linearize pixel data:
/// they ride ``ScopeDisplayScale`` on encoded codes.
public enum LiveColorScience {
    /// Scene-linear reflectance from a normalized encoded channel (`0…1`).
    /// Values below a log toe clamp to 0 so downstream math never sees NaN / negatives.
    public static func linearize(_ encoded: Double, transfer: MonitorTransfer) -> Double {
        let code = clamp01(encoded)
        let linear = decode(code, transfer: transfer)
        guard linear.isFinite else { return 0 }
        return max(0, linear)
    }

    /// Normalized encoded code from scene-linear reflectance. Clamped to `0…1`.
    public static func encode(_ linear: Double, transfer: MonitorTransfer) -> Double {
        let y = max(0, linear)
        let encoded = encodeRaw(y, transfer: transfer)
        guard encoded.isFinite else { return 0 }
        return clamp01(encoded)
    }

    /// Linearize one encoded RGB pixel (normalized `0…1`).
    public static func linearizeRGB(
        red: Double, green: Double, blue: Double, transfer: MonitorTransfer
    ) -> (red: Double, green: Double, blue: Double) {
        (
            linearize(red, transfer: transfer),
            linearize(green, transfer: transfer),
            linearize(blue, transfer: transfer)
        )
    }

    /// Scene-linear luminance. Channels are decoded first, then weighted.
    /// Rec.709 / D-Log use BT.709 Y; HDR (HLG), D-Log2 and I-Log use BT.2020 Y (BT.2100).
    public static func linearLuminance(
        red: Double, green: Double, blue: Double, transfer: MonitorTransfer
    ) -> Double {
        let rgb = linearizeRGB(red: red, green: green, blue: blue, transfer: transfer)
        let w = lumaWeights(transfer)
        return w.red * rgb.red + w.green * rgb.green + w.blue * rgb.blue
    }

    /// Encoded-domain luma weights for the scope sampler (same per-transfer choice).
    public static func lumaWeights(_ transfer: MonitorTransfer) -> (
        red: Double, green: Double, blue: Double
    ) {
        switch transfer {
        case .rec709, .dlog, .dlogm, .srgb:
            (0.2126, 0.7152, 0.0722)
        case .hdr, .dlog2, .ilog, .nlog:
            (0.2627, 0.6780, 0.0593)
        case .log3G10:
            // REDWideGamutRGB luminance row.
            (0.286694, 0.842979, -0.129673)
        }
    }

    /// Published paper IRE: encoded curve fraction × 100.
    /// D-Log2 18% = 30.4985; D-Log 18% = 39.88; Rec.709 18% ≈ 40.9.
    public static func paperIRE(_ encoded: Double) -> Double {
        encoded * 100
    }

    /// Stops relative to 18% grey. Zero light is `−∞`, never NaN.
    public static func stops(linear: Double) -> Double {
        let y = max(0, linear)
        guard y > 0, y.isFinite else { return -.infinity }
        return log2(y / 0.18)
    }

    public static func stops(encoded: Double, transfer: MonitorTransfer) -> Double {
        stops(linear: linearize(encoded, transfer: transfer))
    }

    // MARK: - Private transfers

    private static func decode(_ encoded: Double, transfer: MonitorTransfer) -> Double {
        switch transfer {
        case .rec709: Rec709.decode(encoded)
        case .hdr: HLG.decode(encoded)
        case .dlog: DLog.decode(encoded)
        case .dlog2: DLog2.decode(encoded)
        case .ilog: ILog.decode(encoded)
        case .dlogm: DLogM.decode(encoded)
        case .srgb: SRGB.decode(encoded)
        case .nlog: NLog.decode(encoded)
        case .log3G10: Log3G10.decode(encoded)
        }
    }

    private static func encodeRaw(_ linear: Double, transfer: MonitorTransfer) -> Double {
        switch transfer {
        case .rec709: Rec709.encode(linear)
        case .hdr: HLG.encode(linear)
        case .dlog: DLog.encode(linear)
        case .dlog2: DLog2.encode(linear)
        case .ilog: ILog.encode(linear)
        case .dlogm: DLogM.encode(linear)
        case .srgb: SRGB.encode(linear)
        case .nlog: NLog.encode(linear)
        case .log3G10: Log3G10.encode(linear)
        }
    }

    static func clamp01(_ x: Double) -> Double { clamp(x, 0, 1) }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }
}

// MARK: - I-Log (Insta360 June 2026 white paper)

/// Published equations from printed p3. The curve's 10-bit axis is code / 1023.
private enum ILog {
    private static let alpha = 5.77837328
    private static let beta = 0.09055934
    private static let delta = 0.623992
    private static let eta = 0.280055
    private static let theta = 0.01

    static func decode(_ encoded: Double) -> Double {
        if encoded < 0.154402 { return (encoded - beta) / alpha }
        return pow(10, (encoded - delta) / eta) - theta
    }

    static func encode(_ linear: Double) -> Double {
        if linear <= 0.01104854 { return alpha * linear + beta }
        return delta + eta * log10(linear + theta)
    }
}

// MARK: - BT.709 (ITU-R BT.709-6)

/// ITU-R BT.709-6 §1.2 inverse OETF / OETF.
private enum Rec709 {
    static func decode(_ encoded: Double) -> Double {
        let e = encoded
        return e < 0.081 ? e / 4.5 : pow((e + 0.099) / 1.099, 1 / 0.45)
    }

    static func encode(_ linear: Double) -> Double {
        let l = min(1, linear)
        return l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099
    }
}

// MARK: - HLG (ITU-R BT.2100 / BT.2408)

/// ITU-R BT.2100 HLG OETF (ARIB STD-B67). `linear` is scene reflectance with
/// 1.0 = diffuse white, scaled per BT.2408 (75% signal).
private enum HLG {
    private static let a = 0.178_832_77
    private static let b = 0.284_668_92
    private static let c = 0.559_910_73
    /// Inverse OETF of the BT.2408 75% reference-white signal.
    private static let diffuseWhite = inverseOETF(0.75)

    static func decode(_ encoded: Double) -> Double {
        inverseOETF(min(1, max(0, encoded))) / diffuseWhite
    }

    static func encode(_ linear: Double) -> Double {
        oetf(min(1, max(0, linear * diffuseWhite)))
    }

    private static func oetf(_ scene: Double) -> Double {
        scene <= 1.0 / 12.0 ? sqrt(3 * scene) : a * log(12 * scene - b) + c
    }

    private static func inverseOETF(_ e: Double) -> Double {
        e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
    }
}

// MARK: - D-Log (DJI 2017 white paper)

/// DJI, *White Paper on D-Log and D-Gamut of DJI Cinema Color System* (2017-09-29),
/// https://dl.djicdn.com/downloads/zenmuse+x7/20171010/D-Log_D-Gamut_Whitepaper.pdf
///
/// Curve fractions: 0% → 95/1023 (0.0929); 18% → 408/1023; 90% → 586/1023;
/// peak 4200% (7.8 stops above 18% grey) → 1.0.
private enum DLog {
    static let peakLinear = 42.0

    static func decode(_ encoded: Double) -> Double {
        if encoded <= 0.14 {
            return (encoded - 0.0929) / 6.025
        }
        return (pow(10, 3.89616 * encoded - 2.27752) - 0.0108) / 0.9892
    }

    static func encode(_ linear: Double) -> Double {
        if linear <= 0.0078 {
            return 6.025 * linear + 0.0929
        }
        return log10(linear * 0.9892 + 0.0108) * 0.256663 + 0.584555
    }
}

// MARK: - D-Log M (empirical Pocket 3 reference)

/// Neutral-channel fit from Thatcher Freeman's Pocket 3 DCTL, revision
/// 22f2134e5b2f62a8508ebe02f77f2691d4794d8a (see OpenPocketCine docs/pocket3-dlogm-curve.md).
/// This is an estimate for scene-stop tools, not a DJI specification or a
/// sensor saturation/noise model. Scopes use unmodified signal percentages.
private enum DLogM {
    static func decode(_ encoded: Double) -> Double {
        let t = pow(2, encoded * 5.612990379333496 + 0.9327186346054077)
            - 2.428226947784424
        let value = t < 0.6034245491027832
            ? t * 1.0151796340942383 + 0.5178895592689514
            : t * 1.8734303712844849
        return value * (0.18 / 12.4054)
    }

    static func encode(_ linear: Double) -> Double {
        let value = linear / (0.18 / 12.4054)
        let t = value < 0.6034245491027832 * 1.8734303712844849
            ? (value - 0.5178895592689514) / 1.0151796340942383
            : value / 1.8734303712844849
        return (log2(t + 2.428226947784424) - 0.9327186346054077)
            / 5.612990379333496
    }
}

// MARK: - D-Log2 (Gamut unofficial white paper, Rev 1.0, 2026-06-30)

/// D-Log2 transfer from *White Paper on D-Log2 and D-Gamut2 of DJI Cinema Color
/// System* (Gamut, Revision 1.0, June 30, 2026). Constants match that paper
/// bit-for-bit. Peak 475 linear, +11.37 EV above 18%.
///
/// Curve fractions: 0 → 0.062561; 18% → 0.304985; 1.0 → 0.454539; 475 → 1.0.
private enum DLog2 {
    static let peakLinear = 475.0
    private static let a = 16.285_770_761_945_304
    private static let k1 = 0.059_439_938_321_493
    private static let b1 = 0.304_985_337_243_402
    private static let k2 = 2.960_935_245_492_250
    private static let b2 = 0.148_314_799_066_323
    private static let inLimit1 = 0.18
    private static let inLimit2 = 0.028_961_695_254_132

    static func decode(_ encoded: Double) -> Double {
        if encoded >= b1 {
            return (peakLinear / (pow(2, a) - 1)) * (pow(2, a * encoded) - 1)
        }
        if encoded >= b2 {
            return pow(2, (encoded - b1) / k1 + log2(inLimit1))
        }
        return (encoded - b2) / k2 + inLimit2
    }

    static func encode(_ linear: Double) -> Double {
        if linear >= inLimit1 {
            return (1 / a) * log2(linear * (pow(2, a) - 1) / peakLinear + 1)
        }
        if linear >= inLimit2 {
            return k1 * (log2(max(linear, 1e-15)) - log2(inLimit1)) + b1
        }
        return k2 * (linear - inLimit2) + b2
    }
}

// MARK: - sRGB (IEC 61966-2-1)

/// Display-referred: linear 1.0 is display white and anything above clips.
public enum SRGB {
    public static func decode(_ encoded: Double) -> Double {
        let e = min(1, max(0, encoded))
        return e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
    }

    public static func encode(_ linear: Double) -> Double {
        let l = min(1, max(0, linear))
        return l <= 0.003_130_8 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
    }
}

// MARK: - N-Log (Nikon N-Log specification 1.0.0)

/// On the 10-bit code divided by 1023. Gamut is BT.2020.
public enum NLog {
    public static func decode(_ encoded: Double) -> Double {
        let code = encoded * 1023
        return code < 452 ? pow(code / 650, 3) - 0.0075 : exp((code - 619) / 150)
    }

    public static func encode(_ linear: Double) -> Double {
        if linear < 0.328 { return 650 * pow(max(0, linear + 0.0075), 1 / 3) / 1023 }
        return (150 * log(linear) + 619) / 1023
    }
}

// MARK: - Log3G10 (RED white paper 915-0187 Rev C)

/// Gamut is REDWideGamutRGB.
public enum Log3G10 {
    private static let a = 0.224282
    private static let b = 155.975327
    private static let c = 0.01
    private static let g = 15.1927

    public static func decode(_ encoded: Double) -> Double {
        encoded < 0 ? encoded / g - c : (pow(10, encoded / a) - 1) / b - c
    }

    public static func encode(_ linear: Double) -> Double {
        linear <= -c ? (linear + c) * g : a * log10((linear + c) * b + 1)
    }
}

/// Row-major 3×3 for gamut interchange (camera gamut to Rec.709 and back).
/// Integrations own the published matrices.
public struct ColorMatrix3: Equatable, Sendable {
    public var m00: Double, m01: Double, m02: Double
    public var m10: Double, m11: Double, m12: Double
    public var m20: Double, m21: Double, m22: Double

    public init(
        _ m00: Double, _ m01: Double, _ m02: Double,
        _ m10: Double, _ m11: Double, _ m12: Double,
        _ m20: Double, _ m21: Double, _ m22: Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
    }

    public func apply(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        (
            m00 * r + m01 * g + m02 * b,
            m10 * r + m11 * g + m12 * b,
            m20 * r + m21 * g + m22 * b
        )
    }
}
