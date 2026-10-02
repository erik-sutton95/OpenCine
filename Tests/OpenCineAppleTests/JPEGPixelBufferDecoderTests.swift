#if canImport(VideoToolbox) && canImport(ImageIO) && canImport(CoreGraphics)
    import CoreGraphics
    import Foundation
    import ImageIO
    import OpenCineApple
    import Testing

    /// A flat JPEG made on the spot, so the test needs no fixture.
    func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// SHELL-04: the hardware JPEG decoder lends its frames as decoded-frame leases.
    @Suite struct JPEGPixelBufferDecoderTests {
        @Test func aDecodedFrameIsALeaseOfTheCurrentGeneration() throws {
            let decoder = JPEGPixelBufferDecoder()
            let lease = try #require(
                decoder.decodeLease(try makeJPEG(width: 64, height: 48), timeNs: 5),
                "VideoToolbox refused the frame (\(decoder.report))")
            #expect(lease.stream == decoder.fence.stream)
            #expect(lease.generation == decoder.fence.generation)
            #expect(lease.format.width == 64 && lease.format.height == 48)
            #expect(lease.timeNs == 5)
            var published = false
            #expect(decoder.fence.publish(lease) { _ in published = true })
            #expect(published)
            lease.release()
        }

        @Test func aFrameFromBeforeANewStreamIsNeverPublished() throws {
            let decoder = JPEGPixelBufferDecoder()
            let lease = try #require(decoder.decodeLease(try makeJPEG(width: 64, height: 48)))
            decoder.fence.advance()
            #expect(!decoder.fence.publish(lease) { _ in Issue.record("stale frame published") })
            #expect(lease.isReleased)
        }

        @Test func notAJPEGIsNoLease() {
            let decoder = JPEGPixelBufferDecoder()
            #expect(decoder.decodeLease(Data([0x00, 0x01, 0x02])) == nil)
            #expect(decoder.report == "not a JPEG")
        }
    }
#endif
