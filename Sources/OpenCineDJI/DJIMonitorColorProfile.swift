import Foundation
import OpenCineMedia

// MARK: - Live-tap EI ceiling (not recording 1023, not code 255)

/// Preview clip model of **one** picture source. WAVE 100 / zebra highlight /
/// false-colour Maximum / traffic clip all sit on this ceiling. Each sample bus / feed
/// effects session owns its own instance, so two cameras (or a camera and a clip) never
/// share an ISO or a ratchet. Thread-safe.
///
/// Device evidence (SoftAP x420 1280×720 tap, `scope max:` journal):
/// D-Log2 ISO 1600 measures `max=247` (typical 243–247); D-Log measures
/// `max=223` (typical 219–223). 255 is a full-range leak and is ignored.
/// 188 was an under-read that made zebra / traffic-clip fire ~50 codes
/// early. DJI papers: below native EI the output cannot reach saturation;
/// at/above native an S-curve holds the code. D-Log2 native = 1600; D-Log
/// native = 400.
public final class DJIScopeExposureCeiling: OpenCineMedia.ScopeExposureCeiling, @unchecked Sendable {
    public static let referenceEI = 1600
    /// Pocket D-Log native / base ISO. Hold the live-tap ceiling from here up.
    public static let dlogReferenceEI = 400
    /// Measured live-tap max at ISO 1600. Do not replace with recording ~847/1023.
    public static let dlog2LiveTapByteAt1600: UInt8 = 247
    /// Same blast also logged 248: treat as the same ceiling, not a new curve.
    public static let dlog2LiveTapByteAt1600High: UInt8 = 248
    /// Measured D-Log live-tap max (ISO 400–6400 hold). Independent of D-Log2.
    public static let dlogLiveTapByteAtNative: UInt8 = 223
    /// Same blast also logged 224: treat as the same ceiling, not a new curve.
    public static let dlogLiveTapByteAtNativeHigh: UInt8 = 224
    /// The measured live-tap calibration above, for sample buses and other ceilings of this source.
    public static let sourceProfile = ScopeClipProfile(calibrations: [
        .dlog2: ScopeClipCalibration(referenceISO: referenceEI,
            referenceByte: dlog2LiveTapByteAt1600, refinementMaximumByte: dlog2LiveTapByteAt1600High),
        .dlog: ScopeClipCalibration(referenceISO: dlogReferenceEI,
            referenceByte: dlogLiveTapByteAtNative, refinementMaximumByte: dlogLiveTapByteAtNativeHigh,
            refinementAtOrAboveReference: true),
    ], defaultISO: referenceEI)

    public init() { super.init(profile: Self.sourceProfile) }
    public static func referenceClipByte(transfer: MonitorTransfer) -> Int {
        DJIScopeExposureCeiling().clipByte(transfer: transfer)
    }
}

// MARK: - Official Rec.709 looks (DJI cubes) for the 709 false-colour reading

/// DJI's official Rec.709 looks and the 709 readings through them. A DJI namespace, not an
/// extension of OpenCineMedia's neutral `LiveColorScience`: the curves are DJI's even though they
/// are keyed by the shared `MonitorTransfer`, so another integration never reads them by accident
/// (MULTI-03 F7). Each integration hands its own look to the `lookCurve:` overloads.
public enum DJILook {
    /// Luma of the grey axis (33 points) of DJI's official Rec.709 cubes: Pocket 4P D-Log2
    /// and D-Log, Nano D-Log M. Regenerate from the cubes if DJI updates them. Curves
    /// without an official look (Rec.709, HLG) return `nil` and stay on the signal.
    public static func rec709LookCurve(_ transfer: MonitorTransfer) -> [Double]? {
        switch transfer {
        case .dlog2:
            [
                0.0000, 0.0048, 0.0294, 0.0657, 0.1016, 0.1390, 0.1854, 0.2390, 0.2987, 0.3631,
                0.4300, 0.4976, 0.5651, 0.6306, 0.6930, 0.7508, 0.8024, 0.8471, 0.8847, 0.9152,
                0.9392, 0.9571, 0.9702, 0.9796, 0.9865, 0.9916, 0.9953, 0.9977, 0.9991, 0.9998,
                1.0000, 1.0000, 1.0000,
            ]
        case .dlog:
            [
                0.0000, 0.0162, 0.0253, 0.0379, 0.0519, 0.0697, 0.0938, 0.1231, 0.1583, 0.1974,
                0.2451, 0.2989, 0.3568, 0.4155, 0.4741, 0.5322, 0.5896, 0.6463, 0.7019, 0.7561,
                0.8081, 0.8543, 0.8922, 0.9224, 0.9459, 0.9636, 0.9762, 0.9849, 0.9905, 0.9939,
                0.9962, 0.9988, 1.0000,
            ]
        case .dlogm:
            [
                0.0000, 0.0029, 0.0115, 0.0275, 0.0535, 0.0849, 0.1192, 0.1552, 0.1925, 0.2303,
                0.2692, 0.3090, 0.3488, 0.3883, 0.4239, 0.4563, 0.4874, 0.5193, 0.5538, 0.5908,
                0.6299, 0.6685, 0.7057, 0.7404, 0.7743, 0.8073, 0.8402, 0.8727, 0.9040, 0.9332,
                0.9604, 0.9832, 1.0000,
            ]
        case .rec709, .hdr, .ilog, .srgb, .nlog, .log3G10:
            nil
        }
    }

    /// Video level (0…100 IRE) of an encoded neutral code through the official look.
    public static func rec709LookIRE(encoded: Double, transfer: MonitorTransfer) -> Double? {
        LiveColorScience.rec709LookIRE(encoded: encoded, lookCurve: rec709LookCurve(transfer))
    }

    /// True when the 709 reading applies: the operator picked 709 and this curve has an
    /// official Rec.709 look.
    public static func readsThroughLook(transfer: MonitorTransfer, rec709: Bool) -> Bool {
        LiveColorScience.readsThroughLook(lookCurve: rec709LookCurve(transfer), rec709: rec709)
    }

    /// `LiveColorScience.falseColorReading(encoded:transfer:rec709:lookCurve:scale:)` through the
    /// official look.
    public static func falseColorReading(
        encoded: Double, transfer: MonitorTransfer, rec709: Bool,
        scale: LiveFalseColorScale = .ire
    ) -> (encoded: Double, transfer: MonitorTransfer) {
        LiveColorScience.falseColorReading(
            encoded: encoded, transfer: transfer, rec709: rec709,
            lookCurve: rec709LookCurve(transfer), scale: scale)
    }

    /// `LiveColorScience.falseColorClip(scale:transfer:rec709:lookCurve:clipEncoded:)` for a source whose
    /// live ceiling for `transfer` is `clipByte` (see ``ScopeExposureCeiling``).
    public static func falseColorClip(
        scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
    ) -> (transfer: MonitorTransfer, ceiling: Double) {
        LiveColorScience.falseColorClip(
            scale: scale, transfer: transfer, rec709: rec709,
            lookCurve: rec709LookCurve(transfer), clipEncoded: Double(clipByte) / 255)
    }
}

/// Actual DJI preview calibration and bundled official look samples.
public enum DJIMonitorColorProfile {
    public static let value = MonitorColorSourceProfile(clip: DJIScopeExposureCeiling.sourceProfile,
        rec709LookCurves: Dictionary(uniqueKeysWithValues: MonitorTransfer.allCases.compactMap { transfer in
            DJILook.rec709LookCurve(transfer).map { (transfer, $0) }
        }), transferInference: [
            .init(fallback: .rec709, transfer: .dlog2, minByte: 12...22, maxByte: 180...252),
            .init(fallback: .rec709, transfer: .dlog, minByte: 20...30, maxByte: 160...240),
        ])

    /// Fingerprint the live tap when ColorMode `@2` has not arrived.
    ///
    /// D-Log2 paper black is byte 16 and the ISO 1600 preview ceiling is ~247.
    /// Plotting those codes on Rec.709 WAVE is the screenshot shelf (black at
    /// ~8, ceiling at ~75). An explicit ColorMode (`fallback` other than
    /// Rec.709) always wins.
    public static func inferredTransfer(
        minByte: UInt8, maxByte: UInt8, fallback: MonitorTransfer
    ) -> MonitorTransfer {
        value.inferredTransfer(minByte: minByte, maxByte: maxByte, fallback: fallback)
    }
}

extension MonitorTransfer {
    /// Compatibility entry point for clients importing the DJI integration.
    public static func inferred(minByte: UInt8, maxByte: UInt8, fallback: MonitorTransfer)
        -> MonitorTransfer {
        DJIMonitorColorProfile.inferredTransfer(minByte: minByte, maxByte: maxByte, fallback: fallback)
    }
}
