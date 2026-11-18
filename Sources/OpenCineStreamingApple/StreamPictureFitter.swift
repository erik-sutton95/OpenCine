#if canImport(VideoToolbox)
import CoreImage
import CoreVideo
import Foundation

/// Scales any source picture into the stream's fixed output frame, so the encoder never sees a
/// size change: on a cut, a camera reconnecting or a capture card changing mode.
public final class StreamPictureFitter: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Keep the source's shape inside the frame, with black bars.
        case fit
        /// Fill the frame from the center of the source (the vertical preset).
        case centerCrop
    }

    public let width: Int
    public let height: Int
    public let mode: Mode
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool: CVPixelBufferPool?
    private let black: CIImage

    public init(width: Int, height: Int, mode: Mode) {
        self.width = width
        self.height = height
        self.mode = mode
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = pool
        black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The source in a new output-sized buffer, or `nil` when no buffer could be made.
    public func fit(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        let image = CIImage(cvPixelBuffer: source)
        let sourceWidth = image.extent.width
        let sourceHeight = image.extent.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scaleX = CGFloat(width) / sourceWidth
        let scaleY = CGFloat(height) / sourceHeight
        let scale = mode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (CGFloat(width) - scaled.extent.width) / 2
        let y = (CGFloat(height) - scaled.extent.height) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        let frame = placed.composited(over: black).cropped(to: black.extent)
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        context.render(frame, to: output)
        return output
    }

    /// A black output frame: the slate shown while the selected camera is missing.
    public func slate() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        context.render(black, to: output)
        return output
    }
}
#endif
