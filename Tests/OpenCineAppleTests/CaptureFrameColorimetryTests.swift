#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreMedia)
    import CoreGraphics
    import CoreImage
    import CoreMedia
    import CoreVideo
    import Testing

    @testable import OpenCineApple

    /// A captured HDMI frame decodes to the RGB the camera encoded. Known BT.709 and BT.601
    /// YCbCr values, in each uncompressed layout a UVC capture device delivers through
    /// AVFoundation (`420v`, `420f`, `yuvs`, `2vuy`), go through `prepareForDisplay` and the
    /// CoreImage render every consumer of the lease uses, and land on the expected RGB.
    @Suite struct CaptureFrameColorimetryTests {
        /// One 75% colour bar: its Y'CbCr code values in video and full range, and its RGB.
        struct Bar: Sendable {
            let name: String
            let video: (Int, Int, Int)
            let full: (Int, Int, Int)
            let rgb: (Int, Int, Int)
        }

        /// BT.709 (HDMI's HD encoding, CTA-861): 75% green and 75% red, and a mid grey.
        static let bars709 = [
            Bar(name: "green", video: (133, 63, 52), full: (137, 54, 41), rgb: (0, 191, 0)),
            Bar(name: "red", video: (51, 109, 212), full: (41, 106, 224), rgb: (191, 0, 0)),
            Bar(name: "grey", video: (126, 128, 128), full: (128, 128, 128), rgb: (128, 128, 128)),
        ]
        /// BT.601 (standard definition): the same 75% green.
        static let green601 = Bar(
            name: "green 601", video: (112, 72, 58), full: (112, 65, 48), rgb: (0, 191, 0))

        static let formats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_422YpCbCr8_yuvs,
            kCVPixelFormatType_422YpCbCr8,
        ]

        /// What the frame claims: UVC's class default matrix (SMPTE 170M, i.e. BT.601, the
        /// value a device without a colour matching descriptor reports), no tag, or BT.709.
        static let hdClaims: [String?] = [
            kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String, nil,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
        ]

        @Test(arguments: formats, hdClaims.indices)
        func highDefinitionFrameDecodesAsBT709(format: OSType, claim: Int) throws {
            for bar in Self.bars709 {
                let frame = try Self.frame(
                    format, width: 1920, height: 1080, bar: bar, matrix: Self.hdClaims[claim])
                CaptureFrameColorimetry.prepareForDisplay(frame)
                let rgb = try Self.rendered(frame)
                Self.expectNear(
                    rgb, bar.rgb,
                    "\(Self.name(format)) \(Self.hdClaims[claim] ?? "untagged") \(bar.name)")
            }
        }

        /// A standard-definition frame tagged BT.601 keeps BT.601.
        @Test(arguments: formats)
        func standardDefinitionFrameKeepsBT601(format: OSType) throws {
            let frame = try Self.frame(
                format, width: 720, height: 480, bar: Self.green601,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            CaptureFrameColorimetry.prepareForDisplay(frame)
            Self.expectNear(try Self.rendered(frame), Self.green601.rgb, Self.name(format))
        }

        /// A frame carrying the UVC class-default colour claims (BT.709 primaries and transfer,
        /// SMPTE 170M matrix: what every capture device without a colour matching descriptor
        /// reports) still renders to the signal's own code values. The monitor's looks, scopes
        /// and exposure tools all read code values, as they do for the camera's JPEG live view;
        /// letting Core Image honour the transfer claim re-encoded BT.709 to sRGB first and lifted
        /// a log mid grey by 11 codes (about two thirds of a stop under a Log3G10 look).
        @Test(arguments: formats)
        func classDefaultClaimsRenderTheSignalCodes(format: OSType) throws {
            let ramp = [
                Bar(name: "shadow", video: (64, 128, 128), full: (56, 128, 128), rgb: (56, 56, 56)),
                Bar(name: "mid", video: (126, 128, 128), full: (128, 128, 128), rgb: (128, 128, 128)),
                Bar(name: "high", video: (182, 128, 128), full: (193, 128, 128), rgb: (193, 193, 193)),
                Self.bars709[0],
            ]
            for bar in ramp {
                let frame = try Self.frame(
                    format, width: 1920, height: 1080, bar: bar,
                    matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
                CVBufferSetAttachment(
                    frame, kCVImageBufferColorPrimariesKey,
                    kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(
                    frame, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CaptureFrameColorimetry.prepareForDisplay(frame)
                Self.expectNear(
                    try Self.rendered(frame), bar.rgb, "\(Self.name(format)) \(bar.name)")
            }
        }

        /// The capture output is asked for the device's own YCbCr layout, or biplanar 4:2:0 in
        /// the device's range, and never for RGB (which would hand the matrix to AVFoundation).
        @Test func captureRequestsYCbCrNeverRGB() {
            let offered: [OSType] = [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_32BGRA,
            ]
            let request = { (device: OSType) in
                CaptureFrameColorimetry.outputPixelFormat(deviceFormat: device, available: offered)
            }
            #expect(request(kCVPixelFormatType_422YpCbCr8_yuvs) == kCVPixelFormatType_422YpCbCr8_yuvs)
            #expect(
                request(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            // UYVY not offered by the output: biplanar video range, its own range.
            #expect(
                request(kCVPixelFormatType_422YpCbCr8)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            // A motion-JPEG mode decodes to full range.
            #expect(
                request(kCMVideoCodecType_JPEG_OpenDML)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            #expect(request(kCVPixelFormatType_32BGRA) != kCVPixelFormatType_32BGRA)
        }

        /// The request is always one the output offers, since asking for another throws. Without
        /// 4:2:0 it takes another offered YCbCr layout, and RGB only when nothing else is offered.
        @Test func captureRequestsOnlyAnOfferedFormat() {
            let yuvs = kCVPixelFormatType_422YpCbCr8_yuvs
            let bgra = kCVPixelFormatType_32BGRA
            let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            func request(_ device: OSType, _ offered: [OSType]) -> OSType {
                CaptureFrameColorimetry.outputPixelFormat(deviceFormat: device, available: offered)
            }
            #expect(request(videoRange, [bgra, yuvs]) == yuvs)
            #expect(request(kCMVideoCodecType_JPEG_OpenDML, [bgra, yuvs]) == yuvs)
            #expect(request(kCMVideoCodecType_JPEG_OpenDML, [videoRange, bgra]) == videoRange)
            #expect(request(fullRange, [bgra]) == bgra)
        }

        // MARK: - Fixtures

        static func name(_ format: OSType) -> String {
            String(decoding: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, as: UTF8.self)
        }

        static func expectNear(
            _ actual: (Int, Int, Int), _ expected: (Int, Int, Int), _ label: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let tolerance = 4
            #expect(
                abs(actual.0 - expected.0) <= tolerance && abs(actual.1 - expected.1) <= tolerance
                    && abs(actual.2 - expected.2) <= tolerance,
                "\(label): expected \(expected), rendered \(actual)", sourceLocation: sourceLocation)
        }

        struct FixtureError: Error {}

        /// A uniform frame of one colour in `format`, carrying `matrix` as its YCbCr matrix tag.
        static func frame(
            _ format: OSType, width: Int, height: Int, bar: Bar, matrix: String?
        ) throws -> CVPixelBuffer {
            var made: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            guard
                CVPixelBufferCreate(
                    nil, width, height, format, attributes as CFDictionary, &made)
                    == kCVReturnSuccess, let buffer = made
            else { throw FixtureError() }
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let (y, cb, cr) = full ? bar.full : bar.video
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if CVPixelBufferIsPlanar(buffer) {
                fill(buffer, plane: 0, rows: height, pattern: [UInt8(y)])
                fill(buffer, plane: 1, rows: height / 2, pattern: [UInt8(cb), UInt8(cr)])
            } else {
                let pattern: [UInt8] =
                    format == kCVPixelFormatType_422YpCbCr8_yuvs
                    ? [UInt8(y), UInt8(cb), UInt8(y), UInt8(cr)]
                    : [UInt8(cb), UInt8(y), UInt8(cr), UInt8(y)]
                fill(buffer, plane: nil, rows: height, pattern: pattern)
            }
            if let matrix {
                CVBufferSetAttachment(
                    buffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
            }
            return buffer
        }

        static func fill(_ buffer: CVPixelBuffer, plane: Int?, rows: Int, pattern: [UInt8]) {
            let base =
                plane.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) }
                ?? CVPixelBufferGetBaseAddress(buffer)
            let stride =
                plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
                ?? CVPixelBufferGetBytesPerRow(buffer)
            guard let bytes = base?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<rows {
                for column in 0..<stride { bytes[row * stride + column] = pattern[column % pattern.count] }
            }
        }

        /// The frame's centre pixel after the CoreImage render the capture consumers use.
        static func rendered(_ frame: CVPixelBuffer) throws -> (Int, Int, Int) {
            let image = CIImage(cvPixelBuffer: frame)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let cgImage = context.createCGImage(image, from: image.extent),
                let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { throw FixtureError() }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard
                let target = CGContext(
                    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw FixtureError() }
            target.draw(
                cgImage,
                in: CGRect(
                    x: -Double(cgImage.width) / 2, y: -Double(cgImage.height) / 2,
                    width: Double(cgImage.width), height: Double(cgImage.height)))
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }
    }
#endif
