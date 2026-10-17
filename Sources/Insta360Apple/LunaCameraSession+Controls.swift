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
        Self.controlCapabilities(snapshot: current.capabilities,
            backendCapabilities: backendCapabilities(), codecColor: codecColor)
    }

    /// Derives controls from camera facts and the backend's current verified operation domains.
    /// Nil means no backend declaration. Video/audio transport and the host clock are not controls.
    public static func controlCapabilities(snapshot: CapabilitySnapshot,
        backendCapabilities: CameraCapabilities?, codecColor: CaptureCodecColorChoices? = nil) -> ControlCapabilities {
        let controls = ControlCapabilities(snapshot: snapshot, profile: Self.captureProfile,
            motion: Self.motion, codecColor: codecColor)
        guard let backendCapabilities else { return controls }
        let domains: [(CameraCapabilities, [ControlFamily])] = [
            (.exposure, [.iso, .shutter, .exposureCompensation, .faceMetering]),
            (.whiteBalance, [.whiteBalance, .tint]),
            (.captureFormat, [.recordingFormat, .codecColor]),
            (.focus, [.focus, .tapFocus]),
            (.zoom, [.zoom]), (.gimbal, [.gimbal, .headTracking]),
            (.recording, [.recording]), (.cameraMedia, [.media, .mediaDelete]),
        ]
        var inputs: [ControlFamily: ControlStatus] = [:]
        for (domain, families) in domains {
            let status = ControlStatus(support: backendCapabilities.contains(domain) ? .supported : .unsupported)
            for family in families { inputs[family] = status }
        }
        return controls.restricting(inputs)
    }
}
