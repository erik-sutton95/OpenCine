#if canImport(CoreImage) && canImport(Metal)
import CoreGraphics
import CoreImage
import Foundation
import OpenCineMedia

/// The picture assists of one decoded still: peaking, zebra and false colour painted by the same
/// Core Image graph the live and playback pictures use (`MonitorImageCompositor`). The still is
/// read as its encoded codes, like a camera frame, and the graph works at most
/// `FeedPresentPolicy.maxWorkingWidth` wide. Display geometry (desqueeze, mirror) stays with the
/// page that shows the still. One instance renders serially; call it off the main thread.
public final class MonitorStillLookRenderer: @unchecked Sendable {
    private let mapper: MonitorFalseColorMapper
    private let lock = NSLock()
    private var displayContext: CIContext?
    private var cubeContext: CIContext?

    public init(lookCurves: [MonitorTransfer: [Double]] = [:]) {
        mapper = MonitorFalseColorMapper(lookCurves: lookCurves)
    }

    /// Whether `effects` paints anything on a still; when it does not, the still shows as decoded.
    public static func paints(_ effects: MonitorFrameEffects) -> Bool {
        effects.peaking || effects.zebra || effects.falseColor
            || (effects.lutDimension >= 2 && !effects.lutRGBA.isEmpty)
    }

    /// The still with `effects` painted on it, or nil when they paint nothing or rendering failed.
    public func render(_ image: CGImage, effects requested: MonitorFrameEffects) -> CGImage? {
        guard Self.paints(requested), image.width > 0, image.height > 0 else { return nil }
        var effects = requested
        effects.desqueezeFactor = 1
        effects.mirror = false
        effects.mirrorVertical = false
        lock.lock()
        defer { lock.unlock() }
        return autoreleasepool {
            let codes = CIImage(cgImage: image, options: MonitorWorkingSpace.imageOptions)
            let display = CIImage(cgImage: image)
            var plan = effects.nativeImagePlan
            if effects.falseColor {
                // One still is painted once, so its overlay is built now rather than warmed for
                // a later frame as the live path does.
                let scale = effects.falseColorScale.liveScale, clip = effects.resolvedClipByte
                let paint = mapper.overlayPaintCube(scale: scale, transfer: effects.transfer,
                    rec709: effects.falseColorRec709, clipByte: clip)
                let weight = mapper.overlayWeightCube(scale: scale, transfer: effects.transfer,
                    rec709: effects.falseColorRec709, clipByte: clip)
                plan.falseColorMaps = MonitorOverlayMaps(dimension: paint.size,
                    paint: paint.rgbaComponents.withUnsafeBytes { Data($0) },
                    weight: weight.rgbaComponents.withUnsafeBytes { Data($0) })
            }
            let product = MonitorImageCompositor.applyProduct(to: codes, effects: plan, display: display)
            let extent = product.image.extent
            guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0
            else { return nil }
            let placed = product.image.transformed(
                by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let context: CIContext
            if product.unmanagedBake {
                if cubeContext == nil { cubeContext = CIContext(options: MonitorWorkingSpace.contextOptions) }
                guard let cube = cubeContext else { return nil }
                context = cube
            } else {
                if displayContext == nil {
                    displayContext = CIContext(options: MonitorWorkingSpace.displayContextOptions)
                }
                guard let shown = displayContext else { return nil }
                context = shown
            }
            return context.createCGImage(placed, from: placed.extent)
        }
    }
}
#endif
