#if canImport(CoreImage) && canImport(Metal)
import CoreGraphics
import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineApple

/// A still's picture assists: the photo viewer paints peaking, zebra and false colour on the
/// decoded still with the shared graph, and shows the still untouched when nothing is on.
/// SIMULATED stills: a bright left half beside a dark right half (one hard, in-focus edge).
@Suite struct MonitorStillLookRendererTests {
    private static let width = 96, height = 64

    private static func still() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value: UInt8 = x < width / 2 ? 250 : 30
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &out, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    private static func rec709Still() -> MonitorFrameEffects {
        var effects = MonitorFrameEffects()
        effects.transfer = .rec709; effects.clipByte = 255; effects.allowsTransferInference = false
        return effects
    }

    @Test func nothingOnShowsTheStillAsDecoded() throws {
        var effects = Self.rec709Still()
        effects.desqueezeFactor = 2; effects.mirror = true
        #expect(!MonitorStillLookRenderer.paints(effects))
        #expect(MonitorStillLookRenderer().render(try Self.still(), effects: effects) == nil)
    }

    @Test func peakingPaintsTheInFocusEdgeAndLeavesFlatAreas() throws {
        let still = try Self.still()
        var effects = Self.rec709Still()
        effects.peaking = true; effects.peakingColor = .red; effects.peakingSensitivity = .high
        let painted = try #require(MonitorStillLookRenderer().render(still, effects: effects))
        #expect(painted.width == still.width && painted.height == still.height)
        let before = try Self.pixels(still), after = try Self.pixels(painted)
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * Self.width + x) * 4; return Array(bytes[i..<(i + 3)])
        }
        let edge = (Self.width / 2 - 3)...(Self.width / 2 + 2)
        #expect(edge.contains { pixel(after, $0, Self.height / 2) != pixel(before, $0, Self.height / 2) },
            "The edge between the halves is painted")
        #expect(pixel(after, 8, Self.height / 2) == pixel(before, 8, Self.height / 2), "Flat bright area untouched")
        #expect(pixel(after, Self.width - 8, Self.height / 2) == pixel(before, Self.width - 8, Self.height / 2),
            "Flat dark area untouched")
    }

    @Test func zebraStripesTheBrightHalfOnly() throws {
        let still = try Self.still()
        var effects = Self.rec709Still()
        effects.zebra = true; effects.zebraHighlight = true; effects.zebraHighlightIRE = 90
        effects.zebraMidtone = false
        let painted = try #require(MonitorStillLookRenderer().render(still, effects: effects))
        let before = try Self.pixels(still), after = try Self.pixels(painted)
        func changed(columns: Range<Int>) -> Bool {
            for y in 0..<Self.height { for x in columns {
                let i = (y * Self.width + x) * 4
                if before[i..<(i + 3)] != after[i..<(i + 3)] { return true }
            } }
            return false
        }
        #expect(changed(columns: 4..<(Self.width / 2 - 4)), "Over 90 IRE is striped")
        #expect(!changed(columns: (Self.width / 2 + 4)..<(Self.width - 4)), "The dark half is not")
    }

    @Test func falseColourRepaintsTheWholeStill() throws {
        let still = try Self.still()
        var effects = Self.rec709Still()
        effects.falseColor = true; effects.falseColorScale = .ire
        let painted = try #require(MonitorStillLookRenderer().render(still, effects: effects))
        #expect(try Self.pixels(painted) != Self.pixels(still))
    }
}
#endif
