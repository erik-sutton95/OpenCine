#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineMedia
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED empty samples isolate the actual shared plot's reference rendering.
    /// Native trace delivery and physical display calibration are outside this test.
    @MainActor final class MonitorUnknownSignalRenderingTests: XCTestCase {
        func testRawWaveformAndParadeOmitSavedCalibratedGuides() throws {
            for mode in [MonitorScopeTraceMetal.Mode.waveform(.luma), .parade(.rgb)] {
                let off = MonitorScopeGuides(clip: false, crush: false, middle: false)
                let rawDefault = try render(mode, axis: .rawCodes, guides: .default)
                XCTAssertEqual(rawDefault, try render(mode, axis: .rawCodes, guides: off))
                let calibrated = ScopeLevelAxis(transfer: .dlog2, clipByte: 247)
                XCTAssertNotEqual(
                    try render(mode, axis: calibrated, guides: .default),
                    try render(mode, axis: calibrated, guides: off))
                XCTAssertEqual(
                    try render(mode, axis: calibrated, guides: .default),
                    try render(
                        mode,
                        axis: ScopeLevelAxis(
                            table: calibrated.table,
                            middleGrayIRE: calibrated.middleGrayIRE,
                            supportsCalibratedReferences: true),
                        guides: .default))
            }
        }

        private func render(
            _ mode: MonitorScopeTraceMetal.Mode, axis: ScopeLevelAxis,
            guides: MonitorScopeGuides
        ) throws -> [UInt8] {
            let size = CGSize(width: 240, height: 120)
            let renderer = ImageRenderer(
                content: MonitorWaveformScopePlot(
                    samples: .empty,
                    mode: mode, axis: axis, revision: 1, intensity: 1, guides: guides, size: size
                )
                .frame(width: size.width, height: size.height).background(Color.black))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &data, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
    }
#endif
