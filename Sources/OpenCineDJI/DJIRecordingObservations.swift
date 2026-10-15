import OpenCineCore
import OpenCineCameraVocabulary

/// The decoded recording schema supplies dimensions; a transport codec supplies no recording fact.
enum DJIRecordingObservations {
    static func dimensions(_ code: UInt8) -> CameraRecordingFormat.Dimensions? {
        let size: (Int, Int)
        switch code {
        case 0x0A: size = (1920, 1080)
        case 0x0C: size = (1920, 1440)
        case 0x10: size = (3840, 2160)
        case 0x2D: size = (2688, 1512)
        case 0x42: size = (1080, 1920)
        case 0x43: size = (1512, 2688)
        case 0x5F: size = (2688, 2016)
        case 0x67: size = (3840, 2880)
        case 0x69: size = (1080, 1080)
        case 0x6A: size = (2160, 2160)
        case 0x6B: size = (3072, 3072)
        case 0x6C: size = (1728, 3072)
        case 0x7D: size = (3840, 3840)
        default: return nil
        }
        return CameraRecordingFormat.Dimensions(width: size.0, height: size.1)
    }

    static func exposureProgram(_ status: CameraStatus) -> ObservedValue<CameraExposureProgram> {
        let value: CameraExposureProgram?
        switch status.expoMode {
        case .auto?: value = .automatic
        case .manual?: value = .manual
        case nil: value = nil
        }
        return value.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown
    }

    /// The profile reads in the body's own colour names (`labels`, from its capture profile).
    static func recording(_ status: CameraStatus, labels: CameraLabelProfile = .standard) -> CameraRecordingObservations {
        let dimensions = (status.videoResolution ?? status.videoFormat?.resolution).flatMap { Self.dimensions($0.rawValue) }
        let profile: String?
        switch status.colorMode {
        case .normal?, .normal10?, .dLog?, .dLog2?, .dLogM?, .hdr?: profile = status.colorMode?.label(in: labels)
        default: profile = nil
        }
        return CameraRecordingObservations(
            dimensions: dimensions.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown,
            profile: profile.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown)
    }
}
