import Foundation
import OpenCineMedia

/// Luna preview clip calibration for I-Log, over the portable ISO-aware ceiling
/// (``ScopeExposureCeiling``). Twin of Kotlin `LunaScopeClip` in `insta360-shell`.
///
/// Evidence (2026-10-20), in order of trust:
/// - Insta360's Luna Ultra / Luna Pro manual, I-Log page: "The I-Log Mode only has a single
///   native ISO value of 400." Below a log curve's native ISO the sensor saturates before the
///   curve does, so the clip code falls with ISO; at and above it the code holds.
/// - Owner report on a Luna Ultra: a fixed 255 ceiling (7-code shelf, floor 248) showed clipping
///   at ISO 400 and above and missed it below 400. So the live tap reaches at least 248 at 400.
/// - Derivation: 248 / 255 decodes (I-Log white paper curve) to 17.55 scene reflectance, 6.6
///   stops over 18% grey. Each ISO below 400 removes its stop fraction from that linear value.
///
/// **Not hardware-measured.** 248 is the lowest native-ISO clip consistent with the report, so
/// the table can only warn early, never late. Refinement raises it from the tap maximum seen at
/// ISO 400 and above (up to 254). Measurement procedure: OpenCine-Parity MORNING.md.
public enum LunaScopeClip {
    /// Insta360: I-Log has one native ISO, 400.
    public static let nativeISO = 400
    /// Lowest ISO the Luna offers (100, 160, 200, 400 ... 6400).
    public static let lowestISO = 100
    /// Derived live-tap I-Log clip at ISO 400 (needs a hardware measurement).
    public static let iLogClipByteAtNative: UInt8 = 248
    /// Highest tap maximum at or above ISO 400 accepted as the real clip.
    public static let iLogClipByteAtNativeHigh: UInt8 = 254

    /// ISO 100 205, 160 220, 200 227, 400 and above 248.
    /// Luna reports ISO 0 in Auto (the applied value is not published): the ceiling then assumes
    /// the lowest ISO, so an unreported Auto ISO warns early instead of missing a clip.
    public static let profile = ScopeClipProfile(calibrations: [
        .ilog: ScopeClipCalibration(referenceISO: nativeISO, referenceByte: iLogClipByteAtNative,
            refinementMaximumByte: iLogClipByteAtNativeHigh, refinementAtOrAboveReference: true),
    ], defaultISO: lowestISO, unreportedISO: lowestISO)
}
