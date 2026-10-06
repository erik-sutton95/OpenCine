#if os(iOS)
    import SwiftUI
    import XCTest

    @testable import MonitorUI

    /// Moved from both iOS apps' MonitorReadoutRenderingTests: the held drum and the rasterized
    /// readout shadow. The status chrome case renders each app's model and stays there.
    @MainActor
    final class MonitorReadoutRenderingTests: XCTestCase {
        func testHeldDrumPreservesEnabledContrastWhileDisabledChoicesRemainDim() throws {
            func pixels(interactive: Bool, preview: Double?) throws -> [UInt8] {
                let renderer = ImageRenderer(
                    content: MonitorValueDrum(
                        options: ["AF-S", "AF-C", "Showcase"], selection: .constant("AF-C"),
                        isInteractive: interactive, haptics: false, previewPosition: preview
                    )
                    .frame(width: 420, height: 86)
                    .background(Color.black))
                renderer.scale = 1
                return try rgba(XCTUnwrap(renderer.cgImage))
            }
            let enabled = try pixels(interactive: true, preview: nil)
            let preview = try pixels(interactive: false, preview: 1)
            let disabled = try pixels(interactive: false, preview: nil)
            XCTAssertEqual(preview, enabled, "A read-only held preview is an active adjustment")
            let rgb = enabled.indices.filter { $0 % 4 != 3 }
            let enabledBrightness = rgb.reduce(0) { $0 + Int(enabled[$1]) }
            let disabledBrightness = rgb.reduce(0) { $0 + Int(disabled[$1]) }
            XCTAssertLessThan(disabledBrightness, enabledBrightness / 2)
        }

        func testRasterizedReadoutsPreserveGlyphsAndShadowSpread() throws {
            for background in [Color.black, .white, .cyan] {
                let original = try pixels(background: background, optimized: false)
                let optimized = try pixels(background: background, optimized: true)
                let differences = zip(original, optimized).map { abs(Int($0) - Int($1)) }
                let mean = Double(differences.reduce(0, +)) / Double(differences.count)
                XCTAssertLessThan(
                    mean, 1, "Rasterization must preserve the approved readout appearance")
                XCTAssertLessThan(
                    Double(differences.filter { $0 > 8 }.count) / Double(differences.count), 0.01,
                    "Glyph edges and the tight shadow must retain their shape")
            }
        }

        private func pixels(background: Color, optimized: Bool) throws -> [UInt8] {
            let renderer = ImageRenderer(
                content: ZStack {
                    background
                    if optimized {
                        readout.monitorReadoutShadow()
                    } else {
                        readout
                            .shadow(color: .black, radius: 1.5)
                            .shadow(color: .black.opacity(0.92), radius: 2.5)
                            .shadow(color: .black.opacity(0.85), radius: 1, y: 1)
                    }
                }
                .frame(width: 200, height: 80))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            return try rgba(image)
        }

        private func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &bytes, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }

        private var readout: some View {
            VStack(spacing: 3) {
                Text("4K · 25p").font(MonitorTheme.font(16, weight: .semibold))
                Text("FORMAT").font(MonitorTheme.font(9)).tracking(1)
            }
            .foregroundStyle(.white)
        }
    }
#endif
