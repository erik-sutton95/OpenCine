#if canImport(CoreImage) && canImport(CoreVideo) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import OpenCineApple
import Testing

@Suite struct MonitorMediaThumbnailEncoderTests {
    @Test func packedVideoRangeNV12KeepsDimensionsAndBT709Colors() throws {
        let encoder = MonitorMediaThumbnailEncoder(), width = 24, height = 16
        for (y, cb, cr, expected): (UInt8, UInt8, UInt8, [UInt8]) in [
            (16, 128, 128, [0, 0, 0]), (235, 128, 128, [255, 255, 255]), (173, 42, 26, [0, 255, 0]),
        ] {
            var nv12 = Data(repeating: y, count: width * height)
            for _ in 0..<(width * height / 4) { nv12.append(contentsOf: [cb, cr]) }
            let jpeg = try #require(encoder.jpeg(width: width, height: height, nv12: nv12))
            let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == width && image.height == height)
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            for channel in 0..<3 {
                #expect(abs(Int(pixel[channel]) - Int(expected[channel])) <= 12,
                    "BT.709 video-range sample should retain its decoded color")
            }
        }
    }
    @Test func incompleteOrInvalidPixelStorageCannotProduceJPEG() {
        let encoder = MonitorMediaThumbnailEncoder()
        #expect(encoder.jpeg(width: 0, height: 16, nv12: Data()) == nil)
        #expect(encoder.jpeg(width: -2, height: 16, nv12: Data()) == nil)
        #expect(encoder.jpeg(width: Int.max, height: 2, nv12: Data()) == nil)
        #expect(encoder.jpeg(width: 24, height: 16, nv12: Data(repeating: 0, count: 575)) == nil)
    }
}
#endif
