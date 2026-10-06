import Foundation
import Testing

@testable import OpenCineMedia

@Suite struct PlaybackVideoLayoutTests {
    @Test func aspectFitCentersTheRaster() {
        let rect = PlaybackVideoLayout.aspectFitRect(
            videoSize: CGSize(width: 16, height: 9),
            in: CGRect(x: 0, y: 0, width: 320, height: 320))
        #expect(abs(rect.width - 320) < 0.01)
        #expect(abs(rect.height - 180) < 0.01)
        #expect(abs(rect.midY - 160) < 0.01)
    }

    @Test func squareRecordingPillarboxesInsideASixteenNineWell() {
        let well = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let picture = PlaybackVideoLayout.aspectFitRect(
            videoSize: CGSize(width: 1, height: 1), in: well)
        #expect(abs(picture.width - 1080) < 0.01)
        #expect(abs(picture.height - 1080) < 0.01)
        #expect(abs(picture.minX - 420) < 0.01)
        #expect(abs(picture.midY - well.midY) < 0.01)
    }

    @Test func listedResolutionBecomesTheFeedRaster() {
        #expect(
            PlaybackVideoLayout.size(fromResolution: "3840x2160")
                == CGSize(width: 3840, height: 2160))
        #expect(
            PlaybackVideoLayout.size(fromResolution: "1080×1920")
                == CGSize(width: 1080, height: 1920))
        #expect(PlaybackVideoLayout.size(fromResolution: nil) == nil)
        #expect(PlaybackVideoLayout.size(fromResolution: "n/a") == nil)
    }
}
