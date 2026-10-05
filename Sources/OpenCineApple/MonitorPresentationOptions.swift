#if canImport(Metal)
import Foundation
import Metal

/// Platform Metal resampling policy; existing playback consumers keep bilinear.
public enum MonitorPresentationResampling: Equatable, Sendable {
    case bilinear
    case selectedUpscaler
}

public struct MonitorPresentationOptions: Equatable, Sendable {
    public var resampling: MonitorPresentationResampling
    public var exactCopyAtNativeSize: Bool
    public var upscaler: MonitorUpscaler
    public var hdr: Bool
    public var hdrGain: Float
    public var previewSuperResolutionInput: Bool
    public init(upscaler: MonitorUpscaler = .lanczos, hdr: Bool = false, hdrGain: Float = 1,
        previewSuperResolutionInput: Bool = false,
        resampling: MonitorPresentationResampling = .bilinear,
        exactCopyAtNativeSize: Bool = false) {
        self.resampling = resampling
        self.exactCopyAtNativeSize = exactCopyAtNativeSize
        self.upscaler = upscaler; self.hdr = hdr
        self.hdrGain = hdrGain; self.previewSuperResolutionInput = previewSuperResolutionInput
    }
    public static let bakePixelFormat = MTLPixelFormat.bgra8Unorm
    public var drawablePixelFormat: MTLPixelFormat { hdr ? .rgba16Float : .bgra8Unorm }
}
#endif
