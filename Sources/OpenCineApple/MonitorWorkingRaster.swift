#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
import CoreImage
import CoreVideo
import Foundation
import Metal
import OpenCineMedia

/// One native owner's working raster. A retained output remains unchanged until its lease ends.
public final class MonitorWorkingRaster: @unchecked Sendable {
    private struct PoolKey: Hashable { var width: Int; var height: Int }
    private let lock = NSLock()
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    /// Scales encoded codes as they are: no working-space linearization on the way in or out.
    private let context: CIContext

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: MonitorWorkingSpace.contextOptions)
        } else {
            context = CIContext(options: MonitorWorkingSpace.contextOptions)
        }
    }
    public static func targetSize(width: Int, height: Int, maxWidth: Int = FeedPresentPolicy.maxWorkingWidth)
        -> (width: Int, height: Int) {
        guard width > maxWidth, width > 1, height > 1 else { return (width, height) }
        let scale = Double(maxWidth) / Double(width)
        return (maxWidth, max(1, Int((Double(height) * scale).rounded())))
    }
    public func prepared(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let target = Self.targetSize(width: width, height: height)
        guard target.width != width, let destination = allocate(width: target.width, height: target.height)
        else { return buffer }
        // The assists, the scopes and the cube read this raster as the source's encoded
        // codes, and the identity picture reads it through the source's color tags. A
        // color-managed scale wrote linear light here (code 128 became 66), so every source
        // wider than the working width graded, striped and measured a far darker signal.
        let image = CIImage(cvPixelBuffer: buffer, options: MonitorWorkingSpace.imageOptions)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(target.width) / max(image.extent.width, 1),
            y: CGFloat(target.height) / max(image.extent.height, 1)))
        context.render(scaled, to: destination,
            bounds: CGRect(x: 0, y: 0, width: target.width, height: target.height), colorSpace: nil)
        CVBufferPropagateAttachments(buffer, destination)
        return destination
    }
    /// A decoded still (motion JPEG) on this raster: its codes copied unmanaged into a pooled
    /// BGRA buffer at the working size, scaled the way a wider video frame is. Nil when no
    /// buffer can be made.
    public func prepared(_ image: CGImage) -> CVPixelBuffer? {
        let target = Self.targetSize(width: image.width, height: image.height)
        guard target.width > 0, target.height > 0,
            let destination = allocate(width: target.width, height: target.height)
        else { return nil }
        let source = CIImage(cgImage: image, options: MonitorWorkingSpace.imageOptions)
        let scaled = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(target.width) / max(source.extent.width, 1),
            y: CGFloat(target.height) / max(source.extent.height, 1)))
        context.render(scaled, to: destination,
            bounds: CGRect(x: 0, y: 0, width: target.width, height: target.height), colorSpace: nil)
        return destination
    }
    public func reset() { lock.lock(); pools.removeAll(); lock.unlock() }
    private func allocate(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        let key = PoolKey(width: width, height: height)
        let pool: CVPixelBufferPool
        if let existing = pools[key] { pool = existing }
        else {
            var created: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                attributes as CFDictionary, &created) == kCVReturnSuccess, let created else { return nil }
            pools[key] = created; pool = created
        }
        var output: CVPixelBuffer?
        // Latest-frame processing plus held UI/inspector frames stays bounded. If all slots
        // are held, keep the source buffer; the compositor still caps its working graph.
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
            pool, limits, &output) == kCVReturnSuccess else { return nil }
        return output
    }
}
#endif
