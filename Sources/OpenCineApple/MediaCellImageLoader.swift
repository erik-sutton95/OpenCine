#if os(iOS)
    import AVFoundation
    import Foundation
    import ImageIO
    import UIKit

    /// Decodes cell images downsampled to a bounded pixel size, off the main actor.
    public actor MediaCellImageLoader {
        public static let shared = MediaCellImageLoader()

        public func downsampled(
            at url: URL, maxPixelSize: Int, fallbackOrientation: Int? = nil
        ) -> UIImage? {
            autoreleasepool {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                    return nil
                }
                return Self.downsampled(
                    source: source, maxPixelSize: maxPixelSize,
                    fallbackOrientation: fallbackOrientation)
            }
        }

        public func downsampled(
            data: Data, maxPixelSize: Int, fallbackOrientation: Int? = nil
        ) -> UIImage? {
            autoreleasepool {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                    return nil
                }
                return Self.downsampled(
                    source: source, maxPixelSize: maxPixelSize,
                    fallbackOrientation: fallbackOrientation)
            }
        }

        private nonisolated static func exifOrientation(source: CGImageSource) -> Int? {
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any]
            else { return nil }
            return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        }

        private static func downsampled(
            source: CGImageSource, maxPixelSize: Int, fallbackOrientation: Int?
        ) -> UIImage? {
            let thumbnailOptions =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as [CFString: Any] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
            else { return nil }
            if let fallbackOrientation, fallbackOrientation != 1,
                exifOrientation(source: source) == nil,
                let exif = CGImagePropertyOrientation(rawValue: UInt32(fallbackOrientation))
            {
                return UIImage(cgImage: cgImage, scale: 1, orientation: UIImage.Orientation(exif))
            }
            return UIImage(cgImage: cgImage)
        }
    }

    /// A local clip's poster frame and duration for a media cell.
    public enum MediaCellVideoFrames {
        /// The frame 0.2 s in, at most 600 points on a side, upright.
        public static func poster(at url: URL) async -> UIImage? {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let time = CMTime(seconds: 0.2, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else { return nil }
            return UIImage(cgImage: cgImage)
        }

        /// The clip's duration when the container states a positive one.
        public static func durationSeconds(at url: URL) async -> Double? {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0
            else { return nil }
            return duration.seconds
        }
    }

    extension UIImage.Orientation {
        fileprivate init(_ exif: CGImagePropertyOrientation) {
            switch exif {
            case .up: self = .up
            case .upMirrored: self = .upMirrored
            case .down: self = .down
            case .downMirrored: self = .downMirrored
            case .left: self = .left
            case .leftMirrored: self = .leftMirrored
            case .right: self = .right
            case .rightMirrored: self = .rightMirrored
            }
        }
    }
#endif
