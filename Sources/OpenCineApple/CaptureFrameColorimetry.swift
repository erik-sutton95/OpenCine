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

        /// Writes the decoding matrix onto a YCbCr frame, so CoreImage and Metal consumers decode
        /// it alike. An RGB frame is already decoded and passes untouched.
        static func prepareForDisplay(_ pixelBuffer: CVPixelBuffer) {
            guard isYCbCr(CVPixelBufferGetPixelFormatType(pixelBuffer)) else { return }
            let tagged = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
            let matrix = decodingMatrix(
                tagged: tagged as? String, height: CVPixelBufferGetHeight(pixelBuffer))
            if tagged as? String != matrix {
                CVBufferSetAttachment(
                    pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
            }
        }

        /// The pixel format to ask the capture output for: the device's own YCbCr layout when the
        /// output can deliver it untouched, otherwise biplanar 4:2:0 in the device's range. Never
        /// RGB, which would let AVFoundation choose the matrix.
        static func outputPixelFormat(deviceFormat: OSType, available: [OSType]) -> OSType {
            if isYCbCr(deviceFormat), available.contains(deviceFormat) { return deviceFormat }
            let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // A motion-JPEG mode decodes to full range, as JPEG is.
            let fullRange =
                deviceFormat == full || deviceFormat == kCMVideoCodecType_JPEG
                || deviceFormat == kCMVideoCodecType_JPEG_OpenDML
            let preferred = fullRange ? full : video
            return available.contains(preferred) || available.isEmpty ? preferred : video
        }

        /// The four characters of a pixel format, for an operator readout (`420v`, not 875704438).
        static func fourCC(_ format: OSType) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "\0" } ? text : String(format)
        }
    }
#endif
