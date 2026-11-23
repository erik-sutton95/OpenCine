#if canImport(CoreImage) && canImport(Metal)
import CoreImage
import CoreVideo
import Foundation
import OpenCineMedia

/// One clean picture: the camera picture with the monitor LUT when one is on, and nothing else.
public struct MonitorCleanFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// The source frame's host time in nanoseconds, when the source stated one.
    public let timeNs: Int64?
}

/// Renders the clean picture for an outgoing stream: the monitor's look (its LUT and desqueeze),
/// never assists (peaking, zebra, false colour, the split comparison) and never app controls.
///
/// It renders on its own queue into its own pool. While one render runs, a newer frame replaces
/// the waiting one, so a slow consumer never backs up the monitor. Nothing renders unless a tap
/// is set on the runtime (`MonitorLiveVideoRuntime.setCleanPictureTap`).
public final class MonitorCleanPictureTap: @unchecked Sendable {
    private let maxWidth: Int
    private let deliver: @Sendable (MonitorCleanFrame) -> Void
    private let queue = DispatchQueue(label: "opencine.monitor.clean-picture", qos: .userInitiated)
    private let managed = CIContext(options: MonitorWorkingSpace.displayContextOptions)
    private let unmanaged = CIContext(options: MonitorWorkingSpace.contextOptions)
    private let rec709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    // Touched only on `queue`.
    private var pool: (pool: CVPixelBufferPool, width: Int, height: Int)?
    private var busy = false
    private var waiting: (input: Input, effects: MonitorImageEffects, timeNs: Int64?)?

    public init(maxWidth: Int = 1920, deliver: @escaping @Sendable (MonitorCleanFrame) -> Void) {
        self.maxWidth = maxWidth
        self.deliver = deliver
    }

    /// Queues one decoded source frame with the monitor's current image effects.
    public func submit(_ buffer: CVPixelBuffer, effects: MonitorImageEffects, timeNs: Int64?) {
        enqueue(.buffer(buffer), effects: effects, timeNs: timeNs)
    }

    /// Queues one source frame that arrives as a decoded still image (a JPEG live view, say), with
    /// the monitor's current image effects.
    public func submit(_ image: CGImage, effects: MonitorImageEffects, timeNs: Int64?) {
        enqueue(.image(image), effects: effects, timeNs: timeNs)
    }

    private func enqueue(_ input: Input, effects: MonitorImageEffects, timeNs: Int64?) {
        queue.async { [self] in
            waiting = (input, effects, timeNs)
            guard !busy else { return }
            busy = true
            while let next = waiting {
                waiting = nil
                if let picture = render(next.input, effects: next.effects) {
                    deliver(MonitorCleanFrame(pixelBuffer: picture, timeNs: next.timeNs))
                }
            }
            busy = false
        }
    }

    /// The clean picture of one frame, at the source size capped to `maxWidth` (also with a LUT on:
    /// the monitor's narrower working width does not apply here), BGRA tagged Rec.709.
    func render(_ buffer: CVPixelBuffer, effects: MonitorImageEffects) -> CVPixelBuffer? {
        render(.buffer(buffer), effects: effects)
    }

    func render(_ image: CGImage, effects: MonitorImageEffects) -> CVPixelBuffer? {
        render(.image(image), effects: effects)
    }

    private func render(_ input: Input, effects: MonitorImageEffects) -> CVPixelBuffer? {
        var look = MonitorImageEffects()
        look.lutDimension = effects.lutDimension
        look.lutRGBA = effects.lutRGBA
        look.transfer = effects.transfer
        look.clipByte = effects.clipByte
        look.desqueezeFactor = effects.desqueezeFactor
        look.desqueezeHorizontal = effects.desqueezeHorizontal
        // The same inputs the assist engine gives the compositor: the LUT reads encoded camera
        // codes, the identity keeps the buffer's colour attachments.
        let hasLUT = look.lutDimension >= 2 && !look.lutRGBA.isEmpty
        let identity: CIImage
        let measure: CIImage
        switch input {
        case .buffer(let buffer):
            identity = CIImage(cvPixelBuffer: buffer)
            measure = hasLUT ? CIImage(cvPixelBuffer: buffer, options: MonitorWorkingSpace.imageOptions) : identity
        case .image(let image):
            identity = CIImage(cgImage: image)
            measure = hasLUT ? CIImage(cgImage: image, options: MonitorWorkingSpace.imageOptions) : identity
        }
        let product = MonitorImageCompositor.applyProduct(
            to: measure, effects: look, display: identity, workingWidth: CGFloat(maxWidth))
        var image = product.image
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, extent.width.isFinite, extent.height.isFinite else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if extent.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let width = max(2, Int(image.extent.width.rounded()) / 2 * 2)
        let height = max(2, Int(image.extent.height.rounded()) / 2 * 2)
        guard let output = makeBuffer(width: width, height: height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if product.unmanagedBake {
            unmanaged.render(image, to: output, bounds: bounds, colorSpace: nil)
        } else {
            managed.render(image, to: output, bounds: bounds, colorSpace: rec709)
        }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return output
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool?.width != width || pool?.height != height {
            var created: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created.map { ($0, width, height) }
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool.pool, &output) == kCVReturnSuccess else { return nil }
        return output
    }

    /// Carries a read-only decoded frame across the queue hop; the source keeps ownership.
    private enum Input: @unchecked Sendable {
        case buffer(CVPixelBuffer)
        case image(CGImage)
    }
}
#endif
