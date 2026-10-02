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
    private let context: CIContext

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: MonitorWorkingSpace.displayContextOptions)
        } else {
            context = CIContext(options: MonitorWorkingSpace.displayContextOptions)
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
        let image = CIImage(cvPixelBuffer: buffer)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(target.width) / max(image.extent.width, 1),
            y: CGFloat(target.height) / max(image.extent.height, 1)))
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
