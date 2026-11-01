#if canImport(CoreImage) && canImport(CoreVideo) && canImport(IOSurface)
    import CoreImage
    import CoreVideo
    import Testing

    @testable import OpenCineApple

    /// The decode readout names what Core Image was handed: the path, the frame's colour tags, the
    /// IOSurface's own colour keys and the colour space the CIImage and its render ended up in.
    @Suite struct CaptureDecodeReadoutTests {
        @Test func describesAPreparedHDMIFrame() throws {
            var made: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferCreate(
                nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary, &made)
            let buffer = try #require(made)
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CaptureFrameColorimetry.prepareForDisplay(buffer)
            let image = CIImage(cvPixelBuffer: buffer)
            let context = CIContext(options: [.cacheIntermediates: false])
            let rendered = context.createCGImage(image, from: image.extent)
            let readout = CaptureDecodeReadout()
            readout.recordIfDue(now: 10) {
                CaptureDecodeReadout.describe(
                    .hdmiRender, pixelBuffer: buffer, image: image, context: context,
                    rendered: rendered)
            }
            let summary = try #require(readout.summary)
            print("DECODE READOUT\n\(summary)")
            #expect(summary.hasPrefix("HDMI render · 420v · M 709"))
            #expect(summary.contains("\nIOSurface "))
            #expect(summary.contains(" · CI "))
            #expect(summary.contains(" · ctx work "))
        }

        @Test func recordsAtMostOncePerInterval() {
            let readout = CaptureDecodeReadout(interval: 1)
            readout.recordIfDue(now: 100) { "first" }
            readout.recordIfDue(now: 100.5) { "second" }
            #expect(readout.summary == "first")
            readout.recordIfDue(now: 101) { "third" }
            #expect(readout.summary == "third")
        }
    }
#endif
