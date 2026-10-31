#if canImport(CoreVideo)
    import CoreVideo
    import Testing

    @testable import OpenCineApple

    /// The HDMI levels readout reports the code values a frame holds, in each layout a capture
    /// device delivers: full-range data in a video-range container reads as luma outside 16...235,
    /// and a tinted black reads as dark Cb/Cr away from 128.
    @Suite struct CaptureSignalLevelsTests {
        static let formats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr8_yuvs,
            kCVPixelFormatType_422YpCbCr8,
        ]

        /// Top half a tinted sub-black (Y 8, Cb 120, Cr 136), bottom half a neutral super-white.
        @Test(arguments: formats)
        func readsOutOfRangeLumaAndTintedBlack(format: OSType) throws {
            let frame = try Self.frame(
                format, width: 64, height: 32, top: (8, 120, 136), bottom: (240, 128, 128))
            let levels = try #require(CaptureSignalLevels.measure(frame, stride: 2))
            #expect(levels.lumaLow == 8)
            #expect(levels.lumaHigh == 240)
            #expect(abs(levels.belowBlack - 0.5) < 0.01)
            #expect(abs(levels.aboveWhite - 0.5) < 0.01)
            #expect(levels.darkCb == 120)
            #expect(levels.darkCr == 136)
            #expect(levels.summary.hasPrefix("Y 8-240 <16 50.0% >235 50.0% dark Cb/Cr 120/136"))
        }

        @Test func tenBitFrameReadsNoLevels() throws {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(
                nil, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &made)
            #expect(CaptureSignalLevels.measure(try #require(made)) == nil)
        }

        struct FixtureError: Error {}

        static func frame(
            _ format: OSType, width: Int, height: Int, top: (UInt8, UInt8, UInt8),
            bottom: (UInt8, UInt8, UInt8)
        ) throws -> CVPixelBuffer {
            var made: CVPixelBuffer?
            guard
                CVPixelBufferCreate(nil, width, height, format, nil, &made) == kCVReturnSuccess,
                let buffer = made
            else { throw FixtureError() }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            func value(row: Int, of rows: Int) -> (UInt8, UInt8, UInt8) {
                row < rows / 2 ? top : bottom
            }
            if CVPixelBufferIsPlanar(buffer) {
                let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                    .assumingMemoryBound(to: UInt8.self)
                let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
                    .assumingMemoryBound(to: UInt8.self)
                let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                for row in 0..<height {
                    for column in 0..<width { y[row * yRow + column] = value(row: row, of: height).0 }
                }
                for row in 0..<(height / 2) {
                    let (_, cb, cr) = value(row: row, of: height / 2)
                    for pair in 0..<(width / 2) {
                        c[row * cRow + pair * 2] = cb
                        c[row * cRow + pair * 2 + 1] = cr
                    }
                }
            } else {
                let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for row in 0..<height {
                    let (y, cb, cr) = value(row: row, of: height)
                    let group: [UInt8] =
                        format == kCVPixelFormatType_422YpCbCr8_yuvs ? [y, cb, y, cr] : [cb, y, cr, y]
                    for byte in 0..<(width * 2) { p[row * bytesPerRow + byte] = group[byte % 4] }
                }
            }
            return buffer
        }
    }
#endif
