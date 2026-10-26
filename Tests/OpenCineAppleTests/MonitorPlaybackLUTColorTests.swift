#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
import CoreImage
import CoreVideo
import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineApple

/// The playback LUT reads the clip's encoded log codes: a Log3G10 18% grey through a Log3G10 to
/// Rec.709 cube lands on mid grey. OpenZCine build 317 drew a Nikon ZR RED Log3G10 clip (1920 px,
/// wider than the working raster) nearly black because the raster handed the cube linear light.
/// SIMULATED frames and a tiny analytic cube; no vendor LUT is bundled.
@Suite struct MonitorPlaybackLUTColorTests {
    /// RED Log3G10 (IPP2) decode to scene linear.
    static func log3G10Linear(_ code: Double) -> Double {
        (pow(10, code / 0.224282) - 1) / 155.975327 - 0.01
    }

    /// BT.709 / BT.1886 encode of display-referred linear.
    static func rec709(_ linear: Double) -> Double {
        let x = min(max(linear, 0), 1)
        return x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099
    }

    /// Log3G10 18% grey: 0.224282 * log10(155.975327 * (0.18 + 0.01)) = 0.3333.
    static let greyCode = 0.3333

    /// A small Log3G10 to Rec.709 cube with the RED IPP2 domain (0...1 Log3G10 in, Rec.709 out),
    /// without IPP2's tone map: 18% grey encodes to Rec.709 0.409.
    static func log3G10ToRec709Cube(size n: Int = 33) -> CubeLUT {
        var rgb = [Float]()
        rgb.reserveCapacity(n * n * n * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    for channel in [r, g, b] {
                        let code = Double(channel) / Double(n - 1)
                        rgb.append(Float(rec709(log3G10Linear(code))))
                    }
                }
            }
        }
        return CubeLUT(size: n, rgb: rgb)
    }

    /// A flat SIMULATED playback frame holding one encoded code, tagged as the clip is (BT.709).
    static func frame(width: Int, height: Int, format: OSType, code: Double) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &created)
                == kCVReturnSuccess, let buffer = created
        else { return nil }
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let scale = tenBit ? 4.0 : 1.0
        let luma = (fullRange ? code * 255 : 16 + 219 * code) * scale
        let chroma = 128 * scale
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let samples = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            let value = (plane == 0 ? luma : chroma).rounded()
            for row in 0..<rows {
                if tenBit {
                    let pointer = (base + row * stride).assumingMemoryBound(to: UInt16.self)
                    for index in 0..<samples { pointer[index] = UInt16(value) << 6 }
                } else {
                    let pointer = (base + row * stride).assumingMemoryBound(to: UInt8.self)
                    for index in 0..<samples { pointer[index] = UInt8(value) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate)
        return buffer
    }

    /// The playback picture's LUT graph for one pulled frame: the feed's working raster, the
    /// engine's encoded camera codes, the compositor's cube and the baker's unmanaged context.
    /// Returns the centre green as 0...1.
    static func gradedCentre(_ buffer: CVPixelBuffer, cube: CubeLUT) -> Double? {
        let working = MonitorWorkingRaster().prepared(buffer)
        var effects = MonitorImageEffects()
        let gpu = cube.colorCube
        effects.lutDimension = gpu.size
        effects.lutRGBA = gpu.rgbaComponents.withUnsafeBytes { Data($0) }
        let codes = CIImage(cvPixelBuffer: working, options: MonitorWorkingSpace.imageOptions)
        let product = MonitorImageCompositor.applyProduct(
            to: codes, effects: effects, display: CIImage(cvPixelBuffer: working))
        guard product.unmanagedBake else { return nil }
        let extent = product.image.extent
        let context = CIContext(options: MonitorWorkingSpace.contextOptions)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            product.image, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: extent.midX.rounded(), y: extent.midY.rounded(), width: 1, height: 1),
            format: .RGBA8, colorSpace: MonitorWorkingSpace.metalDestination)
        return Double(pixel[1]) / 255
    }

    @Test func theAnalyticCubeMapsLog3G10GreyToRec709MidGrey() {
        let cube = Self.log3G10ToRec709Cube()
        let grey = cube.map(red: Float(Self.greyCode), green: Float(Self.greyCode), blue: Float(Self.greyCode))
        #expect(abs(Double(grey.green) - 0.409) < 0.01)
        #expect(abs(Self.log3G10Linear(Self.greyCode) - 0.18) < 0.001)
    }

    /// The owner's clip shape (1920x1080 8-bit full range), a 10-bit UHD clip and a frame
    /// narrower than the working raster: each grades 18% grey to mid grey, never near black.
    @Test(arguments: [
        (1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (3840, 2160, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        (1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ])
    func log3G10GreyGradesToMidGreyOnPlayback(width: Int, height: Int, format: OSType) throws {
        let buffer = try #require(
            Self.frame(width: width, height: height, format: format, code: Self.greyCode))
        let graded = try #require(Self.gradedCentre(buffer, cube: Self.log3G10ToRec709Cube()))
        // Rec.709 0.409 for 18% grey; linearized input put it at about 0.03.
        #expect(abs(graded - 0.409) < 0.03, "18% grey graded to \(graded)")
    }

    /// Brighter and darker log codes keep their order and their stops through the cube.
    @Test func log3G10StopsAroundGreyGradeInOrder() throws {
        let cube = Self.log3G10ToRec709Cube()
        var previous = -1.0
        for stops in [-2.0, -1, 0, 1, 2] {
            let linear = 0.18 * pow(2, stops)
            let code = 0.224282 * log10(155.975327 * (linear + 0.01))
            let buffer = try #require(
                Self.frame(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, code: code))
            let graded = try #require(Self.gradedCentre(buffer, cube: cube))
            #expect(abs(graded - Self.rec709(linear)) < 0.035, "\(stops) stops graded to \(graded)")
            #expect(graded > previous)
            previous = graded
        }
    }
}
#endif
