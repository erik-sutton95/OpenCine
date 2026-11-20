#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
import OpenCineMedia
import Testing

@testable import OpenCineApple

/// The clean picture for an outgoing stream: the monitor's LUT look, never its assists.
/// SIMULATED frames.
@Suite struct MonitorCleanPictureTapTests {
    private static let width = 160
    private static let height = 90

    /// A BGRA buffer: red on the left, a fine grey ramp on the right (edges for peaking and zebra).
    private static func buffer() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * rowBytes + x * 4
                let grey = UInt8((x * 37 + y * 11) % 256)
                (base[o], base[o + 1], base[o + 2], base[o + 3]) = x < 40 ? (0, 0, 230, 255) : (grey, grey, grey, 255)
            }
        }
        return buffer
    }

    private static func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        return (0..<CVPixelBufferGetHeight(buffer)).flatMap { y in Array(UnsafeBufferPointer(start: base + y * rowBytes, count: width * 4)) }
    }

    private static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        let all = bytes(buffer)
        let i = (y * CVPixelBufferGetWidth(buffer) + x) * 4
        return (Int(all[i]), Int(all[i + 1]), Int(all[i + 2]))
    }

    private static func inverting() -> MonitorImageEffects {
        var rgb = [Float]()
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { rgb += [1 - Float(r), 1 - Float(g), 1 - Float(b)] } } }
        let cube = CubeLUT(size: 2, rgb: rgb)
        var effects = MonitorImageEffects()
        effects.lutDimension = cube.size
        effects.lutRGBA = cube.rgbaComponents.withUnsafeBytes { Data($0) }
        return effects
    }

    private static func withAssists(_ base: MonitorImageEffects) -> MonitorImageEffects {
        var effects = base
        effects.peaking = true
        effects.zebra = true
        effects.falseColor = true
        effects.splitComparison = true
        return effects
    }

    @Test func assistsNeverReachTheCleanPicture() throws {
        let tap = MonitorCleanPictureTap { _ in }
        let source = try Self.buffer()
        for base in [MonitorImageEffects(), Self.inverting()] {
            let clean = try #require(tap.render(source, effects: base))
            let assisted = try #require(tap.render(source, effects: Self.withAssists(base)))
            #expect(Self.bytes(assisted) == Self.bytes(clean))
        }
    }

    @Test func theLUTReachesTheCleanPicture() throws {
        let tap = MonitorCleanPictureTap { _ in }
        let source = try Self.buffer()
        let plain = try #require(tap.render(source, effects: MonitorImageEffects()))
        let graded = try #require(tap.render(source, effects: Self.inverting()))
        #expect(CVPixelBufferGetWidth(graded) == Self.width && CVPixelBufferGetHeight(graded) == Self.height)
        let red = Self.pixel(plain, x: 10, y: 45)
        #expect(red.r > 200 && red.g < 40 && red.b < 40)
        let inverted = Self.pixel(graded, x: 10, y: 45)
        #expect(inverted.r < 60 && inverted.g > 200 && inverted.b > 200)
    }

    /// A source that decodes to still images (a JPEG live view, a capture card's frames once drawn)
    /// gets the same clean look as a decoded buffer.
    @Test func aStillImageSourceGetsTheSameLook() throws {
        let tap = MonitorCleanPictureTap { _ in }
        let source = try Self.buffer()
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(source, options: nil, imageOut: &cgImage)
        let still = try #require(cgImage)
        let graded = try #require(tap.render(still, effects: Self.withAssists(Self.inverting())))
        #expect(CVPixelBufferGetWidth(graded) == Self.width && CVPixelBufferGetHeight(graded) == Self.height)
        let inverted = Self.pixel(graded, x: 10, y: 45)
        #expect(inverted.r < 60 && inverted.g > 200 && inverted.b > 200)
    }

    @Test func wideSourcesAreCapped() throws {
        let tap = MonitorCleanPictureTap(maxWidth: 80) { _ in }
        let out = try #require(tap.render(try Self.buffer(), effects: MonitorImageEffects()))
        #expect(CVPixelBufferGetWidth(out) == 80 && CVPixelBufferGetHeight(out) == 44)  // even sizes for the encoder
    }

    @Test func submittedFramesArriveWithTheirTime() async throws {
        let frames = AsyncStream<MonitorCleanFrame>.makeStream()
        let tap = MonitorCleanPictureTap { frames.continuation.yield($0) }
        tap.submit(try Self.buffer(), effects: Self.withAssists(MonitorImageEffects()), timeNs: 42)
        var iterator = frames.stream.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.timeNs == 42)
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == Self.width)
    }

    @Test func theEngineFeedsTheTapOnlyWhileOneIsSet() async throws {
        let engine = MonitorAssistEngine()
        let frames = AsyncStream<MonitorCleanFrame>.makeStream()
        let tap = MonitorCleanPictureTap { frames.continuation.yield($0) }
        let results = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        var policy = MonitorAssistPolicy()
        policy.image.peaking = true
        engine.setCleanPictureTap(tap)
        engine.submit(try Self.buffer(), effects: policy, transfer: .rec709, timeNs: 7) { results.continuation.yield($0) }
        var iterator = frames.stream.makeAsyncIterator()
        #expect(try #require(await iterator.next()).timeNs == 7)
        var resultIterator = results.stream.makeAsyncIterator()
        _ = await resultIterator.next()
    }
}
#endif
