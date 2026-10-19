#if os(iOS)
import MonitorPresentation
import SwiftUI
import XCTest

@testable import MonitorUI

/// Kotlin suite `MonitorStatusGlowRenderTest`. The live header readouts stay legible over a bright
/// picture through the shared readout glow, not an opaque bar. White readouts over a white picture
/// only show dark pixels where the glow draws them.
@MainActor
final class MonitorStatusGlowRenderingTests: XCTestCase {
    func testPortraitHeaderReadoutsCarryTheDarkGlowOverABrightPicture() throws {
        try assertGlow(FieldMonitorLayout(width: 440, height: 956, safeArea: .init(top: 62)), name: "portrait")
    }

    func testLandscapeHeaderReadoutsCarryTheDarkGlowOverABrightPicture() throws {
        try assertGlow(FieldMonitorLayout(width: 956, height: 440, safeArea: .init(leading: 62, trailing: 62)),
            name: "landscape")
    }

    private func assertGlow(_ layout: FieldMonitorLayout, name: String) throws {
        let fixture = ZStack(alignment: .topLeading) {
            Color.white
            MonitorStatusChrome(
                layout: layout, status: MonitorStatusPresentation(recording: false, timecode: "18:37:37:02")
            ) {
                Text("916 GB").font(MonitorTheme.font(14, weight: .medium))
            } format: {
                Text("6K 25p").font(MonitorTheme.font(layout.portrait ? 23 : 16, weight: .medium))
            } color: {
                Text("N-Log").font(MonitorTheme.font(16, weight: .medium))
            } mode: {
                EmptyView()
            } link: {
                EmptyView()
            }
            .foregroundStyle(.white)
            .frame(width: layout.status.width, alignment: .topLeading)
            .offset(x: layout.status.x, y: layout.status.y)
        }
        .frame(width: layout.viewport.width, height: layout.viewport.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "SIMULATED status glow \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let band = CGRect(
            x: layout.status.x, y: max(0, layout.status.y - 40), width: layout.status.width,
            height: layout.status.height + 80)
        let dark = try darkPixels(image, in: band.applying(CGAffineTransform(scaleX: 2, y: 2)))
        XCTAssertGreaterThan(dark, 200, "\(name): the header readouts lost their dark glow")
    }

    /// Pixels no brighter than 64 in any channel: only a glow can draw them over white.
    private func darkPixels(_ image: CGImage, in rect: CGRect) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var count = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let i = (y * image.width + x) * 4
                if max(bytes[i], bytes[i + 1], bytes[i + 2]) <= 64 { count += 1 }
            }
        }
        return count
    }
}
#endif
