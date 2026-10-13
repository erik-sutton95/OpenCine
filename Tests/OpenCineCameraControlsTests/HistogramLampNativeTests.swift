#if os(iOS)
import MonitorUI
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED empty signal through the actual shared SwiftUI Canvas, at the operator's minimum size.
@MainActor final class HistogramLampNativeTests: XCTestCase {
    func testEveryChannelLampFitsAtTheMinimumPanelScale() throws {
        var traffic = ScopeTrafficLightsReading.none
        traffic.red.clip = true; traffic.red.crush = true
        traffic.green.clip = true; traffic.green.crush = true
        traffic.blue.clip = true; traffic.blue.crush = true
        for height in [77.0, 77.0 * 0.6] {
            let renderer = ImageRenderer(content: MonitorHistogramScopePlot(
                display: .empty, traffic: traffic).frame(width: 150, height: height).background(Color.black))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var counts = [0, 0, 0]
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                if r > 180 && r > g + 100 && r > b + 100 { counts[0] += 1 }
                if g > 180 && g > r + 70 && g > b + 70 { counts[1] += 1 }
                if b > 180 && b > r + 70 && b > g + 70 { counts[2] += 1 }
            }
            XCTAssertGreaterThan(counts.min() ?? 0, 40, "Every actual lamp paints at height \(height): \(counts)")
            XCTAssertGreaterThanOrEqual(Double(counts.min() ?? 0), Double(counts.max() ?? 0) * 0.8,
                "No channel is cropped at height \(height): \(counts)")
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "histogram-all-lamps-\(height)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
