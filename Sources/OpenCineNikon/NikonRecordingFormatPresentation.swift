import Foundation

/// Grouping facts for one exact advertised movie token. No image-area command is created.
public struct NikonRecordingFormatPresentation: Equatable, Sendable {
    public let token: String
    public let imageArea: String?
    public let resolution: String
    public let frameRate: String

    public init(mode: PTPCameraScreenSizeMode, currentCodec: String?, isNikonZR: Bool) {
        token = NikonZRRawCropPresentation.label(for: mode, currentCodec: currentCodec, isNikonZR: isNikonZR)
        let size = PTPCameraPropertyDecoders.screenSize(mode.raw)
        resolution = MonitorTextFormat.resolutionClass(pixelWidth: size.width)
        frameRate = "\(size.fps)p"
        // The existing formatter alone decides whether RAW image-area facts are applicable.
        imageArea = token.hasPrefix("[") ? NikonZRRawCropPresentation.imageArea(for: mode.raw) : nil
    }
}
