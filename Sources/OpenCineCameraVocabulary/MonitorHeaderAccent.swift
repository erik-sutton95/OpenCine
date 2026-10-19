import Foundation

/// Which live header readout carries the app accent: the shooting mode where the body shows one,
/// else the codec. The integration declares it in its static capture profile (`headerAccent`); the
/// shared header never tests a brand. Kotlin twin: `MonitorHeaderAccent`.
public enum MonitorHeaderAccent: String, CaseIterable, Codable, Sendable {
    /// The shooting-mode readout, where the camera reports a mode the header shows.
    case shootingMode
    /// The codec readout: a body with no shooting-mode readout, as Nikon.
    case codec
}
