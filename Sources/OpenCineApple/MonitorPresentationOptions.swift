#if canImport(Metal)
import Foundation
import Metal

public struct MonitorPresentationOptions: Equatable, Sendable {
    public var upscaler: MonitorUpscaler
    public var hdr: Bool
    public var hdrGain: Float
    public var previewSuperResolutionInput: Bool
    public init(upscaler: MonitorUpscaler = .lanczos, hdr: Bool = false, hdrGain: Float = 1,
        previewSuperResolutionInput: Bool = false) {
        self.upscaler = upscaler; self.hdr = hdr
        self.hdrGain = hdrGain; self.previewSuperResolutionInput = previewSuperResolutionInput
    }
    public static let bakePixelFormat = MTLPixelFormat.bgra8Unorm
    public var drawablePixelFormat: MTLPixelFormat { hdr ? .rgba16Float : .bgra8Unorm }
}
#endif
