#if os(iOS)
    import MonitorUI
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI
    import XCTest

    @testable import OpenCineCameraControls

    /// Pins OpenZCine histogram rows + `MovablePanel` ("histo") onto the shared assists.
    final class HistogramAssistTests: XCTestCase {
        /// This test's monitored source (XCTest makes a fresh one per test).
        private let ceiling = DeclaredMonitorColorFacts.makeCeiling()


        func testTrafficLightsSitOutsideMinMaxLines() {
            let size = MonitorScopePanelSize.histogram
            let plot = HistogramAssist.plotRect(in: size)
            let leftLampMinX = HistogramAssist.trafficHorizontalInset
            let leftLampMaxX = leftLampMinX + HistogramAssist.trafficLampWidth
            let rightLampMaxX = size.width - HistogramAssist.trafficHorizontalInset
            let rightLampMinX = rightLampMaxX - HistogramAssist.trafficLampWidth
            let line0 = HistogramAssist.ireX(0, in: plot)
            let line100 = HistogramAssist.ireX(100, in: plot)
            XCTAssertLessThan(leftLampMaxX, line0, "crush lamps sit left of the 0 line")
            XCTAssertGreaterThan(rightLampMinX, line100, "clip lamps sit right of the 100 line")
            XCTAssertGreaterThan(leftLampMinX, 0)
            XCTAssertLessThan(rightLampMaxX, size.width)
            XCTAssertEqual(HistogramAssist.trafficHorizontalInset, HistogramAssist.trafficOuterPad)
            XCTAssertEqual(
                HistogramAssist.trafficGutter,
                HistogramAssist.trafficOuterPad + HistogramAssist.trafficLampWidth
                    + HistogramAssist.trafficLineGap,
                accuracy: 0.01)
            XCTAssertEqual(
                line0 - leftLampMaxX,
                HistogramAssist.trafficLineGap + MonitorWaveformAxis.plotInset,
                accuracy: 0.01)
            XCTAssertEqual(
                rightLampMinX - line100,
                HistogramAssist.trafficLineGap + MonitorWaveformAxis.plotInset,
                accuracy: 0.01)
        }

        func testRemapPutsPaperBlackAndClipOnTheWaveEdges() {
            var bins = [Int](repeating: 0, count: 256)
            bins[5] = 8
            bins[16] = 100
            bins[78] = 40
            bins[188] = 25
            bins[247] = 20
            bins[255] = 10
            let out = MonitorWaveformAxis.remapHistogram(
                bins, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
            XCTAssertEqual(out.reduce(0, +), 203)
            XCTAssertEqual(out[0], 108, "sub-black and paper black clamp onto IRE 0")
            XCTAssertEqual(out[255], 30, "live-tap 247 and overshoot 255 clamp onto IRE 100")
            let greyBucket = Int(
                (MonitorWaveformAxis.ire(
                    78.0 / 255, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
                    / 100
                    * 255).rounded())
            XCTAssertEqual(out[greyBucket], 40)
            XCTAssertEqual(greyBucket, 78)
            let earlyBucket = Int(
                (MonitorWaveformAxis.ire(
                    188.0 / 255, transfer: .dlog2, clipByte: ceiling.clipByte(transfer: .dlog2))
                    / 100
                    * 255).rounded())
            XCTAssertEqual(out[earlyBucket], 25)
            XCTAssertLessThan(earlyBucket, 230, "188 is recoverable highlight, not the 100 line")
        }
        @MainActor
        func testSharedHistogramKeepsTheSignalWhenEdgeLightsAreHidden() throws {
            var display = ScopeHistogramDisplay.empty
            for index in 100..<156 { display.red[index] = 20 }
            var traffic = ScopeTrafficLightsReading.none
            traffic.red.crush = true
            func render(lights: Bool) throws -> CGImage {
                let renderer = ImageRenderer(
                    content:
                        MonitorHistogramScopePlot(
                            display: display, traffic: traffic,
                            showTrafficLights: lights
                        )
                        .frame(width: 250, height: 77).background(Color.black))
                renderer.scale = 1
                return try XCTUnwrap(renderer.cgImage)
            }
            func redPixels(_ image: CGImage, xRange: Range<Int>) throws -> Int {
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try bytes.withUnsafeMutableBytes { storage in
                    let context = try XCTUnwrap(
                        CGContext(
                            data: storage.baseAddress,
                            width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(
                        image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return (0..<image.height).reduce(0) { count, y in
                    count
                        + xRange.reduce(0) { row, x in
                            let offset = (y * image.width + x) * 4
                            return row
                                + (bytes[offset] > 180 && bytes[offset + 1] < 170
                                    && bytes[offset + 2] < 170 ? 1 : 0)
                        }
                }
            }
            let shown = try render(lights: true)
            let hidden = try render(lights: false)
            XCTAssertGreaterThan(
                try redPixels(shown, xRange: 0..<17), 60,
                "The source's crushed red channel must light its edge block")
            XCTAssertEqual(
                try redPixels(hidden, xRange: 0..<17), 0,
                "Hiding traffic lights removes their edge block")
            let signal = try redPixels(hidden, xRange: 20..<230)
            XCTAssertGreaterThan(signal, 30, "The ready-to-draw histogram remains visible")
            XCTAssertEqual(
                try redPixels(shown, xRange: 20..<230), signal,
                "The traffic-light preference cannot change the measured signal trace")
        }

    }
#endif
