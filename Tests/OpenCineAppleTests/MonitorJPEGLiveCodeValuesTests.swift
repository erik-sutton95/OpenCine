#if canImport(UIKit) && canImport(VideoToolbox) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing
    import UIKit

    @testable import OpenCineApple

    /// The camera's live-view JPEG reaches the monitor as the R'G'B' codes the camera encoded.
    ///
    /// A camera JPEG carries no colour profile, and its codes are the camera's log encoding
    /// (Log3G10, D-Log M, I-Log...) that every LUT, scope and exposure tool reads as they are.
    /// VideoToolbox tags its decode of such a JPEG with guessed NTSC colour (SMPTE C primaries,
    /// BT.709 transfer); a colour-managed render then converted 'Composite NTSC' to sRGB, lifting
    /// mids and moving the gamut (128 rendered 142), and a decode asked for video range held the
    /// JPEG's full-range samples (16 rendered 0, 235 rendered 255). The hardware path must render
    /// what the ImageIO fallback renders, and both what was encoded, within JPEG error.
    @Suite struct MonitorJPEGLiveCodeValuesTests {
        /// Greys across the signal range, then colour patches.
        static let patches: [(Int, Int, Int)] = [
            (16, 16, 16), (64, 64, 64), (128, 128, 128), (192, 192, 192),
            (235, 235, 235), (0, 0, 0), (255, 255, 255), (56, 128, 193),
            (180, 40, 40), (40, 160, 60), (50, 70, 190), (200, 180, 60),
        ]
        static let columns = 4
        /// Several JPEG blocks a side, so each patch centre is flat after decode.
        static let patchSize = 64

        @Test func hardwareDecodeRendersTheEncodedCodes() async throws {
            let jpeg = try Self.untaggedJPEG()
            // The hardware decoder takes this frame, so the decoder below runs its hardware path.
            #expect(JPEGPixelBufferDecoder().decode(jpeg) != nil, "VideoToolbox refused the JPEG")

            let decoder = MonitorJPEGImageDecoder()
            let owner = NSObject()
            let source = try #require(decoder.source(owner))
            let hardware = try #require(
                await decoder.decode(jpeg, source: source, preferHardware: true)?.cgImage)
            let imageIO = try #require(
                await decoder.decode(jpeg, source: source, preferHardware: false)?.cgImage)
            withExtendedLifetime(owner) {}

            for (index, encoded) in Self.patches.enumerated() {
                let hw = try Self.patch(index, of: hardware)
                let io = try Self.patch(index, of: imageIO)
                print("Wi-Fi patch \(encoded): hardware \(hw), ImageIO \(io)")
                Self.expectNear(hw, io, tolerance: 2, "hardware vs ImageIO, patch \(encoded)")
                Self.expectNear(hw, encoded, tolerance: 2, "hardware vs encoded, patch \(encoded)")
                Self.expectNear(io, encoded, tolerance: 2, "ImageIO vs encoded, patch \(encoded)")
            }
        }

        // MARK: - Fixtures

        struct FixtureError: Error {}

        static func expectNear(
            _ actual: (Int, Int, Int), _ expected: (Int, Int, Int), tolerance: Int,
            _ label: String, sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(
                abs(actual.0 - expected.0) <= tolerance && abs(actual.1 - expected.1) <= tolerance
                    && abs(actual.2 - expected.2) <= tolerance,
                "\(label): expected \(expected), rendered \(actual)", sourceLocation: sourceLocation)
        }

        /// A baseline JPEG of the patch grid with no colour profile, as a camera sends it.
        static func untaggedJPEG() throws -> Data {
            let rows = (patches.count + columns - 1) / columns
            let width = columns * patchSize
            let height = rows * patchSize
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw FixtureError() }
            for (index, rgb) in patches.enumerated() {
                context.setFillColor(
                    red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                    blue: CGFloat(rgb.2) / 255, alpha: 1)
                context.fill(rect(index, height: height))
            }
            guard let image = context.makeImage() else { throw FixtureError() }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data, "public.jpeg" as CFString, 1, nil)
            else { throw FixtureError() }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FixtureError() }
            return withoutColourProfile(data as Data)
        }

        /// Patch `index` in CoreGraphics coordinates (origin bottom left) of a grid `height` tall.
        static func rect(_ index: Int, height: Int) -> CGRect {
            let column = index % columns
            let row = index / columns
            return CGRect(
                x: column * patchSize, y: height - (row + 1) * patchSize, width: patchSize,
                height: patchSize)
        }

        /// The JPEG without its APP2 segments (ICC profile), every other byte unchanged.
        static func withoutColourProfile(_ jpeg: Data) -> Data {
            let bytes = [UInt8](jpeg)
            guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }
            var out: [UInt8] = [0xFF, 0xD8]
            var index = 2
            while index + 4 <= bytes.count, bytes[index] == 0xFF {
                let marker = bytes[index + 1]
                // Start of scan: the entropy-coded data and the rest of the file follow as is.
                if marker == 0xDA { break }
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                let end = index + 2 + length
                guard end <= bytes.count else { return jpeg }
                if marker != 0xE2 { out.append(contentsOf: bytes[index..<end]) }
                index = end
            }
            out.append(contentsOf: bytes[index...])
            return Data(out)
        }

        /// The centre pixel of patch `index`, read in the image's own colour space (no conversion).
        static func patch(_ index: Int, of image: CGImage) throws -> (Int, Int, Int) {
            let rows = (patches.count + columns - 1) / columns
            let space =
                image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpaceCreateDeviceRGB()
            var pixel = [UInt8](repeating: 0, count: 4)
            guard
                let target = CGContext(
                    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw FixtureError() }
            let frame = rect(index, height: rows * patchSize)
            target.interpolationQuality = .none
            target.draw(
                image,
                in: CGRect(
                    x: -frame.midX, y: -frame.midY, width: CGFloat(image.width),
                    height: CGFloat(image.height)))
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }
    }
#endif
