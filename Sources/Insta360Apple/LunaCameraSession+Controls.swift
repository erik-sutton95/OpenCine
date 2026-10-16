import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineMotion

extension LunaCameraSession {
    /// Luna's static control facts (fw 1.1.15): focus modes and tap focus, a fixed aperture, the
    /// gimbal, zoom presets 1/2/3/6/15, face metering, native exposure compensation, no native ISO
    /// hop or ISO ceiling, no ND, photo modes, the camera's media served and deleted over its
    /// access point. Multiview is not declared (unknown).
    public nonisolated static let captureProfile: CameraCaptureProfile = {
        var profile = CameraCaptureProfile(supportsFocusMode: true, supportsTapFocus: true,
            supportsAperture: false, hasGimbal: true, supportsZoom: true,
            zoom: CameraZoomProfile(stops: [1, 2, 3, 6, 15]),
            nativeISO: CaptureNativeISOCapabilities(hop: false, ceiling: false))
        profile.controls = [
            .ndFilter: .unsupported, .faceMetering: .supported, .exposureCompensation: .supported,
            .recordingFormat: .supported,
            .codecColor: .supported, .photo: .supported, .media: .supported, .mediaDelete: .supported,
        ]
        return profile
    }()

    /// The one control model for this camera: `captureProfile` and `motion` merged with the live
    /// capabilities. `codecColor` is what the codec and colour popup lists now, when the host has it.
    public func controlCapabilities(codecColor: CaptureCodecColorChoices? = nil) -> ControlCapabilities {
        ControlCapabilities(snapshot: current.capabilities, profile: Self.captureProfile,
            motion: Self.motion, codecColor: codecColor)
    }
}
