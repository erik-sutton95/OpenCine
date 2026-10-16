import OpenCineCameraVocabulary
import OpenCineCore

extension NikonCameraSession {
    /// Nikon Z static control facts: focus modes and tap focus on every body, no motion service
    /// (no gimbal, so no head tracking), no built-in ND, movie audio input settings, the codec and
    /// colour (movie tone) and recording format lists the body reports, photo, the card served and
    /// deleted over PTP, and a multi-camera stage. Zoom stays unknown (power-zoom lenses exist);
    /// the setting descriptors (ISO, shutter, aperture, white balance, frame rate) come live from
    /// the body.
    public nonisolated static let captureProfile: CameraCaptureProfile = {
        var profile = CameraCaptureProfile(supportsFocusMode: true, supportsTapFocus: true,
            hasGimbal: false)
        profile.controls = [
            .ndFilter: .unsupported, .audio: .supported, .recordingFormat: .supported,
            .codecColor: .supported, .photo: .supported, .media: .supported, .mediaDelete: .supported,
            .multiview: .supported,
        ]
        return profile
    }()

    /// The one control model for the connected body: `captureProfile` merged with the live
    /// capabilities. `codecColor` is what the codec and colour popup lists now, when the host has it.
    public nonisolated func controlCapabilities(codecColor: CaptureCodecColorChoices? = nil) -> ControlCapabilities {
        ControlCapabilities(snapshot: commandSnapshot.capabilities, profile: Self.captureProfile,
            motion: nil, codecColor: codecColor)
    }
}
