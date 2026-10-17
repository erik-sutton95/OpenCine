import Foundation

/// A camera's display identity and declared facts, supplied by its integration.
public struct CameraModel: Equatable, Sendable {
    public let name: String
    public let datalinkPort: Int
    public let tcpPoke: Bool
    public let wpa3: Bool
    public let verified: Bool
    public let isDrone: Bool
    public let family: CameraBodyFamily
    public var captureProfile: CameraCaptureProfile?

    public init(name: String, datalinkPort: Int = 9004, tcpPoke: Bool = true,
        wpa3: Bool = false, verified: Bool = false, isDrone: Bool = false,
        family: CameraBodyFamily = .other, captureProfile: CameraCaptureProfile? = nil) {
        self.name = name
        self.datalinkPort = datalinkPort
        self.tcpPoke = tcpPoke
        self.wpa3 = wpa3
        self.verified = verified
        self.isDrone = isDrone
        self.family = family
        self.captureProfile = captureProfile
    }

    // These are admission decisions; the optional profile retains unknown capability facts.
    public var supportsAperture: Bool { captureProfile?.supportsAperture == true }
    public var supportsTapFocus: Bool { captureProfile?.supportsTapFocus == true }
    public var supportsFocusMode: Bool { captureProfile?.supportsFocusMode == true }
    public var supportsZoom: Bool { captureProfile?.supportsZoom == true }
    public var hasGimbal: Bool { captureProfile?.hasGimbal == true }
    public var isoAutoRangeFloor: Int? { captureProfile?.isoAutoRangeFloor }
    public var zoomStops: [Double] { captureProfile?.zoom?.stops ?? [1] }
    public var zoomMax: Double { zoomStops.last ?? 1 }
    public func activeZoomStops(resolution: VideoResolution?, shootingMode: Int) -> [Double] {
        captureProfile?.zoom?.choices(resolution: resolution, shootingMode: shootingMode) ?? [1]
    }
}

/// Integration-supplied grouping retained for saved records and transport compatibility.
/// Shared controls use the explicit capture profile instead of this grouping.
public enum CameraBodyFamily: Equatable, Sendable {
    case pocket, nano, other
    public static let fallback: CameraBodyFamily = .pocket
}

extension CameraBodyFamily {
    /// The family's word in diagnostic reports (Kotlin twin: the same words).
    public var reportName: String {
        switch self {
        case .pocket: "pocket"
        case .nano: "nano"
        case .other: "other"
        }
    }
}
