import OpenCineCameraControls
import XCTest

/// Twin of the Compose MonitorOperatorPicturePlateTest: same cases.
final class MonitorOperatorPicturePlateTests: XCTestCase {
    private func picture(waiting: Bool, notice: MonitorOperatorPictureNotice? = nil)
        -> MonitorOperatorLivePicture
    {
        MonitorOperatorLivePicture(
            aspect: 16 / 9, waiting: waiting, vertical: false, flipped: false, recovering: false,
            notice: notice)
    }

    func testTheSourcesNoticeReplacesTheWaitingPlatesWords() {
        let notice = MonitorOperatorPictureNotice(title: "No camera")
        XCTAssertEqual(picture(waiting: true, notice: notice).plate, .notice(notice))
        XCTAssertEqual(picture(waiting: false, notice: notice).plate, .notice(notice))
    }

    func testWithoutANoticeAWaitingPictureShowsTheWaitingPlateAndALiveOneNone() {
        XCTAssertEqual(picture(waiting: true).plate, .waiting)
        XCTAssertNil(picture(waiting: false).plate)
    }

    func testANoticeHasNoDetailAndNoSpinnerUnlessTheSourceSaysSo() {
        let notice = MonitorOperatorPictureNotice(title: "Connecting…")
        XCTAssertNil(notice.detail)
        XCTAssertFalse(notice.progress)
    }

    /// Hardware pass 4.1: a taken-over monitor showed "Reconnecting" over "Camera taken over".
    func testTheReconnectingPillFollowsRecoveryUnlessTheSourceSaysOtherwise() {
        let follows = MonitorOperatorLivePicture(
            aspect: 16 / 9, waiting: false, vertical: false, flipped: false, recovering: true)
        XCTAssertTrue(follows.reconnecting)
        let takenOver = MonitorOperatorLivePicture(
            aspect: 16 / 9, waiting: false, vertical: false, flipped: false, recovering: true,
            reconnecting: false)
        XCTAssertTrue(takenOver.recovering)
        XCTAssertFalse(takenOver.reconnecting)
    }
}
