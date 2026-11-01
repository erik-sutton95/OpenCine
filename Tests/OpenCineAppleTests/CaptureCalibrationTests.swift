#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreMedia)
    import CoreGraphics
    import CoreImage
    import CoreVideo
    import Testing

    @testable import OpenCineApple

    /// An HDMI capture frame from a device with a measured correction decodes to its code values
    /// with that correction applied to the codes themselves; any other device decodes exactly as
    /// it did without one.
    @Suite struct CaptureCalibrationTests {
        typealias Fixture = CaptureFrameColorimetryTests

        /// The capture dongle measured on 2026-11-01 (USB 345F:2130), as AVFoundation names it.
        static let dongle = CaptureDeviceIdentity(
            deviceIdentifier: "UVC Camera VendorID_13407 ProductID_8496")
        static let unknown = CaptureDeviceIdentity(
            deviceIdentifier: "UVC Camera VendorID_11802 ProductID_19460")

        @Test func deviceIdentityIsReadFromTheModelID() {
            #expect(Self.dongle == CaptureDeviceIdentity(vendorID: 0x345F, productID: 0x2130))
            #expect(Self.dongle?.description == "345F:2130")
            #expect(
                CaptureDeviceIdentity(deviceIdentifier: "VendorID_0x345F ProductID_0x2130")
                    == Self.dongle)
            #expect(CaptureDeviceIdentity(deviceIdentifier: "0x11213302e1a4c04") == nil)
            #expect(CaptureDeviceIdentity(deviceIdentifier: "UVC Camera VendorID_13407") == nil)
            #expect(CaptureDeviceIdentity(deviceIdentifier: "VendorID_99999 ProductID_1") == nil)
        }

        @Test func onlyTheMeasuredDeviceIsCorrected() {
            #expect(!CaptureCalibration.forDevice(Self.dongle).isIdentity)
            #expect(CaptureCalibration.forDevice(Self.unknown).isIdentity)
            #expect(CaptureCalibration.forDevice(nil).isIdentity)
        }

        /// Greys from black to white move by exactly the measured offsets, in code values: a
        /// neutral 128 grey by about +2.4, +0.4, +2.3 codes. Every grey, the darkest included,
        /// lands within half a code of the affine. The same matrix run in Core Image's linear
        /// working space would lift a dark grey by several codes more, which the last check shows
        /// this test would catch.
        @Test func measuredDongleMovesGreysByItsOffsets() throws {
            let calibration = CaptureCalibration.forDevice(Self.dongle)
            for grey in [16, 32, 64, 128, 192, 235] {
                let frame = try Self.fullRangeFrame(y: grey, cb: 128, cr: 128)
                let plain = try Self.renderedCodes(LiveFrameDecoding.image(frame))
                #expect(Self.near(plain, [grey, grey, grey].map(Double.init), 0.5))
                let corrected = try Self.renderedCodes(
                    LiveFrameDecoding.image(frame, calibration: calibration))
                let expected = Self.affine(calibration, plain)
                print("calibrated grey \(grey): plain \(plain), corrected \(corrected)")
                #expect(
                    Self.near(corrected, expected, 0.5),
                    "grey \(grey): expected \(expected), rendered \(corrected)")
                if grey == 128 {
                    let shift = zip(corrected, plain).map { $0 - $1 }
                    #expect(Self.near(shift, [2.4, 0.4, 2.3], 0.5), "grey 128 moved by \(shift)")
                }
            }
            let dark = try Self.fullRangeFrame(y: 32, cb: 128, cr: 128)
            let linear = try Self.renderedCodes(
                Self.matrixInWorkingSpace(calibration, LiveFrameDecoding.image(dark)))
            let expected = Self.affine(calibration, [32, 32, 32])
            print("grey 32: code-value affine \(expected), linear-space matrix \(linear)")
            #expect(!Self.near(linear, expected, 3), "linear-space matrix rendered \(linear)")
        }

        /// Colours, not only greys: in every channel the corrected codes are the affine of the
        /// uncorrected ones, through the decode's own Y'CbCr to R'G'B' step.
        @Test func measuredDongleCorrectsColoursAsAnAffine() throws {
            let calibration = CaptureCalibration.forDevice(Self.dongle)
            let colours = [(180, 120, 90), (100, 140, 60), (60, 90, 170), (200, 60, 70)]
            for rgb in colours {
                let (y, cb, cr) = Fixture.video709(rgb)
                let signal = Fixture.Bar(
                    name: "\(rgb)", video: (y, cb, cr), full: (y, cb, cr), rgb: rgb)
                let frame = try Fixture.frame(
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 1920, height: 1080,
                    bar: signal, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
                CaptureFrameColorimetry.prepareForDisplay(frame)
                let plain = try Self.renderedCodes(LiveFrameDecoding.image(frame))
                let corrected = try Self.renderedCodes(
                    LiveFrameDecoding.image(frame, calibration: calibration))
                let expected = Self.affine(calibration, plain)
                #expect(
                    Self.near(corrected, expected, 0.5),
                    "\(rgb): expected \(expected), rendered \(corrected)")
            }
        }

        /// A device without a measured correction renders bit for bit as the decode did before
        /// calibrations existed, through both the image and the 8-bit bitmap path.
        @Test func unknownDeviceRendersExactlyAsBefore() throws {
            let context = CIContext(options: [.cacheIntermediates: false])
            for calibration in [CaptureCalibration.forDevice(Self.unknown), .forDevice(nil)] {
                let samples = [(16, 128, 128), (128, 128, 128), (90, 60, 200), (235, 128, 128)]
                for (y, cb, cr) in samples {
                    let frame = try Self.fullRangeFrame(y: y, cb: cb, cr: cr)
                    let before = CIImage(
                        cvPixelBuffer: frame,
                        options: [.colorSpace: LiveFrameDecoding.codeValueSpace])
                    let beforeImage = try #require(
                        context.createCGImage(
                            before, from: before.extent, format: .RGBA8,
                            colorSpace: LiveFrameDecoding.codeValueSpace))
                    let after = try #require(
                        LiveFrameDecoding.cgImage(
                            frame, context: context, calibration: calibration))
                    #expect(try Self.bytes(after) == Self.bytes(beforeImage))
                    let image = CIImage(color: .gray)
                    let space = LiveFrameDecoding.codeValueSpace
                    #expect(calibration.applied(to: image, codeValueSpace: space) === image)
                }
            }
        }

        // MARK: - Fixtures

        /// A uniform 1080p full-range BT.709 frame, so Y is the grey's own code.
        static func fullRangeFrame(y: Int, cb: Int, cr: Int) throws -> CVPixelBuffer {
            let frame = try Fixture.frame(
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 1920, height: 1080,
                bar: Fixture.Bar(name: "", video: (y, cb, cr), full: (y, cb, cr), rgb: (0, 0, 0)),
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            CaptureFrameColorimetry.prepareForDisplay(frame)
            return frame
        }

        /// The centre pixel of `image` rendered as floats in the code-value space, in 8-bit codes.
        static func renderedCodes(_ image: CIImage) throws -> [Double] {
            let context = CIContext(options: [.cacheIntermediates: false])
            var pixel = [Float](repeating: 0, count: 4)
            context.render(
                image, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                format: .RGBAf, colorSpace: LiveFrameDecoding.codeValueSpace)
            return pixel.prefix(3).map { Double($0) * 255 }
        }

        /// `codes` (8-bit) through the calibration's affine.
        static func affine(_ calibration: CaptureCalibration, _ codes: [Double]) -> [Double] {
            let input = SIMD3(codes[0], codes[1], codes[2]) / 255
            let rows = [calibration.red, calibration.green, calibration.blue]
            return rows.enumerated().map { index, row in
                ((row * input).sum() + calibration.offset[index]) * 255
            }
        }

        /// The mistake the calibration avoids: the same colour matrix applied to Core Image's
        /// linear working values.
        static func matrixInWorkingSpace(_ calibration: CaptureCalibration, _ image: CIImage)
            -> CIImage
        {
            func vector(_ row: SIMD3<Double>) -> CIVector {
                CIVector(x: row.x, y: row.y, z: row.z, w: 0)
            }
            let offset = calibration.offset
            return image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": vector(calibration.red),
                    "inputGVector": vector(calibration.green),
                    "inputBVector": vector(calibration.blue),
                    "inputBiasVector": CIVector(x: offset.x, y: offset.y, z: offset.z, w: 0),
                ])
        }

        static func near(_ actual: [Double], _ expected: [Double], _ tolerance: Double) -> Bool {
            zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
        }

        static func bytes(_ image: CGImage) throws -> [UInt8] {
            let data = try #require(image.dataProvider?.data as Data?)
            return [UInt8](data)
        }
    }
#endif
