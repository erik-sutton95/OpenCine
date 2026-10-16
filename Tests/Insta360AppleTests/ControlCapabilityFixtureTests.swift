import Foundation
import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCameraVocabulary
import OpenCineCore
import XCTest

/// What Luna offers through the one control model (the controls the Insta app offers today),
/// exported to `Fixtures/control-capabilities-luna.tsv`, which the Kotlin
/// `ControlCapabilityFixtureTest` and `tools/parity-metrics.py` read. After an intended change,
/// regenerate with `OPENCINE_WRITE_FIXTURES=1 swift test --filter ControlCapabilityFixtureTests`.
@MainActor
final class ControlCapabilityFixtureTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/control-capabilities-luna.tsv")

    func testLunaOffersTodaysControls() {
        let controls = FakeLuna().connectedSession().controlCapabilities()
        XCTAssertEqual(controls.offered, [
            .iso, .shutter, .whiteBalance, .exposureCompensation, .focus, .tapFocus, .faceMetering,
            .codecColor, .recordingFormat, .zoom, .gimbal, .headTracking, .recording, .photo, .media,
            .mediaDelete,
        ])
        // Fixed aperture, no ND, no audio levels and so no audio input tile, host-clock timecode.
        XCTAssertEqual(controls.iris.support, .unsupported)
        XCTAssertEqual(controls.ndFilter.support, .unsupported)
        XCTAssertEqual(controls.audio.support, .unsupported)
        XCTAssertEqual(controls.liveAudioLevels.support, .unsupported)
        XCTAssertTrue(controls.timecode.isShown)
        XCTAssertEqual(controls.timecode.offer, .seconds)
        XCTAssertEqual(controls.iso.offer?.nativeISO, CaptureNativeISOCapabilities(hop: false, ceiling: false))
        XCTAssertEqual(controls.zoom.offer?.stops, [1, 2, 3, 6, 15])
        XCTAssertEqual(controls.gimbal.offer, LunaCameraSession.motion)
        XCTAssertEqual(controls.multiview.support, .unknown, "not declared")
    }

    /// The ten-section layout is a computed view of the model and equals the session's projection.
    func testLayoutIsAViewOfTheModel() {
        let session = FakeLuna().connectedSession()
        var base = MonitorLayoutCapabilities()
        base.audio = true
        base.clipDelete = true
        base.clipStar = true
        base.requiresInternetHop = true
        XCTAssertEqual(MonitorLayoutCapabilities(controls: session.controlCapabilities(), base: base),
            session.layout(base: base))
    }

    func testFixtureMatchesSwift() throws {
        let rendered = ControlCapabilityVectors.document(integration: "luna",
            bodies: [("Luna Ultra", FakeLuna().connectedSession().controlCapabilities())])
        if ProcessInfo.processInfo.environment["OPENCINE_WRITE_FIXTURES"] == "1" {
            try rendered.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: Self.fixture, encoding: .utf8), rendered)
    }
}
