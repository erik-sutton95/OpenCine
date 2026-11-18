#if canImport(VideoToolbox)
import CoreVideo
import Foundation
import Testing

@testable import OpenCineStreamingApple

@Suite struct StreamPictureFitterTests {
    private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) < 12 && abs(a.1 - b.1) < 12 && abs(a.2 - b.2) < 12
    }

    @Test func differentSourceSizesFitTheSameOutput() throws {
        let fitter = StreamPictureFitter(width: 1280, height: 720, mode: .fit)
        let fourByThree = try #require(fitter.fit(MediaFixtures.solid(width: 1024, height: 768, (0, 0, 255))))
        #expect(CVPixelBufferGetWidth(fourByThree) == 1280 && CVPixelBufferGetHeight(fourByThree) == 720)
        #expect(near(MediaFixtures.pixel(fourByThree, x: 10, y: 360), (0, 0, 0)))  // side bar
        #expect(near(MediaFixtures.pixel(fourByThree, x: 640, y: 360), (0, 0, 255)))
        let wide = try #require(fitter.fit(MediaFixtures.solid(width: 1920, height: 1080, (255, 0, 0))))
        #expect(CVPixelBufferGetWidth(wide) == 1280 && CVPixelBufferGetHeight(wide) == 720)
        #expect(near(MediaFixtures.pixel(wide, x: 2, y: 2), (255, 0, 0)))
        #expect(near(MediaFixtures.pixel(wide, x: 1277, y: 717), (255, 0, 0)))
    }

    @Test func centerCropFillsVertical() throws {
        let fitter = StreamPictureFitter(width: 720, height: 1280, mode: .centerCrop)
        let halves = MediaFixtures.picture(width: 1280, height: 720) { x, _ in x < 640 ? (0, 0, 255) : (255, 0, 0) }
        let out = try #require(fitter.fit(halves))
        #expect(CVPixelBufferGetWidth(out) == 720 && CVPixelBufferGetHeight(out) == 1280)
        #expect(near(MediaFixtures.pixel(out, x: 100, y: 640), (0, 0, 255)))
        #expect(near(MediaFixtures.pixel(out, x: 620, y: 640), (255, 0, 0)))
    }
}
#endif
