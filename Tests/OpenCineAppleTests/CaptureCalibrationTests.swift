#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreMedia)
    import CoreGraphics
    import CoreImage
    import CoreVideo
    import Testing

    @testable import OpenCineApple

    /// An HDMI capture frame from any UVC capture device decodes to its code values with the
    /// measured HDMI correction applied to the codes themselves; the camera's live-view JPEG
    /// decodes exactly as it did without one.
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

        /// Every UVC capture device gets the correction, whatever its USB identity and whether or
        /// not it could be read.
        @Test func everyCaptureDeviceIsCorrected() {
            for device in [Self.dongle, Self.unknown, nil] {
                #expect(CaptureCalibration.forDevice(device) == .uvcHDMICapture)
            }
            #expect(!CaptureCalibration.uvcHDMICapture.isIdentity)
        }

        /// Greys, low-chroma log-like colours on both sides of neutral and saturated colours come
        /// out at the measured model's values within 0.3 code. The model is written out here from
        /// its published coefficients, independently of the implementation.
        @Test func measuredDongleRendersTheModel() throws {
            let calibration = CaptureCalibration.uvcHDMICapture
            let greys = [16, 32, 64, 128, 192, 235].map { ($0, $0, $0) }
            let logLike = [
                (122, 118, 114), (114, 118, 122), (100, 104, 99), (104, 100, 106),
                (140, 139, 143), (139, 141, 137),
            ]
            let saturated = [(200, 60, 70), (60, 90, 170), (180, 120, 90), (100, 140, 60)]
            for rgb in greys + logLike + saturated {
                let (y, cb, cr) = Self.fullRange709(rgb)
                let frame = try Self.fullRangeFrame(y: y, cb: cb, cr: cr)
                let plain = try Self.renderedCodes(LiveFrameDecoding.image(frame))
                let corrected = try Self.renderedCodes(
                    LiveFrameDecoding.image(frame, calibration: calibration))
                let expected = Self.model(plain)
                print("calibrated \(rgb): plain \(plain) corrected \(corrected) model \(expected)")
                #expect(
                    Self.near(corrected, expected, 0.3),
                    "\(rgb): model \(expected), rendered \(corrected)")
            }
        }

        /// A neutral grey gains Y' + 1.0, Cb + 0.77 and Cr + 1.13 codes; a chroma just above
        /// neutral moves further than the same chroma just below it (the sign-dependent offset).
        @Test func measuredDongleShiftsNeutralAndChromaAsMeasured() throws {
            let calibration = CaptureCalibration.uvcHDMICapture
            let grey = try Self.fullRangeFrame(y: 128, cb: 128, cr: 128)
            let shift = try Self.yCbCrShift(grey, calibration)
            #expect(Self.near(shift, [1.0, 0.768, 1.125], 0.15), "grey 128 moved by \(shift)")
            let above = try Self.yCbCrShift(
                Self.fullRangeFrame(y: 110, cb: 131, cr: 131), calibration)
            let below = try Self.yCbCrShift(
                Self.fullRangeFrame(y: 110, cb: 125, cr: 125), calibration)
            #expect(above[1] > below[1] + 1 && above[2] > below[2] + 1, "\(above) vs \(below)")
            // The same filters on Core Image's linear working values lift a dark grey by
            // several codes more: the mistake the code-value matching avoids.
            let dark = LiveFrameDecoding.image(try Self.fullRangeFrame(y: 32, cb: 128, cr: 128))
            let linear = try Self.renderedCodes(calibration.correctingCodes(dark))
            let expected = Self.model([32, 32, 32])
            print("grey 32: model \(expected), filters in linear working space \(linear)")
            #expect(!Self.near(linear, expected, 2), "linear-space correction rendered \(linear)")
        }

        /// A capture device of another make, or one whose USB identity could not be read, still
        /// decodes with the correction: a neutral grey moves as through the measured dongle.
        @Test func unknownOrUnreadableCaptureDeviceStillGetsTheCorrection() throws {
            let grey = try Self.fullRangeFrame(y: 128, cb: 128, cr: 128)
            for device in [Self.unknown, nil] {
                let shift = try Self.yCbCrShift(grey, .forDevice(device))
                #expect(
                    Self.near(shift, [1.0, 0.768, 1.125], 0.15),
                    "\(device?.description ?? "unread"): grey 128 moved by \(shift)")
            }
        }

        /// The camera's live-view JPEG decode takes no calibration and renders bit for bit as it
        /// did before calibrations existed: a BT.601 full-range frame prepared as the JPEG paths
        /// prepare it, through the 8-bit bitmap path both Wi-Fi decoders use.
        @Test func wifiJPEGDecodeIsByteIdenticalToBefore() throws {
            let context = CIContext(options: [.cacheIntermediates: false])
            let samples = [(16, 128, 128), (128, 128, 128), (90, 60, 200), (235, 128, 128)]
            for (y, cb, cr) in samples {
                let jpeg = Fixture.Bar(
                    name: "", video: (y, cb, cr), full: (y, cb, cr), rgb: (0, 0, 0))
                let frame = try Fixture.frame(
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 1280, height: 720,
                    bar: jpeg, matrix: nil)
                LiveFrameDecoding.prepareJPEGFrame(frame)
                let before = CIImage(
                    cvPixelBuffer: frame, options: [.colorSpace: LiveFrameDecoding.codeValueSpace])
                let beforeImage = try #require(
                    context.createCGImage(
                        before, from: before.extent, format: .RGBA8,
                        colorSpace: LiveFrameDecoding.codeValueSpace))
                let after = try #require(LiveFrameDecoding.cgImage(frame, context: context))
                #expect(try Self.bytes(after) == Self.bytes(beforeImage), "Y'CbCr \((y, cb, cr))")
            }
            let image = CIImage(color: .gray)
            let space = LiveFrameDecoding.codeValueSpace
            #expect(CaptureCalibration.identity.applied(to: image, codeValueSpace: space) === image)
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

        /// BT.709 full-range Y'CbCr of R'G'B' codes, all in 8-bit codes, chroma centred on 0.
        static func yCbCr(_ rgb: [Double]) -> [Double] {
            let (kr, kb) = (0.2126, 0.0722)
            let y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2]
            return [y, (rgb[2] - y) / (2 * (1 - kb)), (rgb[0] - y) / (2 * (1 - kr))]
        }

        static func rgb(_ ycc: [Double]) -> [Double] {
            let (kr, kb) = (0.2126, 0.0722)
            let r = ycc[0] + 2 * (1 - kr) * ycc[2]
            let b = ycc[0] + 2 * (1 - kb) * ycc[1]
            return [r, (ycc[0] - kr * r - kb * b) / (1 - kr - kb), b]
        }

        /// Full-range BT.709 Y'CbCr codes of an R'G'B' colour, as a frame stores them.
        static func fullRange709(_ rgb: (Int, Int, Int)) -> (Int, Int, Int) {
            let ycc = yCbCr([Double(rgb.0), Double(rgb.1), Double(rgb.2)])
            return (
                Int(ycc[0].rounded()), Int((ycc[1] + 128).rounded()), Int((ycc[2] + 128).rounded())
            )
        }

        /// The measured model of the HDMI capture correction, on 8-bit R'G'B' codes.
        static func model(_ codes: [Double]) -> [Double] {
            let ycc = yCbCr(codes)
            let cb = ycc[1] + 0.899 + 0.875 * tanh((ycc[1] - 0.226) / 1.5)
            let cr = 1.008 * ycc[2] + 0.900 + 0.751 * tanh((ycc[2] + 0.463) / 1.5)
            return rgb([ycc[0] + 1.0, cb, cr])
        }

        /// How far the correction moves `frame` in Y'CbCr codes.
        static func yCbCrShift(_ frame: CVPixelBuffer, _ calibration: CaptureCalibration) throws
            -> [Double]
        {
            let plain = yCbCr(try renderedCodes(LiveFrameDecoding.image(frame)))
            let corrected = yCbCr(
                try renderedCodes(LiveFrameDecoding.image(frame, calibration: calibration)))
            return zip(corrected, plain).map { $0 - $1 }
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
