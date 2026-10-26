#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
    import CoreVideo
    import OpenCineMedia
    import XCTest

    @testable import OpenCineApple

    /// A wide source (a UHD clip from the playback output) is scaled onto the working raster
    /// before the assists read it. Scaling must keep the encoded camera codes: zebra, false
    /// colour, the LUT cube and the scopes all read them as the source's signal.
    final class MonitorWorkingRasterCodesTests: XCTestCase {
        private func videoRangeBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            XCTAssertEqual(
                CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary,
                    &buffer), kCVReturnSuccess)
            let value = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(value, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(value, 0)!
            memset(y, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(value, 0) * height)
            let uv = CVPixelBufferGetBaseAddressOfPlane(value, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(value, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(value, [])
            CVBufferSetAttachment(
                value, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(
                value, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                value, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate)
            return value
        }

        private func centreGreen(_ buffer: CVPixelBuffer) -> Int {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let row = CVPixelBufferGetHeight(buffer) / 2
            let column = CVPixelBufferGetWidth(buffer) / 2
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            return Int(base[row * CVPixelBufferGetBytesPerRow(buffer) + column * 4 + 1])
        }

        func testScalingAWideSourceKeepsItsEncodedCodes() throws {
            // Video-range Y 126 is full-range code (126 - 16) * 255 / 219 = 128.
            let source = try videoRangeBuffer(width: 2880, height: 1620, luma: 126)
            let working = MonitorWorkingRaster().prepared(source)
            XCTAssertEqual(CVPixelBufferGetWidth(working), FeedPresentPolicy.maxWorkingWidth)
            XCTAssertEqual(centreGreen(working), 128, accuracy: 2)
            // The identity picture reads the raster through the source's own transfer.
            let transfer = CVBufferCopyAttachment(working, kCVImageBufferTransferFunctionKey, nil)
            XCTAssertEqual(transfer as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        }
    }
#endif
