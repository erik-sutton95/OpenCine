#if canImport(UIKit) && canImport(CoreImage)
import CoreImage
import OpenCineMedia
import UIKit
import OpenCineMedia

/// Downsamples a live frame to a small tightly-packed RGBA8 buffer for the scopes. The scopes only
/// need a coarse read of the distribution, so shrinking to a couple hundred pixels wide keeps the
/// per-frame sampling cheap; `ScopeSampler` then strides over what's left.
public enum MonitorImageSampling {
    /// One device-RGB color space for every downsample, per-sample creation (~8–12 Hz) is
    /// allocator churn on the scope path.
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    /// A BT.709 file-code space. The source adapter opts into this interpretation. Scope
    /// taps render into this space to recover the file's raw code values, undoing the
    /// 709→sRGB conversion AVFoundation applies into the composition working space, so playback
    /// scopes read the same numbers live view samples straight off the feed JPEG.
    public static let fileCodeColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    /// One shared context for scope-tap renders, a per-call `CIContext` is an allocator and
    /// GPU-state churn hazard on a repeating path.
    private static let scopeTapContext = CIContext(options: [.cacheIntermediates: false])

    /// Downsamples a `CVPixelBuffer` (e.g. from `AVPlayerItemVideoOutput`) into a small RGBA buffer.
    public static func rgbaBuffer(
        from pixelBuffer: CVPixelBuffer, maxWidth: Int
    ) -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = scopeTapContext.createCGImage(ciImage, from: ciImage.extent)
        else { return nil }
        return rgbaBuffer(from: UIImage(cgImage: cgImage), maxWidth: maxWidth)
    }

    public static func rgbaBuffer(
        from image: UIImage, maxWidth: Int
    ) -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(cgImage.width))
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: rgbColorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? (data, width, height, bytesPerRow) : nil
    }
}

/// Native decoded-image preparation and the shared raw pixel walk are serial and off-main.
public actor MonitorUIImageScopeSampler {
    public init() {}
    public func sample(from image: UIImage, maxWidth: Int, stride: Int,
        includePoints: Bool = true, transfer: MonitorTransfer = .rec709,
        includeSampleCoordinates: Bool = false) -> ScopeSamples {
        autoreleasepool {
            guard let buffer = MonitorImageSampling.rgbaBuffer(from: image, maxWidth: maxWidth)
                else { return .empty }
            return ScopeSampler.sampleRaw(bytes: buffer.data, width: buffer.width,
                height: buffer.height, bytesPerRow: buffer.bytesPerRow, transfer: transfer,
                includePoints: includePoints, layout: .rgba, stride: stride,
                includeSampleCoordinates: includeSampleCoordinates, requireCompleteRows: true)
        }
    }
    public func sample(_ jpeg: Data, maxWidth: Int, stride: Int,
        includePoints: Bool = true, transfer: MonitorTransfer = .rec709,
        includeSampleCoordinates: Bool = false) -> ScopeSamples {
        autoreleasepool {
            guard let image = UIImage(data: jpeg) else { return .empty }
            return sample(from: image, maxWidth: maxWidth, stride: stride,
                includePoints: includePoints, transfer: transfer,
                includeSampleCoordinates: includeSampleCoordinates)
        }
    }
}
#endif
