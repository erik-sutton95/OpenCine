#if os(iOS)
import MonitorPresentation
@testable import MonitorUI
import SwiftUI
import UIKit
import XCTest

/// Actual pixels of the shared playback picture. Owner request 2026-10-28: a zoomed clip fills the
/// playback area instead of staying cropped to its letterboxed 16:9 or 9:16 frame. A red picture
/// sits on the black canvas, which sits on a white page, so each pixel says what covers it.
/// Kotlin twin: MonitorPlaybackZoomBeyondFrameTest (monitor-ui androidTest).
@MainActor
final class MonitorPlaybackZoomRenderingTests: XCTestCase {
    private let page = CGSize(width: 460, height: 460)
    private let cases: [(name: String, canvas: CGSize, aspect: Double)] = [
        ("16x9-portrait", CGSize(width: 200, height: 400), 16.0 / 9),
        ("16x9-landscape", CGSize(width: 400, height: 200), 16.0 / 9),
        ("9x16-portrait", CGSize(width: 200, height: 400), 9.0 / 16),
        ("9x16-landscape", CGSize(width: 400, height: 200), 9.0 / 16),
    ]

    func testOneTimesKeepsTheLetterboxedFrame() throws {
        for (name, canvas, aspect) in cases {
            let feed = Self.fit(aspect: aspect, in: canvas)
            let pixels = try render(canvas: canvas, feed: feed, zoom: MonitorPlaybackZoom())
            XCTAssertEqual(pixels.rgb(Self.center(of: feed)), Self.red, name)
            XCTAssertEqual(pixels.rgb(Self.letterbox(feed: feed, canvas: canvas)), Self.black, name)
        }
    }

    func testTwoTimesDrawsThePicturePastTheLetterboxedFrame() throws {
        for (name, canvas, aspect) in cases {
            let feed = Self.fit(aspect: aspect, in: canvas)
            let pixels = try render(canvas: canvas, feed: feed, zoom: Self.zoom(2, canvas: canvas))
            XCTAssertEqual(pixels.rgb(Self.letterbox(feed: feed, canvas: canvas)), Self.red,
                "\(name): at 2x the picture covers the letterbox beside its frame")
            attach(pixels.image, name: "playback-zoom-2x-\(name)")
        }
    }

    func testFullyZoomedPictureFillsTheCanvasButNeverThePageAroundIt() throws {
        for (name, canvas, aspect) in cases {
            let feed = Self.fit(aspect: aspect, in: canvas)
            let pixels = try render(canvas: canvas, feed: feed, zoom: Self.zoom(4, canvas: canvas))
            for point in [CGPoint(x: 2, y: 2), CGPoint(x: canvas.width - 3, y: canvas.height - 3)] {
                XCTAssertEqual(pixels.rgb(point), Self.red, "\(name): 4x fills the canvas corner")
            }
            XCTAssertEqual(pixels.rgb(CGPoint(x: canvas.width + 10, y: 10)), Self.white, name)
            XCTAssertEqual(pixels.rgb(CGPoint(x: 10, y: canvas.height + 10)), Self.white, name)
        }
    }

    private static let red = [255, 0, 0], black = [0, 0, 0], white = [255, 255, 255]

    private static func zoom(_ magnification: CGFloat, canvas: CGSize) -> MonitorPlaybackZoom {
        var zoom = MonitorPlaybackZoom()
        zoom.pinchChanged(magnification: magnification, startAnchorX: 0.5, startAnchorY: 0.5, size: canvas)
        return zoom
    }

    private static func fit(aspect: Double, in canvas: CGSize) -> CGRect {
        let width = min(canvas.width, canvas.height * aspect), height = width / aspect
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2,
            width: width, height: height)
    }

    private static func center(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Just outside the frame on its letterboxed side, a quarter of the narrower band away.
    private static func letterbox(feed: CGRect, canvas: CGSize) -> CGPoint {
        feed.minY > 1 ? CGPoint(x: feed.minX + feed.width * 0.3, y: feed.minY - min(feed.minY, feed.height) / 4)
            : CGPoint(x: feed.minX - min(feed.minX, feed.width) / 4, y: feed.minY + feed.height * 0.3)
    }

    private func render(canvas: CGSize, feed: CGRect, zoom: MonitorPlaybackZoom) throws -> Pixels {
        let content = ZStack(alignment: .topLeading) {
            Color.white
            ZStack {
                Color.black
                MonitorPlaybackPictureCanvas(canvas: canvas, feed: feed, zoom: zoom,
                    mirrorHorizontal: false, mirrorVertical: false
                ) { Color(.sRGB, red: 1, green: 0, blue: 0) }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
        .frame(width: page.width, height: page.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try Pixels(XCTUnwrap(renderer.cgImage))
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Pixels {
        let image: CGImage
        let bytes: [UInt8]
        init(_ image: CGImage) throws {
            self.image = image
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &data, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            bytes = data
        }
        func rgb(_ point: CGPoint) -> [Int] {
            let x = Int(point.x), y = Int(point.y)
            return (0..<3).map { Int(bytes[(y * image.width + x) * 4 + $0]) }
        }
    }
}
#endif
