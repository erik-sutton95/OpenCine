#if canImport(UIKit) && canImport(CoreImage)
import CoreImage
import OpenCineApple
import UIKit
import XCTest

/// SIMULATED same source image and settings across an externally invalidated stored cube.
@MainActor
final class MonitorUIImageGraphRefreshTests: XCTestCase {
    func testChangedCubeRequestKeyInvalidatesTheBakedImageMemo() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image {
            UIColor.gray.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var readbacks = 0
        let processor = MonitorUIImageGraphProcessor<Int>(beginReadback: { readbacks += 1 })
        func graph(key: String, rgb: [Float]) -> MonitorUIImageGraph {
            var graph = MonitorUIImageGraph()
            graph.look = .grade(MonitorNativeCubeRequest(key: key) {
                let rgba = Array(repeating: rgb + [1], count: 8).flatMap { $0 }
                return (2, rgba.withUnsafeBytes { Data($0) })
            }, splitVertical: nil)
            return graph
        }
        let first = processor.render(source, settings: 7, identity: false) {
            graph(key: "operator.cube#0", rgb: [1, 0, 0])
        }
        XCTAssertEqual(try rgb(first), [255, 0, 0])
        let cached = processor.render(source, settings: 7, identity: false) {
            graph(key: "operator.cube#0", rgb: [1, 0, 0])
        }
        XCTAssertTrue(cached === first)
        XCTAssertEqual(readbacks, 1, "An unchanged cube still reuses the bounded readback memo")

        let replaced = processor.render(source, settings: 7, identity: false) {
            graph(key: "operator.cube#1", rgb: [0, 0, 1])
        }
        XCTAssertEqual(try rgb(replaced), [0, 0, 255])
        XCTAssertEqual(readbacks, 2, "A new cube revision must render the held source again")
    }

    private func rgb(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(bytes.prefix(3))
    }
}
#endif
