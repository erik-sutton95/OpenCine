import OpenCineCore
import Testing

/// A camera that publishes its own stream: which frame rate a request gets.
struct CameraStreamPublishingTests {
    private let both = CameraStreamPublishing(
        width: 1920, height: 1080, frameRates: [25, 30], codecs: [.hevc, .h264], takesLUT: false, experimental: false)

    @Test func frameRateFallsBackToAListedRate() {
        #expect(both.frameRate(near: 25) == 25)
        #expect(both.frameRate(near: 30) == 30)
        #expect(both.frameRate(near: nil) == 30)
        #expect(both.frameRate(near: 60) == 30)
        let fast = CameraStreamPublishing(
            width: 1920, height: 1080, frameRates: [50, 60], codecs: [.h264], takesLUT: false, experimental: true)
        #expect(fast.frameRate(near: 30) == 50)
        #expect(fast.preferredCodec == .h264)
        #expect(both.preferredCodec == .hevc)
    }
}
