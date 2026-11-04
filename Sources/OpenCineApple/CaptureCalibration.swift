#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreMedia)
    import CoreGraphics
    import CoreImage
    import Foundation

    /// The USB identity of an HDMI capture device: its vendor and product IDs.
    ///
    /// AVFoundation reports a UVC device's IDs inside its model ID, in decimal:
    /// `"UVC Camera VendorID_13407 ProductID_8496"` (read on macOS from an attached UVC device).
    public struct CaptureDeviceIdentity: Hashable, Sendable, CustomStringConvertible {
        public let vendorID: UInt16
        public let productID: UInt16

        public init(vendorID: UInt16, productID: UInt16) {
            self.vendorID = vendorID
            self.productID = productID
        }

        /// The identity named in a capture device's model or unique ID, or nil when the text
        /// carries no `VendorID_<n>` and `ProductID_<n>` pair (decimal, or hex with `0x`).
        public init?(deviceIdentifier: String) {
            func value(after label: String) -> UInt16? {
                guard let start = deviceIdentifier.range(of: label)?.upperBound else { return nil }
                let digits = deviceIdentifier[start...].prefix { $0.isHexDigit || $0 == "x" }
                if digits.hasPrefix("0x") { return UInt16(digits.dropFirst(2), radix: 16) }
                return UInt16(digits, radix: 10)
            }
            guard let vendor = value(after: "VendorID_"), let product = value(after: "ProductID_")
            else { return nil }
            self.init(vendorID: vendor, productID: product)
        }

        /// `345F:2130`, the form USB tools print.
        public var description: String {
            String(format: "%04X:%04X", vendorID, productID)
        }
    }

    /// One channel's correction in BT.709 Y'CbCr, in 8-bit code units (chroma centred on 0):
    /// `out = gain * x + offset + amplitude * tanh((x - centre) / width)`.
    ///
    /// The tanh term models a sign-dependent offset: it moves values on one side of `centre` by
    /// up to `amplitude` more than those on the other, with a slope bounded by
    /// `gain + amplitude / width`, so noise near neutral is not amplified without limit.
    public struct CaptureChannelCurve: Equatable, Sendable {
        public let gain: Double
        public let offset: Double
        public let amplitude: Double
        public let centre: Double
        public let width: Double

        public init(
            gain: Double = 1, offset: Double = 0, amplitude: Double = 0, centre: Double = 0,
            width: Double = 1
        ) {
            self.gain = gain
            self.offset = offset
            self.amplitude = amplitude
            self.centre = centre
            self.width = width
        }

        /// No change.
        public static let identity = CaptureChannelCurve()

        /// The corrected value of `x`, both in 8-bit code units.
        public func callAsFunction(_ x: Double) -> Double {
            gain * x + offset + amplitude * tanh((x - centre) / width)
        }
    }

    /// A measured colour correction for HDMI capture frames, applied to the frame's R'G'B' code
    /// values as they come out of ``LiveFrameDecoding``.
    ///
    /// The codes are taken to BT.709 full-range Y'CbCr (Kr 0.2126, Kb 0.0722, chroma centred on
    /// 0, in 8-bit code units), each channel goes through its ``CaptureChannelCurve``, and the
    /// result returns to R'G'B'. The chroma curves are nonlinear, so no colour matrix can stand in
    /// for them, and their action lies within about 2 codes of neutral, finer than a 3D lookup
    /// cube resolves.
    ///
    /// The correction belongs to the capture chain, not to the picture: one curve per channel
    /// fits three picture profiles, so it is a fixed property of the HDMI path. It only ever
    /// applies to an HDMI capture frame; the camera's own live-view JPEG is the reference it is
    /// measured against and is never corrected.
    ///
    /// It works on gamma-encoded code values, never on Core Image's linear working values: the
    /// same operations inside a default render would run in linear extended sRGB, where a 1-code
    /// luma offset lifts a dark grey by several codes.
    public struct CaptureCalibration: Equatable, Sendable {
        /// Y' (luma).
        public let luma: CaptureChannelCurve
        /// Cb (blue difference).
        public let blueDifference: CaptureChannelCurve
        /// Cr (red difference).
        public let redDifference: CaptureChannelCurve
        /// The curves sampled for `CIColorCurves`, built once.
        private let table: Data

        public init(
            luma: CaptureChannelCurve, blueDifference: CaptureChannelCurve,
            redDifference: CaptureChannelCurve
        ) {
            self.luma = luma
            self.blueDifference = blueDifference
            self.redDifference = redDifference
            self.table = Self.sampledTable(luma, blueDifference, redDifference)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.luma == rhs.luma && lhs.blueDifference == rhs.blueDifference
                && lhs.redDifference == rhs.redDifference
        }

        /// No correction: the frame's codes as they are.
        public static let identity = CaptureCalibration(
            luma: .identity, blueDifference: .identity, redDifference: .identity)

        public var isIdentity: Bool { self == .identity }

        /// The correction for a frame from a UVC capture device: ``uvcHDMICapture`` for every
        /// device, whatever its USB identity and whether or not that identity could be read.
        /// The identity stays in the signature for the readout and for a known-good exception,
        /// should a device ever measure clean.
        public static func forDevice(_ device: CaptureDeviceIdentity?) -> CaptureCalibration {
            .uvcHDMICapture
        }

        /// The correction for a YCbCr HDMI signal through a USB (UVC) capture device.
        ///
        /// Fitted on one dongle (SandbergCapture, MacroSilicon, USB 345F:2130), and applied to
        /// every UVC capture device: four or five different USB-C capture dongles used with the
        /// camera over time all showed the same tint, so the bias belongs to the HDMI YCbCr
        /// chain, not to one device.
        ///
        /// Measured on 2026-11-01 on a Calibrite ColorChecker Video, LUT off, in three picture
        /// profiles (SDR, N-Log, Log3G10), against in-camera recordings of the same card (ProRes
        /// 422 HQ N-Log, and R3D Log3G10 through REDline). The Wi-Fi live view's chroma tracks
        /// the recordings. The HDMI chroma error is not a gain but a sign-dependent offset:
        /// positive Cb and Cr lose about 1.8 codes, negative ones about none. Flat log pictures
        /// (median |chroma| 2 to 4 codes) suffer far more than SDR: with the Log3G10 look on,
        /// HDMI against Wi-Fi had a chroma gain of 0.87 even after a linear correction.
        ///
        /// One curve per chroma channel, fitted on all three profiles, predicts the Wi-Fi chroma
        /// from the raw HDMI chroma with residuals of 0.14 to 0.28 code (N-Log Cr 0.57), where
        /// the earlier linear correction left 0.5 to 0.7. Both curves are monotonic, with a slope
        /// of at most about 1.6. A neutral grey gets Y' + 1.0, Cb' + 0.77, Cr' + 1.13 codes.
        ///
        /// The same dongle fed RGB HDMI from a Mac measured unbiased (greys at Cb = Cr = 128), so
        /// the bias is either the camera's YCbCr HDMI output or the dongle's YCbCr input path;
        /// this kit cannot separate the two. Evidence: OpenCine-Parity
        /// `evidence/hardware-pass-20261024/RESULTS.md`, "HDMI dongle characterisation" to the
        /// in-camera ground truth, and the pooled fit `dongle/cc/pool.py` (BUG-Z-HDMI-GREEN-TINT).
        public static let uvcHDMICapture = CaptureCalibration(
            luma: CaptureChannelCurve(offset: 1.0),
            blueDifference: CaptureChannelCurve(
                gain: 1.0, offset: 0.899, amplitude: 0.875, centre: 0.226, width: 1.5),
            redDifference: CaptureChannelCurve(
                gain: 1.008, offset: 0.900, amplitude: 0.751, centre: -0.463, width: 1.5))

        // MARK: - Core Image

        static let kr = 0.2126
        static let kb = 0.0722
        static let kg = 1 - kr - kb

        /// The curve table's domain, in normalised `(Y', Cb + 0.5, Cr + 0.5)`: wider than 0...1
        /// so super-white and sub-black luma pass rather than clamp.
        static let tableDomain = (lower: -0.25, upper: 1.25)
        /// Entries per channel: about 0.19 code apart, so linear interpolation between them is
        /// exact to well under a hundredth of a code on these curves.
        static let tableSize = 2048

        /// `CIColorCurves` data: `tableSize` float triples `(Y', Cb + 0.5, Cr + 0.5)` across
        /// `tableDomain`.
        static func sampledTable(
            _ luma: CaptureChannelCurve, _ cb: CaptureChannelCurve, _ cr: CaptureChannelCurve
        ) -> Data {
            var values = [Float]()
            values.reserveCapacity(tableSize * 3)
            let (lower, upper) = tableDomain
            for index in 0..<tableSize {
                let x = lower + (upper - lower) * Double(index) / Double(tableSize - 1)
                values.append(Float(luma(x * 255) / 255))
                values.append(Float(cb((x - 0.5) * 255) / 255 + 0.5))
                values.append(Float(cr((x - 0.5) * 255) / 255 + 0.5))
            }
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        /// The correction as three Core Image filters on values that are already code values:
        /// R'G'B' to `(Y', Cb + 0.5, Cr + 0.5)`, the per-channel curves, and back. None converts
        /// colour (`CIColorCurves` is given no colour space), so the curves see the codes.
        func correctingCodes(_ codes: CIImage) -> CIImage {
            let (kr, kg, kb) = (Self.kr, Self.kg, Self.kb)
            let toYCbCr = codes.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: kr, y: kg, z: kb, w: 0),
                    "inputGVector": CIVector(
                        x: -kr / (2 * (1 - kb)), y: -kg / (2 * (1 - kb)), z: 0.5, w: 0),
                    "inputBVector": CIVector(
                        x: 0.5, y: -kg / (2 * (1 - kr)), z: -kb / (2 * (1 - kr)), w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0.5, z: 0.5, w: 0),
                ])
            let domain = Self.tableDomain
            let curved = toYCbCr.applyingFilter(
                "CIColorCurves",
                parameters: [
                    "inputCurvesData": table,
                    "inputCurvesDomain": CIVector(x: domain.lower, y: domain.upper),
                    "inputColorSpace": NSNull(),
                ])
            // R' = Y' + 2(1 - Kr) Cr, B' = Y' + 2(1 - Kb) Cb and
            // G' = Y' - (2 Kr (1 - Kr) Cr + 2 Kb (1 - Kb) Cb) / Kg, the 0.5 chroma offsets folded
            // into the bias.
            let crToG = 2 * kr * (1 - kr) / kg
            let cbToG = 2 * kb * (1 - kb) / kg
            return curved.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 2 * (1 - kr), w: 0),
                    "inputGVector": CIVector(x: 1, y: -cbToG, z: -crToG, w: 0),
                    "inputBVector": CIVector(x: 1, y: 2 * (1 - kb), z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(
                        x: -(1 - kr), y: (cbToG + crToG) / 2, z: -(1 - kb), w: 0),
                ])
        }

        /// `image` with the correction applied to its code values as seen in `codeValueSpace`.
        ///
        /// Core Image holds pixels as linear working values; the image is matched out of the
        /// working space into `codeValueSpace` (its codes), corrected there and matched back. All
        /// of it runs on the GPU inside the render that consumes the image, with no extra pass
        /// over the frame on the CPU. ``identity`` returns `image` itself.
        public func applied(to image: CIImage, codeValueSpace: CGColorSpace) -> CIImage {
            guard !isIdentity, let codes = image.matchedFromWorkingSpace(to: codeValueSpace)
            else { return image }
            return correctingCodes(codes).matchedToWorkingSpace(from: codeValueSpace) ?? image
        }
    }
#endif
