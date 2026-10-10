#if os(iOS)
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Immutable native still-codec policy. A schema may name these bytes JPEG while an exercised
/// deployment accepts HEIF through UIImage; the transport never rewrites that historical key.
public enum WatchPreviewImageFormat: Equatable, Sendable { case jpeg, heifWithJPEGFallback }

public enum WatchUIImagePreviewEncoder {
    nonisolated public static func encodedFrameData(
        _ image: UIImage, quality: CGFloat, format: WatchPreviewImageFormat
    ) -> Data? {
        guard format == .heifWithJPEGFallback, let cgImage = image.cgImage else {
            return image.jpegData(compressionQuality: quality)
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.heic.identifier as CFString, 1, nil)
        else { return image.jpegData(compressionQuality: quality) }
        CGImageDestinationAddImage(destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), buffer.length > 0 else {
            return image.jpegData(compressionQuality: quality)
        }
        return buffer as Data
    }

    /// The budget is pixels, not UIImage points. Rendering receives only the admitted thumbnail,
    /// retaining the existing native effect owner and avoiding full-resolution work for a Watch.
    nonisolated public static func thumbnail(
        from image: UIImage, maxWidth: CGFloat, quality: CGFloat, format: WatchPreviewImageFormat,
        render: (@Sendable (UIImage) async -> UIImage)? = nil
    ) async -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let imageScale = max(image.scale, 1)
        let pixelWidth = CGFloat(image.cgImage?.width ?? Int((size.width * imageScale).rounded()))
        let pixelHeight = CGFloat(image.cgImage?.height ?? Int((size.height * imageScale).rounded()))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, maxWidth / pixelWidth)
        let target = CGSize(width: (pixelWidth * scale).rounded() / imageScale,
            height: (pixelHeight * scale).rounded() / imageScale)
        guard let thumb = await image.byPreparingThumbnail(ofSize: target) else { return nil }
        let displayImage = await render?(thumb) ?? thumb
        return encodedFrameData(displayImage, quality: quality, format: format)
    }
}
#endif
