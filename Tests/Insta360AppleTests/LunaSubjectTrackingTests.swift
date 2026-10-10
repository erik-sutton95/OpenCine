import Insta360Apple
import Insta360AppleTestSupport
import Insta360Protocol
import XCTest

/// Deep Track and tap focus requests go through the Luna session; the camera's 0x85 frames and
/// 8315 notifications drive the boxes the app draws.
@MainActor
final class LunaSubjectTrackingTests: XCTestCase {
    private typealias Box = LunaSubjectTracking.Box

    private func run(_ body: (@escaping @MainActor (Error?) -> Void) throws -> Void) async throws
        -> Error?
    {
        var result: Error?
        var thrown: Error?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            do {
                try body { error in
                    result = error
                    done.resume()
                }
            } catch {
                thrown = error
                done.resume()
            }
        }
        if let thrown { throw thrown }
        return result
    }

    private func frame(state: UInt8, x: Float) throws -> LunaTrackFrame {
        var box = Data([0x0d]) + withUnsafeBytes(of: x.bitPattern.littleEndian) { Data($0) }
        box += Data([0x1d]) + withUnsafeBytes(of: Float(0.15).bitPattern.littleEndian) { Data($0) }
        box += Data([0x25]) + withUnsafeBytes(of: Float(0.27).bitPattern.littleEndian) { Data($0) }
        return try LunaTrackFrame(Data([0x10, state, 0x22, UInt8(box.count)]) + box)
    }

    func testStartSendsTheClampedRectangleAndACancelBeforeALockClearsTheSearch() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        let tracking = LunaSubjectTracking(session: { session })
        let box = Box(x: 0.9, y: -0.1, width: 0.3, height: 0.4)
        let outcome = try await run { try tracking.start(box, finished: $0) }
        XCTAssertNil(outcome)
        let sent = try XCTUnwrap(camera.sent.last)
        XCTAssertEqual(sent.command, .openTracking)
        let roi = try ProtoMessage(sent.body)
        XCTAssertEqual(try roi.float(2), 0.9, accuracy: 1e-6)
        XCTAssertThrowsError(try roi.float(3), "a top clamped to 0 is omitted, as proto3 does")
        XCTAssertEqual(try roi.float(4), 0.1, accuracy: 1e-6, "width kept inside the frame")
        XCTAssertEqual(try roi.float(5), 0.4, accuracy: 1e-6)
        XCTAssertEqual(tracking.snapshot, .init(searchBox: box))

        tracking.ingest(trackingState: 0)
        XCTAssertFalse(
            tracking.snapshot.active, "a cancel before any lock clears the pending search")
    }

    func testFramesAndNotificationsDriveTheSnapshot() throws {
        var heard: [LunaSubjectTracking.Snapshot] = []
        let tracking = LunaSubjectTracking(session: { nil }, changed: { heard.append($0) })
        tracking.ingest(try frame(state: 5, x: 0.4))
        tracking.ingest(try frame(state: 3, x: 0.4))
        XCTAssertFalse(tracking.snapshot.active, "idle or lost before any lock is ignored")
        XCTAssertTrue(heard.isEmpty)

        tracking.ingest(try frame(state: 2, x: 0.4))
        XCTAssertEqual(try XCTUnwrap(tracking.snapshot.subjectBox).x, 0.4, accuracy: 1e-6)
        XCTAssertTrue(tracking.snapshot.tracking)
        tracking.ingest(try frame(state: 3, x: 0.42))
        let lost = try XCTUnwrap(tracking.snapshot.searchBox)
        XCTAssertEqual(lost.x, 0.42, accuracy: 1e-6)
        XCTAssertFalse(tracking.snapshot.tracking)
        tracking.ingest(trackingState: 1)
        XCTAssertEqual(tracking.snapshot, .init(subjectBox: lost.subject(), tracking: true))
        tracking.ingest(try frame(state: 5, x: 0.4))
        XCTAssertFalse(tracking.snapshot.active, "idle after a lock ends tracking")
        XCTAssertEqual(heard.count, 4)
    }

    func testClearingTheBoxesKeepsTheLockSoTheNextReportDrawsThemAgain() throws {
        let tracking = LunaSubjectTracking(session: { nil })
        tracking.ingest(try frame(state: 2, x: 0.4))
        tracking.clearBoxes()
        XCTAssertFalse(tracking.snapshot.active)
        tracking.ingest(try frame(state: 3, x: 0.42))
        XCTAssertNotNil(tracking.snapshot.searchBox, "lost after a lock still shows the search box")
        tracking.clear()
        tracking.ingest(try frame(state: 3, x: 0.42))
        XCTAssertFalse(tracking.snapshot.active, "a full clear forgets the lock")
    }

    func testSubjectBoxIsAShrunkenCentredSearchBox() {
        let subject = Box(x: 0.2, y: 0.2, width: 0.4, height: 0.08).subject()
        XCTAssertEqual(subject.x, 0.31, accuracy: 1e-9)
        XCTAssertEqual(subject.y, 0.215, accuracy: 1e-9)
        XCTAssertEqual(subject.width, 0.18, accuracy: 1e-9)
        XCTAssertEqual(subject.height, 0.05, accuracy: 1e-9, "the 0.05 floor")
    }

    func testCancelSendsOnlyWhenTrackingWasActiveAndTheSessionAdmitsControl() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        let tracking = LunaSubjectTracking(session: { session })
        tracking.cancel()
        let before = camera.sent.count
        XCTAssertEqual(camera.sent.count, before, "nothing tracked, nothing sent")

        tracking.ingest(try frame(state: 2, x: 0.4))
        let outcome = try await run { tracking.cancel(finished: $0) }
        XCTAssertNil(outcome)
        XCTAssertEqual(camera.sent.last, LunaProtocol.cancelTrackingRequest)
        XCTAssertFalse(tracking.snapshot.active)

        tracking.ingest(try frame(state: 2, x: 0.4))
        session.close(.linkLost)
        let count = camera.sent.count
        tracking.cancel()
        XCTAssertFalse(tracking.snapshot.active, "cleared locally without a link")
        XCTAssertEqual(camera.sent.count, count)
    }

    func testTapFocusSendsTheOfficialUprightROIKeptInsideTheFrame() async throws {
        let camera = FakeLuna()
        let session = camera.connectedSession()
        let tracking = LunaSubjectTracking(session: { session })
        let outcome = try await run { try tracking.focus(x: 0.98, y: 0.5, finished: $0) }
        XCTAssertNil(outcome)
        XCTAssertEqual(
            camera.sent.last,
            try LunaProtocol.setTapFocus(
                x: 1 - 0.1545, y: 0.5 - 0.2727 / 2, width: 0.1545, height: 0.2727,
                functionMode: LunaFunctionMode.normalVideo.rawValue))
    }

    func testARequestTheSessionDoesNotAdmitFailsAndClearsTheSearch() async throws {
        let camera = FakeLuna()
        let session = camera.makeSession()
        let tracking = LunaSubjectTracking(session: { session })
        XCTAssertFalse(tracking.admitsControl)
        let outcome = try await run {
            try tracking.start(Box(x: 0.3, y: 0.2, width: 0.2, height: 0.4), finished: $0)
        }
        XCTAssertNotNil(outcome)
        XCTAssertFalse(tracking.snapshot.active)
        XCTAssertTrue(camera.sent.isEmpty)
    }
}
