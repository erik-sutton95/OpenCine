#if canImport(CoreImage) && canImport(CoreVideo)
import CoreGraphics
import CoreImage
import CoreVideo

/// Clean source pixels retained alongside the bake that actually reached the screen.
struct MonitorReferencePixelSource: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let seekRevision: UInt64
}

enum MonitorReferenceRaster {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let maximumEdge: CGFloat = 1600

    static func render(
        _ source: MonitorReferencePixelSource, transform: CGAffineTransform = .identity
    ) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let buffer = source.buffer
            let image = CIImage(cvPixelBuffer: buffer)
            let clean = CVImageBufferGetCleanRect(buffer).intersection(image.extent)
            guard !clean.isEmpty, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            let display = CVImageBufferGetDisplaySize(buffer)
            let pixelAspect = (display.width / display.height) / (clean.width / clean.height)
            let squarePixels = pixelAspect.isFinite && pixelAspect > 0 ? pixelAspect : 1
            let cropped = image.cropped(to: clean)
                .transformed(by: CGAffineTransform(scaleX: squarePixels, y: 1))
                // AVFoundation track matrices use top-left coordinates. Normalize their
                // translation from the oriented extent rather than the encoded raster size.
                .transformed(by: CGAffineTransform(
                    a: transform.a, b: -transform.b, c: -transform.c, d: transform.d,
                    tx: 0, ty: 0))
            let extent = cropped.extent
            guard extent.width.isFinite, extent.height.isFinite,
                extent.width > 0, extent.height > 0
            else { return nil }
            let scale = min(1, maximumEdge / max(extent.width, extent.height))
            let size = CGSize(
                width: max(1, (extent.width * scale).rounded()),
                height: max(1, (extent.height * scale).rounded()))
            let normalized = cropped
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: size.width / extent.width, y: size.height / extent.height))
            return context.createCGImage(
                normalized, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                colorSpace: colorSpace)
        }.value
    }
}
#endif
