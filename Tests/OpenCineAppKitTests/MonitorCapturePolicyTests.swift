import OpenCineAppKit
import XCTest

/// Kotlin suite `MonitorCapturePolicyTest`, same method names: the capture control keeps the
/// pre-shared-UI behavior of every app (behavior audit ZIA-359, II-034, II-144, PIA-425, ZAA-415).
final class MonitorCapturePolicyTests: XCTestCase {
    private func policy(
        enabled: Bool = true, busy: Bool = false, pending: Bool = false, photo: Bool = false,
        canRecord: Bool = true, recording: Bool? = false, offersMode: Bool = false
    ) -> MonitorCapturePolicy {
        MonitorCapturePolicy(
            enabled: enabled, busy: busy, pending: pending, photo: photo, canRecord: canRecord,
            recording: recording, offersMode: offersMode)
    }

    /// ZIA-359: Z offers no mode sheet; a held press recorded in the baseline (a Button fires on release).
    func testAHoldRecordsWhenTheSourceOffersNoModeSheet() {
        XCTAssertEqual(policy().holdAction, .press)
        XCTAssertEqual(policy(recording: true).holdAction, .press)
        XCTAssertNil(policy(enabled: false).holdAction)
        XCTAssertEqual(policy(offersMode: true).holdAction, .openMode)
    }

    /// II-034: the hold opened Shooting mode in every state but busy or locked, also before the
    /// camera reports whether it records.
    func testTheModeHoldDoesNotWaitForTheRecordingState() {
        let unknown = policy(canRecord: false, recording: nil, offersMode: true)
        XCTAssertNil(unknown.tapAction)
        XCTAssertEqual(unknown.holdAction, .openMode)
        XCTAssertNil(policy(busy: true, offersMode: true).holdAction)
        XCTAssertNil(policy(pending: true, offersMode: true).holdAction)
        XCTAssertNil(policy(enabled: false, offersMode: true).holdAction)
    }

    /// II-144, PIA-425: busy and pending windows are inert without the locked look; stopping is 72 %.
    func testOnlyTheLockedLookDimsToFortyPercent() {
        XCTAssertEqual(policy(enabled: false).opacity, 0.4)
        XCTAssertEqual(policy(busy: true).opacity, 1)
        XCTAssertEqual(policy(pending: true).opacity, 1)
        XCTAssertEqual(policy(busy: true, photo: true).opacity, 1)
        XCTAssertEqual(policy(busy: true, recording: true).opacity, 0.72)
        XCTAssertEqual(policy(pending: true, recording: true).opacity, 0.72)
        XCTAssertEqual(policy(recording: true).opacity, 1)
        XCTAssertNil(policy(busy: true).tapAction)
        XCTAssertNil(policy(pending: true).tapAction)
    }

    /// ZAA-415: the record disc speaks its state beside the action.
    func testTheRecordDiscSpeaksItsState() {
        XCTAssertEqual(policy(recording: true).stateDescription, "Recording")
        XCTAssertEqual(policy(recording: false).stateDescription, "Standby")
        XCTAssertNil(policy(recording: nil).stateDescription)
        XCTAssertNil(policy(photo: true).stateDescription)
        XCTAssertEqual(policy(recording: false).accessibilityLabel, "Start recording")
        XCTAssertEqual(policy(recording: true).accessibilityLabel, "Stop recording")
        XCTAssertEqual(policy(photo: true).accessibilityLabel, "Take photo")
    }

    /// Review: an unrelated busy command is not a stop; a hold that opens the sheet is named.
    func testOnlyAPendingStopIsAnnouncedAndTheModeHoldIsNamed() {
        XCTAssertEqual(policy(busy: true, recording: true).accessibilityLabel, "Stop recording")
        XCTAssertEqual(policy(pending: true, recording: true).accessibilityLabel, "Stopping recording")
        XCTAssertEqual(policy(offersMode: true).holdAccessibilityLabel, "Shooting mode")
        XCTAssertNil(policy().holdAccessibilityLabel)
    }

    func testATapPressesOnlyWhenAdmitted() {
        XCTAssertEqual(policy().tapAction, .press)
        XCTAssertEqual(policy(photo: true, canRecord: false, recording: nil).tapAction, .press)
        XCTAssertNil(policy(canRecord: false, recording: nil).tapAction)
        XCTAssertNil(policy(enabled: false).tapAction)
    }
}
