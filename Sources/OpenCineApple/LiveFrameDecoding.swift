#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreMedia)
    import CoreGraphics
    import CoreImage
    import CoreVideo

    /// How a live camera frame becomes RGB: as the R'G'B' code values the camera encoded, and
    /// nothing else.
    ///
    /// A live frame is an HDMI capture buffer or the camera's live-view JPEG decoded in hardware.
    /// Either carries the camera's own encoding (a log curve such as Log3G10, D-Log M or I-Log,
    /// or BT.709), and every look, scope and exposure tool of the monitor reads those codes as they
    /// are. The only conversion that belongs between the frame and the monitor is Y'CbCr to
    /// R'G'B', with the frame's matrix (``CaptureFrameColorimetry`` decides it for HDMI, JFIF fixes
    /// BT.601 for a JPEG) and the range its pixel format states.
    ///
    /// Core Image colour-manages a `CIImage(cvPixelBuffer:)` from whatever colour the frame claims,
    /// and a live frame's claims are guesses: a UVC capture device without a colour matching
    /// descriptor reports the class default BT.709 transfer and primaries, the iPad's capture
    /// pipeline writes its own colour space (an nclc ICC profile, BT.709 primaries with a SMPTE
    /// 240M transfer) onto the frame's IOSurface, where Core Image finds it even after the
    /// CoreVideo attachments are gone, and VideoToolbox tags an untagged JPEG with NTSC colour
    /// (SMPTE C primaries, BT.709 transfer). Each made Core Image re-encode the codes before any
    /// look saw them: on device HDMI code 128 showed as 138.5 and the JPEG lifted its mids.
    ///
    /// So a live frame is read in the colour space it is rendered into: Core Image linearises
    /// with exactly the curve it encodes with on the way out, and the codes come back unchanged
    /// whatever the frame, its attachments or its IOSurface claim.
    public enum LiveFrameDecoding {
        /// The colour space decoded live frames are rendered into and tagged with: sRGB, which is
        /// what an untagged JPEG decodes as through ImageIO, so both Wi-Fi decode paths agree.
        public static let codeValueSpace: CGColorSpace =
            CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        /// A Core Image view of `frame` whose pixels, rendered into `outputSpace`, are the frame's
        /// R'G'B' code values. Pass the space of the render that consumes the image.
        ///
        /// `calibration` is the capture device's measured correction (``CaptureCalibration``),
        /// applied to those code values; only an HDMI capture frame passes one. The default,
        /// ``CaptureCalibration/identity``, adds nothing to the render.
        public static func image(
            _ frame: CVPixelBuffer, renderedInto outputSpace: CGColorSpace = codeValueSpace,
            calibration: CaptureCalibration = .identity
        ) -> CIImage {
            calibration.applied(
                to: CIImage(cvPixelBuffer: frame, options: [.colorSpace: outputSpace]),
                codeValueSpace: outputSpace)
        }

        /// `frame` rendered to an 8-bit bitmap of its R'G'B' code values, tagged
        /// ``codeValueSpace``, with `calibration` applied to them. Nil when the render fails.
        public static func cgImage(
            _ frame: CVPixelBuffer, context: CIContext, calibration: CaptureCalibration = .identity
        ) -> CGImage? {
            let image = image(frame, calibration: calibration)
            return context.createCGImage(
                image, from: image.extent, format: .RGBA8, colorSpace: codeValueSpace)
        }

        /// Prepares a decoded live-view JPEG frame: a JPEG is JFIF, Y'CbCr in BT.601 whatever its
        /// size, so a YCbCr frame decodes with that matrix, and the colour the decoder guessed for
        /// it (primaries, transfer, gamma, profile) is dropped, as it is from an HDMI frame.
        public static func prepareJPEGFrame(_ frame: CVPixelBuffer) {
            guard CaptureFrameColorimetry.isYCbCr(CVPixelBufferGetPixelFormatType(frame)) else {
                return
            }
            for key in CaptureFrameColorimetry.codeValueClaims {
                CVBufferRemoveAttachment(frame, key)
            }
            CVBufferSetAttachment(
                frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                .shouldPropagate)
        }
    }
#endif
