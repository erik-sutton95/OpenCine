import Foundation

/// Per-session presentation and media addressing for one camera: the camera's own names for modes
/// and where it serves media. A session value, never process-wide, so two sessions with different
/// cameras never read each other's configuration.
public struct CameraLabelProfile: Sendable, Equatable {
    public var shootingModeLabels: [ShootingMode: String]
    public var colorModeLabels: [ColorMode: String]
    public var gimbalModeLabels: [GimbalMode: String]
    public var media: MediaHTTP.Route
    /// Legal ordered choices supplied by the integration; nil means undeclared.
    public var colorModes: [ColorMode]?
    public var shootingModes: [ShootingMode]?

    public init(
        shootingModeLabels: [ShootingMode: String] = [:], colorModeLabels: [ColorMode: String] = [:],
        gimbalModeLabels: [GimbalMode: String] = [:], media: MediaHTTP.Route = .cameraSoftAP,
        colorModes: [ColorMode]? = nil, shootingModes: [ShootingMode]? = nil
    ) {
        self.shootingModeLabels = shootingModeLabels
        self.colorModeLabels = colorModeLabels
        self.gimbalModeLabels = gimbalModeLabels
        self.media = media
        self.colorModes = colorModes
        self.shootingModes = shootingModes
    }

    /// The vocabulary's own names and the camera SoftAP `/v2` media route.
    public static let standard = CameraLabelProfile()
}
