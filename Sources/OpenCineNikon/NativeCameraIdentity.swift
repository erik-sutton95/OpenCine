import Foundation

/// Identity reported by a Nikon body after its PTP session opens.
public struct NativeCameraIdentity: Equatable, Sendable {
    /// Nikon session host.
    public let host: String
    /// Nikon session camera name.
    public let cameraName: String
    /// Nikon session manufacturer.
    public let manufacturer: String
    /// Nikon session model.
    public let model: String
    /// Nikon session device version.
    public let deviceVersion: String
    /// Nikon session serial number.
    public let serialNumber: String
    /// Nikon session establishment summary.
    public let establishmentSummary: String

    /// Nikon session display name.
    public var displayName: String {
        CameraDisplayNamePolicy.displayName(
            cameraName: cameraName,
            manufacturer: manufacturer,
            model: model
        )
    }
}
