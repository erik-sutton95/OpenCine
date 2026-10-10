import Foundation

/// One setting a capture sheet or readout drum sends to the camera. Every capture commit goes
/// through this one typed entry; each app routes it to its own session path, so the shared
/// sheets never name an integration.
public enum CaptureSetting: Equatable, Sendable {
    /// A readout drum's ISO stop, Auto included.
    case iso(IsoIndex)
    /// The sheet's Auto tab.
    case isoAuto
    /// The sheet's Manual tab, at the stop it shows (empty when the camera reported none).
    case isoManual(label: String)
    case isoLimit(IsoLimit)
    case ev(EvComp)
    case shutterDenom(Int)
    case shutterAngle(Double)
    case whiteBalanceAuto
    /// Custom at a Kelvin, keeping the tint the sheet or drum showed.
    case whiteBalanceCustom(kelvin: Int, tint: Int)
    /// A tint from the tint drum: on Auto when `kelvin` is nil, else on that Custom Kelvin.
    case whiteBalanceTint(Int, kelvin: Int?)
    /// Pin the live Auto Kelvin as Custom.
    case autoWhiteBalanceLock
    case videoFormat(VideoFormat)
    case colorMode(ColorMode)
    case shootingMode(ShootingMode)
    case aperture(ApertureStrategy)
    case expoMode(ExpoMode)
    /// A focus row, with the label the operator chose (AF-S, AF-C or a track).
    case focus(FocusOption, label: String)
}
