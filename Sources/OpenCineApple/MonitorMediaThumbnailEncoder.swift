#if canImport(CoreImage) && canImport(CoreVideo)
import Foundation
import CoreImage
import CoreVideo

/// Per-owner native thumbnail conversion. CIContext supports concurrent image rendering; its
/// immutable configuration lives here, rather than in a process-wide source/app singleton.
public final class MonitorMediaThumbnailEncoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    public init() {}
    /// Packed NV12, video range, BT.709, JPEG quality 0.8. Raw source packet parsing stays in the
    /// integration; this owner accepts only dimensions and pixel bytes.
    public func jpeg(width: Int, height: Int, nv12: Data) -> Data? {
        let (lumaBytes, overflow) = width.multipliedReportingOverflow(by: height)
        let (required, sizeOverflow) = lumaBytes.addingReportingOverflow(lumaBytes / 2)
        guard width > 0, height > 0, !overflow, !sizeOverflow, nv12.count >= required else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        nv12.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for plane in 0..<2 {
                guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rows = plane == 0 ? height : height / 2
                let source = base.advanced(by: plane == 0 ? 0 : lumaBytes)
                for row in 0..<rows {
                    memcpy(destination.advanced(by: row * rowBytes), source.advanced(by: row * width), width)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    }
}
#endif
