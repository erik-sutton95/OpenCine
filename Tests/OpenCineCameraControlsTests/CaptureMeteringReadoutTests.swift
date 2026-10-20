#if os(iOS)
    import OpenCineAppKit
    import XCTest

    @testable import OpenCineCameraControls

    /// Behavior audit II-083: the face-priority metering tile speaks as it did in the standalone
    /// Insta app ("Metering", its value and what a tap does), not its visual caption.
    @MainActor final class CaptureMeteringReadoutTests: XCTestCase {
        func testTheMeteringToggleKeepsItsSpokenNameAndHint() {
            var sent: [Bool] = []
            let face = MonitorOperatorSupplementaryCaptureReadout<CaptureSheet, Int>.metering(
                .init(face: true, isCurrent: { true }, setFace: { sent.append($0) }), section: nil)
            XCTAssertEqual(face.title, "METER")
            XCTAssertEqual(face.value, "Face")
            XCTAssertEqual(face.accessibilityLabel, "Metering")
            XCTAssertEqual(face.accessibilityValue, "Face Priority")
            XCTAssertEqual(face.accessibilityHint, "Switches between Matrix and Face Priority metering")
            XCTAssertEqual(face.accessibilityIdentifier, "monitor.capture.metering")
            XCTAssertTrue(face.perform(admitted: true))
            XCTAssertEqual(sent, [false])

            let unknown = MonitorOperatorSupplementaryCaptureReadout<CaptureSheet, Int>.metering(
                .init(face: nil, isCurrent: { true }, setFace: { sent.append($0) }), section: nil)
            XCTAssertEqual(unknown.accessibilityLabel, "Metering")
            XCTAssertEqual(unknown.accessibilityValue, "Unknown")
            XCTAssertFalse(unknown.perform(admitted: true))
        }
    }
#endif
