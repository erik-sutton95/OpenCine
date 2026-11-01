#if canImport(CoreVideo) && canImport(CoreMedia)
    import CoreMedia
    import CoreVideo
    import Foundation

    /// How a captured HDMI frame's YCbCr samples become RGB.
    ///
    /// HDMI carries high definition as BT.709 and standard definition as BT.601 (CTA-861). A UVC
    /// capture device without a colour matching descriptor is reported with the class default
    /// matrix, SMPTE 170M (BT.601), whatever the signal is, and an untagged buffer decodes with
    /// whichever default the converter has: CoreVideo's pixel transfer (what AVFoundation uses to
    /// hand out RGB) takes BT.601, CoreImage takes BT.709 for `420v` and BT.601 for the other
    /// layouts. Decoding a BT.709 signal as BT.601 throws every saturated colour toward green
    /// (a 75% green bar renders at 223 instead of 191, a 75% red bar at 174 instead of 191).
    ///
    /// So the capture source never asks AVFoundation for RGB. It takes the device's own YCbCr
    /// frames and writes the matrix decided here onto each one, and every consumer (CoreImage,
    /// Metal) decodes with that one answer. [verify-on-HW] whether a given dongle tags at all.
    ///
    /// The matrix is the only colour decision a frame carries. Its transfer and primaries are
    /// not the signal's (see ``prepareForDisplay(_:)``), and the iPad's capture IOSurface carries
    /// a colour space of its own that no CoreVideo attachment controls, so a frame becomes RGB
    /// only through ``LiveFrameDecoding``, which ignores every colour claim but the matrix.
    enum CaptureFrameColorimetry {
        /// Frames this tall or taller are high definition.
        static let highDefinitionHeight = 720

        /// The YCbCr matrix a frame decodes with, from its own tag and its height.
        ///
        /// An explicit BT.709, BT.2020 or SMPTE 240M tag is the device's claim and is kept. BT.601
        /// or no tag on a high-definition frame is the UVC class default, not a claim about the
        /// signal, so it decodes as HDMI's HD encoding, BT.709. Standard definition keeps BT.601.
        static func decodingMatrix(tagged: String?, height: Int) -> String {
            let bt601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
            if let tagged, tagged != bt601 { return tagged }
            return height >= highDefinitionHeight
                ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String : bt601
        }

        /// Whether `format` carries YCbCr samples (as opposed to RGB).
        static func isYCbCr(_ format: OSType) -> Bool {
            guard
                let description = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, format)
                    as? [String: Any]
            else { return false }
            return description[kCVPixelFormatContainsYCbCr as String] as? Bool ?? false
        }

        /// Colour claims a monitor frame must not carry: each makes a colour-managed decode
        /// convert the signal's code values into another encoding before any look sees them.
        static var codeValueClaims: [CFString] {
            [
                kCVImageBufferTransferFunctionKey, kCVImageBufferColorPrimariesKey,
                kCVImageBufferGammaLevelKey, kCVImageBufferICCProfileKey,
                kCVImageBufferCGColorSpaceKey,
            ]
        }

        /// Writes the decoding matrix onto a YCbCr frame, so CoreImage and Metal consumers decode
        /// it alike, and drops its transfer, primaries, gamma, ICC and colour space attachments
        /// once the readout has recorded them. An RGB frame is already decoded and passes untouched.
        ///
        /// Every look, scope and exposure tool of the monitor reads code values: a camera LUT
        /// expects the log codes the camera encoded, as the camera's own JPEG live view delivers
        /// them. A UVC device without a colour matching descriptor claims the class default
        /// BT.709 transfer and primaries whatever the signal is, and Core Image honours a transfer
        /// claim by re-encoding BT.709 to sRGB.
        ///
        /// Dropping the attachments is not enough on its own. On the iPad the capture pipeline
        /// also writes `kIOSurfaceColorSpace` onto the frame's IOSurface (an nclc ICC profile:
        /// BT.709 primaries and matrix, SMPTE 240M transfer), this leaves it in place, and a
        /// plain `CIImage(cvPixelBuffer:)` falls back to it: a 240M to sRGB re-encode that showed
        /// code 128 as 138.5 and 64 as 72.3 through the dongle. The simulator writes no surface
        /// colour space. Consumers therefore decode with ``LiveFrameDecoding``, which reads the
        /// frame in the space it renders into and so yields the signal's codes whatever the
        /// surface says.
        static func prepareForDisplay(_ pixelBuffer: CVPixelBuffer) {
            guard isYCbCr(CVPixelBufferGetPixelFormatType(pixelBuffer)) else { return }
            for key in codeValueClaims { CVBufferRemoveAttachment(pixelBuffer, key) }
            let tagged = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
            let matrix = decodingMatrix(
                tagged: tagged as? String, height: CVPixelBufferGetHeight(pixelBuffer))
            if tagged as? String != matrix {
                CVBufferSetAttachment(
                    pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
            }
        }

        /// The pixel format to ask the capture output for: the device's own YCbCr layout when the
        /// output can deliver it untouched, otherwise biplanar 4:2:0 in the device's range, then
        /// any other offered YCbCr layout. RGB, which lets AVFoundation choose the matrix, only
        /// when the output offers nothing else: asking for a format it doesn't offer throws.
        static func outputPixelFormat(deviceFormat: OSType, available: [OSType]) -> OSType {
            if isYCbCr(deviceFormat), available.contains(deviceFormat) { return deviceFormat }
            let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // A motion-JPEG mode decodes to full range, as JPEG is.
            let fullRange =
                deviceFormat == full || deviceFormat == kCMVideoCodecType_JPEG
                || deviceFormat == kCMVideoCodecType_JPEG_OpenDML
            let preferred = fullRange ? full : video
            if available.isEmpty || available.contains(preferred) { return preferred }
            return [video, full].first(where: available.contains)
                ?? available.first(where: isYCbCr) ?? available[0]
        }

        /// The four characters of a pixel format, for an operator readout (`420v`, not 875704438).
        static func fourCC(_ format: OSType) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "\0" } ? text : String(format)
        }
    }
#endif
