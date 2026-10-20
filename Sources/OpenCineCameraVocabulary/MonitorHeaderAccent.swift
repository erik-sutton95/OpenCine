import Foundation

/// Which live header readout carries the app accent: the shooting mode, or the codec for a body
/// with no shooting-mode readout. The integration declares it in its static capture profile (`headerAccent`); the
/// shared header never tests a brand. Kotlin twin: `MonitorHeaderAccent`.
public enum MonitorHeaderAccent: String, CaseIterable, Codable, Sendable {
    /// The shooting-mode readout, where the camera reports a mode the header shows.
    case shootingMode
    /// The codec readout, for a body with no shooting-mode readout.
    case codec
}
