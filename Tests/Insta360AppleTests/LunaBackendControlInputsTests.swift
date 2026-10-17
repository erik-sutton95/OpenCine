import Insta360Apple
import Insta360AppleTestSupport
import OpenCineCameraVocabulary
import OpenCineCore
import XCTest

@MainActor
final class LunaBackendControlInputsTests: XCTestCase {
    func testBackendInputsRestrictConnectedControlsWithoutChangingPreConnectionProfile() {
        let camera = FakeLuna()
        var backend: CameraCapabilities? = nil
        let session = camera.connectedSession(backendCapabilities: { backend })
        let original = session.controlCapabilities()
        backend = []
        let unavailable = session.controlCapabilities()
        for family in [ControlFamily.iso, .shutter, .whiteBalance, .tint, .focus, .tapFocus, .zoom,
            .gimbal, .headTracking, .faceMetering, .exposureCompensation, .codecColor,
            .recordingFormat, .recording, .media, .mediaDelete] {
            XCTAssertEqual(unavailable.status(family).support, .unsupported, "\(family)")
        }
        backend = [.focus]
        let focus = session.controlCapabilities()
        XCTAssertTrue(focus.focus.isOffered && focus.tapFocus.isOffered)
        XCTAssertEqual(focus.zoom.support, .unsupported)
        XCTAssertEqual(unavailable.multiview.support, .unknown, "the product decision stays open")
        XCTAssertEqual(unavailable.timecode, original.timecode, "a host clock is not a backend control")
        XCTAssertTrue(session.admitsControl, "support does not replace connection admission")
        session.linkChanged(.idle, serial: nil)
        XCTAssertFalse(session.admitsControl)
        backend = []
        XCTAssertEqual(session.controlCapabilities().focus.support, .unsupported)
        let before = ControlCapabilities(beforeConnection: LunaCameraSession.captureProfile,
            motion: LunaCameraSession.motion)
        XCTAssertTrue(before.focus.isOffered && before.zoom.isOffered && before.gimbal.isOffered)
        backend = nil
        XCTAssertEqual(session.controlCapabilities().focus, original.focus, "restrictions never change static facts")
    }

    func testFullBackendInputKeepsTheFrozenLunaFixture() throws {
        let camera = FakeLuna()
        let session = camera.connectedSession(backendCapabilities: {
            [.liveVideo, .recording, .exposure, .captureFormat, .whiteBalance, .focus, .zoom,
                .gimbal, .cameraMedia]
        })
        let document = ControlCapabilityVectors.document(integration: "luna",
            bodies: [("Luna Ultra", session.controlCapabilities())])
        XCTAssertEqual(document, try String(contentsOf: ControlCapabilityFixtureTests.fixture, encoding: .utf8))
    }
}
