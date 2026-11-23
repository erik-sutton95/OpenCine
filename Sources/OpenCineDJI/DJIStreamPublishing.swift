import Foundation
import OpenCineCore

/// Which DJI bodies can publish their own 1080p stream to the phone (Core's
/// `CameraStreamPublishing`). Pocket 4 Pro is proven on hardware (2026-11-21: HEVC over Enhanced
/// RTMP, Rec.709; log is refused in livestream mode, so no LUT). Pocket 4 and Pocket 3 follow the
/// same captures but are unconfirmed, so they are experimental. Osmo Nano has no livestream mode.
/// Kotlin twin: `DjiStreamPublishing`.
public enum DJIStreamPublishing {
    public static func capability(for model: CameraModel) -> CameraStreamPublishing? {
        let name = model.name.lowercased().replacingOccurrences(of: " ", with: "")
        let codecs: [CameraStreamPublishing.Codec]
        let experimental: Bool
        if model.isPocket4Pro {
            (codecs, experimental) = ([.hevc, .h264], false)
        } else if name.contains("pocket4") {
            (codecs, experimental) = ([.hevc, .h264], true)
        } else if model.isPocket3 {
            (codecs, experimental) = ([.h264], true)
        } else {
            return nil
        }
        return CameraStreamPublishing(
            width: 1920, height: 1080, frameRates: [25, 30], codecs: codecs, takesLUT: false,
            experimental: experimental)
    }
}
