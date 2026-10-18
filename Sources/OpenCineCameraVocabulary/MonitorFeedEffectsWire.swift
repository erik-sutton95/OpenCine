import Foundation
import OpenCineMedia

/// Bakes LUT-adjacent assist payloads for an Android app's GLES feed, behind its JNI exports.
///
/// Overlay cubes and zebra codes follow the iOS false colour map and live compositor so PEAK /
/// FALSE / ZEBRA / LUT match the Metal path. The camera integration supplies its source profile
/// (clip ceilings and official Rec.709 look curves); the JNI colour mode code names the curve.
/// Compiles on Darwin so `swift test` exercises the same lattice as the APK.
public enum MonitorFeedEffectsWire {
    public static let falseColorCubeSize = 64
    public static let assistScalarCount = 4

    public static func monitorTransfer(colorModeCode: Int) -> MonitorTransfer {
        guard (0...255).contains(colorModeCode),
            let mode = ColorMode(rawValue: UInt8(colorModeCode))
        else { return .rec709 }
        return MonitorTransfer(mode)
    }

    public static func falseColorScale(_ ordinal: Int) -> LiveFalseColorScale? {
        switch ordinal {
        case 0: .stops
        case 1: .ire
        case 2: .limits
        case 3: .sceneStops
        case 4...7: falseColorScale(ordinal - 4)
        default: nil
        }
    }

    /// Ordinals 4…7 are 0…3 read through the official Rec.709 look (Read: 709 / LOG).
    public static func readsRec709Look(_ ordinal: Int) -> Bool { (4...7).contains(ordinal) }

    /// Packed-2D RGBA8 overlay paint (`n³ × 4`). Sampled on encoded camera codes.
    public static func packedFalseColorPaint(
        scaleOrdinal: Int, colorModeCode: Int, iso: Int,
        sourceProfile: MonitorColorSourceProfile
    ) -> [UInt8]? {
        packedFalseColorPaint(scaleOrdinal: scaleOrdinal,
            transfer: monitorTransfer(colorModeCode: colorModeCode), iso: iso, sourceProfile: sourceProfile)
    }

    /// The paint for a named curve, for a source whose colour identity is not a mode byte.
    public static func packedFalseColorPaint(
        scaleOrdinal: Int, transfer: MonitorTransfer, iso: Int,
        sourceProfile: MonitorColorSourceProfile
    ) -> [UInt8]? {
        guard let scale = falseColorScale(scaleOrdinal) else { return nil }
        let ceiling = prepared(iso: iso, sourceProfile: sourceProfile)
        return lattice(scale: scale, transfer: transfer, ceiling: ceiling,
            rec709: readsRec709Look(scaleOrdinal), sourceProfile: sourceProfile).packedCube(.paint)
    }

    /// Packed-2D RGBA8 overlay weight. CineStop / Video / IRE are opaque; Limits is holes-only.
    public static func packedFalseColorWeight(
        scaleOrdinal: Int, colorModeCode: Int, iso: Int,
        sourceProfile: MonitorColorSourceProfile
    ) -> [UInt8]? {
        packedFalseColorWeight(scaleOrdinal: scaleOrdinal,
            transfer: monitorTransfer(colorModeCode: colorModeCode), iso: iso, sourceProfile: sourceProfile)
    }

    /// The weight for a named curve, for a source whose colour identity is not a mode byte.
    public static func packedFalseColorWeight(
        scaleOrdinal: Int, transfer: MonitorTransfer, iso: Int,
        sourceProfile: MonitorColorSourceProfile
    ) -> [UInt8]? {
        guard let scale = falseColorScale(scaleOrdinal) else { return nil }
        let ceiling = prepared(iso: iso, sourceProfile: sourceProfile)
        return lattice(scale: scale, transfer: transfer, ceiling: ceiling,
            rec709: readsRec709Look(scaleOrdinal), sourceProfile: sourceProfile).packedCube(.weight)
    }

    /// `[highlightNative, midtoneNative, midtoneHalfNative, peakingGateScale]`.
    public static func assistScalars(
        colorModeCode: Int, iso: Int, highlightIRE: Double, midtoneIRE: Double,
        sourceProfile: MonitorColorSourceProfile
    ) -> [Float] {
        assistScalars(transfer: monitorTransfer(colorModeCode: colorModeCode), iso: iso,
            highlightIRE: highlightIRE, midtoneIRE: midtoneIRE, sourceProfile: sourceProfile)
    }

    /// The assist scalars for a named curve, for a source whose colour identity is not a mode byte.
    public static func assistScalars(
        transfer: MonitorTransfer, iso: Int, highlightIRE: Double, midtoneIRE: Double,
        sourceProfile: MonitorColorSourceProfile
    ) -> [Float] {
        let ceiling = prepared(iso: iso, sourceProfile: sourceProfile)
        let clipByte = ceiling.clipByte(transfer: transfer, iso: iso)
        let highlight = ScopeDisplayScale.zebraHighlightNative(
            monitorPercent: highlightIRE, transfer: transfer, clipByte: clipByte)
        let half = LiveZebra.midtoneHalfWidthIRE
        let lo = ScopeDisplayScale.signalNative(
            monitorPercent: midtoneIRE - half, transfer: transfer, clipByte: clipByte)
        let hi = ScopeDisplayScale.signalNative(
            monitorPercent: midtoneIRE + half, transfer: transfer, clipByte: clipByte)
        return [
            Float(highlight),
            Float((lo + hi) * 0.5),
            Float(abs(hi - lo) * 0.5),
            Float(peakingGateScale(for: transfer)),
        ]
    }

    /// Display-referred feeds read larger gradients than log (iOS `peakingGateScale`).
    public static func peakingGateScale(for transfer: MonitorTransfer) -> Double {
        Peaking.gateScale(for: transfer)
    }

    /// Each JNI call carries its session's ISO, so the facade builds that source's ceiling
    /// per call instead of sharing one process-wide ratchet. Kotlin ratchets its own tap
    /// ceiling per feed session; the facade never observed tap maxima. An ISO outside
    /// 50…102400 leaves ISO unknown; the supplied source profile selects any reference.
    private static func prepared(
        iso: Int, sourceProfile: MonitorColorSourceProfile
    ) -> OpenCineMedia.ScopeExposureCeiling {
        let ceiling = OpenCineMedia.ScopeExposureCeiling(profile: sourceProfile.clip)
        ceiling.setISO(iso)
        return ceiling
    }

    private static func lattice(scale: LiveFalseColorScale, transfer: MonitorTransfer,
        ceiling: OpenCineMedia.ScopeExposureCeiling, rec709: Bool,
        sourceProfile: MonitorColorSourceProfile) -> MonitorFalseColorLattice {
        .signal(scale: scale, transfer: transfer, clipByte: ceiling.clipByte(transfer: transfer),
            rec709ClipByte: ceiling.clipByte(transfer: .rec709),
            lookCurve: sourceProfile.rec709LookCurves[transfer], readThroughLook: rec709,
            size: falseColorCubeSize)
    }
}
