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

    /// A measured colour correction for one HDMI capture device, applied to the frame's R'G'B'
    /// code values as they come out of ``LiveFrameDecoding``: `out = matrix * in + offset`, with
    /// codes normalised to 0...1.
    ///
    /// The correction belongs to the capture chain, not to the picture: it was fitted on one
    /// picture profile and held unchanged on another, so it is a fixed property of the HDMI path.
    /// It only ever applies to an HDMI capture frame; the camera's own live-view JPEG is the
    /// reference it is measured against and is never corrected.
    ///
    /// It works on gamma-encoded code values, never on Core Image's linear working values: a
    /// colour matrix inside a default render would run in linear extended sRGB, where the same
    /// offset lifts black by about 24 codes instead of 2.4.
    public struct CaptureCalibration: Equatable, Sendable {
        /// Rows of the 3x3 matrix applied to normalised (R', G', B').
        public let red: SIMD3<Double>
        public let green: SIMD3<Double>
        public let blue: SIMD3<Double>
        /// Added after the matrix, in normalised code values (1/255 is one 8-bit code).
        public let offset: SIMD3<Double>

        public init(
            red: SIMD3<Double>, green: SIMD3<Double>, blue: SIMD3<Double>, offset: SIMD3<Double>
        ) {
            self.red = red
            self.green = green
            self.blue = blue
            self.offset = offset
        }

        /// No correction: the frame's codes as they are.
        public static let identity = CaptureCalibration(
            red: [1, 0, 0], green: [0, 1, 0], blue: [0, 0, 1], offset: [0, 0, 0])

        public var isIdentity: Bool { self == .identity }

        /// The correction for `device`. A device without a measured entry, or one whose identity
        /// could not be read, gets ``identity`` and renders exactly as before.
        public static func forDevice(_ device: CaptureDeviceIdentity?) -> CaptureCalibration {
            device.flatMap { measured[$0] } ?? .identity
        }

        /// Measured corrections, by capture device.
        static let measured: [CaptureDeviceIdentity: CaptureCalibration] = [
            CaptureDeviceIdentity(vendorID: 0x345F, productID: 0x2130): .yCbCrHDMIChroma
        ]

        /// SandbergCapture HDMI to USB dongle (MacroSilicon, USB 345F:2130), with a YCbCr HDMI
        /// signal from the camera.
        ///
        /// Measured on 2026-11-01 against ground truth: an in-camera ProRes 422 HQ recording of a
        /// ColorChecker Video in a log profile (decoded BT.709 limited range, no transfer change),
        /// beside the HDMI and Wi-Fi live views of the same card, LUT off. The Wi-Fi feed's chroma
        /// matches the recording (residual 0.2 code). The HDMI feed sits about 1 code toward green
        /// and is slightly desaturated in Cr: Cb/Cr offsets -0.70/-0.86, gains 0.987/0.943.
        ///
        /// The correction, in BT.709 Y'CbCr 8-bit full-scale units, is Y + 1.0,
        /// Cb' = (Cb + 0.70) / 0.987, Cr' = (Cr + 0.86) / 0.943, written here as the equivalent
        /// R'G'B' affine. Fitted on the log recording, validated on an independent SDR pair: HDMI
        /// against Wi-Fi went from RMS 2.82 to 1.10 codes, mean RGB difference (-3.8, -0.9, -2.2)
        /// to (-0.5, -0.7, -0.1). A neutral grey moves by about +2.4, +0.4, +2.3 codes.
        ///
        /// The same dongle fed RGB HDMI from a Mac measured unbiased (greys at Cb = Cr = 128), so
        /// the bias is either the camera's YCbCr HDMI output or the dongle's YCbCr input path;
        /// this kit cannot separate the two. Evidence: OpenCine-Parity
        /// `evidence/hardware-pass-20261024/RESULTS.md`, "HDMI dongle characterisation" to the
        /// in-camera ground truth (BUG-Z-HDMI-GREEN-TINT).
        static let yCbCrHDMIChroma = CaptureCalibration(
            red: [1.047595, -0.043231, -0.004364],
            green: [-0.013865, 1.013802, 0.000064],
            blue: [-0.002800, -0.009420, 1.012220],
            offset: [0.009554, 0.001726, 0.009082])

        /// `image` with the correction applied to its code values as seen in `codeValueSpace`.
        ///
        /// Core Image holds pixels as linear working values; the image is matched out of the
        /// working space into `codeValueSpace` (its codes), the matrix runs on those codes, and the
        /// result is matched back. The three are colour kernels Core Image concatenates into the
        /// render's own pass, so the cost is a few arithmetic operations per pixel and no extra
        /// pass over the frame. ``identity`` returns `image` itself.
        public func applied(to image: CIImage, codeValueSpace: CGColorSpace) -> CIImage {
            guard !isIdentity, let codes = image.matchedFromWorkingSpace(to: codeValueSpace)
            else { return image }
            func vector(_ row: SIMD3<Double>) -> CIVector {
                CIVector(x: row.x, y: row.y, z: row.z, w: 0)
            }
            let corrected = codes.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": vector(red), "inputGVector": vector(green),
                    "inputBVector": vector(blue), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: offset.x, y: offset.y, z: offset.z, w: 0),
                ])
            return corrected.matchedToWorkingSpace(from: codeValueSpace) ?? image
        }
    }
#endif
