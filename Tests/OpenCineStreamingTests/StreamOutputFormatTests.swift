import Foundation
import OpenCineCore
import Testing

import OpenCineStreaming

@Suite struct StreamOutputFormatTests {
    private let p720 = StreamSourceFormat(width: 1280, height: 720, frameRate: Rational(25, 1))
    private let p1080 = StreamSourceFormat(width: 1920, height: 1080, frameRate: Rational(30, 1))
    private let uhd = StreamSourceFormat(width: 3840, height: 2160, frameRate: Rational(24, 1))
    private let fourByThree = StreamSourceFormat(width: 1024, height: 768, frameRate: nil)
    private func capped(_ bps: Int?, aspect: StreamServicePreset.Aspect = .landscape16x9) -> StreamServicePreset {
        StreamServicePreset(
            id: "test", displayName: "Test", serverURL: nil, requiresServerEntry: true, maxVideoBitrateBps: bps,
            aspect: aspect, keyHint: "Test hint.")
    }

    @Test func wirelessSourceStaysAt720() {
        let f = StreamOutputFormat.resolve(selected: p720, connected: [p720], preset: .custom)
        #expect(f.width == 1280 && f.height == 720)
        #expect(f.frameRate == Rational(25, 1))
        #expect(f.videoBitrateBps == 3_000_000)
        #expect(f.keyframeIntervalSeconds == 2)
        #expect(f.audioBitrateBps == 160_000 && f.audioSampleRate == 48_000 && f.audioChannels == 2)
    }

    @Test func captureSourceEarns1080() {
        let f = StreamOutputFormat.resolve(selected: p1080, connected: [p1080], preset: .custom)
        #expect(f.width == 1920 && f.height == 1080)
        #expect(f.videoBitrateBps == 6_000_000)
    }

    @Test func aboveSourceIsNeverOffered() {
        let f = StreamOutputFormat.resolve(selected: uhd, connected: [uhd], preset: .custom)
        #expect(f.width == 1920 && f.height == 1080)
        #expect(f.frameRate == Rational(24, 1))
    }

    @Test func verticalSourceIsMeasuredByItsShortSide() {
        // A phone held upright sends 720x1280: still a 720p picture, never 1080p.
        let upright = StreamSourceFormat(width: 720, height: 1280, frameRate: Rational(30, 1))
        let f = StreamOutputFormat.resolve(selected: upright, connected: [], preset: .custom)
        #expect(f.width == 1280 && f.height == 720)
        #expect(f.videoBitrateBps == 3_000_000)
    }

    @Test func fourByThreeSourceGivesA720Frame() {
        // The output stays 16:9; the shell keeps the source's shape inside it with side bars.
        let f = StreamOutputFormat.resolve(selected: fourByThree, connected: [fourByThree], preset: .custom)
        #expect(f.width == 1280 && f.height == 720)
    }

    @Test func smallSourceKeepsItsOwnHeight() {
        let small = StreamSourceFormat(width: 640, height: 480, frameRate: Rational(30, 1))
        let f = StreamOutputFormat.resolve(selected: small, connected: [small], preset: .custom)
        #expect(f.width == 854 && f.height == 480)
        #expect(f.videoBitrateBps == 2_000_000)
    }

    @Test func bestConnectedSourceSetsSizeSelectedSetsRate() {
        let f = StreamOutputFormat.resolve(selected: p720, connected: [p720, p1080], preset: .custom)
        #expect(f.width == 1920 && f.height == 1080)
        #expect(f.frameRate == Rational(25, 1))
    }

    @Test func unknownFrameRateFallsBackTo30() {
        #expect(StreamOutputFormat.resolve(selected: fourByThree, connected: [], preset: .custom).frameRate == Rational(30, 1))
    }

    @Test func presetCapsBitrate() {
        #expect(StreamOutputFormat.resolve(selected: p720, connected: [p720], preset: capped(2_000_000)).videoBitrateBps == 2_000_000)
        #expect(StreamOutputFormat.resolve(selected: p720, connected: [p720], preset: capped(9_000_000)).videoBitrateBps == 3_000_000)
    }

    @Test func portraitPresetSwapsToVertical() {
        let f = StreamOutputFormat.resolve(selected: p720, connected: [p720], preset: capped(nil, aspect: .portrait9x16))
        #expect(f.width == 720 && f.height == 1280)
    }

    @Test func routesThatMayStream() {
        #expect(StreamConnectionRoute.canStream(.usbCable))
        #expect(StreamConnectionRoute.canStream(.captureCard))
        #expect(StreamConnectionRoute.canStream(.sharedWiFi))
        #expect(StreamConnectionRoute.canStream(.deviceHotspot))
        #expect(!StreamConnectionRoute.canStream(.cameraWiFi))
        #expect(!StreamConnectionRoute.canStream(nil))
    }

    @Test func everyCoreRouteMapsToAStreamingRoute() {
        // Only the camera's own access point blocks streaming; the app's route vocabulary decides.
        #expect(StreamConnectionRoute(.cameraAccessPoint) == .cameraWiFi)
        #expect(StreamConnectionRoute(.infrastructureNetwork) == .sharedWiFi)
        #expect(StreamConnectionRoute(.phoneHotspot) == .deviceHotspot)
        #expect(StreamConnectionRoute(.usb) == .usbCable)
        #expect(StreamConnectionRoute(.captureDevice) == .captureCard)
        #expect(RouteKind.allCases.filter { StreamConnectionRoute.canStream(StreamConnectionRoute($0)) }.count == 4)
    }

    @Test func upscaledChoiceGivesThe1080Tier() {
        let landscape = StreamOutputFormat.resolve(
            selected: p720, connected: [], preset: capped(4_500_000), choice: .upscaled1080p)
        #expect(landscape.width == 1920 && landscape.height == 1080)
        #expect(landscape.videoBitrateBps == 4_500_000)
        #expect(landscape.frameRate == Rational(25, 1))
        let open = StreamOutputFormat.resolve(selected: p720, connected: [], preset: .custom, choice: .upscaled1080p)
        #expect(open.videoBitrateBps == 6_000_000)
        let vertical = StreamOutputFormat.resolve(
            selected: p720, connected: [], preset: capped(nil, aspect: .portrait9x16), choice: .upscaled1080p)
        #expect(vertical.width == 1080 && vertical.height == 1920)
        let feed = StreamOutputFormat.resolve(selected: p720, connected: [], preset: .custom, choice: .cameraFeed)
        #expect(feed.width == 1280)
    }

    @Test func upscaledIsOfferedOnlyBelow1080() {
        #expect(StreamQualityChoice.offered(for: p720) == [.cameraFeed, .upscaled1080p])
        #expect(StreamQualityChoice.offered(for: fourByThree) == [.cameraFeed, .upscaled1080p])
        #expect(StreamQualityChoice.offered(for: StreamSourceFormat(width: 720, height: 1280, frameRate: nil))
            == [.cameraFeed, .upscaled1080p])
        #expect(StreamQualityChoice.offered(for: p1080) == [.cameraFeed])
        #expect(StreamQualityChoice.offered(for: nil) == [.cameraFeed])
    }

    /// The host offers the camera's own stream; the source size never does, and it is a 1080 output.
    @Test func cameraChoiceComesFromTheHostAndIs1080() {
        #expect(StreamQualityChoice(rawValue: "camera1080p") == .camera1080p)
        #expect(!StreamQualityChoice.offered(for: p720).contains(.camera1080p))
        #expect(!StreamQualityChoice.offered(for: p1080).contains(.camera1080p))
        let camera = StreamOutputFormat.resolve(
            selected: StreamSourceFormat(width: 1920, height: 1080, frameRate: Rational(25, 1)), connected: [],
            preset: .custom, choice: .camera1080p)
        #expect(camera.width == 1920 && camera.height == 1080 && camera.videoBitrateBps == 6_000_000)
    }
}
